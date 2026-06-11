defmodule PowerModel.Solver.Harmonics.ScenarioTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Harmonics.Scenario
  alias PowerModel.Solver.Harmonics.Scenario.{HarmonicDevice, HarmonicScenario}

  # ---------------------------------------------------------------------------
  # Helpers — plain-map builders matching Grid.get_grid_snapshot format
  # ---------------------------------------------------------------------------

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0,
      b_shunt_mvar: Keyword.get(opts, :b_shunt_mvar, 0.0)
    }
  end

  defp line(id, from, to, opts \\ []) do
    %{
      id: id,
      from_bus_id: from,
      to_bus_id: to,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: Keyword.get(opts, :b_pu, 0.02),
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 200.0)
    }
  end

  defp generator(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      prime_mover: Keyword.get(opts, :prime_mover, "ST"),
      status: Keyword.get(opts, :status, "in_service"),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      v_set_pu: Keyword.get(opts, :v_set_pu, 1.0),
      x_d_pu: Keyword.get(opts, :x_d_pu, nil),
      x_d_prime_pu: Keyword.get(opts, :x_d_prime_pu, nil),
      x_q_prime_pu: Keyword.get(opts, :x_q_prime_pu, nil),
      ra_pu: Keyword.get(opts, :ra_pu, nil)
    }
  end

  defp load_map(id, bus_id, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 20.0)
    }
  end

  # Standard 3-bus test system:
  #   Bus 1: Slack generator (200 MW NG)
  #   Bus 2: Solar farm (50 MW) + load (50 MW)
  #   Bus 3: Large industrial load (80 MW)
  #
  #   Bus 1 ---line_1--- Bus 2 ---line_2--- Bus 3
  defp snapshot_3bus do
    %{
      buses: [
        bus(1, bus_type: 3, base_kv: 138.0),
        bus(2, base_kv: 138.0),
        bus(3, base_kv: 138.0)
      ],
      lines: [
        line(1, 1, 2, r_pu: 0.01, x_pu: 0.1, b_pu: 0.02),
        line(2, 2, 3, r_pu: 0.015, x_pu: 0.12, b_pu: 0.015)
      ],
      transformers: [],
      generators: [
        generator(1, 1, p_max_mw: 200.0, fuel_type: "NG"),
        generator(2, 2, p_max_mw: 50.0, fuel_type: "SUN", capacity_factor: 0.25)
      ],
      loads: [
        load_map(1, 2, p_mw: 50.0),
        load_map(2, 3, p_mw: 80.0)
      ]
    }
  end

  # 4-bus system with two harmonic sources (for comparison tests):
  #   Bus 1: Slack gen (300 MW)
  #   Bus 2: 6-pulse converter station
  #   Bus 3: Solar farm (100 MW)
  #   Bus 4: Load bus (100 MW)
  #
  #   Bus 1 ---line_1--- Bus 2
  #     |                   |
  #   line_3             line_2
  #     |                   |
  #   Bus 4 ---line_4--- Bus 3
  defp snapshot_4bus do
    %{
      buses: [
        bus(1, bus_type: 3, base_kv: 345.0),
        bus(2, base_kv: 345.0),
        bus(3, base_kv: 345.0),
        bus(4, base_kv: 345.0)
      ],
      lines: [
        line(1, 1, 2, r_pu: 0.005, x_pu: 0.05, b_pu: 0.04),
        line(2, 2, 3, r_pu: 0.008, x_pu: 0.08, b_pu: 0.03),
        line(3, 1, 4, r_pu: 0.006, x_pu: 0.06, b_pu: 0.035),
        line(4, 4, 3, r_pu: 0.007, x_pu: 0.07, b_pu: 0.025)
      ],
      transformers: [],
      generators: [
        generator(1, 1, p_max_mw: 300.0, fuel_type: "NG"),
        generator(2, 3, p_max_mw: 100.0, fuel_type: "SUN", capacity_factor: 0.30)
      ],
      loads: [
        load_map(1, 2, p_mw: 60.0),
        load_map(2, 4, p_mw: 100.0)
      ]
    }
  end

  defp six_pulse_device(id, bus_id, p_mw) do
    %HarmonicDevice{
      id: id,
      bus_id: bus_id,
      device_type: :six_pulse,
      p_mw: p_mw,
      v_pu: 1.0,
      params: %{},
      active: true
    }
  end

  defp pwm_device(id, bus_id, p_mw, opts \\ []) do
    params = Keyword.get(opts, :params, %{})

    %HarmonicDevice{
      id: id,
      bus_id: bus_id,
      device_type: :pwm_inverter,
      p_mw: p_mw,
      v_pu: Keyword.get(opts, :v_pu, 1.0),
      params: params,
      active: Keyword.get(opts, :active, true)
    }
  end

  # ===========================================================================
  # 1. Scenario Creation
  # ===========================================================================

  describe "create_scenario/2" do
    test "auto-detects IBR generators as PWM inverter sources" do
      snapshot = snapshot_3bus()
      scenario = Scenario.create_scenario(snapshot)

      assert %HarmonicScenario{} = scenario
      # Should detect generator 2 (SUN fuel_type) as a PWM inverter
      ibr_devices = Enum.filter(scenario.devices, &(&1.device_type == :pwm_inverter))
      assert length(ibr_devices) == 1

      dev = hd(ibr_devices)
      assert dev.bus_id == 2
      assert dev.active == true
      assert dev.id == {:gen, 2}
      # p_mw = 50.0 * 0.25 (capacity factor)
      assert_in_delta dev.p_mw, 12.5, 0.01
    end

    test "auto-detects large loads as potential arc furnace (inactive)" do
      snapshot = snapshot_3bus()
      scenario = Scenario.create_scenario(snapshot, arc_furnace_threshold_mw: 60.0)

      arc_devices = Enum.filter(scenario.devices, &(&1.device_type == :arc_furnace))
      assert length(arc_devices) == 1

      dev = hd(arc_devices)
      assert dev.bus_id == 3
      # inactive by default
      assert dev.active == false
      assert dev.p_mw == 80.0
    end

    test "respects auto_detect: false" do
      snapshot = snapshot_3bus()
      scenario = Scenario.create_scenario(snapshot, auto_detect: false)

      assert scenario.devices == []
    end

    test "sets max_harmonic and base_mva from options" do
      snapshot = snapshot_3bus()
      scenario = Scenario.create_scenario(snapshot, max_harmonic: 50, base_mva: 200.0)

      assert scenario.max_harmonic == 50
      assert scenario.base_mva == 200.0
    end

    test "skips retired generators" do
      snapshot = %{
        snapshot_3bus()
        | generators: [
            generator(1, 1, p_max_mw: 200.0, fuel_type: "NG"),
            generator(2, 2, p_max_mw: 50.0, fuel_type: "SUN", status: "retired")
          ]
      }

      scenario = Scenario.create_scenario(snapshot)

      ibr_devices = Enum.filter(scenario.devices, &(&1.device_type == :pwm_inverter))
      assert Enum.empty?(ibr_devices)
    end

    test "handles empty snapshot gracefully" do
      snapshot = %{buses: [], lines: [], transformers: [], generators: [], loads: []}
      scenario = Scenario.create_scenario(snapshot)

      assert scenario.devices == []
      assert scenario.filters == %{}
    end
  end

  # ===========================================================================
  # 2. Device Management
  # ===========================================================================

  describe "add_device/2" do
    test "adds a new device to the scenario" do
      scenario = %HarmonicScenario{}
      device = six_pulse_device(:conv1, 2, 50.0)

      updated = Scenario.add_device(scenario, device)
      assert length(updated.devices) == 1
      assert hd(updated.devices).id == :conv1
    end

    test "replaces existing device with same ID" do
      scenario = %HarmonicScenario{}
      device1 = six_pulse_device(:conv1, 2, 50.0)
      device2 = %{device1 | p_mw: 100.0}

      updated =
        scenario
        |> Scenario.add_device(device1)
        |> Scenario.add_device(device2)

      assert length(updated.devices) == 1
      assert hd(updated.devices).p_mw == 100.0
    end

    test "accepts a plain map and converts to struct" do
      scenario = %HarmonicScenario{}

      updated =
        Scenario.add_device(scenario, %{
          id: :test,
          bus_id: 1,
          device_type: :pwm_inverter,
          p_mw: 30.0
        })

      assert length(updated.devices) == 1
      assert %HarmonicDevice{} = hd(updated.devices)
    end

    test "preserves existing devices when adding" do
      scenario = %HarmonicScenario{}
      d1 = six_pulse_device(:a, 1, 10.0)
      d2 = six_pulse_device(:b, 2, 20.0)

      updated =
        scenario
        |> Scenario.add_device(d1)
        |> Scenario.add_device(d2)

      assert length(updated.devices) == 2
      ids = Enum.map(updated.devices, & &1.id)
      assert :a in ids
      assert :b in ids
    end
  end

  describe "remove_device/2" do
    test "removes a device by ID" do
      scenario = %HarmonicScenario{
        devices: [
          six_pulse_device(:a, 1, 10.0),
          six_pulse_device(:b, 2, 20.0)
        ]
      }

      updated = Scenario.remove_device(scenario, :a)
      assert length(updated.devices) == 1
      assert hd(updated.devices).id == :b
    end

    test "returns scenario unchanged if device not found" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:a, 1, 10.0)]}
      updated = Scenario.remove_device(scenario, :nonexistent)
      assert updated == scenario
    end
  end

  describe "modify_device/3" do
    test "modifies device type (6-pulse to 12-pulse conversion)" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:conv1, 2, 50.0)]}

      {:ok, updated} = Scenario.modify_device(scenario, :conv1, %{device_type: :twelve_pulse})
      dev = hd(updated.devices)
      assert dev.device_type == :twelve_pulse
      # unchanged
      assert dev.p_mw == 50.0
    end

    test "modifies power rating" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:conv1, 2, 50.0)]}

      {:ok, updated} = Scenario.modify_device(scenario, :conv1, %{p_mw: 100.0})
      assert hd(updated.devices).p_mw == 100.0
    end

    test "deactivates a device" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:conv1, 2, 50.0)]}

      {:ok, updated} = Scenario.modify_device(scenario, :conv1, %{active: false})
      assert hd(updated.devices).active == false
    end

    test "merges params maps (does not overwrite)" do
      device = %HarmonicDevice{
        id: :inv1,
        bus_id: 2,
        device_type: :pwm_inverter,
        p_mw: 50.0,
        params: %{switching_freq_hz: 5000, spectrum: %{5 => 4.0, 7 => 3.0}}
      }

      scenario = %HarmonicScenario{devices: [device]}

      {:ok, updated} =
        Scenario.modify_device(scenario, :inv1, %{
          params: %{spectrum: %{5 => 8.0}}
        })

      dev = hd(updated.devices)
      # The spectrum should be merged (new value for key 5, key 7 dropped due to merge)
      assert dev.params.spectrum == %{5 => 8.0}
      # switching_freq_hz preserved from original
      assert dev.params.switching_freq_hz == 5000
    end

    test "returns error for nonexistent device" do
      scenario = %HarmonicScenario{}
      assert {:error, :not_found} = Scenario.modify_device(scenario, :nope, %{p_mw: 10.0})
    end

    test "accepts keyword list changes" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:conv1, 2, 50.0)]}

      {:ok, updated} = Scenario.modify_device(scenario, :conv1, p_mw: 75.0)
      assert hd(updated.devices).p_mw == 75.0
    end
  end

  # ===========================================================================
  # 3. Filter Management
  # ===========================================================================

  describe "add_filter/6" do
    test "adds a single-tuned filter" do
      scenario = %HarmonicScenario{}
      updated = Scenario.add_filter(scenario, 2, :single_tuned, 5, 30.0, bus_kv: 138.0)

      assert Map.has_key?(updated.filters, 2)
      filter = updated.filters[2]
      assert filter.filter_type == :single_tuned
      assert filter.target_harmonic == 5
      assert filter.c_uf > 0.0
      assert filter.l_mh > 0.0
      assert filter.r_ohm > 0.0
    end

    test "adds a high-pass filter" do
      scenario = %HarmonicScenario{}
      updated = Scenario.add_filter(scenario, 3, :high_pass, 11, 20.0, bus_kv: 138.0)

      assert Map.has_key?(updated.filters, 3)
      filter = updated.filters[3]
      assert filter.filter_type == :high_pass
    end

    test "replaces existing filter at same bus" do
      scenario = %HarmonicScenario{}

      updated =
        scenario
        |> Scenario.add_filter(2, :single_tuned, 5, 30.0)
        |> Scenario.add_filter(2, :single_tuned, 7, 25.0)

      assert map_size(updated.filters) == 1
      assert updated.filters[2].target_harmonic == 7
    end
  end

  describe "remove_filter/2" do
    test "removes filter at specified bus" do
      scenario =
        %HarmonicScenario{}
        |> Scenario.add_filter(2, :single_tuned, 5, 30.0)

      updated = Scenario.remove_filter(scenario, 2)
      assert updated.filters == %{}
    end

    test "returns scenario unchanged if no filter at bus" do
      scenario = %HarmonicScenario{}
      updated = Scenario.remove_filter(scenario, 99)
      assert updated == scenario
    end
  end

  # ===========================================================================
  # 4. List and Summary
  # ===========================================================================

  describe "list_devices/2" do
    setup do
      devices = [
        six_pulse_device(:a, 1, 10.0),
        pwm_device(:b, 2, 20.0),
        %HarmonicDevice{id: :c, bus_id: 2, device_type: :arc_furnace, p_mw: 30.0, active: false}
      ]

      scenario = %HarmonicScenario{devices: devices}
      {:ok, scenario: scenario}
    end

    test "returns all devices with no filter", %{scenario: scenario} do
      assert length(Scenario.list_devices(scenario)) == 3
    end

    test "filters by bus_id", %{scenario: scenario} do
      devs = Scenario.list_devices(scenario, bus_id: 2)
      assert length(devs) == 2
      assert Enum.all?(devs, &(&1.bus_id == 2))
    end

    test "filters by device_type", %{scenario: scenario} do
      devs = Scenario.list_devices(scenario, device_type: :six_pulse)
      assert length(devs) == 1
      assert hd(devs).id == :a
    end

    test "filters by active_only", %{scenario: scenario} do
      devs = Scenario.list_devices(scenario, active_only: true)
      assert length(devs) == 2
      assert Enum.all?(devs, & &1.active)
    end

    test "combines filters", %{scenario: scenario} do
      devs = Scenario.list_devices(scenario, bus_id: 2, active_only: true)
      assert length(devs) == 1
      assert hd(devs).id == :b
    end
  end

  describe "summary/1" do
    test "reports device counts and types" do
      scenario = %HarmonicScenario{
        devices: [
          six_pulse_device(:a, 1, 50.0),
          six_pulse_device(:b, 2, 30.0),
          pwm_device(:c, 3, 100.0),
          %HarmonicDevice{id: :d, bus_id: 4, device_type: :arc_furnace, p_mw: 80.0, active: false}
        ],
        filters: %{2 => %{filter_type: :single_tuned}}
      }

      s = Scenario.summary(scenario)

      assert s.total_devices == 4
      assert s.active_devices == 3
      assert s.inactive_devices == 1
      assert s.devices_by_type == %{six_pulse: 2, pwm_inverter: 1}
      assert_in_delta s.total_injection_mw, 180.0, 0.01
      assert s.filter_count == 1
      assert s.filter_bus_ids == [2]
      assert length(s.source_bus_ids) == 3
    end
  end

  # ===========================================================================
  # 5. Run Analysis
  # ===========================================================================

  describe "run/3" do
    test "produces THD map for all buses" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13,
        base_mva: 100.0
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert is_map(result.thd)
      assert Map.has_key?(result.thd, 1)
      assert Map.has_key?(result.thd, 2)
      assert Map.has_key?(result.thd, 3)

      # Bus 2 should have higher THD (harmonic source is here)
      assert result.thd[2] > 0.0
    end

    test "includes individual harmonic distortion" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13,
        base_mva: 100.0
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert is_map(result.individual_hd)
      # Bus 2 should have individual HD at characteristic harmonics (5, 7, 11, 13)
      bus2_hd = result.individual_hd[2]
      assert is_map(bus2_hd)
      assert Map.has_key?(bus2_hd, 5)
      assert Map.has_key?(bus2_hd, 7)
    end

    test "includes IEEE 519 compliance check" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13,
        base_mva: 100.0
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert is_list(result.ieee_519)
      # one per bus
      assert length(result.ieee_519) == 3

      bus2_compliance = Enum.find(result.ieee_519, &(&1.bus_id == 2))
      assert is_boolean(bus2_compliance.compliant)
      assert bus2_compliance.thd_pct >= 0.0
    end

    test "includes impedance scan at source buses" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13,
        base_mva: 100.0
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert Map.has_key?(result.impedance_scans, 2)
      scan = result.impedance_scans[2]
      assert is_list(scan)
      assert length(scan) > 0

      # Each entry is {h, z_mag, z_angle}
      {h, z_mag, _z_angle} = hd(scan)
      assert is_integer(h) or is_float(h)
      assert z_mag >= 0.0
    end

    test "reports worst bus and total violations" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13,
        base_mva: 100.0
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      {worst_id, worst_thd} = result.worst_bus
      assert is_integer(worst_id)
      assert worst_thd >= 0.0
      assert is_integer(result.total_violations)
    end

    test "inactive devices do not contribute to injections" do
      snapshot = snapshot_3bus()

      # Active device
      scenario_active = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13
      }

      # Same device but inactive
      inactive_dev = %{six_pulse_device(:conv1, 2, 50.0) | active: false}

      scenario_inactive = %HarmonicScenario{
        devices: [inactive_dev],
        max_harmonic: 13
      }

      {:ok, result_active} = Scenario.run(scenario_active, snapshot)
      {:ok, result_inactive} = Scenario.run(scenario_inactive, snapshot)

      # Inactive scenario should have zero THD everywhere
      assert Enum.all?(Map.values(result_inactive.thd), &(&1 < 1.0e-10))
      # Active scenario should have nonzero THD at bus 2
      assert result_active.thd[2] > 0.0
    end

    test "respects custom fundamental solution" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 7
      }

      fund_sol = %{
        bus_ids: [1, 2, 3],
        vm_pu: [1.0, 0.95, 0.90],
        va_rad: [0.0, -0.05, -0.10]
      }

      {:ok, result} = Scenario.run(scenario, snapshot, fundamental_solution: fund_sol)

      # The fundamental voltages should match what we provided
      assert result.harmonic_voltages[1][1] == {1.0, 0.0}
      assert result.harmonic_voltages[1][2] == {0.95, -0.05}
    end
  end

  # ===========================================================================
  # 6. Converter Topology Switching
  # ===========================================================================

  describe "6-pulse to 12-pulse conversion" do
    test "switching from 6-pulse to 12-pulse reduces 5th and 7th harmonics" do
      snapshot = snapshot_3bus()

      # Scenario with 6-pulse converter
      scenario_6p = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13
      }

      # Scenario with 12-pulse converter (same bus, same power)
      device_12p = %HarmonicDevice{
        id: :conv1,
        bus_id: 2,
        device_type: :twelve_pulse,
        p_mw: 50.0,
        active: true
      }

      scenario_12p = %HarmonicScenario{
        devices: [device_12p],
        max_harmonic: 13
      }

      {:ok, result_6p} = Scenario.run(scenario_6p, snapshot)
      {:ok, result_12p} = Scenario.run(scenario_12p, snapshot)

      # 12-pulse should have significantly lower THD than 6-pulse
      # because 5th and 7th harmonics are cancelled
      assert result_12p.thd[2] < result_6p.thd[2]

      # Check that 5th harmonic is much smaller with 12-pulse
      hd_5_6p = get_in(result_6p, [:individual_hd, 2, 5]) || 0.0
      hd_5_12p = get_in(result_12p, [:individual_hd, 2, 5]) || 0.0
      # should be essentially zero for ideal 12-pulse
      assert hd_5_12p < hd_5_6p * 0.1
    end

    test "modify_device can switch topology in place" do
      scenario = %HarmonicScenario{devices: [six_pulse_device(:conv1, 2, 50.0)]}

      {:ok, updated} = Scenario.modify_device(scenario, :conv1, %{device_type: :twelve_pulse})
      assert hd(updated.devices).device_type == :twelve_pulse
      # power preserved
      assert hd(updated.devices).p_mw == 50.0
    end
  end

  # ===========================================================================
  # 7. PWM Inverter Custom Spectrum ("solar farm 5th harmonic at 8%")
  # ===========================================================================

  describe "custom inverter spectrum" do
    test "custom 5th harmonic injection produces expected THD pattern" do
      snapshot = snapshot_3bus()

      # Default PWM inverter (standard spectrum)
      scenario_default = %HarmonicScenario{
        devices: [pwm_device(:solar1, 2, 100.0)],
        max_harmonic: 13
      }

      # Degraded inverter with elevated 5th harmonic
      scenario_bad = %HarmonicScenario{
        devices: [
          pwm_device(:solar1, 2, 100.0,
            params: %{spectrum: %{5 => 8.0, 7 => 5.0, 11 => 2.0, 13 => 1.5}}
          )
        ],
        max_harmonic: 13
      }

      {:ok, result_default} = Scenario.run(scenario_default, snapshot)
      {:ok, result_bad} = Scenario.run(scenario_bad, snapshot)

      # Elevated 5th harmonic should increase THD at bus 2
      assert result_bad.thd[2] > result_default.thd[2]
    end

    test "what_if can model inverter degradation" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [pwm_device(:solar1, 2, 100.0)],
        max_harmonic: 13
      }

      # Inject elevated 5th harmonic at 12% (default is 4%) — clearly worse
      changes = [
        {:modify_device, :solar1,
         %{
           params: %{
             spectrum: %{
               2 => 0.5,
               3 => 2.0,
               5 => 12.0,
               7 => 8.0,
               9 => 1.0,
               11 => 2.0,
               13 => 1.5
             }
           }
         }}
      ]

      {:ok, result} = Scenario.what_if(scenario, snapshot, changes)

      assert result.comparison != nil
      # The source bus (bus 2) should have higher THD with elevated injection
      assert result.modified.thd[2] > result.baseline.thd[2]
    end
  end

  # ===========================================================================
  # 8. Filter Application
  # ===========================================================================

  describe "filters reduce THD" do
    test "5th harmonic filter reduces THD at source bus" do
      snapshot = snapshot_3bus()

      # Scenario with 6-pulse converter (dominant 5th harmonic)
      scenario_no_filter = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 80.0)],
        max_harmonic: 13
      }

      scenario_with_filter =
        scenario_no_filter
        |> Scenario.add_filter(2, :single_tuned, 5, 30.0, bus_kv: 138.0)

      {:ok, result_before} = Scenario.run(scenario_no_filter, snapshot)
      {:ok, result_after} = Scenario.run(scenario_with_filter, snapshot)

      comparison = Scenario.compare(result_before, result_after)

      # Bus 2 THD should improve
      assert comparison.thd_improvement[2] > 0.0
    end

    test "what_if with filter addition" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 80.0)],
        max_harmonic: 13
      }

      changes = [{:add_filter, 2, :single_tuned, 5, 30.0}]

      {:ok, result} = Scenario.what_if(scenario, snapshot, changes)

      # Should have both baseline and comparison
      assert result.baseline != nil
      assert result.comparison != nil
    end
  end

  # ===========================================================================
  # 9. Compare Results
  # ===========================================================================

  describe "compare/2" do
    test "computes THD improvement between two results" do
      snapshot = snapshot_3bus()

      scenario_before = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 80.0)],
        max_harmonic: 13
      }

      scenario_after = %HarmonicScenario{
        devices: [
          %HarmonicDevice{
            id: :conv1,
            bus_id: 2,
            device_type: :twelve_pulse,
            p_mw: 80.0,
            active: true
          }
        ],
        max_harmonic: 13
      }

      {:ok, result_before} = Scenario.run(scenario_before, snapshot)
      {:ok, result_after} = Scenario.run(scenario_after, snapshot)

      comparison = Scenario.compare(result_before, result_after)

      assert is_map(comparison.thd_improvement)
      assert is_map(comparison.thd_improvement_pct)
      assert is_float(comparison.average_thd_before)
      assert is_float(comparison.average_thd_after)

      # 12-pulse should have lower average THD
      assert comparison.average_thd_after < comparison.average_thd_before
    end

    test "tracks compliance changes" do
      # Create a synthetic result pair where compliance changes
      result_before = %{
        # bus 2 exceeds 5% THD limit
        thd: %{1 => 0.5, 2 => 6.0},
        worst_bus: {2, 6.0},
        total_violations: 1,
        ieee_519: [
          %{bus_id: 1, compliant: true, violations: []},
          %{bus_id: 2, compliant: false, violations: [%{type: :thd}]}
        ]
      }

      result_after = %{
        # bus 2 now below 5% THD limit
        thd: %{1 => 0.4, 2 => 3.0},
        worst_bus: {2, 3.0},
        total_violations: 0,
        ieee_519: [
          %{bus_id: 1, compliant: true, violations: []},
          %{bus_id: 2, compliant: true, violations: []}
        ]
      }

      comparison = Scenario.compare(result_before, result_after)

      assert 2 in comparison.newly_compliant
      assert Enum.empty?(comparison.newly_violated)
      assert comparison.total_violations_before == 1
      assert comparison.total_violations_after == 0
    end
  end

  # ===========================================================================
  # 10. What-If Analysis
  # ===========================================================================

  describe "what_if/4" do
    test "applies multiple changes in sequence" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [
          six_pulse_device(:conv1, 2, 50.0),
          pwm_device(:solar1, 2, 30.0)
        ],
        max_harmonic: 13
      }

      changes = [
        {:modify_device, :conv1, %{device_type: :twelve_pulse}},
        {:modify_device, :solar1, %{active: false}},
        {:add_filter, 2, :single_tuned, 11, 20.0}
      ]

      {:ok, result} = Scenario.what_if(scenario, snapshot, changes)

      # The modified scenario should reflect all changes
      modified_devices = result.modified.devices
      conv1 = Enum.find(modified_devices, &(&1.id == :conv1))
      assert conv1.device_type == :twelve_pulse

      solar1 = Enum.find(modified_devices, &(&1.id == :solar1))
      refute solar1.active

      assert Map.has_key?(result.modified.filters, 2)
    end

    test "does not mutate original scenario" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 13
      }

      _result =
        Scenario.what_if(scenario, snapshot, [
          {:modify_device, :conv1, %{device_type: :twelve_pulse}}
        ])

      # Original scenario should be unchanged
      assert hd(scenario.devices).device_type == :six_pulse
    end

    test "skips baseline when run_baseline: false" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 7
      }

      {:ok, result} = Scenario.what_if(scenario, snapshot, [], run_baseline: false)

      assert result.baseline == nil
      assert result.comparison == nil
      assert is_map(result.modified)
    end

    test "handles add and remove device changes" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 7
      }

      new_device = pwm_device(:solar1, 3, 40.0)

      changes = [
        {:remove_device, :conv1},
        {:add_device, new_device}
      ]

      {:ok, result} = Scenario.what_if(scenario, snapshot, changes)

      modified_devices = result.modified.devices
      assert length(modified_devices) == 1
      assert hd(modified_devices).id == :solar1
    end
  end

  # ===========================================================================
  # 11. Arc Furnace Scenarios
  # ===========================================================================

  describe "arc furnace modeling" do
    test "arc furnace produces broadband harmonics" do
      snapshot = snapshot_3bus()

      device = %HarmonicDevice{
        id: :eaf1,
        bus_id: 3,
        device_type: :arc_furnace,
        p_mw: 80.0,
        params: %{phase: :melting},
        active: true
      }

      scenario = %HarmonicScenario{devices: [device], max_harmonic: 13}
      {:ok, result} = Scenario.run(scenario, snapshot)

      # Arc furnaces inject at both odd and even harmonics
      bus3_hd = result.individual_hd[3]
      assert is_map(bus3_hd)
      # Should have 2nd harmonic (even) since EAF has significant even content
      assert Map.has_key?(bus3_hd, 2)
      assert bus3_hd[2] > 0.0
    end

    test "refining phase produces lower harmonics than melting" do
      snapshot = snapshot_3bus()

      scenario_melting = %HarmonicScenario{
        devices: [
          %HarmonicDevice{
            id: :eaf1,
            bus_id: 3,
            device_type: :arc_furnace,
            p_mw: 80.0,
            params: %{phase: :melting},
            active: true
          }
        ],
        max_harmonic: 13
      }

      scenario_refining = %HarmonicScenario{
        devices: [
          %HarmonicDevice{
            id: :eaf1,
            bus_id: 3,
            device_type: :arc_furnace,
            p_mw: 80.0,
            params: %{phase: :refining},
            active: true
          }
        ],
        max_harmonic: 13
      }

      {:ok, result_melting} = Scenario.run(scenario_melting, snapshot)
      {:ok, result_refining} = Scenario.run(scenario_refining, snapshot)

      # Melting phase should produce higher THD
      assert result_melting.thd[3] > result_refining.thd[3]
    end
  end

  # ===========================================================================
  # 12. Saturated Transformer Scenarios
  # ===========================================================================

  describe "saturated transformer modeling" do
    test "GIC saturation produces even harmonics" do
      snapshot = snapshot_3bus()

      device = %HarmonicDevice{
        id: :sat_xfmr1,
        bus_id: 2,
        device_type: :saturated_transformer,
        p_mw: 0.0,
        params: %{i_magnetizing_pu: 2.0, saturation_type: :gic},
        active: true
      }

      scenario = %HarmonicScenario{devices: [device], max_harmonic: 13}
      {:ok, result} = Scenario.run(scenario, snapshot)

      # GIC saturation is dominated by 2nd harmonic
      bus2_hd = result.individual_hd[2]
      assert Map.has_key?(bus2_hd, 2)
      assert bus2_hd[2] > 0.0
    end
  end

  # ===========================================================================
  # 13. Multi-source Scenarios
  # ===========================================================================

  describe "multiple harmonic sources" do
    test "sources at different buses both contribute to THD" do
      snapshot = snapshot_4bus()

      scenario = %HarmonicScenario{
        devices: [
          six_pulse_device(:conv1, 2, 60.0),
          pwm_device(:solar1, 3, 100.0)
        ],
        max_harmonic: 13
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      # Both source buses should have nonzero THD
      assert result.thd[2] > 0.0
      assert result.thd[3] > 0.0
    end

    test "adding a second source increases THD" do
      snapshot = snapshot_4bus()

      scenario_one = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 60.0)],
        max_harmonic: 13
      }

      scenario_two = %HarmonicScenario{
        devices: [
          six_pulse_device(:conv1, 2, 60.0),
          pwm_device(:solar1, 3, 100.0)
        ],
        max_harmonic: 13
      }

      {:ok, result_one} = Scenario.run(scenario_one, snapshot)
      {:ok, result_two} = Scenario.run(scenario_two, snapshot)

      # Adding a second source should generally increase THD somewhere
      # (not necessarily at every bus due to phase cancellation, but
      # at least at bus 3 where the new source is)
      assert result_two.thd[3] > result_one.thd[3]
    end
  end

  # ===========================================================================
  # 14. Custom Device Type
  # ===========================================================================

  describe "custom device type" do
    test "custom spectrum injects at specified harmonics" do
      snapshot = snapshot_3bus()

      device = %HarmonicDevice{
        id: :custom1,
        bus_id: 2,
        device_type: :custom,
        p_mw: 50.0,
        params: %{spectrum: %{3 => 10.0, 9 => 5.0}},
        active: true
      }

      scenario = %HarmonicScenario{devices: [device], max_harmonic: 13}
      {:ok, result} = Scenario.run(scenario, snapshot)

      bus2_hd = result.individual_hd[2]
      # Should have 3rd and 9th harmonics
      assert Map.has_key?(bus2_hd, 3)
      assert Map.has_key?(bus2_hd, 9)
      # Both should be nonzero
      assert bus2_hd[3] > 0.0
      assert bus2_hd[9] > 0.0
      # Note: 9th harmonic voltage can be larger than 3rd despite smaller
      # injection because network impedance Z(h) increases with h, so
      # V_h = Z_h * I_h can be larger at higher harmonics.
    end
  end

  # ===========================================================================
  # 15. Edge Cases
  # ===========================================================================

  describe "edge cases" do
    test "empty scenario with no devices produces zero THD" do
      snapshot = snapshot_3bus()
      scenario = %HarmonicScenario{devices: [], max_harmonic: 7}

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert Enum.all?(Map.values(result.thd), &(&1 < 1.0e-10))
    end

    test "scenario with only filters and no sources produces zero THD" do
      snapshot = snapshot_3bus()

      scenario =
        %HarmonicScenario{devices: []}
        |> Scenario.add_filter(2, :single_tuned, 5, 30.0)

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert Enum.all?(Map.values(result.thd), &(&1 < 1.0e-10))
    end

    test "very small power device produces negligible THD" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:tiny, 2, 0.001)],
        max_harmonic: 7
      }

      {:ok, result} = Scenario.run(scenario, snapshot)

      assert result.thd[2] < 0.01
    end

    test "what_if with empty changes returns same result as baseline" do
      snapshot = snapshot_3bus()

      scenario = %HarmonicScenario{
        devices: [six_pulse_device(:conv1, 2, 50.0)],
        max_harmonic: 7
      }

      {:ok, result} = Scenario.what_if(scenario, snapshot, [])

      # With no changes, THD should be the same
      Enum.each(Map.keys(result.baseline.thd), fn bus_id ->
        assert_in_delta result.baseline.thd[bus_id],
                        result.modified.thd[bus_id],
                        1.0e-10
      end)
    end
  end
end
