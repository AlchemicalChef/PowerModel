defmodule PowerModel.Demand do
  @moduledoc """
  Actual electricity demand from EIA-930, applied to grid snapshots.

  The synthetic loads created by `PowerModel.Ingestion.LoadEstimator` define
  WHERE demand sits (per-bus spatial weights); EIA-930 defines HOW MUCH each
  balancing authority actually consumed in a given hour. `scale_loads/3`
  reconciles the two at snapshot-build time by rescaling each load with its
  BA's factor. The `loads` table is never rewritten, so concurrent
  simulations can use different hours.

  ## The scaling rule (ENE-17)

  A BA's factor is its actual demand divided by the BA's TOTAL baseline over
  ALL its geolocated loads in the database — never by the baseline of
  whatever slice of the BA a particular snapshot happens to hold:

      factor(BA) = (actual_demand(BA, hour) − flat_datacenter_mw(BA))
                   / total_geolocated_baseline(BA)

  The denominator is a property of the BA, not of the snapshot, so a bus
  carries the same MW whether or not its siblings made it into the snapshot,
  and identical loads in a regional and a national run scale identically.

  The consequence is deliberate: **a snapshot serves its genuine share of
  real demand, not 100% of it.** A snapshot holding 30% of a BA's baseline
  serves ~30% of that BA's demand. Scoped served load therefore drops
  compared with the pre-ENE-17 behaviour, which concentrated a BA's whole
  demand onto whatever buses survived (measured: MISO's 69 GW landing on
  stray ERCOT-labelled buses at 17.2×, AECI at 191×). This aligns the load
  universe with the generation universe — `PowerModel.Dispatch` likewise
  places only the measured MW that found a mapped unit — so balance metrics
  compare two populations covering the same fraction of the real network.
  `baseline_coverage/2` reports each BA's scoped/total share, and
  `scale_loads/3` logs it, so the share a run represents is always visible.

  The generation side reads the same share back out through
  `snapshot_load_shares/1`: `PowerModel.Dispatch` offers a BA's units their
  share of that BA's measured MW, so the two sides of every balance metric
  are scaled by one number (REVIEW ENE-20). Dispatch cannot recompute it from
  the snapshot's loads — they have already been scaled by the time it runs —
  which is why the share is read from the untouched table instead.

  Loads on buses without a BA assignment (run `mix power_model.ingest map_bas`)
  or in BAs without demand data for the hour keep their baseline values. A BA
  with no geolocated loads in the database (synthetic fixtures, an un-ingested
  network) falls back to the snapshot's own baseline as the denominator.

  Datacenter loads (`load_type: "datacenter"`) are held FLAT: datacenters run
  near-constant 24/7 and do not follow the residential/commercial demand
  shape. The BA's total datacenter MW is subtracted from its actual demand
  before computing the scale factor for the remaining loads, so summing a
  BA's served load over snapshots that partition its buses still reproduces
  its actual demand exactly.

  Note: water-facility loads merged into bus loads are scaled along with
  everything else; the small distortion of nominally-fixed industrial load is
  accepted.
  """

  require Logger

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator, Load}

  # Per-BA scale factors outside this range usually indicate bad demand data
  # or a badly skewed baseline; they are applied but logged.
  @sane_factor_range {0.05, 2.0}

  # EIA's own published identity, `net_generation - (demand + interchange)`,
  # counts as CLOSED for an hour when it lands inside this tolerance — the
  # same shape `PowerModel.Ingestion.Validation` screens balance rows with,
  # widened to 5% because this screen is looking for a systematic bias, not
  # for rounding (REVIEW ENE-18).
  @identity_tolerance_mw 50.0
  @identity_tolerance_rel 0.05

  # A BA is only called persistently broken on a real history (a handful of
  # hours is a gap, not a pattern) and only when the identity fails on MOST
  # of it. Measured 2026-08-15: BPAT closes 0 of 4,417 hours, MISO 4,389 of
  # 4,389, CISO 2,090 of 2,473 — so this screen catches BPAT alone.
  @identity_min_hours 24
  @identity_max_closure 0.5

  @doc """
  The `{min, max}` UTC timestamps covered by ingested demand data,
  or nil when no data is loaded.
  """
  def available_range do
    case Repo.one(
           from d in BADemandHour,
             select: {min(d.timestamp_utc), max(d.timestamp_utc)}
         ) do
      {nil, _} -> nil
      {_, nil} -> nil
      {min_ts, max_ts} -> {min_ts, max_ts}
    end
  end

  @doc """
  The most recent UTC hour with COMPLETE ingested EIA-930 demand, or nil when
  no demand data is loaded. Used as the default simulation hour so that
  simulations run against real demand rather than the ~2x synthetic baseline.

  ENE-13: the last hour in a bulk file is a boundary hour that only the BAs
  which had already reported appear in — measured at 17 of 53 BAs. Defaulting
  to it left two-thirds of the country on the synthetic baseline while looking
  like a real-demand run. An hour therefore qualifies only if the number of
  BAs reporting it is at least the MODAL count across all hours minus one (the
  slack absorbs a single BA's routine gap without accepting a truncated hour).
  """
  def latest_demand_hour do
    hour_counts =
      from d in BADemandHour,
        group_by: d.timestamp_utc,
        select: %{hour: d.timestamp_utc, bas: count(d.id)}

    modal_bas =
      Repo.one(
        from hc in subquery(hour_counts),
          group_by: hc.bas,
          order_by: [desc: count(hc.bas), desc: hc.bas],
          limit: 1,
          select: hc.bas
      )

    case modal_bas do
      nil ->
        nil

      modal_bas ->
        threshold = max(modal_bas - 1, 1)

        Repo.one(
          from hc in subquery(hour_counts),
            where: hc.bas >= ^threshold,
            select: max(hc.hour)
        )
    end
  end

  @doc """
  Per-fuel net generation for the given hour, as
  `%{ba_id => %{fuel => net_generation_mw}}`.

  Rows are stored against the EIA BA code; codes with no
  `balancing_authorities` row (hence no buses) are dropped. Returns an empty
  map when the hour has no per-fuel data, which is how `PowerModel.Dispatch`
  detects that it must decline.
  """
  def fuel_generation_at(%DateTime{} = timestamp) do
    hour = truncate_to_hour(timestamp)

    from(f in BAFuelHour,
      join: ba in BalancingAuthority,
      on: ba.code == f.ba_code,
      where: f.timestamp_utc == ^hour,
      select: {ba.id, f.fuel, f.net_generation_mw}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ba_id, fuel, mw}, acc ->
      Map.update(acc, ba_id, %{fuel => mw}, &Map.put(&1, fuel, mw))
    end)
  end

  @doc """
  Whether any BA reported per-fuel generation for the given hour.
  """
  def fuel_data_available?(%DateTime{} = timestamp) do
    hour = truncate_to_hour(timestamp)

    Repo.exists?(from f in BAFuelHour, where: f.timestamp_utc == ^hour)
  end

  @doc """
  Total interchange per balancing authority for the given hour:
  `%{ba_id => interchange_mw}` (positive = net exporter).

  EIA's own accounting of what each BA sent to its neighbors — the figure a
  dispatch built from absolute per-fuel MW should reproduce as
  generation minus load.
  """
  def interchange_at(%DateTime{} = timestamp) do
    hour = truncate_to_hour(timestamp)

    from(d in BADemandHour,
      where: d.timestamp_utc == ^hour and not is_nil(d.total_interchange_mw),
      select: {d.balancing_authority_id, d.total_interchange_mw}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Actual demand per balancing authority for the given hour:
  `%{ba_id => demand_mw}`.
  """
  def demand_at(%DateTime{} = timestamp) do
    hour = truncate_to_hour(timestamp)

    Repo.all(
      from d in BADemandHour,
        where: d.timestamp_utc == ^hour,
        select: {d.balancing_authority_id, d.demand_mw}
    )
    |> Map.new()
  end

  @doc """
  Per-BA scale factors for the given hour, applied to NON-datacenter loads:
  `(actual_BA_demand(hour) − flat_datacenter_mw) / total_geolocated_baseline`.

  The denominator is the BA's whole geolocated load baseline in the database,
  NOT the part of it this snapshot contains (ENE-17) — see the moduledoc. It
  falls back to the snapshot's own baseline only for BAs the database has no
  geolocated loads for.

  BAs with no non-datacenter load in the snapshot, without demand data for
  the hour, or with a non-positive demand row are omitted (their loads stay
  at baseline).
  """
  def ba_scale_factors(loads, buses, %DateTime{} = timestamp) do
    ba_scale_factors(loads, buses, timestamp, universe_baselines())
  end

  defp ba_scale_factors(loads, buses, timestamp, universe) do
    bus_to_ba = bus_to_ba(buses)
    demand = demand_at(timestamp)
    {scoped_baseline, scoped_dc} = scoped_sums(loads, bus_to_ba)

    {min_sane, max_sane} = @sane_factor_range

    scoped_baseline
    |> Enum.flat_map(fn {ba_id, scoped_mw} ->
      with true <- scoped_mw > 0.0,
           demand_mw when is_number(demand_mw) <- Map.get(demand, ba_id),
           true <- positive_demand_or_warn(ba_id, demand_mw, scoped_mw) do
        {baseline_mw, dc_mw} =
          denominator(ba_id, scoped_mw, Map.get(scoped_dc, ba_id, 0.0), universe)

        target_mw = demand_mw - dc_mw

        if target_mw < 0.0 do
          Logger.warning(
            "Flat datacenter load #{round1(dc_mw)} MW exceeds BA #{ba_id} actual " <>
              "demand #{round1(demand_mw)} MW at this hour -- " <>
              "datacenter estimates likely too high; scaling other loads to zero"
          )
        end

        factor = max(target_mw, 0.0) / baseline_mw

        if factor < min_sane or factor > max_sane do
          Logger.warning(
            "EIA-930 scale factor #{Float.round(factor, 3)} for BA #{ba_id} is outside " <>
              "[#{min_sane}, #{max_sane}] (demand #{round1(demand_mw)} MW, " <>
              "flat DC #{round1(dc_mw)} MW, total geolocated baseline " <>
              "#{round1(baseline_mw)} MW) -- check demand data / baseline"
          )
        end

        [{ba_id, factor}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp bus_to_ba(buses), do: Map.new(buses, &{&1.id, Map.get(&1, :balancing_authority_id)})

  # This snapshot's own per-BA sums: `{non_datacenter_mw, datacenter_mw}`.
  defp scoped_sums(loads, bus_to_ba) do
    Enum.reduce(loads, {%{}, %{}}, fn load, {base, dc} ->
      case Map.get(bus_to_ba, load.bus_id) do
        nil ->
          {base, dc}

        ba_id ->
          if datacenter_load?(load) do
            {base, Map.update(dc, ba_id, load.p_mw, &(&1 + load.p_mw))}
          else
            {Map.update(base, ba_id, load.p_mw, &(&1 + load.p_mw)), dc}
          end
      end
    end)
  end

  # ENE-17: the denominator is the BA's TOTAL geolocated baseline, so a
  # snapshot holding part of a BA gets its share of the BA's demand rather
  # than all of it. A BA the database has no geolocated loads for (synthetic
  # fixtures, un-ingested network) — or one whose in-snapshot baseline somehow
  # exceeds the database total — keeps the snapshot-scoped denominator, which
  # is the best available estimate of its universe.
  defp denominator(ba_id, scoped_mw, scoped_dc_mw, universe) do
    case Map.get(universe, ba_id) do
      %{baseline_mw: total_mw, datacenter_mw: total_dc_mw} when total_mw >= scoped_mw ->
        {total_mw, total_dc_mw}

      _ ->
        {scoped_mw, scoped_dc_mw}
    end
  end

  # Every BA's whole load universe, in ONE query: in-service loads on
  # geolocated, BA-assigned buses. That is the same population the replay
  # harness measures its share over, so the load and generation sides of a
  # balance metric describe the same network.
  #
  # With `bus_ids` it is the same query restricted to a bus set, which is what
  # makes the numerator of `snapshot_load_shares/1` and the denominator here
  # two readings of one measurement.
  defp universe_baselines(bus_ids \\ nil) do
    from(l in Load,
      join: b in Bus,
      on: l.bus_id == b.id,
      where:
        l.status == "in_service" and not is_nil(b.coordinates) and
          not is_nil(b.balancing_authority_id),
      group_by: [b.balancing_authority_id, l.load_type],
      select: {b.balancing_authority_id, l.load_type, sum(l.p_mw)}
    )
    |> then(fn query ->
      if bus_ids, do: from([l, _b] in query, where: l.bus_id in ^bus_ids), else: query
    end)
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ba_id, load_type, mw}, acc ->
      mw = (mw || 0.0) * 1.0
      entry = Map.get(acc, ba_id, %{baseline_mw: 0.0, datacenter_mw: 0.0})

      entry =
        if load_type == "datacenter" do
          %{entry | datacenter_mw: entry.datacenter_mw + mw}
        else
          %{entry | baseline_mw: entry.baseline_mw + mw}
        end

      Map.put(acc, ba_id, entry)
    end)
  end

  @doc """
  What share of each BA's load universe a snapshot holds:
  `%{ba_id => %{snapshot_baseline_mw:, total_baseline_mw:, share:}}`.

  The share is the fraction of that BA's real demand the snapshot serves
  under the ENE-17 rule (non-datacenter loads only; datacenters are flat and
  carry their own absolute MW). BAs absent from the snapshot are omitted.
  """
  def baseline_coverage(loads, buses) do
    baseline_coverage(loads, bus_to_ba(buses), universe_baselines())
  end

  defp baseline_coverage(loads, bus_to_ba, universe) do
    {scoped_baseline, scoped_dc} = scoped_sums(loads, bus_to_ba)

    Map.new(scoped_baseline, fn {ba_id, scoped_mw} ->
      {total_mw, _dc_mw} = denominator(ba_id, scoped_mw, Map.get(scoped_dc, ba_id, 0.0), universe)

      {ba_id,
       %{
         snapshot_baseline_mw: scoped_mw,
         total_baseline_mw: total_mw,
         share: if(total_mw > 0.0, do: scoped_mw / total_mw, else: 0.0)
       }}
    end)
  end

  @doc """
  What share of each BA's load universe a set of buses holds:
  `%{ba_id => share in 0..1}`.

  The same quantity `baseline_coverage/2` reports, read straight from the
  `loads` table for an arbitrary bus set instead of from a snapshot's load
  list. That difference is the point: by the time `PowerModel.Dispatch` runs,
  the snapshot's loads have already been through `scale_loads/3` and no
  longer carry the baseline the share is defined against, while the table
  itself is never rewritten.

  Non-datacenter loads only — datacenters are held flat and carry absolute
  MW, so they are no part of the share the hourly curve is applied through
  (ENE-17). A BA with no load on the bus set is omitted; callers read an
  absent BA as 1.0, i.e. "no part of this BA's load universe is missing here".

  Because the read happens per call, connectivity repair that pulls off-main
  fragments back into the main component moves these shares toward 1.0 on
  their own, and the dispatch correction they drive retires itself
  (REVIEW ENE-20).
  """
  @spec snapshot_load_shares([integer()]) :: %{optional(integer()) => float()}
  def snapshot_load_shares([]), do: %{}

  def snapshot_load_shares(bus_ids) when is_list(bus_ids) do
    universe = universe_baselines()
    scoped = universe_baselines(bus_ids)

    Map.new(scoped, fn {ba_id, %{baseline_mw: scoped_mw}} ->
      {total_mw, _dc_mw} = denominator(ba_id, scoped_mw, 0.0, universe)

      {ba_id, if(total_mw > 0.0, do: min(scoped_mw / total_mw, 1.0), else: 0.0)}
    end)
  end

  @doc """
  Balancing authorities whose own EIA-930 identity — `net_generation −
  (demand + interchange)` — is persistently broken:
  `%{ba_id => %{hours:, closed:, closure_rate:, mean_error_mw:}}`.

  REVIEW ENE-18 recorded three such BAs by name. That list is not a constant:
  the ENE-16 re-ingest fixed two of them, and a re-ingest can fix or break
  others. So the screen is a measurement, taken per call — a BA qualifies
  only with at least #{@identity_min_hours} hours of history and a closure
  rate below #{trunc(@identity_max_closure * 100)}%.

  `PowerModel.Dispatch` uses it to anchor a screened BA's generation budget on
  `demand + interchange` rather than on a net-generation column that cannot be
  reconciled with either.
  """
  @spec broken_identity_bas() :: %{optional(integer()) => map()}
  def broken_identity_bas do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT d.balancing_authority_id,
               count(*),
               count(*) FILTER (
                 WHERE abs(d.net_generation_mw - (d.demand_mw + d.total_interchange_mw))
                       <= greatest($1, $2 * abs(d.demand_mw))),
               avg(d.net_generation_mw - (d.demand_mw + d.total_interchange_mw))
        FROM ba_demand_hourly d
        WHERE d.demand_mw IS NOT NULL AND d.demand_mw > 0
          AND d.net_generation_mw IS NOT NULL
          AND d.total_interchange_mw IS NOT NULL
        GROUP BY 1
        """,
        [@identity_tolerance_mw, @identity_tolerance_rel]
      )

    for [ba_id, hours, closed, mean_error] <- rows,
        hours >= @identity_min_hours,
        closed / hours < @identity_max_closure,
        into: %{} do
      {ba_id,
       %{
         hours: hours,
         closed: closed,
         closure_rate: closed / hours,
         mean_error_mw: (mean_error || 0.0) * 1.0
       }}
    end
  end

  @doc """
  Generation anchor at `timestamp` for every BA `broken_identity_bas/0`
  screens in: `%{ba_id => demand_mw + total_interchange_mw}`.

  What the BA's fleet must have produced to serve the demand and interchange
  EIA published for it, which for a screened BA is the only self-consistent
  reading of its row.
  """
  @spec broken_identity_anchors(DateTime.t()) :: %{optional(integer()) => float()}
  def broken_identity_anchors(%DateTime{} = timestamp) do
    screened = broken_identity_bas()

    if map_size(screened) == 0 do
      %{}
    else
      hour = truncate_to_hour(timestamp)
      ba_ids = Map.keys(screened)

      from(d in BADemandHour,
        where:
          d.timestamp_utc == ^hour and d.balancing_authority_id in ^ba_ids and
            not is_nil(d.demand_mw) and not is_nil(d.total_interchange_mw),
        select: {d.balancing_authority_id, d.demand_mw + d.total_interchange_mw}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  # ENE-9: a zero/negative demand row would produce factor 0.0 and black out
  # the whole BA. Keep those loads at baseline instead, loudly.
  defp positive_demand_or_warn(_ba_id, demand_mw, _baseline_mw) when demand_mw > 0.0, do: true

  defp positive_demand_or_warn(ba_id, demand_mw, baseline_mw) do
    Logger.warning(
      "EIA-930 demand row for BA #{ba_id} is non-positive " <>
        "(#{round1(demand_mw)} MW) -- keeping #{round1(baseline_mw)} MW of baseline load " <>
        "instead of scaling to zero; check demand ingestion"
    )

    false
  end

  @doc """
  Scale snapshot loads to the actual demand of the given hour.

  Returns the load list with `p_mw`/`q_mvar` multiplied by each load's BA
  factor (q scales identically, preserving power factor). Loads without an
  applicable factor are returned unchanged.

  The snapshot serves its SHARE of each BA's demand, not the whole of it —
  see the moduledoc (ENE-17). The share per BA is logged and available from
  `baseline_coverage/2`.

  When NO load in the snapshot can be matched to a BA, the uniform NATIONAL
  fallback (snapshot total -> sum of all reporting BAs) is applied ONLY when
  the snapshot is national in scope: its buses either carry no
  interconnection metadata at all (synthetic MATPOWER networks) or span
  multiple interconnections. A REGIONAL snapshot (all buses in one
  interconnection, e.g. an un-BA-mapped ERCOT snapshot) is left at baseline
  with a warning -- scaling one interconnection to national demand would
  inflate it severalfold (ENE-2).
  """
  def scale_loads(loads, buses, %DateTime{} = timestamp) do
    universe = universe_baselines()
    factors = ba_scale_factors(loads, buses, timestamp, universe)
    bus_to_ba = bus_to_ba(buses)

    if map_size(factors) == 0 do
      national_fallback_or_baseline(loads, buses, bus_to_ba, timestamp)
    else
      {scaled_loads, unscaled_by_ba} =
        Enum.map_reduce(loads, %{}, fn load, unscaled ->
          ba_id = Map.get(bus_to_ba, load.bus_id)
          factor = if ba_id, do: Map.get(factors, ba_id)

          cond do
            # Datacenters run flat -- never shaped by the hourly curve
            datacenter_load?(load) ->
              {load, unscaled}

            factor == nil ->
              {load, Map.update(unscaled, ba_id, load.p_mw, &(&1 + load.p_mw))}

            true ->
              f = factor
              {%{load | p_mw: load.p_mw * f, q_mvar: (load.q_mvar || 0.0) * f}, unscaled}
          end
        end)

      if map_size(unscaled_by_ba) > 0, do: log_unscaled(unscaled_by_ba)

      log_coverage(baseline_coverage(loads, bus_to_ba, universe), factors)

      scaled_loads
    end
  end

  # ENE-17: served load is now the snapshot's SHARE of real demand. State the
  # share so no consumer reads a scoped total as national demand. One line
  # (DAT-20): per-BA detail is folded into it, not emitted per BA.
  defp log_coverage(coverage, factors) do
    scaled = Map.take(coverage, Map.keys(factors))

    if map_size(scaled) > 0 do
      snapshot_mw = scaled |> Map.values() |> Enum.map(& &1.snapshot_baseline_mw) |> Enum.sum()
      total_mw = scaled |> Map.values() |> Enum.map(& &1.total_baseline_mw) |> Enum.sum()

      partial =
        scaled
        |> Enum.filter(fn {_ba, c} -> c.share < 0.999 end)
        |> Enum.sort_by(&elem(&1, 1).share)

      codes = ba_codes(Enum.map(partial, &elem(&1, 0)))

      lowest =
        partial
        |> Enum.take(8)
        |> Enum.map_join(", ", fn {ba_id, c} ->
          "#{Map.get(codes, ba_id) || "BA #{ba_id}"} #{pct(c.share)}"
        end)

      Logger.info(
        "EIA-930 scaling: snapshot holds #{pct(safe_share(snapshot_mw, total_mw))} of the " <>
          "geolocated load baseline of the #{map_size(scaled)} scaled BAs " <>
          "(#{round1(snapshot_mw)} of #{round1(total_mw)} MW) and therefore serves that " <>
          "share of their real demand (ENE-17)" <>
          if(lowest == "",
            do: "",
            else:
              "; #{length(partial)} BAs partially covered, lowest: #{lowest}" <>
                if(length(partial) > 8, do: ", ...", else: "")
          )
      )
    end
  end

  defp safe_share(_num, denom) when denom <= 0.0, do: 0.0
  defp safe_share(num, denom), do: num / denom

  defp pct(share), do: "#{Float.round(share * 100.0, 1)}%"

  # ENE-8: partial EIA-930 coverage silently mixes real demand with the
  # (~2x) synthetic baseline. Report the MW involved and the BA codes so the
  # gap is visible, not just a load count.
  defp log_unscaled(unscaled_by_ba) do
    {unmapped_mw, by_ba} = Map.pop(unscaled_by_ba, nil, 0.0)
    total_mw = unmapped_mw + Enum.sum(Map.values(by_ba))
    codes = ba_codes(Map.keys(by_ba))

    ba_desc =
      by_ba
      |> Enum.map(fn {ba_id, mw} ->
        "#{Map.get(codes, ba_id) || "BA #{ba_id}"} (#{round1(mw)} MW)"
      end)
      |> Enum.sort()
      |> Enum.join(", ")

    Logger.warning(
      "EIA-930 scaling: #{round1(total_mw)} MW kept synthetic baseline, mixed with " <>
        "real demand -- #{round1(unmapped_mw)} MW on buses without a BA" <>
        if(ba_desc == "", do: "", else: "; BAs without applicable demand: #{ba_desc}")
    )
  end

  defp ba_codes([]), do: %{}

  defp ba_codes(ba_ids) do
    from(ba in BalancingAuthority, where: ba.id in ^ba_ids, select: {ba.id, ba.code})
    |> Repo.all()
    |> Map.new()
  end

  defp round1(value), do: Float.round(value * 1.0, 1)

  # ENE-2: the national fallback is only valid when the snapshot really is
  # national in scope (no interconnection filter) AND no load carries a BA.
  # A single-interconnection snapshot left un-BA-mapped stays at baseline.
  defp national_fallback_or_baseline(loads, buses, bus_to_ba, timestamp) do
    interconnections =
      buses
      |> Enum.map(&Map.get(&1, :interconnection_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ba_mapped_mw =
      loads
      |> Enum.filter(&(Map.get(bus_to_ba, &1.bus_id) != nil))
      |> Enum.map(& &1.p_mw)
      |> Enum.sum()

    regional? = match?([_], interconnections)

    cond do
      regional? ->
        total_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

        Logger.warning(
          "EIA-930 scaling: regional snapshot (interconnection #{hd(interconnections)}) " <>
            "has no BA-scalable loads; leaving #{round1(total_mw)} MW at synthetic " <>
            "baseline instead of scaling to national demand -- " <>
            "run `mix power_model.ingest map_bas` / `demand`"
        )

        loads

      ba_mapped_mw > 0.0 ->
        total_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

        Logger.warning(
          "EIA-930 scaling: #{round1(ba_mapped_mw)} MW of loads carry a BA but none " <>
            "matched demand data for this hour; leaving all #{round1(total_mw)} MW at " <>
            "synthetic baseline (national fallback suppressed)"
        )

        loads

      true ->
        scale_loads_to_national(loads, timestamp)
    end
  end

  # Uniform national scaling: snapshot total -> sum of all BA demand at the
  # hour. Used when per-BA mapping is impossible for the entire snapshot.
  # Flat datacenter loads are excluded from shaping and subtracted from the
  # national target, mirroring the per-BA treatment.
  defp scale_loads_to_national(loads, timestamp) do
    national_mw = timestamp |> demand_at() |> Map.values() |> Enum.sum()
    {dc_loads, other_loads} = Enum.split_with(loads, &datacenter_load?/1)
    dc_mw = Enum.sum(Enum.map(dc_loads, & &1.p_mw))
    baseline_mw = Enum.sum(Enum.map(other_loads, & &1.p_mw))

    if national_mw > 0.0 and baseline_mw > 0.0 do
      factor = max(national_mw - dc_mw, 0.0) / baseline_mw

      Logger.info(
        "EIA-930 scaling: no BA-mappable loads in snapshot; applying uniform " <>
          "national factor #{Float.round(factor, 3)} " <>
          "(actual #{Float.round(national_mw / 1000.0, 1)} GW, " <>
          "flat DC #{Float.round(dc_mw / 1000.0, 1)} GW, " <>
          "baseline #{Float.round(baseline_mw / 1000.0, 1)} GW)"
      )

      Enum.map(loads, fn l ->
        if datacenter_load?(l) do
          l
        else
          %{l | p_mw: l.p_mw * factor, q_mvar: (l.q_mvar || 0.0) * factor}
        end
      end)
    else
      Logger.warning(
        "No EIA-930 demand applicable at #{DateTime.to_iso8601(timestamp)} -- " <>
          "loads remain at synthetic baseline"
      )

      loads
    end
  end

  defp datacenter_load?(load), do: Map.get(load, :load_type) == "datacenter"

  # ---------------------------------------------------------------------------
  # Per-interconnection capacity / demand (utilization view)
  # ---------------------------------------------------------------------------

  @doc """
  Nameplate generation capacity of the modeled (geolocated) network per
  interconnection: `%{interconnection_id => capacity_mw}`.
  """
  def interconnection_capacity do
    from(g in Generator,
      join: b in Bus,
      on: g.bus_id == b.id,
      where:
        g.status == "in_service" and not is_nil(b.coordinates) and
          not is_nil(b.interconnection_id),
      group_by: b.interconnection_id,
      select: {b.interconnection_id, sum(g.p_max_mw)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Each balancing authority's interconnection, by majority vote of its buses:
  `%{ba_id => interconnection_id}`.
  """
  def ba_interconnection_map do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT DISTINCT ON (balancing_authority_id) balancing_authority_id, interconnection_id
      FROM (
        SELECT balancing_authority_id, interconnection_id, count(*) AS c
        FROM buses
        WHERE balancing_authority_id IS NOT NULL AND interconnection_id IS NOT NULL
        GROUP BY 1, 2
      ) t
      ORDER BY balancing_authority_id, c DESC
      """)

    Map.new(rows, fn [ba, ic] -> {ba, ic} end)
  end

  @doc """
  Actual hourly demand per interconnection for one UTC date:
  `%{interconnection_id => %{hour => demand_mw}}`.
  """
  def interconnection_demand_for_date(%Date{} = date) do
    start_ts = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_ts = DateTime.add(start_ts, 24 * 3600, :second)
    ba_ic = ba_interconnection_map()

    from(d in BADemandHour,
      where: d.timestamp_utc >= ^start_ts and d.timestamp_utc < ^end_ts,
      select: {d.balancing_authority_id, d.timestamp_utc, d.demand_mw}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ba_id, ts, mw}, acc ->
      case Map.get(ba_ic, ba_id) do
        nil ->
          acc

        ic ->
          Map.update(acc, ic, %{ts.hour => mw}, fn hours ->
            Map.update(hours, ts.hour, mw, &(&1 + mw))
          end)
      end
    end)
  end

  @doc """
  The UTC date with the highest single-hour national demand in the dataset.
  """
  def peak_demand_date do
    case Repo.one(
           from d in BADemandHour,
             group_by: d.timestamp_utc,
             order_by: [desc: sum(d.demand_mw)],
             limit: 1,
             select: d.timestamp_utc
         ) do
      nil -> nil
      ts -> DateTime.to_date(ts)
    end
  end

  # Shift to UTC FIRST, then truncate -- truncating wall-clock minutes in a
  # non-whole-hour-offset zone would yield a non-hour-aligned UTC timestamp
  # that matches no stored row.
  defp truncate_to_hour(%DateTime{} = ts) do
    ts = DateTime.shift_zone!(ts, "Etc/UTC")

    %{ts | minute: 0, second: 0, microsecond: {0, 0}}
    |> DateTime.truncate(:second)
  end
end
