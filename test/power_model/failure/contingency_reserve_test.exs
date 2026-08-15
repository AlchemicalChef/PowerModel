defmodule PowerModel.Failure.ContingencyReserveTest do
  @moduledoc """
  REVIEW ENE-19: the fuel-anchored dispatch must carry contingency reserve.

  The finding this test exists to reverse, measured 2026-08-15 on the ingested
  fleet: ERCOT's operating point left ~1.27 GW of governor-duty headroom
  against a 1,375 MW design contingency, so the interconnection **shed
  customers for its own largest credible single loss** — nadir 59.282 Hz,
  ~3.36 GW of under-frequency load shedding. An interconnection that cannot
  ride out its own N-1 is not meeting the obligation the contingency is
  defined by, and the old nameplate-droop response model had been masking it.

  The acceptance test is the reversal: with the requirement held at dispatch
  time, the same trip on the same fleet at the same hour must produce no load
  shedding at all.

  A pure-fixture version of the same mechanism runs without a database; the
  interconnection-scale measurement needs the development fleet and skips
  without it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias PowerModel.Dispatch
  alias PowerModel.FleetRepo
  alias PowerModel.Grid.{Bus, Generator, Interconnection, Load}
  alias PowerModel.Solver.Frequency

  @trip_mw 1375.0

  # ===========================================================================
  # The mechanism, on a fixture
  # ===========================================================================

  describe "holding primary-capable spinning reserve" do
    # Twenty gas machines of 1 GW, and a measured 12 GW to place on them. A
    # plain merit fill loads twelve of them flat out and leaves eight cold: no
    # headroom on the committed units, no reserve anywhere.
    defp gas_fleet do
      for i <- 1..20 do
        %{
          id: i,
          bus_id: i,
          fuel_type: "NG",
          prime_mover: "CT",
          p_max_mw: 1000.0,
          summer_capacity_mw: 1000.0,
          winter_capacity_mw: 1000.0,
          capacity_factor: 0.5,
          status: "in_service"
        }
      end
    end

    defp dispatch_gas_fleet(requirement) do
      Application.put_env(:power_model, :contingency_reserve_mw, requirement)

      on_exit(fn -> Application.delete_env(:power_model, :contingency_reserve_mw) end)

      hour = ~U[2024-07-01 18:00:00Z]

      {:ok, result} =
        Dispatch.for_hour(gas_fleet(), hour,
          bus_ba: Map.new(1..20, &{&1, 1}),
          bus_interconnection: Map.new(1..20, &{&1, "ERCOT"}),
          fuel_totals: %{1 => %{"natural_gas" => 12_000.0}},
          storage_profile: %{}
        )

      result
    end

    test "a plain merit fill leaves the fleet with no reserve at all" do
      %{dispatch: dispatch, coverage: coverage} = dispatch_gas_fleet(%{})

      assert coverage.reserve.by_interconnection == %{}
      assert_in_delta Enum.sum(Map.values(dispatch)), 12_000.0, 1.0e-6

      # Twelve units at their capability, eight offline: nothing a governor
      # can reach.
      assert Enum.count(dispatch, fn {_id, mw} -> mw > 0.0 end) == 12
      assert Enum.count(dispatch, fn {_id, mw} -> mw >= 999.999 end) == 12
    end

    test "the requirement spreads the same MW over more units, each with headroom" do
      %{dispatch: dispatch, coverage: coverage} =
        dispatch_gas_fleet(%{"ERCOT" => @trip_mw})

      reserve = coverage.reserve.by_interconnection["ERCOT"]

      assert reserve.met?
      assert reserve.requirement_mw == @trip_mw
      assert reserve.primary_reserve_mw >= @trip_mw
      assert reserve.holdback_fraction > 0.0

      # The measurement is untouched — this is a commitment change, not a
      # generation change.
      assert_in_delta Enum.sum(Map.values(dispatch)), 12_000.0, 1.0e-6

      # ...and it is carried by more machines, none of them flat out.
      assert Enum.count(dispatch, fn {_id, mw} -> mw > 0.0 end) > 12
      assert Enum.all?(dispatch, fn {_id, mw} -> mw < 1000.0 end)
    end

    test "a fuel with no governor duty is left exactly as it was" do
      Application.put_env(:power_model, :contingency_reserve_mw, %{"ERCOT" => @trip_mw})
      on_exit(fn -> Application.delete_env(:power_model, :contingency_reserve_mw) end)

      nuclear =
        for i <- 21..24 do
          %{
            id: i,
            bus_id: i,
            fuel_type: "NUC",
            prime_mover: "ST",
            p_max_mw: 1000.0,
            summer_capacity_mw: 1000.0,
            winter_capacity_mw: 1000.0,
            capacity_factor: 0.9,
            status: "in_service"
          }
        end

      {:ok, %{dispatch: dispatch}} =
        Dispatch.for_hour(gas_fleet() ++ nuclear, ~U[2024-07-01 18:00:00Z],
          bus_ba: Map.new(1..24, &{&1, 1}),
          bus_interconnection: Map.new(1..24, &{&1, "ERCOT"}),
          fuel_totals: %{1 => %{"natural_gas" => 12_000.0, "nuclear" => 2500.0}},
          storage_profile: %{}
        )

      # Nuclear fills flat out as it always did: backing it down would buy no
      # frequency response, because its governors are not credited.
      nuclear_mw = for(i <- 21..24, do: Map.fetch!(dispatch, i))
      assert_in_delta Enum.sum(nuclear_mw), 2500.0, 1.0e-6
      assert Enum.count(nuclear_mw, &(&1 >= 999.999)) == 2
    end

    test "a requirement the fleet cannot meet holds what it can and says so" do
      %{coverage: coverage} = dispatch_gas_fleet(%{"ERCOT" => 100_000.0})

      reserve = coverage.reserve.by_interconnection["ERCOT"]

      refute reserve.met?
      assert reserve.primary_reserve_mw > 0.0
      assert reserve.holdback_fraction > 0.0
    end
  end

  # ===========================================================================
  # The acceptance test: ERCOT rides out its own N-1
  # ===========================================================================

  describe "ERCOT's design contingency on the ingested fleet" do
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
    test "the requirement turns a 3 GW shed into no shed at all" do
      context = fleet_context()
      requirements = Dispatch.contingency_reserves()

      without = evaluate(context, %{})
      with_reserve = evaluate(context, requirements)

      report(without, "no requirement (the ENE-19 finding)")
      report(with_reserve, "with the ENE-19 requirement")

      # BEFORE: the interconnection sheds customers for its own largest
      # credible single loss.
      assert without.shed_mw > 0.0
      assert without.nadir <= 59.3

      # AFTER: it rides it out. This reversal IS the acceptance test.
      assert with_reserve.shed_mw == 0.0

      assert with_reserve.nadir > 59.3,
             "ERCOT reached #{Float.round(with_reserve.nadir, 3)} Hz for its design contingency"

      # ...because the operating point now carries the reserve, measured the
      # way the frequency model measures it.
      assert with_reserve.primary_capability_mw >= @trip_mw
      assert with_reserve.primary_capability_mw > without.primary_capability_mw
      assert with_reserve.reserve.met?

      # And the measurement the dispatch exists to reproduce is untouched:
      # the same megawatts, on different machines.
      assert_in_delta with_reserve.dispatched_mw, without.dispatched_mw, 500.0
    end

    @tag :db
    @tag timeout: 300_000
    test "every interconnection with a requirement meets it" do
      context = fleet_context()
      requirements = Dispatch.contingency_reserves()
      %{reserve_by_ic: by_ic} = evaluate(context, requirements)

      for {name, requirement} <- requirements, Map.has_key?(by_ic, name) do
        stat = Map.fetch!(by_ic, name)

        assert stat.met?,
               "#{name}: #{Float.round(stat.primary_reserve_mw, 0)} MW of primary-capable " <>
                 "reserve against a #{requirement} MW design contingency"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fleet, operating point and measurement
  # ---------------------------------------------------------------------------

  defp fleet_context do
    hour = modal_demand_hour()

    generators =
      FleetRepo.all(
        from(g in Generator,
          join: b in Bus,
          on: b.id == g.bus_id,
          where: g.status == "in_service" and not is_nil(b.coordinates),
          select: %{
            id: g.id,
            bus_id: g.bus_id,
            fuel_type: g.fuel_type,
            prime_mover: g.prime_mover,
            p_max_mw: g.p_max_mw,
            p_min_mw: g.p_min_mw,
            summer_capacity_mw: g.summer_capacity_mw,
            winter_capacity_mw: g.winter_capacity_mw,
            capacity_factor: g.capacity_factor,
            status: g.status,
            utility_scale: g.utility_scale
          }
        )
      )

    %{
      hour: hour,
      generators: generators,
      bus_ba:
        FleetRepo.all(from(b in Bus, select: {b.id, b.balancing_authority_id})) |> Map.new(),
      bus_interconnection:
        FleetRepo.all(
          from(b in Bus,
            join: i in Interconnection,
            on: i.id == b.interconnection_id,
            select: {b.id, i.name}
          )
        )
        |> Map.new(),
      fuel_totals: fuel_totals_at(hour),
      ercot_demand_mw: interconnection_demand_mw("ERCOT", hour)
    }
  end

  # Dispatch the whole country at `hour` under `requirements`, then trip
  # ERCOT's design contingency against the operating point that produced.
  defp evaluate(context, requirements) do
    Application.put_env(:power_model, :contingency_reserve_mw, requirements)
    on_exit(fn -> Application.delete_env(:power_model, :contingency_reserve_mw) end)

    {:ok, %{dispatch: dispatch, coverage: coverage}} =
      Dispatch.for_hour(context.generators, context.hour,
        bus_ba: context.bus_ba,
        bus_interconnection: context.bus_interconnection,
        fuel_totals: context.fuel_totals,
        storage_profile: %{}
      )

    fleet =
      context.generators
      |> Enum.filter(&(Map.get(context.bus_interconnection, &1.bus_id) == "ERCOT"))
      |> Enum.map(&shape(&1, Map.get(dispatch, &1.id, 0.0)))

    online = Enum.filter(fleet, &(&1.p_max_mw > 0.0))

    {trajectory, _state} =
      Frequency.simulate_with_state(
        fleet,
        [%{id: 1, p_mw: context.ercot_demand_mw, q_mvar: 0.0}],
        @trip_mw,
        dt_seconds: 0.1,
        duration_seconds: 60.0
      )

    %{
      demand_mw: context.ercot_demand_mw,
      dispatched_mw: Enum.sum(Enum.map(online, & &1.p_dispatch_mw)),
      online_units: length(online),
      governor_headroom_mw:
        online
        |> Enum.filter(&Frequency.governor_duty?/1)
        |> Enum.map(&max(&1.p_nameplate_mw - &1.p_dispatch_mw, 0.0))
        |> Enum.sum(),
      primary_capability_mw:
        online |> Enum.map(&Frequency.primary_response_capability_mw/1) |> Enum.sum(),
      nadir: Frequency.nadir(trajectory),
      settling_hz: Frequency.mean_frequency(trajectory, 20.0, 52.0),
      shed_mw: List.last(trajectory).load_shed_mw,
      reserve: Map.get(coverage.reserve.by_interconnection, "ERCOT", %{met?: false}),
      reserve_by_ic: coverage.reserve.by_interconnection
    }
  end

  defp shape(generator, mw) do
    generator
    |> Map.put(:p_max_mw, mw)
    |> Map.put(:capacity_factor, if(mw > 0.0, do: 1.0, else: 0.0))
    |> Map.put(:p_dispatch_mw, mw)
    |> Map.put(:p_nameplate_mw, generator.p_max_mw)
  end

  defp report(r, label) do
    IO.puts("""

    ── ERCOT N-1 (#{@trip_mw} MW) — #{label} ──────────────────
      demand                #{Float.round(r.demand_mw / 1000, 2)} GW, dispatched #{Float.round(r.dispatched_mw / 1000, 2)} GW on #{r.online_units} units
      governor headroom     #{Float.round(r.governor_headroom_mw, 0)} MW
      primary-capable       #{Float.round(r.primary_capability_mw, 0)} MW
      nadir                 #{Float.round(r.nadir, 3)} Hz
      settling (value B)    #{Float.round(r.settling_hz, 3)} Hz
      UFLS shed             #{Float.round(r.shed_mw, 1)} MW
    """)
  end

  defp modal_demand_hour do
    FleetRepo.all(
      from(d in PowerModel.Demand.BADemandHour,
        group_by: d.timestamp_utc,
        select: {d.timestamp_utc, count(d.id)}
      )
    )
    |> Enum.max_by(fn {ts, n} -> {n, DateTime.to_unix(ts)} end)
    |> elem(0)
  end

  defp fuel_totals_at(hour) do
    FleetRepo.all(
      from(f in PowerModel.Demand.BAFuelHour,
        join: ba in PowerModel.Grid.BalancingAuthority,
        on: ba.code == f.ba_code,
        where: f.timestamp_utc == ^hour,
        select: {ba.id, f.fuel, f.net_generation_mw}
      )
    )
    |> Enum.reduce(%{}, fn {ba_id, fuel, mw}, acc ->
      Map.update(acc, ba_id, %{fuel => mw}, &Map.put(&1, fuel, mw))
    end)
  end

  # A BA's measured demand lands on its buses in proportion to their baseline
  # share, so a BA straddling a seam contributes only its in-interconnection
  # part (REVIEW ENE-17).
  defp interconnection_demand_mw(name, hour) do
    demand =
      FleetRepo.all(
        from(d in PowerModel.Demand.BADemandHour,
          where: d.timestamp_utc == ^hour,
          select: {d.balancing_authority_id, d.demand_mw}
        )
      )
      |> Map.new()

    baseline =
      FleetRepo.all(
        from(l in Load,
          join: b in Bus,
          on: b.id == l.bus_id,
          join: i in Interconnection,
          on: i.id == b.interconnection_id,
          where: l.status == "in_service" and not is_nil(b.balancing_authority_id),
          group_by: [b.balancing_authority_id, i.name],
          select: {b.balancing_authority_id, i.name, sum(l.p_mw)}
        )
      )

    totals =
      Enum.reduce(baseline, %{}, fn {ba, _ic, mw}, acc ->
        Map.update(acc, ba, mw || 0.0, &(&1 + (mw || 0.0)))
      end)

    baseline
    |> Enum.filter(fn {_ba, ic, _mw} -> ic == name end)
    |> Enum.reduce(0.0, fn {ba, _ic, mw}, acc ->
      total = Map.get(totals, ba, 0.0)
      share = if total > 0.0, do: (mw || 0.0) / total, else: 0.0
      acc + (Map.get(demand, ba) || 0.0) * share
    end)
  end
end
