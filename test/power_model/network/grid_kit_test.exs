defmodule PowerModel.Network.GridKitTest do
  @moduledoc """
  The continental ENTSO-E/GridKit reader.

  Unlike `Network.PyPSA`, this source carries NO electrical parameters — only
  voltage, circuits and length — so impedance is derived from PyPSA's standard
  type library. That makes the conversions the same class of hazard, and the
  expectations below are hand-computed for the same reason.

  The filtering assertions matter as much as the arithmetic: this dataset mixes
  in-service plant with under-construction plant, AC with DC, and carries
  self-loops and dangling endpoints. Everything dropped is counted, because a
  network that silently loses 1,215 lines looks identical to one that never had
  them.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Network.GridKit

  @dir "test/fixtures/gridkit/mini"

  setup_all do
    {:ok, net: GridKit.load!(@dir)}
  end

  describe "filtering" do
    test "under-construction and DC buses are excluded, and counted", %{net: net} do
      names = Enum.map(net.buses, & &1.name)
      assert "b1" in names and "b2" in names and "b3" in names
      refute "b4" in names, "a DC bus is not an AC node"
      refute "b5" in names, "under construction is not network"
      assert net.dropped.buses == 2
    end

    test "under-construction lines, self-loops and dangling endpoints are dropped", %{net: net} do
      names = Enum.map(net.lines, & &1.name)
      assert names == ["l1", "l2"]
      # l3 under construction, l4 self-loop, l5 endpoint not in the bus set.
      assert net.dropped.lines == 3
    end

    test "HVDC links are reported, not silently absent", %{net: net} do
      # This repo models HVDC as scheduled injections, so wiring them as AC
      # branches would be wrong — but dropping them without saying so makes a
      # network look more connected than it is.
      assert net.dropped.hvdc_links == 1
    end
  end

  describe "derived impedance" do
    test "a 380 kV double circuit converts to per-unit on the solver base", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "l1"))

      # Al/St 240/40 4-bundle 380: 0.246 ohm/km * 60 km / 2 circuits / (380^2/100)
      assert_in_delta l.x_pu, 0.005_110_803_324, 1.0e-9
      assert_in_delta l.r_pu, 0.000_623_268_698, 1.0e-9
      # Charging scales UP with circuits while series impedance scales down.
      assert_in_delta l.b_pu, 0.751_237_741_5, 1.0e-8
      assert l.num_parallel == 2.0
    end

    test "the class lookup follows the line's own voltage", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "l2"))
      # 220 kV 2-bundle: 0.301 ohm/km * 40 km / (220^2/100)
      assert_in_delta l.x_pu, 0.024_876_033_058, 1.0e-9
    end

    test "rating comes from the conductor's thermal current, not a class table", %{net: net} do
      l = Enum.find(net.lines, &(&1.name == "l1"))
      # S = sqrt(3) * kV * kA * circuits
      assert_in_delta l.rating_a_mva, :math.sqrt(3.0) * 380.0 * 2.58 * 2.0, 1.0e-6
    end

    test "line_type/1 snaps to the nearest standard class" do
      assert GridKit.line_type(400.0) == GridKit.line_type(380.0)
      assert GridKit.line_type(225.0) == GridKit.line_type(220.0)
      # A voltage-less row must not raise; it gets a defensible default.
      assert is_tuple(GridKit.line_type(nil))
      assert is_tuple(GridKit.line_type(0.0))
    end
  end

  describe "provenance and frequency" do
    test "the dataset's own caveats travel with the data", %{net: net} do
      # Its README says it is unofficial, unendorsed, and that voltage is the
      # LOWER BOUND of the ENTSO-E range. Those change how every number should
      # be read, so they are carried rather than left in a commit message.
      assert net.provenance.licence == "CC-BY-4.0"
      assert net.provenance.endorsed == false
      assert Enum.any?(net.provenance.known_defects, &(&1 =~ "LOWER BOUND"))
      assert Enum.any?(net.provenance.known_defects, &(&1 =~ "DERIVED"))
    end

    test "it is stamped 50 Hz, so a cascade on it is refused", %{net: net} do
      assert net.nominal_hz == 50.0
      assert net.system_standard.key == :entsoe_50hz

      assert_raise ArgumentError, ~r/frequency model is compiled for 60.0 Hz/, fn ->
        PowerModel.Grid.SystemStandard.compatible!(net)
      end
    end
  end

  describe "the solver contract" do
    test "the import partitions without further plumbing", %{net: net} do
      # No generator table in the source, so supply one to make an island
      # solvable — the point is that the SHAPE is right.
      with_gen = %{
        net
        | generators: [
            %{id: 1, bus_id: hd(net.buses).id, p_max_mw: 100.0, capacity_factor: 1.0}
          ]
      }

      {subs, _dead} = PowerModel.Solver.Partition.split(with_gen)
      assert subs != []
      assert Enum.all?(subs, &Map.has_key?(&1, :buses))
    end

    test "loads are only present when a caller supplies them", %{net: net} do
      # The source carries no demand. Inventing it silently is how a study
      # starts measuring its own assumptions.
      assert net.loads == []

      bus = hd(net.buses).id
      with_load = GridKit.load!(@dir, loads: %{bus => 250.0})
      l = hd(with_load.loads)
      assert l.p_mw == 250.0
      assert_in_delta l.q_mvar, 250.0 * :math.tan(:math.acos(0.95)), 1.0e-9
    end
  end
end
