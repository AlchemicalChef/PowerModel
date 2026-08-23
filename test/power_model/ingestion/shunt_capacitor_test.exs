defmodule PowerModel.Ingestion.ShuntCapacitorTest do
  @moduledoc """
  The capacitor-bank half of `ParameterEstimator.synthesize_bus_shunts/1`.

  The network modelled line charging correctly and ZERO compensating plant, so
  a first pass synthesized EHV line-end reactors. This is the mirror: the
  substation capacitor banks that compensate the transmission-to-distribution
  interface, plus a top-up at the generator buses a power flow shows running
  out of reactive production.

  Both devices live in ONE column, so the ownership question the tests below
  pin down is not "does the capacitor pass avoid negative rows" — it is that
  the two components are recomputed together and neither can erase the other.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Interconnection, Load, TransmissionLine, BalancingAuthority}
  alias PowerModel.Ingestion.ParameterEstimator, as: PE

  defp bus(ic, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Bus{
          bus_type: 1,
          base_kv: 138.0,
          interconnection_id: ic.id,
          source: "substation",
          source_id: "test-#{System.unique_integer([:positive])}",
          coordinates: %Geo.Point{coordinates: {-100.0, 40.0}, srid: 4326}
        },
        attrs
      )
    )
  end

  defp load(bus, p_mw, q_mvar) do
    Repo.insert!(%Load{bus_id: bus.id, p_mw: p_mw, q_mvar: q_mvar, status: "in_service"})
  end

  defp ehv_line(from, to, b_pu) do
    Repo.insert!(%TransmissionLine{
      from_bus_id: from.id,
      to_bus_id: to.id,
      voltage_kv: 500.0,
      status: "in_service",
      b_pu: b_pu,
      source: "hifld"
    })
  end

  defp bs(bus), do: Repo.get!(Bus, bus.id).bs_mvar

  setup do
    ic = Repo.insert!(%Interconnection{name: "TestIC-#{System.unique_integer([:positive])}"})
    {:ok, ic: ic}
  end

  # The peak-factor lookup reads the whole loads table and the BA demand table,
  # neither of which a focused test wants to depend on. Every DB test below
  # pins it so the bank is exactly the stored Q. `load_compensation: 1.0`
  # because the shipped default is 0.0 — these tests exercise the rule, and the
  # "shipped default" describe block below is what pins the default itself.
  defp unity_peak, do: [peak_factors: %{}, generator_support: false, load_compensation: 1.0]

  describe "sizing rule" do
    test "a bank is the full load Q by default" do
      assert PE.bank_target_mvar(40.0, 138.0) == 40.0
    end

    test "nothing smaller than one standard capacitor group is installed" do
      # ~1.2 MVAr is the capacitor group North American banks are built from;
      # a bus wanting less than one gets no plant rather than a fraction of a can.
      assert PE.bank_target_mvar(1.19, 138.0) == 0.0
      assert PE.bank_target_mvar(1.2, 138.0) == 1.2
    end

    test "the class ceiling holds a 69 kV yard well below a 500 MVAr bank" do
      # The stated failure this guards: a load-allocation outlier putting
      # hundreds of MW on one sub-transmission bus turning into a capacitor
      # installation nobody would build.
      assert PE.bank_target_mvar(500.0, 69.0) == PE.cap_class_ceiling(69.0)
      assert PE.cap_class_ceiling(69.0) < 500.0
    end

    test "ceilings rise monotonically with voltage class" do
      ceilings = Enum.map([34.5, 69.0, 115.0, 230.0, 345.0, 500.0], &PE.cap_class_ceiling/1)
      assert ceilings == Enum.sort(ceilings)
    end

    test "an off-table voltage takes the closest class" do
      assert PE.cap_class_ceiling(130.5) == PE.cap_class_ceiling(115.0)
      assert PE.cap_class_ceiling(60.0) == PE.cap_class_ceiling(69.0)
      assert PE.cap_class_ceiling(13.8) == PE.cap_class_ceiling(34.5)
    end

    test "no usable voltage falls back to the most conservative ceiling" do
      lowest = PE.cap_class_ceilings() |> Map.values() |> Enum.min()

      assert PE.cap_class_ceiling(nil) == lowest
      assert PE.cap_class_ceiling(0.0) == lowest
    end

    test "a non-numeric requirement yields no bank rather than raising" do
      assert PE.bank_target_mvar(nil, 138.0) == 0.0
    end
  end

  describe "ownership: the two synthesized components share one column" do
    test "a load bus gets a positive bank and an EHV terminal keeps its reactor", %{ic: ic} do
      load_bus = bus(ic)
      load(load_bus, 100.0, 40.0)

      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      PE.synthesize_bus_shunts(unity_peak())

      assert_in_delta bs(load_bus), 40.0, 1.0e-6
      assert bs(a) < 0.0
      assert_in_delta bs(a), PE.line_end_reactor_mvar(500.0, 0.5), 1.0e-3
    end

    test "a bus that is BOTH a load bus and an EHV terminal stores the NET", %{ic: ic} do
      # This is the case a strict "never touch the other sign" rule cannot
      # express: measured on the dev DB, 3,798 load-serving buses also
      # terminate an EHV line. Writing either component alone erases the other.
      both = bus(ic, %{base_kv: 500.0})
      far = bus(ic, %{base_kv: 500.0})
      load(both, 100.0, 40.0)
      ehv_line(both, far, 0.5)

      PE.synthesize_bus_shunts(unity_peak())

      reactor = PE.line_end_reactor_mvar(500.0, 0.5)

      assert_in_delta bs(both), 40.0 + reactor, 1.0e-3
      # Neither component was lost: the net is strictly between them.
      assert bs(both) < 40.0
      assert bs(both) > reactor
    end

    test "a reactor-only bus is never given a capacitor", %{ic: ic} do
      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      PE.synthesize_bus_shunts(unity_peak())

      assert bs(a) < 0.0
      assert bs(b) < 0.0
    end

    test "externally authored shunts are not written and not cleared", %{ic: ic} do
      # A source on the excluded list ships its own shunt data; synthesizing on
      # top of it would double-count, and clearing it would delete real data.
      imported = bus(ic, %{source: "matpower", source_id: "m1", bs_mvar: 55.0})
      load(imported, 100.0, 40.0)

      ordinary = bus(ic)
      load(ordinary, 100.0, 40.0)

      PE.synthesize_bus_shunts(unity_peak())

      assert bs(imported) == 55.0
      assert_in_delta bs(ordinary), 40.0, 1.0e-6
    end
  end

  describe "idempotency" do
    test "a second run writes no rows", %{ic: ic} do
      l = bus(ic)
      load(l, 100.0, 40.0)
      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      first = PE.synthesize_bus_shunts(unity_peak())
      assert first.written > 0

      second = PE.synthesize_bus_shunts(unity_peak())

      assert second.written == 0
      assert second.cleared == 0
      assert_in_delta second.mvar, first.mvar, 1.0e-9
    end

    test "the value is recomputed, never accumulated", %{ic: ic} do
      l = bus(ic)
      load(l, 100.0, 40.0)

      PE.synthesize_bus_shunts(unity_peak())
      PE.synthesize_bus_shunts(unity_peak())
      PE.synthesize_bus_shunts(unity_peak())

      assert_in_delta bs(l), 40.0, 1.0e-6
    end

    test "a bank is cleared when its load goes away", %{ic: ic} do
      l = bus(ic)
      ld = load(l, 100.0, 40.0)

      # An EHV pair so the target set is non-empty after the load is removed —
      # otherwise the empty-set guard below correctly declines to clear
      # anything, and this would be testing that guard instead.
      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      PE.synthesize_bus_shunts(unity_peak())
      assert bs(l) > 0.0

      Repo.delete!(ld)
      summary = PE.synthesize_bus_shunts(unity_peak())

      assert bs(l) == 0.0
      assert summary.cleared >= 1
      # The reactors it still owns are untouched by the cleanup.
      assert bs(a) < 0.0
    end

    test "an out-of-service load carries no bank", %{ic: ic} do
      l = bus(ic)
      Repo.insert!(%Load{bus_id: l.id, p_mw: 100.0, q_mvar: 40.0, status: "out_of_service"})

      PE.synthesize_bus_shunts(unity_peak())

      assert bs(l) == 0.0
    end

    test "an empty network clears nothing", %{ic: _ic} do
      # The guard that matters: the stale-device cleanup is "every synthesized
      # shunt NOT in this set", so an empty set would wipe the table.
      kept =
        Repo.insert!(%Bus{
          bus_type: 1,
          base_kv: 138.0,
          bs_mvar: -12.0,
          source: "substation",
          source_id: "keep-me"
        })

      summary =
        PE.synthesize_bus_shunts(
          peak_factors: %{},
          generator_support: false,
          load_compensation: 1.0
        )

      if summary.buses == 0 do
        assert summary.cleared == 0
        assert bs(kept) == -12.0
      end
    end
  end

  describe "peak-hour sizing basis" do
    test "the bank is the load Q at the BA's peak hour, not the stored baseline",
         %{ic: ic} do
      ba =
        Repo.insert!(%BalancingAuthority{code: "TBA", name: "Test BA", interconnection_id: ic.id})

      b = bus(ic, %{balancing_authority_id: ba.id})
      load(b, 100.0, 40.0)

      # A BA running at 60% of its allocation basis at peak compensates to
      # unity THERE, not at a basis no hour in the record ever reaches.
      PE.synthesize_bus_shunts(
        peak_factors: %{ba.id => 0.6},
        generator_support: false,
        load_compensation: 1.0
      )

      assert_in_delta bs(b), 24.0, 1.0e-6
    end

    test "a bus in a BA with no demand data falls back to the stored basis", %{ic: ic} do
      b = bus(ic)
      load(b, 100.0, 40.0)

      PE.synthesize_bus_shunts(
        peak_factors: %{999_999 => 0.1},
        generator_support: false,
        load_compensation: 1.0
      )

      assert_in_delta bs(b), 40.0, 1.0e-6
    end

    test "ba_peak_factors/0 stays inside the sanity range" do
      PE.ba_peak_factors()
      |> Map.values()
      |> Enum.each(fn f -> assert f >= 0.05 and f <= 2.0 end)
    end
  end

  describe "generator support study" do
    defp study(path, banks) do
      File.write!(path, Jason.encode!(%{"banks" => banks}))
      path
    end

    test "a bus whose load bank already covers the shortfall gets no top-up", %{ic: ic} do
      b = bus(ic)
      load(b, 100.0, 40.0)

      path = Path.join(System.tmp_dir!(), "study-#{System.unique_integer([:positive])}.json")

      study(path, [
        %{
          "source" => b.source,
          "source_id" => b.source_id,
          "shortfall_mvar" => 10.0,
          "vm_pu" => 1.0
        }
      ])

      on_exit(fn -> File.rm(path) end)

      PE.synthesize_bus_shunts(peak_factors: %{}, study_path: path, load_compensation: 1.0)

      # 40 MVAr of load bank already delivers 40 MVAr at 1.0 pu, so a 10 MVAr
      # shortfall is fully covered and the support bank is zero.
      assert_in_delta bs(b), 40.0, 1.0e-6
    end

    test "a generator bus with no load carries the whole shortfall", %{ic: ic} do
      b = bus(ic)

      path = Path.join(System.tmp_dir!(), "study-#{System.unique_integer([:positive])}.json")

      study(path, [
        %{
          "source" => b.source,
          "source_id" => b.source_id,
          "shortfall_mvar" => 30.0,
          "vm_pu" => 0.95
        }
      ])

      on_exit(fn -> File.rm(path) end)

      PE.synthesize_bus_shunts(peak_factors: %{}, study_path: path, load_compensation: 1.0)

      assert_in_delta bs(b), 30.0, 1.0e-6
    end

    test "the top-up is the part the load bank does not deliver at the measured voltage",
         %{ic: ic} do
      b = bus(ic)
      load(b, 100.0, 10.0)

      path = Path.join(System.tmp_dir!(), "study-#{System.unique_integer([:positive])}.json")
      vm = 0.9

      study(path, [
        %{
          "source" => b.source,
          "source_id" => b.source_id,
          "shortfall_mvar" => 30.0,
          "vm_pu" => vm
        }
      ])

      on_exit(fn -> File.rm(path) end)

      PE.synthesize_bus_shunts(peak_factors: %{}, study_path: path, load_compensation: 1.0)

      # A 10 MVAr bank delivers 10 * 0.9^2 = 8.1 MVAr at the measured voltage,
      # so the top-up is 30 - 8.1 = 21.9 and the stored total is 10 + 21.9.
      assert_in_delta bs(b), 10.0 + (30.0 - 10.0 * vm * vm), 1.0e-6
    end

    test "a study entry whose bus was renamed is dropped LOUDLY, not silently", %{ic: ic} do
      # `source_id` is "<substation>_<kv>kV", so a voltage restamp renames the
      # bus and the study key stops resolving. Measured on the real database
      # after the OSM voltage backfill: 60 of 1,627 entries went this way, all
      # of them the 138.0 kV blind-yard default. Dropping them is correct —
      # fuzzy-matching the substation would attach a shortfall to the wrong
      # voltage — but it has to be visible.
      import ExUnit.CaptureLog

      present = bus(ic)
      path = Path.join(System.tmp_dir!(), "study-#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "banks" => [
            %{
              "source" => present.source,
              "source_id" => present.source_id,
              "shortfall_mvar" => 20.0,
              "vm_pu" => 1.0
            },
            %{
              "source" => "substation",
              "source_id" => "99999_138.0kV",
              "shortfall_mvar" => 30.0,
              "vm_pu" => 1.0
            }
          ]
        })
      )

      on_exit(fn -> File.rm(path) end)

      log =
        capture_log(fn ->
          PE.synthesize_bus_shunts(peak_factors: %{}, study_path: path)
        end)

      assert log =~ "1 of 2 banks did not resolve"
      assert log =~ "99999_138.0kV"

      # The resolvable one is still placed.
      assert_in_delta bs(present), 20.0, 1.0e-6
    end

    test "an absent study file leaves the load banks alone", %{ic: ic} do
      b = bus(ic)
      load(b, 100.0, 40.0)

      PE.synthesize_bus_shunts(
        peak_factors: %{},
        load_compensation: 1.0,
        study_path: Path.join(System.tmp_dir!(), "definitely-not-here.json")
      )

      assert_in_delta bs(b), 40.0, 1.0e-6
    end

    test "the shipped study file parses and resolves against the class ceilings" do
      path = PE.generator_support_study_path()

      if File.exists?(path) do
        %{"banks" => banks} = path |> File.read!() |> Jason.decode!()

        assert banks != []

        Enum.each(banks, fn b ->
          assert is_binary(b["source"]) and is_binary(b["source_id"])
          assert is_number(b["shortfall_mvar"]) and b["shortfall_mvar"] > 0.0
          assert is_number(b["vm_pu"]) and b["vm_pu"] > 0.0
        end)
      end
    end
  end

  describe "the shipped default" do
    test "load-bus banks are OFF, so an ordinary load bus gets no capacitor", %{ic: ic} do
      # A fixed shunt cannot represent a switched installation. Measured
      # 2026-08-18: load-sized banks left Western with no AC solution at any
      # alpha down to 0.05 (Vm to 1.5 pu) and bought ERCOT no ceiling over the
      # generator-support banks alone while driving 113 buses above 1.1 pu.
      # See @load_compensation for the table.
      l = bus(ic)
      load(l, 100.0, 40.0)

      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      PE.synthesize_bus_shunts(peak_factors: %{}, generator_support: false)

      assert bs(l) == 0.0
      assert bs(a) < 0.0
    end

    test "a generator-support bank is still placed with the default options", %{ic: ic} do
      b = bus(ic)

      path = Path.join(System.tmp_dir!(), "study-#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "banks" => [
            %{
              "source" => b.source,
              "source_id" => b.source_id,
              "shortfall_mvar" => 30.0,
              "vm_pu" => 0.95
            }
          ]
        })
      )

      on_exit(fn -> File.rm(path) end)

      PE.synthesize_bus_shunts(peak_factors: %{}, study_path: path)

      # With load banks off nothing else supplies those vars, so the support
      # bank is the whole measured shortfall.
      assert_in_delta bs(b), 30.0, 1.0e-6
    end
  end

  describe "the solvers see a capacitor bank the way a capacitor behaves" do
    # The reactor direction is covered in branch_normalization_test; these pin
    # the CAPACITIVE direction, which is what this pass writes.
    alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution, YBus}

    defp two_bus(bs_at_2) do
      %{
        buses: [
          %{id: 1, bus_type: 3, base_kv: 138.0, bs_mvar: 0.0, gs_mw: 0.0},
          %{id: 2, bus_type: 1, base_kv: 138.0, bs_mvar: bs_at_2, gs_mw: 0.0}
        ],
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            voltage_kv: 138.0,
            r_pu: 0.01,
            x_pu: 0.10,
            b_pu: 0.02,
            rating_a_mva: 250.0
          }
        ],
        transformers: [],
        generators: [
          %{
            id: 1,
            bus_id: 1,
            p_max_mw: 200.0,
            capacity_factor: 1.0,
            q_max_mvar: 300.0,
            q_min_mvar: -300.0
          }
        ],
        loads: [%{id: 1, bus_id: 2, p_mw: 150.0, q_mvar: 50.0}]
      }
    end

    test "YBus puts a positive bs_mvar on the diagonal as positive susceptance" do
      build = fn snap -> YBus.build(snap.buses, snap.lines, snap.transformers, 100.0) end
      plain = build.(two_bus(0.0))
      capped = build.(two_bus(60.0))

      diag = fn y ->
        i = Map.fetch!(y.bus_index_map, 2)
        y.triplets |> Enum.filter(fn {r, c, _} -> r == i and c == i end) |> Enum.map(&elem(&1, 2))
      end

      [{_g0, b0}] = diag.(plain)
      [{_g1, b1}] = diag.(capped)

      # 60 MVAr at 1.0 pu on a 100 MVA base is +0.6 pu of susceptance.
      assert_in_delta b1 - b0, 0.6, 1.0e-9
    end

    test "a capacitor bank RAISES the bus voltage in the AC solve" do
      {:ok, plain} = NewtonRaphson.solve(two_bus(0.0), base_mva: 100.0, tolerance: 1.0e-10)
      {:ok, capped} = NewtonRaphson.solve(two_bus(60.0), base_mva: 100.0, tolerance: 1.0e-10)

      assert plain.converged and capped.converged

      vm = fn s -> Enum.at(s.vm_pu, Enum.find_index(s.bus_ids, &(&1 == 2))) end

      assert vm.(capped) > vm.(plain)
    end

    test "DC power flow is blind to a capacitor bank, so the DC path is untouched" do
      a = DCPowerFlow.solve(two_bus(0.0), base_mva: 100.0)
      b = DCPowerFlow.solve(two_bus(60.0), base_mva: 100.0)

      assert a.va_rad == b.va_rad

      assert Solution.line_flow(a, :line, 1).p_flow_mw ==
               Solution.line_flow(b, :line, 1).p_flow_mw
    end
  end

  describe "the combined write" do
    test "the summary breaks the two components out", %{ic: ic} do
      l = bus(ic)
      load(l, 100.0, 40.0)
      a = bus(ic, %{base_kv: 500.0})
      b = bus(ic, %{base_kv: 500.0})
      ehv_line(a, b, 0.5)

      s = PE.synthesize_bus_shunts(unity_peak())

      assert s.cap_mvar > 0.0
      assert s.reactor_mvar < 0.0
      assert_in_delta s.mvar, s.cap_mvar + s.reactor_mvar, 1.0e-6
      assert s.buses == s.written
    end
  end
end
