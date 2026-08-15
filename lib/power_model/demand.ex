defmodule PowerModel.Demand do
  @moduledoc """
  Actual electricity demand from EIA-930, applied to grid snapshots.

  The synthetic loads created by `PowerModel.Ingestion.LoadEstimator` define
  WHERE demand sits (per-bus spatial weights); EIA-930 defines HOW MUCH each
  balancing authority actually consumed in a given hour. `scale_loads/3`
  reconciles the two at snapshot-build time: within each BA, baseline loads
  are rescaled so their sum equals that BA's actual demand for the selected
  hour. The `loads` table is never rewritten, so concurrent simulations can
  use different hours.

  Loads on buses without a BA assignment (run `mix power_model.ingest map_bas`)
  or in BAs without demand data for the hour keep their baseline values.

  Datacenter loads (`load_type: "datacenter"`) are held FLAT: datacenters run
  near-constant 24/7 and do not follow the residential/commercial demand
  shape. Their MW is subtracted from each BA's actual demand before computing
  the scale factor for the remaining loads, so the BA total still matches
  reality exactly.

  Note: water-facility loads merged into bus loads are scaled along with
  everything else; the small distortion of nominally-fixed industrial load is
  accepted.
  """

  require Logger

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator}

  # Per-BA scale factors outside this range usually indicate bad demand data
  # or a badly skewed baseline; they are applied but logged.
  @sane_factor_range {0.05, 2.0}

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
  The most recent UTC hour with ingested EIA-930 demand rows, or nil when no
  demand data is loaded. Used as the default simulation hour so that
  simulations run against real demand rather than the ~2x synthetic baseline.
  """
  def latest_demand_hour do
    Repo.one(from d in BADemandHour, select: max(d.timestamp_utc))
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
  `(actual_BA_demand(hour) − flat_datacenter_mw) / baseline_BA_load_sum`.

  BAs without demand data for the hour, or with a non-positive baseline,
  are omitted (their loads stay at baseline).
  """
  def ba_scale_factors(loads, buses, %DateTime{} = timestamp) do
    bus_to_ba = Map.new(buses, &{&1.id, Map.get(&1, :balancing_authority_id)})
    demand = demand_at(timestamp)

    {baseline_by_ba, dc_by_ba} =
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

    {min_sane, max_sane} = @sane_factor_range

    baseline_by_ba
    |> Enum.flat_map(fn {ba_id, baseline_mw} ->
      with true <- baseline_mw > 0.0,
           demand_mw when is_number(demand_mw) <- Map.get(demand, ba_id),
           true <- positive_demand_or_warn(ba_id, demand_mw, baseline_mw) do
        dc_mw = Map.get(dc_by_ba, ba_id, 0.0)
        target_mw = demand_mw - dc_mw

        if target_mw < 0.0 do
          Logger.warning(
            "Flat datacenter load #{Float.round(dc_mw, 1)} MW exceeds BA #{ba_id} actual " <>
              "demand #{Float.round(demand_mw, 1)} MW at this hour -- " <>
              "datacenter estimates likely too high; scaling other loads to zero"
          )
        end

        factor = max(target_mw, 0.0) / baseline_mw

        if factor < min_sane or factor > max_sane do
          Logger.warning(
            "EIA-930 scale factor #{Float.round(factor, 3)} for BA #{ba_id} is outside " <>
              "[#{min_sane}, #{max_sane}] (demand #{Float.round(demand_mw, 1)} MW, " <>
              "flat DC #{Float.round(dc_mw, 1)} MW, baseline #{Float.round(baseline_mw, 1)} MW) " <>
              "-- check demand data / baseline"
          )
        end

        [{ba_id, factor}]
      else
        _ -> []
      end
    end)
    |> Map.new()
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
    factors = ba_scale_factors(loads, buses, timestamp)
    bus_to_ba = Map.new(buses, &{&1.id, Map.get(&1, :balancing_authority_id)})

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

      scaled_loads
    end
  end

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
