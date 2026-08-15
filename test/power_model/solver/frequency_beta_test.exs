defmodule PowerModel.Solver.FrequencyBetaTest do
  @moduledoc """
  β = ΔP/Δf validation against the NERC BAL-003 anchors — the acceptance gate
  for ROADMAP item 14 (deliverable primary response).

  β is the interconnection's frequency response: the megawatts lost divided by
  the frequency deviation that loss settles at, quoted per 0.1 Hz. It is an
  EVENT ratio, not a differential slope — NERC reads it between the
  pre-disturbance average (value A) and the settling point 20–52 s later
  (value B) — so this test reads it the same way, via
  `Frequency.mean_frequency/3` over that window.

  ## Why this test exists

  The 2026-08-15 accuracy exploration measured the model delivering 5–16x too
  much primary response: every synchronous machine online answering at its
  nameplate 5% droop, nuclear included, gives ≈3.33% of online rating per
  0.1 Hz. Nadirs came out too shallow, UFLS under-fired, and cascades settled
  where a real system would have kept falling. Item 14 replaced that with
  deliverable response — governor duty, duty share, delivery rate limits and a
  deadband — and this is the number that says whether the replacement is
  right.

  ## The bands, and why they are shaped this way

  Two published anchors bracket a correct answer:

    * the **Frequency Response Obligation** (FRO) each interconnection is
      allocated under NERC BAL-003 — a FLOOR, the response an interconnection
      must be able to show; and
    * the **measured** response NERC's Frequency Response Annual Analysis
      reports for real events, which runs well above the obligation.

  A model that falls below the obligation is under-responsive; one that
  exceeds real measured response is back to over-delivering. The pass band is
  therefore `[FRO x (1 - 0.30), measured x (1 + 0.30)]` — ±30% around the
  anchors, in the direction each anchor constrains.

  Vintage caveat, stated rather than hidden: FRO values are reallocated
  annually and the measured medians move year to year. The Eastern FRO here is
  the ≈923 MW/0.1 Hz figure the project's own review cites; the others are the
  same-vintage order of magnitude. They are bands, not calibration targets, and
  a change of a few percent in the underlying standard does not move any
  verdict below.

  ## The operating point

  β depends on the operating point as much as on the response model, through
  one thing above all: HEADROOM. A unit at its cap answers nothing, whatever
  its droop. Real systems carry contingency reserve for exactly this reason;
  the model's fuel-anchored dispatch carries no reserve requirement at all
  (that is ROADMAP item 16), so measuring β on it would measure the dispatch,
  not the frequency model.

  The database test therefore builds its own documented operating point —
  merit-order commitment by capacity factor, every committed unit held at
  `1 - @reserve_margin` of its seasonal capability — and says so. It is
  deliberately independent of `PowerModel.Dispatch`: this test's subject is
  the response model.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias PowerModel.FleetRepo
  alias PowerModel.Grid.{Bus, Generator, Load}
  alias PowerModel.Solver.Frequency

  # NERC BAL-003 anchors per interconnection: {FRO, measured median},
  # both in MW per 0.1 Hz. See the moduledoc for what each one constrains.
  @anchors %{
    # The obligation figure this project's review cites for the Eastern
    # Interconnection; measured real response runs in the low thousands.
    "Eastern" => %{fro: 923.0, measured: 2600.0},
    "Western" => %{fro: 840.0, measured: 1500.0},
    "ERCOT" => %{fro: 381.0, measured: 700.0}
  }

  # ±30% around the anchors (ROADMAP item 14: "±30% is a pass").
  @tolerance 0.30

  # Design contingency per interconnection (MW) — the resource loss each one
  # sizes its frequency response against. Eastern and Western are two-unit
  # nuclear plant losses (Western's is the Palo Verde pair); ERCOT's is the
  # South Texas Project pair, its largest single hazard.
  @reference_trip_mw %{
    "Eastern" => 2600.0,
    "Western" => 2626.0,
    "ERCOT" => 1375.0
  }

  # Contingency reserve carried on governor-duty units, as a fraction of
  # seasonal capability. Real operators carry roughly their largest
  # contingency; 5% of committed capability is that order for all three
  # interconnections and is the documented operating point this test measures
  # at. See the moduledoc.
  @reserve_margin 0.05

  # BAL-003 reads the settling point ("value B") in this window after the
  # disturbance.
  @value_b_window {20.0, 52.0}

  defp band(name) do
    %{fro: fro, measured: measured} = Map.fetch!(@anchors, name)
    {fro * (1.0 - @tolerance), measured * (1.0 + @tolerance)}
  end

  # β from a fleet, a load total and a trip: simulate, read value B, divide.
  defp measure_beta(generators, load_mw, trip_mw) do
    {from_s, to_s} = @value_b_window

    {trajectory, _state} =
      Frequency.simulate_with_state(generators, [%{id: 1, p_mw: load_mw, q_mvar: 0.0}], trip_mw,
        dt_seconds: 0.1,
        duration_seconds: 60.0
      )

    value_b = Frequency.mean_frequency(trajectory, from_s, to_s)
    df = 60.0 - value_b

    %{
      beta: if(df > 0.0, do: trip_mw / df * 0.1, else: :infinity),
      value_b: value_b,
      df: df,
      nadir: Frequency.nadir(trajectory),
      shed_mw: List.last(trajectory).load_shed_mw,
      gov_mw: List.last(trajectory).gov_response_mw,
      collapsed?: Frequency.collapsed?(trajectory)
    }
  end

  # The β the fleet WOULD show if every governor-duty machine answered at its
  # nameplate 5% droop — the pre-item-14 model, computed straight from the
  # fleet so the regression guard needs no second implementation.
  defp nameplate_droop_slope(generators, load_mw) do
    governed =
      generators
      |> Enum.filter(&(&1.p_dispatch_mw > 0.0 and Frequency.governor_duty?(&1)))
      |> Enum.map(& &1.p_nameplate_mw)
      |> Enum.sum()

    # 0.1 Hz at 5% droop is 3.33% of rating; damping adds Pload/600 per 0.1 Hz.
    governed * (0.1 / 60.0) / 0.05 + load_mw * Frequency.load_damping() / 600.0
  end

  # ===========================================================================
  # Pure fixture: the mechanism, guarded without a database
  # ===========================================================================

  describe "β on a synthetic Eastern-scale fleet (no database)" do
    # The measured online fuel mix of the Eastern Interconnection at the
    # modelled hour, in GW of nameplate — enough plant of each kind to make
    # the fuel-weighted response meaningful, few enough units to stay fast.
    # Held at the same 5% reserve as the database test.
    @eastern_mix [
      {"NG", 110.0},
      {"NUC", 86.0},
      {"BIT", 61.0},
      {"WND", 42.0},
      {"WAT", 9.5},
      {"import", 9.3},
      {"BLQ", 4.3},
      {"DFO", 1.3},
      {"SUN", 1.2}
    ]

    @eastern_load_mw 300_000.0

    defp synthetic_fleet(reserve \\ @reserve_margin) do
      # 20 identical units per fuel: the per-unit caps in the response model
      # are proportional to nameplate, so the split is arithmetically neutral
      # and only keeps any single unit from being absurdly large.
      @eastern_mix
      |> Enum.with_index()
      |> Enum.flat_map(fn {{fuel, gw}, fuel_index} ->
        nameplate = gw * 1000.0 / 20.0
        output = nameplate * (1.0 - reserve)

        for unit <- 1..20 do
          %{
            id: fuel_index * 100 + unit,
            fuel_type: fuel,
            p_max_mw: output,
            capacity_factor: 1.0,
            p_dispatch_mw: output,
            p_nameplate_mw: nameplate
          }
        end
      end)
    end

    test "lands inside the Eastern BAL-003 band" do
      fleet = synthetic_fleet()
      trip = Map.fetch!(@reference_trip_mw, "Eastern")
      {low, high} = band("Eastern")

      result = measure_beta(fleet, @eastern_load_mw, trip)

      assert result.beta >= low and result.beta <= high,
             "β = #{Float.round(result.beta, 0)} MW/0.1 Hz is outside the Eastern band [#{Float.round(low, 0)}, #{Float.round(high, 0)}] (settled at #{Float.round(result.value_b, 3)} Hz)"

      # The design contingency must not reach the first UFLS stage: an
      # interconnection that sheds load for its own largest credible loss is
      # not meeting its obligation, whatever β says.
      assert result.nadir > 59.3
      assert result.shed_mw == 0.0
      refute result.collapsed?
    end

    test "is far below what nameplate droop would deliver (the item-14 fix)" do
      fleet = synthetic_fleet()
      trip = Map.fetch!(@reference_trip_mw, "Eastern")

      result = measure_beta(fleet, @eastern_load_mw, trip)
      naive = nameplate_droop_slope(fleet, @eastern_load_mw)

      # Nameplate droop on this fleet is ~9,600 MW/0.1 Hz. Deliverable
      # response is a fraction of it — the 5–16x over-delivery, removed.
      assert naive > 3.0 * result.beta,
             "β = #{Float.round(result.beta, 0)} is not meaningfully below the nameplate-droop #{Float.round(naive, 0)} MW/0.1 Hz"
    end

    test "β rises with headroom until the response model, not headroom, binds" do
      trip = Map.fetch!(@reference_trip_mw, "Eastern")

      betas =
        for reserve <- [0.01, 0.02, 0.05, 0.10] do
          measure_beta(synthetic_fleet(reserve), @eastern_load_mw, trip).beta
        end

      # Never falls: more headroom can only help.
      assert betas == Enum.sort(betas)

      # A reserve-starved fleet is measurably worse — this is the mechanism
      # that makes the operating point part of the measurement, and the reason
      # this test documents the one it uses.
      assert Enum.at(betas, 0) < Enum.at(betas, 2) * 0.9

      # ...and past a few percent it plateaus, because duty share and delivery
      # rate take over as the binding limits. Stockpiling reserve beyond that
      # buys no more primary response, which is the physically right shape.
      assert_in_delta Enum.at(betas, 2), Enum.at(betas, 3), 1.0e-6
    end

    test "nuclear contributes inertia but no primary response" do
      trip = Map.fetch!(@reference_trip_mw, "Eastern")
      with_nuclear = synthetic_fleet()
      without_nuclear = Enum.reject(with_nuclear, &(&1.fuel_type == "NUC"))

      settled = measure_beta(with_nuclear, @eastern_load_mw, trip)
      no_nuke = measure_beta(without_nuclear, @eastern_load_mw, trip)

      # 86 GW of nuclear moves the settling point by well under a tenth of a
      # percent — what remains is its rotor, not its governor.
      assert_in_delta settled.beta, no_nuke.beta, settled.beta * 0.001

      # The rotor is what it does contribute: dropping 86 GW of H = 6 s
      # inertia makes the same disturbance fall faster to a deeper nadir.
      assert no_nuke.nadir < settled.nadir
    end
  end

  # ===========================================================================
  # The real fleet
  # ===========================================================================

  describe "β per interconnection from the ingested fleet" do
    setup do
      case FleetRepo.connect() do
        :ok ->
          if FleetRepo.aggregate(Generator, :count) > 0 do
            :ok
          else
            {:skip, "development database has no ingested fleet"}
          end

        {:error, reason} ->
          {:skip, "development database unavailable: #{inspect(reason)}"}
      end
    end

    @tag :db
    @tag timeout: 300_000
    test "lands inside the BAL-003 band for every interconnection" do
      hour = modal_demand_hour()
      season = if hour.month in 5..10, do: :summer, else: :winter
      ba_demand = ba_demand_for(hour)
      ba_baseline = ba_baseline_by_interconnection()

      results =
        for {ic_id, name} <- interconnections(), Map.has_key?(@anchors, name) do
          fleet =
            commit(fleet_for(ic_id), demand_for(name, ic_id, ba_demand, ba_baseline), season)

          load_mw = demand_for(name, ic_id, ba_demand, ba_baseline)
          trip = Map.fetch!(@reference_trip_mw, name)

          result =
            fleet
            |> measure_beta(load_mw, trip)
            |> Map.merge(%{
              name: name,
              load_mw: load_mw,
              trip_mw: trip,
              online_units: Enum.count(fleet, &(&1.p_dispatch_mw > 0.0)),
              governor_headroom_mw: governor_headroom(fleet),
              naive_beta: nameplate_droop_slope(fleet, load_mw)
            })

          report(result)
          result
        end

      assert length(results) == 3,
             "expected Eastern, Western and ERCOT; got #{inspect(Enum.map(results, & &1.name))}"

      for result <- results do
        {low, high} = band(result.name)

        assert is_number(result.beta),
               "#{result.name}: β is undefined — the island did not settle below nominal (shed #{result.shed_mw} MW)"

        assert result.beta >= low,
               "#{result.name}: β = #{Float.round(result.beta, 0)} MW/0.1 Hz is under-responsive (band floor #{Float.round(low, 0)}, FRO #{@anchors[result.name].fro})"

        assert result.beta <= high,
               "#{result.name}: β = #{Float.round(result.beta, 0)} MW/0.1 Hz still over-delivers (band ceiling #{Float.round(high, 0)}, measured anchor #{@anchors[result.name].measured})"

        # The design contingency is the loss the interconnection is built to
        # ride through without shedding customers.
        assert result.nadir > 59.3,
               "#{result.name}: the design contingency reached #{Float.round(result.nadir, 3)} Hz, below the first UFLS stage"

        assert result.shed_mw == 0.0
        refute result.collapsed?

        # And the over-delivery is gone, fleet by fleet.
        assert result.naive_beta > 2.0 * result.beta,
               "#{result.name}: β = #{Float.round(result.beta, 0)} is not meaningfully below nameplate droop's #{Float.round(result.naive_beta, 0)}"
      end
    end

    defp report(r) do
      {low, high} = band(r.name)

      IO.puts("""

      ── β = ΔP/Δf — #{r.name} ────────────────────────────────
        demand                #{Float.round(r.load_mw / 1000, 1)} GW over #{r.online_units} committed units
        governor headroom     #{Float.round(r.governor_headroom_mw / 1000, 2)} GW
        design contingency    #{Float.round(r.trip_mw, 0)} MW
        nadir                 #{Float.round(r.nadir, 3)} Hz
        settling (value B)    #{Float.round(r.value_b, 3)} Hz  (Δf = #{Float.round(r.df, 3)} Hz)
        governor response     #{Float.round(r.gov_mw, 0)} MW
        β                     #{Float.round(r.beta, 0)} MW/0.1 Hz
        BAL-003 band          #{Float.round(low, 0)} … #{Float.round(high, 0)}  (FRO #{@anchors[r.name].fro}, measured #{@anchors[r.name].measured})
        nameplate droop would #{Float.round(r.naive_beta, 0)} MW/0.1 Hz
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # Fleet and operating point, read from the development database
  # ---------------------------------------------------------------------------

  defp interconnections do
    FleetRepo.all(from(i in PowerModel.Grid.Interconnection, select: {i.id, i.name}))
  end

  # The hour the largest number of balancing authorities reported (ENE-13: the
  # file's boundary hour has only a third of them).
  defp modal_demand_hour do
    counts =
      FleetRepo.all(
        from(d in PowerModel.Demand.BADemandHour,
          group_by: d.timestamp_utc,
          select: {d.timestamp_utc, count(d.id)}
        )
      )

    {hour, _} = Enum.max_by(counts, fn {ts, n} -> {n, DateTime.to_unix(ts)} end)
    hour
  end

  defp ba_demand_for(hour) do
    FleetRepo.all(
      from(d in PowerModel.Demand.BADemandHour,
        where: d.timestamp_utc == ^hour,
        select: {d.balancing_authority_id, d.demand_mw}
      )
    )
    |> Map.new()
  end

  # Baseline load per {BA, interconnection}, which is how a BA's measured
  # demand is split when it straddles a seam (ENE-17).
  defp ba_baseline_by_interconnection do
    FleetRepo.all(
      from(l in Load,
        join: b in Bus,
        on: b.id == l.bus_id,
        where: l.status == "in_service" and not is_nil(b.balancing_authority_id),
        group_by: [b.balancing_authority_id, b.interconnection_id],
        select: {b.balancing_authority_id, b.interconnection_id, sum(l.p_mw)}
      )
    )
  end

  defp demand_for(_name, ic_id, ba_demand, ba_baseline) do
    totals =
      Enum.reduce(ba_baseline, %{}, fn {ba, _ic, mw}, acc ->
        Map.update(acc, ba, mw || 0.0, &(&1 + (mw || 0.0)))
      end)

    ba_baseline
    |> Enum.filter(fn {_ba, ic, _mw} -> ic == ic_id end)
    |> Enum.reduce(0.0, fn {ba, _ic, mw}, acc ->
      total = Map.get(totals, ba, 0.0)
      share = if total > 0.0, do: (mw || 0.0) / total, else: 0.0
      acc + (Map.get(ba_demand, ba) || 0.0) * share
    end)
  end

  defp fleet_for(ic_id) do
    FleetRepo.all(
      from(g in Generator,
        join: b in Bus,
        on: b.id == g.bus_id,
        where:
          g.status == "in_service" and b.interconnection_id == ^ic_id and
            not is_nil(b.coordinates),
        select: %{
          id: g.id,
          fuel_type: g.fuel_type,
          p_max_mw: g.p_max_mw,
          summer_capacity_mw: g.summer_capacity_mw,
          winter_capacity_mw: g.winter_capacity_mw,
          capacity_factor: g.capacity_factor
        }
      )
    )
  end

  # Documented operating point (see the moduledoc): commit units in
  # capacity-factor order until committed capability covers demand plus the
  # reserve margin, and hold every committed unit at `1 - reserve` of its
  # seasonal capability so the reserve is real headroom a governor can reach.
  # Uncommitted units are OFFLINE — zero inertia, zero governor — which is the
  # same convention the dispatch and the swing model already share.
  defp commit(generators, demand_mw, season) do
    target = demand_mw * (1.0 + @reserve_margin)

    {committed, _} =
      generators
      |> Enum.sort_by(&(-(&1.capacity_factor || 0.0)))
      |> Enum.map_reduce(0.0, fn gen, committed_mw ->
        capability = seasonal_capability(gen, season)

        if committed_mw < target and capability > 0.0 do
          output = capability * (1.0 - @reserve_margin)
          {shape(gen, output), committed_mw + capability}
        else
          {shape(gen, 0.0), committed_mw}
        end
      end)

    committed
  end

  # EIA-860 seasonal net capability, guarded against the handful of rows whose
  # reported winter capability runs far above nameplate.
  defp seasonal_capability(gen, :summer),
    do: capability(gen.summer_capacity_mw, gen.p_max_mw)

  defp seasonal_capability(gen, :winter),
    do: capability(gen.winter_capacity_mw, gen.p_max_mw)

  defp capability(nil, nameplate), do: nameplate
  defp capability(seasonal, nameplate), do: min(seasonal, nameplate * 1.15)

  # The solver shape the cascade uses: p_max_mw carries dispatched MW, the
  # physical values ride along.
  defp shape(gen, output_mw) do
    %{gen | p_max_mw: output_mw, capacity_factor: if(output_mw > 0.0, do: 1.0, else: 0.0)}
    |> Map.put(:p_dispatch_mw, output_mw)
    |> Map.put(:p_nameplate_mw, gen.p_max_mw)
  end

  defp governor_headroom(fleet) do
    fleet
    |> Enum.filter(&(&1.p_dispatch_mw > 0.0 and Frequency.governor_duty?(&1)))
    |> Enum.map(&max(&1.p_nameplate_mw - &1.p_dispatch_mw, 0.0))
    |> Enum.sum()
  end
end
