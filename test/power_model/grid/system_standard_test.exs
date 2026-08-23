defmodule PowerModel.Grid.SystemStandardTest do
  @moduledoc """
  The 50/60 Hz guard.

  Voltage ports for free — everything electrical is per-unit on
  `v_nom^2 / base_mva`. Frequency does not: `Solver.Frequency` compiles
  `@f0 60.0` and a UFLS program at 59.3/58.9/58.5/58.1 Hz, and a HEALTHY
  Continental European system at 50 Hz sits below all four. A European cascade
  run through the US model sheds load before any contingency.

  Until the frequency layer is threaded properly, the correct behaviour is a
  loud stop — and these tests exist because the failure it replaces is silent.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Grid.SystemStandard

  doctest PowerModel.Grid.SystemStandard

  test "the mismatch this guards is real, not theoretical" do
    us = SystemStandard.fetch!(:nerc_60hz)
    eu = SystemStandard.fetch!(:entsoe_50hz)

    below_all =
      Enum.count(us.ufls_stages, fn {threshold, _shed, _delay} -> eu.nominal_hz < threshold end)

    assert below_all == length(us.ufls_stages),
           "if this stops holding, the guard can be relaxed — until then every US UFLS " <>
             "stage fires on an undisturbed European grid"
  end

  test "European settings are marked representative, not authoritative" do
    # ENTSO-E sets the framework; national TSOs set the demand-disconnection
    # scheme. Presenting the default as citable would be the wrong kind of
    # confident.
    assert SystemStandard.fetch!(:entsoe_50hz).confidence == :representative
    assert SystemStandard.fetch!(:nerc_60hz).confidence == :authoritative
  end

  test "European thresholds sit below European nominal, as they must" do
    eu = SystemStandard.fetch!(:entsoe_50hz)

    for {threshold, _shed, _delay} <- eu.ufls_stages do
      assert threshold < eu.nominal_hz
    end

    for {floor_hz, _secs} <- eu.frequency_ride_through do
      assert floor_hz < eu.nominal_hz
    end

    assert eu.btm_underfrequency_hz < eu.nominal_hz
  end

  test "an unknown key raises rather than defaulting to the US" do
    assert_raise ArgumentError, ~r/unknown system standard/, fn ->
      SystemStandard.fetch!(:no_such_grid)
    end
  end

  describe "compatible!/2" do
    test "a snapshot with no stated frequency is allowed through" do
      # Every DB-backed snapshot is unstamped, and breaking those would fail
      # every existing cascade test.
      assert SystemStandard.compatible!(%{buses: []}) == :ok
    end

    test "a 60 Hz snapshot passes" do
      assert SystemStandard.compatible!(%{nominal_hz: 60.0}) == :ok
    end

    test "a 50 Hz snapshot is refused, and the message says why" do
      err =
        assert_raise ArgumentError, fn ->
          SystemStandard.compatible!(%{nominal_hz: 50.0})
        end

      assert err.message =~ "50.0 Hz"
      assert err.message =~ "59.3"
      assert err.message =~ "entsoe_50hz"
      # It must also say what IS still safe, or the guard just blocks work.
      assert err.message =~ "Steady-state power flow is unaffected"
    end
  end

  describe "the cascade refuses a mismatched network" do
    @tag :db
    test "Cascade.init/3 raises on a 50 Hz snapshot" do
      snapshot = %{
        buses: [%{id: 1, base_kv: 380.0, bus_type: 3, vm_pu: 1.0}],
        lines: [],
        transformers: [],
        generators: [%{id: 1, bus_id: 1, p_max_mw: 10.0, capacity_factor: 1.0}],
        loads: [],
        nominal_hz: 50.0
      }

      assert_raise ArgumentError, ~r/frequency model is compiled for 60.0 Hz/, fn ->
        PowerModel.Failure.Cascade.init(snapshot, 100.0)
      end
    end
  end

  describe "the imported European network is stamped" do
    test "the reader detects 50 Hz and names the standard" do
      net = PowerModel.Network.PyPSA.load!("test/fixtures/pypsa/mini")
      assert net.nominal_hz == 50.0
      assert net.system_standard.key == :entsoe_50hz
    end

    test "an explicit override wins over detection" do
      net = PowerModel.Network.PyPSA.load!("test/fixtures/pypsa/mini", nominal_hz: 60.0)
      assert net.nominal_hz == 60.0
      assert net.system_standard.key == :nerc_60hz
      assert SystemStandard.compatible!(net) == :ok
    end
  end
end
