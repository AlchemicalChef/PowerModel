defmodule PowerModel.Dispatch.Storage do
  @moduledoc """
  A charge/discharge schedule for grid batteries (ROADMAP item 17).

  EIA-930's dedicated `Battery Storage` column is blank for the whole 2024
  vintage: battery output hides inside `Other Fuel Sources`, which is why the
  `"other"` column goes deeply NEGATIVE when the fleet charges (CISO reaches
  -6,686 MW). `PowerModel.Dispatch` floors a negative fuel target at zero, so
  before this module a battery could only ever GENERATE — it was filled from a
  measurement that no longer described it, and the model produced energy no
  battery ever made while the charging half of the duty cycle vanished.

  This module replaces that with a schedule of its own. Storage is held OUT of
  the fuel-anchored pool the way onsite VRE is, and its MW — **negative while
  charging** — are subtracted from the `"other"` target so the remaining pool
  is asked for exactly the non-storage generation EIA measured.

  ## The duty cycle

  Storage arbitrages the BA's own net load: it charges when net load is low
  and discharges when net load is high. The schedule is built per BA, per day,
  from the BA's measured hourly demand minus its measured hourly utility-scale
  solar — the same two series the replay harness already reads.

  For the day's net-load series `n`:

      r = n - mean(n)                 # deviation from the day's mean
      u = r / max(|r|)                # in [-1, 1], and sum(u) = 0 exactly
      shape = g * u                   # g is a single per-BA gain

  A unit's MW for the hour is `capability_mw * shape`, positive discharging and
  negative charging. Three properties follow from the construction and are
  pinned by tests:

    * **SOC returns to its starting value every day.** `sum(u) = 0` holds
      identically because `r` is a deviation from the mean, and a single gain
      cannot break it. The day's charge MWh equal its discharge MWh, so a week
      of dispatch nets to zero energy rather than the phantom GWh above.
    * **Power respects nameplate in both directions**, because `|u| <= 1` and
      `g <= 1`.
    * **The daily cycle fits the energy capacity.** With `S = sum(max(u, 0))`,
      the day discharges `g * S` hours' worth of nameplate, and `g <= D / S`
      caps that at the 4 hours of `duration_hours/0`. The SOC excursion is
      bounded by the same figure, since the swing can never exceed the day's
      total charge.

  ### Duration

  EIA-860 schedule 3_4 (energy capacity, MWh) is not ingested, so duration is
  assumed: **4 hours, MWh = 4 x MW**, the standard for the utility-scale
  lithium fleet these units overwhelmingly are. When schedule 3_4 lands, this
  constant becomes a per-unit column and nothing else here changes.

  ### Which day

  The window is the UTC calendar day containing the hour. BA-local time is
  unavailable anyway — `balancing_authorities` carries no timezone and no tz
  database is vendored — but the deciding argument is stability: a window
  derived from the data (say, anchored on the BA's own net-load trough) moves
  as the surrounding hours move, and a boundary that shifts by an hour splits
  a day into two partial windows that no longer cancel. Measured on a week of
  ERCOT and CISO, that drift left 1-3% of the week's throughput as residual
  energy. A fixed partition cannot drift, and every window is exactly 24 h.

  What a UTC day costs is where the cycle RESETS, not whether it happens: the
  US battery fleet is overwhelmingly Western and ERCOT, and for both the
  midday trough and the evening peak fall well inside one UTC day (CISO's day
  runs 17:00-16:59 PDT, ERCOT's 19:00-18:59 CDT). Only BAs on Eastern time
  have their evening ramp near the 00:00 UTC boundary, and they hold about
  1 GW of the 27 GW fleet. SOC therefore does not start each window empty —
  CISO's starts full, just before the evening discharge — which is why the
  bound that matters is the SOC SWING fitting the energy capacity rather than
  the level starting at zero.

  ## The measurement is a ceiling on discharge

  Whatever the duty cycle proposes, the fleet is then held under the BA's own
  `"other"` column hour by hour. EIA measured that column as `non-storage
  generation + storage`, and non-storage generation is never negative, so the
  reported value is an upper bound on what the batteries can have discharged.
  Charging is scaled back by the same proportion the clamp removed, which
  keeps the day energy-neutral, and the clamp guarantees the pool target
  `reported - storage` never needs flooring on the discharge side — so the
  BA's generation still totals exactly what EIA reported.

  A BA with no `"other"` value for the hour at all is left IDLE (`:unreported`)
  rather than given a ceiling of zero: EIA publishes no column its battery
  output could be inside, and scheduling only the charging half would turn the
  fleet into invented load. 1,380 MW sits in such BAs — IID, HECO, WACM, WALC
  and four more.

  The ceiling is deliberately conservative and can understate. Measured on
  2024-07-15 through 07-21, it holds ERCOT's fleet to 32.4 GWh of discharge
  for the week because ERCOT's `"other"` column never exceeds 1,865 MW; if
  part of that fleet's output is reported somewhere other than `"other"`, the
  model will not find it. That is the intended direction of the error — the
  model no longer produces energy no measurement supports.

  ## Calibration against the "other" residual

  Where a BA's `"other"` column carries a clear charging signal — a value more
  negative than 5% of the storage fleet's capability somewhere in the day —
  the gain is scaled so the modeled fleet's deepest charging hour matches that
  observed negative, and coverage reports the BA as `:calibrated`. Everywhere
  else the duty cycle stands alone and the BA is reported as `:duty_cycle`.

  The observed negative is a FLOOR on charging, not a measurement of it: the
  same column carries geothermal, biomass and landfill gas, whose positive
  generation masks part of the charge. Calibration is therefore applied only
  where it REDUCES the gain (`min(1, ...)`), which keeps the schedule inside
  the nameplate and energy bounds above and keeps the model from inventing
  charging load it cannot evidence.

  ## Scope

  `storage?/1` matches EIA energy-source code `MWH` — batteries and flywheels,
  27.2 GW in service. **Pumped storage (`WAT` with prime mover `PS`, 21.0 GW)
  is deliberately not included**: EIA-930 reports it in its own column that
  this schema folds into `"other"`, and in the BAs where it concentrates
  (PJM, DUK, MISO, TVA) that column never goes negative, so there is no
  charging signal to calibrate against and no phantom-energy symptom of the
  kind batteries show. It stays in the fuel-anchored pool until its own
  schedule is built.

  Round-trip losses are not modeled: charge MWh equal discharge MWh at the
  terminals. Real storage is a small net LOAD (10-15% of throughput), so the
  model understates BA load by that much of the fleet's daily cycle.
  """

  import Ecto.Query

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Grid.BalancingAuthority
  alias PowerModel.Repo

  # EIA energy-source codes dispatched by this module. See "Scope" above for
  # why pumped storage is not one of them.
  @storage_fuel_codes ~w(MWH)

  # Hours of energy capacity per MW of nameplate (EIA-860 schedule 3_4 is not
  # ingested; see "Duration" above).
  @duration_hours 4.0

  # A charging signal in the "other" column counts as CLEAR at this share of
  # the BA's storage capability. Below it the column's swing is as likely to
  # be biomass or geothermal moving as it is to be a battery.
  @calibration_share 0.05

  # A day with fewer hours than this has too little of a profile to rank net
  # load against, and the previous day is used instead. When neither is
  # complete enough the BA's storage sits idle rather than guess.
  @min_window_hours 12

  @doc """
  Whether a generator is storage this module schedules.
  """
  def storage?(generator) do
    code = generator |> Map.get(:fuel_type) |> to_string() |> String.trim() |> String.upcase()
    code in @storage_fuel_codes
  end

  @doc """
  Assumed hours of energy capacity per MW of nameplate.
  """
  def duration_hours, do: @duration_hours

  @doc """
  The hourly net-load profile the schedule is shaped from, read from the
  database for `ba_ids` around `hour`.

  Returns `%{ba_id => [%{hour: DateTime.t(), net_load_mw: float, other_mw:
  float | nil}]}`, hours ascending, covering the UTC day the schedule is built
  from. `PowerModel.Dispatch` passes this shape straight through from its
  `:storage_profile` option, so fixtures can supply a profile without a repo;
  records outside the day are ignored rather than rejected.

  These are the BA's WHOLE published MW. A snapshot holding only part of a BA
  runs them through `scale_profile/2` first — see that function for why.
  """
  def profile([], _hour), do: %{}

  def profile(ba_ids, %DateTime{} = hour) do
    from_hour = DateTime.add(day_start(hour), -24 * 3600, :second)
    to_hour = DateTime.add(day_start(hour), 23 * 3600, :second)

    demand =
      from(d in BADemandHour,
        where:
          d.balancing_authority_id in ^ba_ids and d.timestamp_utc >= ^from_hour and
            d.timestamp_utc <= ^to_hour,
        select: {d.balancing_authority_id, d.timestamp_utc, d.demand_mw}
      )
      |> Repo.all()

    fuels =
      from(f in BAFuelHour,
        join: ba in BalancingAuthority,
        on: ba.code == f.ba_code,
        where:
          ba.id in ^ba_ids and f.fuel in ["solar", "other"] and f.timestamp_utc >= ^from_hour and
            f.timestamp_utc <= ^to_hour,
        select: {ba.id, f.timestamp_utc, f.fuel, f.net_generation_mw}
      )
      |> Repo.all()

    by_hour =
      Enum.reduce(fuels, %{}, fn {ba_id, ts, fuel, mw}, acc ->
        Map.update(acc, {ba_id, ts}, %{fuel => mw}, &Map.put(&1, fuel, mw))
      end)

    demand
    |> Enum.group_by(fn {ba_id, _ts, _mw} -> ba_id end)
    |> Map.new(fn {ba_id, rows} ->
      records =
        rows
        |> Enum.reject(fn {_ba, _ts, mw} -> is_nil(mw) end)
        |> Enum.map(fn {_ba, ts, demand_mw} ->
          measured = Map.get(by_hour, {ba_id, ts}, %{})

          %{
            hour: ts,
            net_load_mw: demand_mw - (Map.get(measured, "solar") || 0.0),
            other_mw: Map.get(measured, "other")
          }
        end)
        |> Enum.sort_by(& &1.hour, DateTime)

      {ba_id, records}
    end)
  end

  @doc """
  Rewrite a profile into the MW THIS snapshot's fleet is measured against:
  every `net_load_mw` and `other_mw` multiplied by the BA's snapshot share.

  REVIEW ENE-24. The duty cycle is bounded by the `"other"` column and sized
  against a fleet capability that only counts the snapshot's own units, but
  `profile/2` reads the BA's whole published series. `PowerModel.Dispatch`
  share-scales the fuel targets (ENE-20) before it schedules storage, so the
  hour being dispatched arrived scaled while the other 23 hours of the same
  window did not — `cap_to_measurement`'s ceiling and `gain/3`'s charging
  calibration then compared a snapshot-sized schedule against BA-sized
  columns, and the error grows with `1 - share`.

  An absent BA is 1.0 and share 1.0 returns the profile unchanged, so a
  repo-free fixture and a whole-BA snapshot are untouched.
  """
  def scale_profile(profile, shares) when is_map(profile) and is_map(shares) do
    Map.new(profile, fn {ba_id, records} ->
      case Map.get(shares, ba_id, 1.0) do
        share when is_number(share) and share != 1.0 ->
          {ba_id, Enum.map(records, &scale_record(&1, share))}

        _ ->
          {ba_id, records}
      end
    end)
  end

  defp scale_record(record, share) do
    %{
      record
      | net_load_mw: record.net_load_mw * share,
        other_mw: record.other_mw && record.other_mw * share
    }
  end

  @doc """
  Schedule `units` — `PowerModel.Dispatch` unit views carrying `:id`,
  `:ba_id` and `:capability_mw` — for `hour` against `profile`.

  `fuel_totals` is the hour's own measurement, `%{ba_id => %{fuel => mw}}`; its
  `"other"` entry is the authoritative ceiling on discharge for THIS hour, and
  binds where it is tighter than the day profile's (which is the borrowed
  previous day whenever the current one is still being ingested).

  Returns `{%{generator_id => mw}, %{ba_id => stat}}`, where MW are negative
  while charging. `p_min_mw` plays no part: a battery has no minimum stable
  load, and its inverter runs down to zero in both directions.
  """
  def schedule([], _hour, _profile, _fuel_totals), do: {%{}, %{}}

  def schedule(units, %DateTime{} = hour, profile, fuel_totals) do
    units
    |> Enum.group_by(& &1.ba_id)
    |> Enum.reduce({%{}, %{}}, fn {ba_id, ba_units}, {alloc, stats} ->
      reported_now = fuel_totals |> Map.get(ba_id, %{}) |> Map.get("other")
      {ba_alloc, stat} = schedule_ba(ba_units, hour, Map.get(profile, ba_id), reported_now)

      {Map.merge(alloc, ba_alloc), Map.put(stats, ba_id, stat)}
    end)
  end

  @doc """
  Subtract the modeled storage MW from each BA's `"other"` target.

  EIA-930's `"other"` column is a NET measurement: it already carries whatever
  the fleet's batteries were doing, so the generation left for biomass,
  geothermal and landfill gas is `reported - storage`. Subtracting a negative
  (charging) therefore RAISES the pool's target, which is the arithmetic that
  keeps the BA whole: pool target + storage MW = the MW EIA reported, so the
  interchange identity `generation - load = interchange` survives the carve-out
  intact.

  Floored at zero, since a pool cannot be asked for negative generation — the
  only case that floors is a BA whose reported `"other"` is more negative than
  the charging this module modeled.
  """
  def adjust_fuel_totals(fuel_totals, stats) when map_size(stats) == 0, do: fuel_totals

  def adjust_fuel_totals(fuel_totals, stats) do
    Enum.reduce(stats, fuel_totals, fn {ba_id, stat}, totals ->
      case totals |> Map.get(ba_id, %{}) |> Map.fetch("other") do
        {:ok, reported_mw} ->
          pool_mw = max(reported_mw - stat.net_mw, 0.0)

          Map.update!(totals, ba_id, &Map.put(&1, "other", pool_mw))

        :error ->
          totals
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Per-BA schedule
  # ---------------------------------------------------------------------------

  # A BA with no `"other"` value for the hour is left idle. EIA publishes no
  # column its battery output could be inside, so there is nothing to place
  # discharge into and nothing to bound it — and scheduling the charging half
  # alone would turn the fleet into pure invented load. 1,380 MW of the fleet
  # sits in such BAs (IID, HECO, WACM, WALC and four more).
  defp schedule_ba(units, _hour, _records, nil) do
    capability_mw = units |> Enum.map(& &1.capability_mw) |> Enum.sum()

    {Map.new(units, &{&1.id, 0.0}), idle_stat(units, capability_mw, :unreported)}
  end

  defp schedule_ba(units, hour, records, reported_now) do
    capability_mw = units |> Enum.map(& &1.capability_mw) |> Enum.sum()

    case day_shape(records, hour, capability_mw, reported_now) do
      nil ->
        {Map.new(units, &{&1.id, 0.0}), idle_stat(units, capability_mw, :no_profile)}

      day ->
        alloc = Map.new(units, &{&1.id, &1.capability_mw * day.shape})
        mw = alloc |> Map.values() |> Enum.sum()

        {alloc,
         %{
           net_mw: mw,
           charge_mw: -min(mw, 0.0),
           discharge_mw: max(mw, 0.0),
           units: length(units),
           charging_units: Enum.count(alloc, fn {_id, unit_mw} -> unit_mw < 0.0 end),
           capability_mw: capability_mw,
           duration_hours: @duration_hours,
           path: day.path,
           gain: day.gain,
           shape: day.shape,
           window_start: day.window_start,
           window_hours: day.window_hours,
           net_load_mw: day.net_load_mw,
           day_mean_net_load_mw: day.mean_net_load_mw,
           observed_other_min_mw: day.observed_other_min_mw
         }}
    end
  end

  defp idle_stat(units, capability_mw, path) do
    %{
      net_mw: 0.0,
      charge_mw: 0.0,
      discharge_mw: 0.0,
      units: length(units),
      charging_units: 0,
      capability_mw: capability_mw,
      duration_hours: @duration_hours,
      path: path,
      gain: 0.0,
      shape: 0.0,
      window_start: nil,
      window_hours: 0,
      net_load_mw: nil,
      day_mean_net_load_mw: nil,
      observed_other_min_mw: nil
    }
  end

  # ---------------------------------------------------------------------------
  # The duty cycle
  # ---------------------------------------------------------------------------

  # nil whenever there is no honest basis for a schedule: no profile, a window
  # too short to rank net load within, a flat day, or an hour the profile does
  # not cover. Storage then sits at zero, which is the one operating point that
  # cannot invent energy.
  defp day_shape(nil, _hour, _capability_mw, _reported_now), do: nil
  defp day_shape([], _hour, _capability_mw, _reported_now), do: nil

  defp day_shape(records, hour, capability_mw, reported_now) do
    window = day_window(records, hour)

    with true <- length(window) >= @min_window_hours,
         {:ok, index} <- hour_index(window, hour) do
      # The hour's own measurement outranks the profile's for the hour being
      # dispatched: the two differ only when the day was borrowed from
      # yesterday, and yesterday's column is the wrong ceiling for today.
      # Folding it in HERE rather than clamping the result afterwards keeps
      # the charge/discharge rebalance downstream of every ceiling, so the
      # fleet can never end up charging against a discharge that was cut.
      window = List.update_at(window, index, &%{&1 | other_mw: reported_now})
      net_loads = Enum.map(window, & &1.net_load_mw)
      mean = Enum.sum(net_loads) / length(net_loads)
      deviations = Enum.map(net_loads, &(&1 - mean))
      spread = deviations |> Enum.map(&abs/1) |> Enum.max()

      if spread <= 0.0 do
        nil
      else
        # sum(u) = 0 exactly, so the day's charge and discharge MWh match
        # whatever single gain is applied below.
        u = Enum.map(deviations, &(&1 / spread))
        {gain, path, observed_min} = gain(u, window, capability_mw)

        day_mw = u |> Enum.map(&(&1 * gain * capability_mw)) |> cap_to_measurement(window)

        %{
          shape: if(capability_mw > 0.0, do: Enum.at(day_mw, index) / capability_mw, else: 0.0),
          gain: gain,
          path: path,
          window_start: window |> List.first() |> Map.fetch!(:hour),
          window_hours: length(window),
          net_load_mw: Enum.at(net_loads, index),
          mean_net_load_mw: mean,
          observed_other_min_mw: observed_min
        }
      end
    else
      _ -> nil
    end
  end

  # EIA measured the "other" column as `non-storage generation + storage`, and
  # non-storage generation is never negative, so the column is a hard CEILING
  # on what the fleet can have discharged that hour. Holding the schedule
  # under it is what stops the carve-out from injecting MW the measurement
  # does not support: without this, a duty cycle at ERCOT's evening peak
  # discharged 2.5 GW that EIA's column never reported.
  #
  # Only the discharge side is bounded — the column says nothing about how
  # much MORE than `reported` the fleet absorbed, since generation in the same
  # column masks it (that is what the calibration in `gain/3` is for). Charging
  # is then scaled back by the same proportion the clamp removed, so the day
  # still ends where it started.
  defp cap_to_measurement(day_mw, window) do
    capped =
      day_mw
      |> Enum.zip(window)
      |> Enum.map(fn
        {mw, %{other_mw: reported}} when is_float(reported) and mw > 0.0 ->
          min(mw, max(reported, 0.0))

        {mw, _record} ->
          mw
      end)

    discharge_mwh = capped |> Enum.map(&max(&1, 0.0)) |> Enum.sum()
    charge_mwh = capped |> Enum.map(&(-min(&1, 0.0))) |> Enum.sum()

    if charge_mwh > 0.0 do
      scale = min(discharge_mwh / charge_mwh, 1.0)
      Enum.map(capped, fn mw -> if mw < 0.0, do: mw * scale, else: mw end)
    else
      capped
    end
  end

  # The gain that carries the normalized shape onto the fleet: capped by
  # nameplate, by the day's energy capacity, and — where the "other" column
  # evidences charging — by the depth of that evidence.
  defp gain(u, window, capability_mw) do
    discharge_hours = u |> Enum.map(&max(&1, 0.0)) |> Enum.sum()

    duty_gain =
      if discharge_hours > 0.0 do
        min(1.0, @duration_hours / discharge_hours)
      else
        0.0
      end

    charge_depth = -Enum.min(u)
    observed_min = observed_other_min(window)
    modeled_charge_mw = capability_mw * duty_gain * charge_depth

    clear_signal? =
      is_float(observed_min) and observed_min < -@calibration_share * capability_mw and
        modeled_charge_mw > 0.0

    if clear_signal? do
      {duty_gain * min(1.0, abs(observed_min) / modeled_charge_mw), :calibrated, observed_min}
    else
      {duty_gain, :duty_cycle, observed_min}
    end
  end

  defp observed_other_min(window) do
    window
    |> Enum.map(& &1.other_mw)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  # ---------------------------------------------------------------------------
  # The storage day
  # ---------------------------------------------------------------------------

  # The hours of the UTC calendar day containing `hour`, or — when that day is
  # still being ingested and too short to rank net load against — the previous
  # day's, read by hour-of-day.
  #
  # The fallback earns its place at the edge of the data, which is exactly
  # where the replay harness runs: the last day in an EIA-930 bulk file is a
  # few hours long, and leaving the fleet idle there both loses the cycle and
  # strands the battery share of the "other" column as unserved.
  defp day_window(records, hour) do
    today = records_for_day(records, day_start(hour))

    if length(today) >= @min_window_hours do
      today
    else
      records_for_day(records, DateTime.add(day_start(hour), -24 * 3600, :second))
    end
  end

  defp records_for_day(records, start) do
    finish = DateTime.add(start, 23 * 3600, :second)

    Enum.filter(records, fn record ->
      DateTime.compare(record.hour, start) != :lt and
        DateTime.compare(record.hour, finish) != :gt
    end)
  end

  defp day_start(%DateTime{} = hour) do
    %{hour | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  # Matched by hour-of-day rather than by instant, so that a window borrowed
  # from the previous day still places the hour on the same point of the cycle.
  defp hour_index(window, hour) do
    case Enum.find_index(window, &(&1.hour.hour == hour.hour)) do
      nil -> :error
      index -> {:ok, index}
    end
  end
end
