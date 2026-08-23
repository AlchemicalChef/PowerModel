defmodule PowerModel.Network.PyPSATest do
  @moduledoc """
  The PyPSA reader's unit conversions, pinned against hand-computed values.

  Every number asserted below was worked out independently of the
  implementation, because the conversions are exactly where a silent factor-of-N
  hides: PyPSA gives line impedance in ohms-per-km and transformer impedance in
  per-unit on the transformer's OWN rating, so treating the latter as ohms is
  wrong by orders of magnitude and still produces a network that solves.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Network.PyPSA

  @dir "test/fixtures/pypsa/mini"

  setup_all do
    {:ok, net: PyPSA.load!(@dir)}
  end

  describe "topology" do
    test "buses map to sequential ids and keep their source name", %{net: net} do
      assert length(net.buses) == 4
      assert Enum.map(net.buses, & &1.name) == ~w(A B C D)
      assert Enum.map(net.buses, & &1.id) == [1, 2, 3, 4]
    end

    test "v_nom becomes base_kv and coordinates carry through", %{net: net} do
      a = Enum.find(net.buses, &(&1.name == "A"))
      assert a.base_kv == 380.0
      assert a.lon == 9.0
      assert a.lat == 52.0
    end

    test "PyPSA control maps to the solver's bus_type", %{net: net} do
      assert Enum.find(net.buses, &(&1.name == "A")).bus_type == 1
      assert Enum.find(net.buses, &(&1.name == "D")).bus_type == 3
    end

    test "a branch referencing an unknown bus is DROPPED and reported", %{net: net} do
      refute Enum.any?(net.lines, &(&1.name == "L_orphan"))
      assert "L_orphan" in net.dropped.lines
    end

    test "a load with no entry in the time series is dropped and reported", %{net: net} do
      refute Enum.any?(net.loads, &(&1.name == "LD_missing"))
      assert "LD_missing" in net.dropped.loads
    end
  end

  describe "line impedance" do
    test "explicit per-km columns convert to per-unit on the solver base", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "L_explicit"))

      # 0.25 ohm/km * 100 km / 2 parallel / (380^2/100)
      assert_in_delta l.x_pu, 0.008_656_509_695, 1.0e-9
      assert_in_delta l.r_pu, 0.001_038_781_163, 1.0e-9
    end

    test "series impedance falls with num_parallel and charging RISES", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "L_explicit"))

      # Two circuits: half the series reactance, twice the capacitance.
      assert_in_delta l.b_pu, 1.270_208_741_7, 1.0e-8
      assert l.num_parallel == 2.0
    end

    test "a line with blank per-km columns falls back to the type library", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "L_typed"))

      # 0.301 ohm/km from Al/St 240/40 2-bundle 220.0 * 50 km / (220^2/100)
      assert_in_delta l.x_pu, 0.031_095_041_322, 1.0e-9
      assert_in_delta l.r_pu, 0.006_198_347_107, 1.0e-9
      assert_in_delta l.b_pu, 0.095_033_177_771, 1.0e-9
    end

    test "s_nom becomes the thermal rating", %{net: net} do
      assert Enum.find(net.lines, &(&1.name == "L_explicit")).rating_a_mva == 1700.0
    end
  end

  describe "transformer impedance" do
    test "PyPSA per-unit-on-own-s_nom is rebased, not read as ohms", %{net: net} do
      t = hd(net.transformers)

      # 0.1 pu on 2000 MVA -> 0.1 * 100/2000 = 0.005 pu on 100 MVA.
      assert_in_delta t.x_pu, 0.005, 1.0e-12
      assert_in_delta t.r_pu, 0.000_1, 1.0e-12
      assert t.rated_mva == 2000.0
      assert t.tap_ratio == 1.0
    end
  end

  describe "generators" do
    test "p_nom is NAMEPLATE, matching this repo's own schema", %{net: net} do
      g = Enum.find(net.generators, &(&1.name == "G1"))
      assert g.p_max_mw == 800.0
      assert g.capacity_factor == 1.0
      assert g.fuel_type == "Gas"
    end

    test "reactive limits are UNCONSTRAINED by default, and the map says so", %{net: net} do
      # PyPSA carries no q_max/q_min. Leaving them nil makes the solver treat
      # the machine as unlimited, so a voltage study on an unmodified import is
      # OPTIMISTIC — which is only safe because it is declared.
      assert Enum.all?(net.generators, &is_nil(&1.q_max_mvar))
      assert net.synthesized.generator_q_limits == :unconstrained
    end

    test "opting into synthesized q limits is symmetric and declared" do
      net = PyPSA.load!(@dir, gen_power_factor: 0.95)
      g = Enum.find(net.generators, &(&1.name == "G1"))

      assert_in_delta g.q_max_mvar, 800.0 * :math.tan(:math.acos(0.95)), 1.0e-9
      assert_in_delta g.q_min_mvar, -800.0 * :math.tan(:math.acos(0.95)), 1.0e-9
      assert net.synthesized.generator_q_limits == :synthesized
    end
  end

  describe "loads" do
    test "p_set is read at the requested snapshot", %{net: net} do
      assert Enum.find(net.loads, &(&1.name == "LD_B")).p_mw == 500.0
      later = PyPSA.load!(@dir, snapshot: 1)
      assert Enum.find(later.loads, &(&1.name == "LD_B")).p_mw == 600.0
    end

    test "reactive demand is synthesized at the stated power factor", %{net: net} do
      l = Enum.find(net.loads, &(&1.name == "LD_B"))
      assert_in_delta l.q_mvar, 500.0 * :math.tan(:math.acos(0.95)), 1.0e-9
      assert net.synthesized.load_q_power_factor == 0.95
    end
  end

  describe "the compensation seam" do
    test "does NOT stamp load_compensation, unlike a published MATPOWER case" do
      # `Test.MATPOWER` stamps 0.0 because a published case states Qd already
      # NET of distribution capacitors, so compensating again double-counts.
      # Here Q is synthesized at a flat 0.95 with nothing netted out — the same
      # fiction our own estimator applies — so the model default must apply.
      net = PyPSA.load!(@dir)
      refute Map.has_key?(net, :load_compensation)

      assert PowerModel.Solver.NewtonRaphson.load_compensation(net, []) ==
               PowerModel.Solver.LoadModel.compensation_fraction()
    end
  end

  describe "the solver contract" do
    test "the import is directly solvable with no further plumbing", %{net: net} do
      # The point of a reader rather than an ingest pipeline: the snapshot shape
      # IS the contract, so Partition/FDPF/Cascade work unmodified.
      {subs, _dead} = PowerModel.Solver.Partition.split(net)
      assert subs != []

      island = Enum.max_by(subs, &length(&1.buses))
      balanced = balance(island)

      assert {:ok, solution} =
               PowerModel.Solver.FDPF.solve(balanced,
                 base_mva: 100.0,
                 dense_nr_max_buses: 0,
                 max_iterations: 200
               )

      assert solution.converged
      assert Enum.all?(solution.vm_pu, &(&1 > 0.9 and &1 < 1.1))
    end
  end

  # p_nom is nameplate, so a raw import injects far more than the load and a
  # caller must dispatch. Scaling uniformly is the crudest version of what
  # `Failure.Cascade.init/3` does properly.
  defp balance(island) do
    load = Enum.reduce(island.loads, 0.0, &(&2 + &1.p_mw))
    nameplate = Enum.reduce(island.generators, 0.0, &(&2 + &1.p_max_mw))
    scale = load * 1.05 / nameplate
    %{island | generators: Enum.map(island.generators, &%{&1 | capacity_factor: scale})}
  end
end
