defmodule PowerModel.Engine.SimulationServerPayloadTest do
  @moduledoc """
  The pure half of the frozen broadcast contract (REVIEW UIW-3/4/5/6).

  `panel_trips/2`, `violating_bus_voltage/1` and `client_step_payload/1` are
  the three functions that decide what a collapse-scale cascade costs on the
  wire. They take plain data, so they are pinned here at unit speed; the live
  PubSub assertions are in `SimulationServerBroadcastTest` below.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Simulation.FailureEvent

  defp shed_event(load_id, mw, opts \\ []) do
    details = %{shed_mw: mw, shed_fraction: 0.15, remaining_mw: 0.0}

    details =
      case Keyword.get(opts, :nadir) do
        nil -> details
        hz -> Map.put(details, :frequency_nadir, hz)
      end

    %{
      component_type: "load",
      component_id: load_id,
      failure_cause: Keyword.get(opts, :cause, "ufls_shed"),
      details: details
    }
  end

  defp component_event(id, cause, type \\ "transmission_line") do
    %{component_type: type, component_id: id, failure_cause: cause, details: %{}}
  end

  describe "UIW-5: shed aggregation" do
    test "per-load shedding collapses to one synthetic event per cause" do
      trips = for i <- 1..5_000, do: shed_event(i, 0.5, nadir: 59.5 - i / 10_000)

      {events, omitted} = SimulationServer.panel_trips(trips, %{})

      assert omitted == 0
      assert [aggregate] = events
      assert aggregate.component_type == "island"
      assert aggregate.failure_cause == "ufls_shed"
      assert aggregate.details.aggregated == true
      assert aggregate.details.count == 5_000
      assert_in_delta aggregate.details.shed_mw, 2_500.0, 1.0e-9
    end

    test "the aggregate keeps the DEEPEST nadir, not the last or the mean" do
      trips = [
        shed_event(1, 1.0, nadir: 59.3),
        shed_event(2, 1.0, nadir: 58.1),
        shed_event(3, 1.0, nadir: 59.9)
      ]

      {[aggregate], 0} = SimulationServer.panel_trips(trips, %{})

      # The LiveView's frequency metric is a running MINIMUM over shed-event
      # nadirs. An aggregate reporting anything else would silently raise the
      # reported nadir of every collapse.
      assert aggregate.details.frequency_nadir == 58.1
    end

    test "when no shed event carried a nadir the aggregate omits the key" do
      {[aggregate], 0} = SimulationServer.panel_trips([shed_event(1, 1.0)], %{})

      refute Map.has_key?(aggregate.details, :frequency_nadir)
    end

    test "each shed cause gets its own aggregate, and island_blackout uses lost_mw" do
      blackout = %{
        component_type: "load",
        component_id: 9,
        failure_cause: "island_blackout",
        details: %{lost_mw: 12.0}
      }

      trips = [shed_event(1, 1.0), shed_event(2, 2.0, cause: "uvls_shed"), blackout]

      {events, 0} = SimulationServer.panel_trips(trips, %{})

      by_cause = Map.new(events, &{&1.failure_cause, &1})

      # UIW-6: uvls_shed used to fall through every shed filter in this module.
      assert by_cause |> Map.keys() |> Enum.sort() == ~w(island_blackout ufls_shed uvls_shed)
      assert by_cause["island_blackout"].details.shed_mw == 12.0
      assert by_cause["uvls_shed"].details.shed_mw == 2.0
    end

    test "the aggregate is identified by the lowest BUS id among the shed loads" do
      trips = [shed_event(70, 1.0), shed_event(71, 1.0), shed_event(72, 1.0)]

      {[aggregate], 0} =
        SimulationServer.panel_trips(trips, %{70 => 5001, 71 => 4002, 72 => 6003})

      assert aggregate.component_id == 4002
    end

    test "a load event that is not a shed cause stays itemized" do
      trips = [
        %{component_type: "load", component_id: 1, failure_cause: "power_loss", details: %{}}
      ]

      assert {^trips, 0} = SimulationServer.panel_trips(trips, %{})
    end

    test "a step with no shed events is passed through untouched" do
      trips = [component_event(1, "thermal_overload"), component_event(2, "distance_zone3")]

      assert {^trips, 0} = SimulationServer.panel_trips(trips, %{})
    end
  end

  describe "UIW-5: the itemized cap" do
    test "component trips are capped with the overflow counted" do
      trips = for i <- 1..1_000, do: component_event(i, "thermal_overload")

      assert {events, 800} = SimulationServer.panel_trips(trips, %{})
      assert length(events) == 200
    end

    test "a rare cause behind 500 identical ones still appears" do
      # Taking the first 200 chronologically would drop every Wave 3b cause
      # that fires behind a burst of one relay type -- which is precisely the
      # set of events the Affected panel exists to surface.
      trips =
        Enum.map(1..500, &component_event(&1, "thermal_overload")) ++
          [
            component_event(9001, "distance_zone3"),
            component_event(9002, "voltage_violation"),
            component_event(9003, "conductor_thermal")
          ]

      assert {events, 303} = SimulationServer.panel_trips(trips, %{})
      assert length(events) == 200

      assert MapSet.new(events, & &1.failure_cause) ==
               MapSet.new(~w(thermal_overload distance_zone3 voltage_violation conductor_thermal))
    end

    test "the cap does not apply to the shed aggregates" do
      trips =
        Enum.map(1..1_000, &component_event(&1, "thermal_overload")) ++
          Enum.map(1..9_000, &shed_event(&1, 0.1))

      assert {events, 800} = SimulationServer.panel_trips(trips, %{})
      assert length(events) == 201
      assert Enum.count(events, &(&1.component_type == "island")) == 1
    end
  end

  describe "UIW-3: violating_bus_voltage/1" do
    test "only buses outside the band appear, rounded to 1e-4 pu" do
      overlay = %{
        islands: [
          %{
            island_id: 1,
            at_s: 3.0,
            bus_count: 4,
            vm_by_bus: %{1 => 0.874_321_9, 2 => 1.0, 3 => 1.153_11, 4 => 0.95},
            undervoltage_bus_ids: [1],
            overvoltage_bus_ids: [3]
          }
        ]
      }

      assert SimulationServer.violating_bus_voltage(overlay) == %{1 => 0.8743, 3 => 1.1531}
    end

    test "an absent or empty voltage layer yields an empty map, never zeros" do
      assert SimulationServer.violating_bus_voltage(nil) == %{}
      assert SimulationServer.violating_bus_voltage(%{islands: []}) == %{}
    end
  end

  describe "UIW-4: voltage_overlay_payload/1" do
    defp overlay_step(step, islands) do
      %{
        step: step,
        voltage_overlay: %{
          islands: islands,
          covered_bus_count: Enum.sum(Enum.map(islands, & &1.bus_count)),
          undervoltage_bus_ids: Enum.flat_map(islands, & &1.undervoltage_bus_ids),
          overvoltage_bus_ids: Enum.flat_map(islands, & &1.overvoltage_bus_ids)
        }
      }
    end

    defp island(id, vm_by_bus, under, over) do
      %{
        island_id: id,
        at_s: 4.5,
        bus_count: map_size(vm_by_bus),
        vm_by_bus: vm_by_bus,
        undervoltage_bus_ids: under,
        overvoltage_bus_ids: over
      }
    end

    test "no island converged anywhere, so there is nothing to overlay" do
      # The ordinary case at real demand: the main island has no AC solution,
      # and the channel must stay silent rather than paint a fabricated one.
      steps = [%{step: 1}, overlay_step(2, []), %{step: 3, voltage_overlay: nil}]

      assert SimulationServer.voltage_overlay_payload(steps) == nil
      assert SimulationServer.voltage_overlay_payload([]) == nil
    end

    test "the LAST converged step wins -- earlier ones describe a dead topology" do
      steps = [
        overlay_step(1, [island(10, %{10 => 0.8}, [10], [])]),
        overlay_step(2, [island(20, %{20 => 1.2}, [], [20])]),
        %{step: 3, voltage_overlay: %{islands: []}}
      ]

      overlay = SimulationServer.voltage_overlay_payload(steps)

      assert overlay.island_count == 1
      assert [%{island_id: 20}] = overlay.islands
    end

    test "carries the FULL magnitude map and marks itself partial" do
      vm = %{1 => 0.888_88, 2 => 1.0, 3 => 1.111_11}
      steps = [overlay_step(1, [island(1, vm, [1], [3])])]

      overlay = SimulationServer.voltage_overlay_payload(steps)

      # Partial is structural, not a status: this covers the islands AC
      # reached and says nothing about the rest, so it may never be merged
      # into a whole-grid metric (CAS-1).
      assert overlay.partial == true
      assert overlay.covered_bus_count == 3
      assert overlay.undervoltage_bus_ids == [1]
      assert overlay.overvoltage_bus_ids == [3]

      # Every bus, not only the violating ones: an H3 per-cell minimum needs
      # the in-band buses too.
      assert [%{vm_by_bus: rounded}] = overlay.islands
      assert rounded == %{1 => 0.8889, 2 => 1.0, 3 => 1.1111}
    end
  end

  # UI-L15: the overlay used to be broadcast only from the SUCCESS branch of
  # the post-cascade DC solve, so :solve_failed -- the state in which the
  # operator most needs the voltage picture -- suppressed it entirely. The
  # cascade's per-island AC is independent of that final solve.
  describe "UI-L15: the overlay survives a failed post-cascade solve" do
    setup do
      sim_id = "overlay_test_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")
      %{sim_id: sim_id, steps: [overlay_step(1, [island(1, %{1 => 0.82}, [1], [])])]}
    end

    test "with no successful solve behind it, the overlay still goes out",
         %{sim_id: sim_id, steps: steps} do
      state = %SimulationServer{sim_id: sim_id, dc_solution: nil, base_mva: 100.0}

      SimulationServer.broadcast_voltage_overlay(state, steps)

      assert_receive {:simulation_ac_update, payload}, 1_000
      assert payload.partial_ac == true
      assert payload.ac_overlay.island_count == 1

      # No solve has ever succeeded, so there are no flow classes to preserve;
      # the client's DC painter clears what it has and applies nothing.
      refute Map.has_key?(payload, :overloaded_line_ids)
    end

    test "the classification lists ride along from the LAST successful solve",
         %{sim_id: sim_id, steps: steps} do
      previous = %PowerModel.Solver.Solution{
        converged: true,
        iterations: 3,
        max_mismatch: 1.0e-8,
        line_flows: %{{:line, 7} => %{loading_pct: 140.0}},
        total_gen_mw: 100.0,
        total_load_mw: 100.0,
        total_loss_mw: 0.0
      }

      state = %SimulationServer{
        sim_id: sim_id,
        dc_solution: previous,
        base_mva: 100.0,
        base_line_categories: %{},
        base_line_loading: %{}
      }

      SimulationServer.broadcast_voltage_overlay(state, steps)

      assert_receive {:simulation_ac_update, payload}, 1_000
      assert payload.ac_overlay.island_count == 1
      assert payload.overloaded_line_ids == [7], "the previous classification is preserved"
      assert payload.line_loading == %{7 => 140.0}
    end
  end

  describe "shed_bus_ids/2" do
    test "resolves shed loads to their buses, deduplicated" do
      # Three loads, two of them on the same bus: the map paints buses, so the
      # shared bus must appear once.
      trips = [shed_event(1, 1.0), shed_event(2, 1.0), shed_event(3, 1.0)]
      bus_by_load = %{1 => 500, 2 => 500, 3 => 501}

      assert SimulationServer.shed_bus_ids(trips, bus_by_load) == [500, 501]
    end

    test "covers every shed cause, including uvls_shed and island_blackout" do
      trips = [
        shed_event(1, 1.0, cause: "ufls_shed"),
        shed_event(2, 1.0, cause: "uvls_shed"),
        %{
          component_type: "load",
          component_id: 3,
          failure_cause: "island_blackout",
          details: %{lost_mw: 5.0}
        }
      ]

      buses = SimulationServer.shed_bus_ids(trips, %{1 => 10, 2 => 11, 3 => 12})

      assert Enum.sort(buses) == [10, 11, 12]
    end

    test "a step that shed nothing yields [], so the key is omitted" do
      trips = [component_event(1, "thermal_overload"), component_event(2, "distance_zone3")]

      assert SimulationServer.shed_bus_ids(trips, %{1 => 10, 2 => 11}) == []
      assert SimulationServer.shed_bus_ids([], %{}) == []
    end

    test "a non-load event whose id collides with a load id does not mark that bus" do
      # Load, generator and line ids are separate id spaces. A generator
      # tripping on frequency must never paint load 1's bus as shed.
      trips = [
        %{
          component_type: "generator",
          component_id: 1,
          failure_cause: "ufls_shed",
          details: %{}
        }
      ]

      assert SimulationServer.shed_bus_ids(trips, %{1 => 500}) == []
    end

    test "a shed load missing from the map is dropped rather than nil-marked" do
      trips = [shed_event(1, 1.0), shed_event(99, 1.0)]

      assert SimulationServer.shed_bus_ids(trips, %{1 => 500}) == [500]
    end
  end

  describe "UIW-4: client_step_payload/1" do
    test "drops exactly the four channels no browser reads, and nothing else" do
      payload = %{
        step: 1,
        trips: [component_event(1, "thermal_overload")],
        shed_ids: [1, 2, 3],
        shed_bus_ids: [500, 501],
        water_facility_trips: [%{id: 1}],
        datacenter_trips: [%{id: 2}],
        tripped_line_ids: [7],
        water_facility_ids: [1],
        datacenter_ids: [2],
        balance: %{},
        voltage_layer: %{islands_ac: 1}
      }

      slim = SimulationServer.client_step_payload(payload)

      assert Map.keys(slim) |> Enum.sort() ==
               ~w(balance datacenter_ids shed_bus_ids step tripped_line_ids
                  voltage_layer water_facility_ids)a

      # The id channels the map actually paints from must survive. shed_bus_ids
      # in particular REPLACES the dropped load-id channel -- dropping it too
      # would leave the shed marks with no producer at all.
      assert slim.shed_bus_ids == [500, 501]
      assert slim.tripped_line_ids == [7]
      assert slim.water_facility_ids == [1]
      assert slim.datacenter_ids == [2]
      assert slim.voltage_layer == %{islands_ac: 1}
    end

    test "the load-id shed channel is dropped while the bus-id one survives" do
      slim = SimulationServer.client_step_payload(%{shed_ids: [1, 2], shed_bus_ids: [500]})

      refute Map.has_key?(slim, :shed_ids)
      assert slim.shed_bus_ids == [500]
    end
  end

  describe "CAS-17: FailureEvent component_type whitelist" do
    test "accepts every type the live cascade emits" do
      for type <- FailureEvent.component_types() do
        changeset =
          FailureEvent.changeset(%FailureEvent{}, %{
            step: 1,
            component_type: type,
            component_id: 1,
            failure_cause: "thermal_overload",
            scenario_id: 1
          })

        assert changeset.valid?, "#{type} should be an accepted component_type"
      end
    end

    test "covers every component_type literal the cascade layers emit" do
      live =
        ~w(transmission_line generator transformer load bus water_facility
           datacenter island btm_solar cascade)

      assert MapSet.subset?(MapSet.new(live), MapSet.new(FailureEvent.component_types()))
    end

    test "still rejects a type nothing emits" do
      changeset =
        FailureEvent.changeset(%FailureEvent{}, %{
          step: 1,
          component_type: "substation",
          component_id: 1,
          failure_cause: "thermal_overload",
          scenario_id: 1
        })

      refute changeset.valid?
    end
  end
end

defmodule PowerModel.Engine.SimulationServerBroadcastTest do
  @moduledoc """
  The live half: keys asserted on payloads that actually crossed PubSub.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp drain_steps(acc \\ []) do
    receive do
      {:simulation_cascade_step, payload} -> drain_steps([payload | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  setup do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: "PayloadIC"})

    slack =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 138.0,
        interconnection_id: ic.id,
        coordinates: point(-112.0, 33.4)
      })

    # A radial feeder of load buses: `loads` is unique on (bus_id, load_type),
    # so several separately-sheddable loads means several buses.
    load_buses =
      for i <- 1..6 do
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: ic.id,
          coordinates: point(-112.0 + i * 0.05, 33.4 + i * 0.05)
        })
      end

    [line | _] =
      [slack | load_buses]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        Repo.insert!(%TransmissionLine{
          voltage_kv: 138.0,
          from_bus_id: from.id,
          to_bus_id: to.id,
          x_pu: 0.1,
          rating_a_mva: 400.0,
          status: "in_service"
        })
      end)

    big = Repo.insert!(%Generator{p_max_mw: 300.0, bus_id: slack.id, status: "in_service"})
    Repo.insert!(%Generator{p_max_mw: 60.0, bus_id: slack.id, status: "in_service"})

    for bus <- load_buses do
      Repo.insert!(%Load{p_mw: 40.0, q_mvar: 12.0, bus_id: bus.id, status: "in_service"})
    end

    sim_id = "payload_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")

    {:ok, pid} = SimulationServer.start_link(sim_id: sim_id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{sim_id: sim_id, tline: line, big_gen: big, bus_count: length(load_buses) + 1}
  end

  test "the manual-trip step carries no additive keys at all", %{sim_id: sim_id, tline: line} do
    assert {:ok, _} = SimulationServer.trip_branch(sim_id, line.id)
    assert_receive {:simulation_cascade_step, %{step: 0} = payload}, 10_000

    # UIW-3's absence rule: the injected failure has no voltage layer, no
    # frequency trajectory and no AGC, so it advertises none of them. This is
    # what keeps a steady-state payload byte-identical to the pre-UI-2 shape.
    for key <- [:voltage_layer, :frequency, :agc, :bus_voltage, :trips_omitted, :shed_bus_ids] do
      refute Map.has_key?(payload, key), "step 0 must not carry #{key}"
    end

    assert [%{failure_cause: "manual_trip"}] = payload.trips
  end

  test "cascade steps carry the voltage layer, frequency and AGC", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)

    steps = Enum.filter(drain_steps(), &(&1.step > 0))
    assert steps != []

    for payload <- steps do
      assert %{islands_ac: _, ac_solves: _, islands_dc_only: _, ac_diverged: _, ac_skipped: _} =
               payload.voltage_layer

      assert %{f_hz: f_hz, nadir_hz: nadir} = payload.frequency
      assert is_number(f_hz) and is_number(nadir)
      assert nadir <= f_hz + 1.0e-9

      # AGC summaries are per island, each tagged with its island id.
      for summary <- Map.get(payload, :agc, []) do
        assert is_integer(summary.island_id)
        assert is_number(summary.reserve_remaining_mw)
      end
    end
  end

  test "trip_count stays the TRUE total even when trips are aggregated", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    assert {:ok, engine_steps} = SimulationServer.trip_generator(sim_id, gen.id)

    by_step = Map.new(drain_steps(), &{&1.step, &1})

    for engine <- engine_steps, payload = by_step[engine.step], payload != nil do
      # `trip_count` is the truth; `trips` is the panel view and may be shorter.
      assert payload.trip_count == length(engine.trips || [])
      assert length(payload.trips) <= payload.trip_count
    end
  end

  test "a step that sheds load carries the buses that lost it", %{sim_id: sim_id, big_gen: gen} do
    assert {:ok, engine_steps} = SimulationServer.trip_generator(sim_id, gen.id)

    load_buses =
      Repo.all(from(l in Load, where: l.status == "in_service", select: l.bus_id))
      |> MapSet.new()

    shed_steps =
      Enum.filter(engine_steps, fn step ->
        Enum.any?(step.trips || [], &(&1.component_type == "load"))
      end)

    # Guard against a vacuous pass: if the fixture stopped shedding, the
    # comprehension below would assert nothing at all.
    assert shed_steps != [], "fixture produced no load-shed step; this test would be vacuous"

    payloads = Map.new(drain_steps(), &{&1.step, &1})

    for engine <- shed_steps, payload = payloads[engine.step], payload != nil do
      buses = Map.get(payload, :shed_bus_ids, [])

      assert buses != [], "step #{engine.step} shed load but carried no shed_bus_ids"
      assert buses == Enum.uniq(buses), "shed_bus_ids must be deduplicated"

      # Every id must be a real load-carrying bus: the map paints these
      # directly, and a load id leaking through would mark the wrong bus.
      for bus_id <- buses do
        assert MapSet.member?(load_buses, bus_id),
               "#{bus_id} is not a bus that carries load"
      end
    end
  end

  test "cascade_done carries the termination reason and the voltage/BTM/AGC summaries", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, done}, 20_000

    # The authoritative read is Cascade.termination/1 on the FINAL STATE: the
    # step stream can never carry :budget_exhausted, so a consumer deriving
    # this from the stream would mislabel every truncated run as a collapse.
    assert done.reason in [:settled, :budget_exhausted, :solve_failed]

    # Orthogonal to reason, and always present: it is defined for any state
    # termination/1 accepts, so a consumer never has to fall back to reading
    # settled-vs-collapsed off `stable`.
    #
    # `:unknown` is in the set because a :solve_failed run has no trustworthy
    # balance to classify -- Cascade suppresses the verdict at the source
    # rather than making every consumer remember that precedence. This module
    # forwards whatever the engine returns and never interprets it, so the
    # fourth atom needs no code here; only this assertion has to know the range.
    assert done.outcome in [:collapsed, :degraded, :intact, :unknown]
    assert %{islands_ac: _, ac_diverged: _} = done.voltage_layer
    assert %{frequency_mw: _, voltage_mw: _, total_mw: _} = done.btm_trip_breakdown
    assert is_list(done.agc)
  end

  test "outcome forwards Cascade.outcome/1 on the server's own final state", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    # This is the seam's actual responsibility: not the thresholds, which are
    # Cascade's and tested there, but that the payload carries the engine's
    # verdict on the state the server ended in rather than a re-derivation.
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, done}, 20_000

    [{pid, _}] = Registry.lookup(PowerModel.SimulationRegistry, sim_id)
    final_state = :sys.get_state(pid).cascade_state

    assert done.outcome == Cascade.outcome(final_state)
  end

  test "losing most of the fleet reports :collapsed, whatever the loop did", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    # 300 MW of 360 MW online serving 240 MW: its loss leaves the island far
    # short, and the balance below is what makes :collapsed the honest label
    # even when the loop settles.
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, done}, 20_000

    b = done.balance
    standing = b.original_load_mw + b.btm_tripped_mw

    assert b.served_load_mw / standing < 0.5,
           "fixture no longer collapses; this test would assert the wrong bucket"

    assert done.outcome == :collapsed
  end

  # No live `:intact` case here on purpose. Both units in this fixture are
  # dispatched, so there is no spare generator whose loss sheds nothing, and
  # the feeder is radial, so every line outage strands load. Manufacturing one
  # would be contorting the fixture to exercise Cascade's classification rather
  # than this module's forwarding -- `Cascade.outcome/1` owns and tests the
  # three buckets; the forwarding test above owns the seam.

  test "outcome and reason are independent fields, neither derived from the other", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, done}, 20_000

    # {:settled, :collapsed} is the pairing that motivates outcome existing:
    # the loop reached a fixed point and the fixed point is a blackout. A
    # consumer reading `stable` or `reason` alone would call that "Stable".
    assert done.reason in [:settled, :budget_exhausted, :solve_failed]
    assert done.outcome == :collapsed

    if done.reason == :settled do
      assert done.stable == true,
             "this cascade settled, so `stable` says so -- and it is exactly why " <>
               "outcome has to be read alongside it"
    end
  end

  test "the wire balance still closes: served + shed + blackout == original + BTM", %{
    sim_id: sim_id,
    big_gen: gen
  } do
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, %{balance: b}}, 20_000

    assert Map.has_key?(b, :btm_tripped_mw)

    assert_in_delta b.served_load_mw + b.shed_load_mw + b.blackout_load_mw,
                    b.original_load_mw + b.btm_tripped_mw,
                    1.0e-6
  end

  test "no post-cascade AC refinement is spawned", %{sim_id: sim_id, big_gen: gen} do
    assert {:ok, _} = SimulationServer.trip_generator(sim_id, gen.id)
    assert_receive {:simulation_cascade_done, _}, 20_000

    # The removed refinement reported asynchronously, so it could only land
    # AFTER cascade_done. The voltage overlay is broadcast synchronously
    # BEFORE it, so anything arriving here is the path UIW-4 deleted.
    refute_receive {:simulation_ac_update, _}, 500
  end

  test "screening_snapshot returns the live topology and its base solve", %{
    sim_id: sim_id,
    bus_count: bus_count
  } do
    assert_receive {:simulation_dc_update, _}, 20_000

    snap = SimulationServer.screening_snapshot(sim_id)

    assert length(snap.snapshot.buses) == bus_count
    assert length(snap.snapshot.generators) == 2
    assert snap.dc_solution != nil
    assert is_map(snap.dispatch)
    assert snap.base_mva == 100.0
    assert snap.epoch == 0
  end

  test "screening_snapshot reflects a trip and bumps the epoch", %{sim_id: sim_id, tline: line} do
    assert_receive {:simulation_dc_update, _}, 20_000
    before = SimulationServer.screening_snapshot(sim_id)

    assert {:ok, _} = SimulationServer.trip_branch(sim_id, line.id)
    assert_receive {:simulation_cascade_done, _}, 20_000

    snap = SimulationServer.screening_snapshot(sim_id)

    refute Enum.any?(snap.snapshot.lines, &(&1.id == line.id))
    assert length(snap.snapshot.lines) == length(before.snapshot.lines) - 1
    assert snap.epoch == 1
  end
end
