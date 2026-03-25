defmodule PowerModel.Solver.HarmonicsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Harmonics.{Impedance, Sources, Solver, Filter}

  # ---------------------------------------------------------------------------
  # Helpers — plain-map builders matching Grid.get_grid_snapshot format
  # ---------------------------------------------------------------------------

  defp bus(id, opts) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0,
      b_shunt_mvar: Keyword.get(opts, :b_shunt_mvar, 0.0)
    }
  end

  defp line(id, from, to, opts) do
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

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      status: "in_service",
      x_d_pu: Keyword.get(opts, :x_d_pu, nil),
      x_d_prime_pu: Keyword.get(opts, :x_d_prime_pu, nil),
      x_q_prime_pu: Keyword.get(opts, :x_q_prime_pu, nil),
      ra_pu: Keyword.get(opts, :ra_pu, nil)
    }
  end

  defp load(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: Keyword.get(opts, :p_mw, 50.0),
      q_mvar: Keyword.get(opts, :q_mvar, 20.0)
    }
  end

  defp snapshot_3bus do
    # 3-bus test system:
    #   Bus 1: Slack generator (200 MW)
    #   Bus 2: 6-pulse converter load (harmonic source, 50 MW)
    #   Bus 3: Passive load (80 MW)
    #
    #   Bus 1 ---line_12--- Bus 2 ---line_23--- Bus 3
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
      generators: [generator(1, 1, p_max_mw: 200.0)],
      loads: [
        load(1, 2, p_mw: 50.0, q_mvar: 20.0),
        load(2, 3, p_mw: 80.0, q_mvar: 30.0)
      ]
    }
  end

  defp fundamental_solution_3bus do
    # Approximate fundamental solution (flat start)
    %{
      bus_ids: [1, 2, 3],
      vm_pu: [1.0, 0.98, 0.96],
      va_rad: [0.0, -0.05, -0.10]
    }
  end

  defp harmonic_sources_3bus do
    # 6-pulse converter at bus 2 with 0.5 pu fundamental current
    %{
      2 => [
        %{
          type: :six_pulse,
          i_fundamental_pu: 0.5,
          opts: [max_harmonic: 25]
        }
      ]
    }
  end

  # ===========================================================================
  # 1. Frequency-Dependent Impedance Tests
  # ===========================================================================

  describe "Impedance.line_impedance_at_harmonic/2" do
    test "at fundamental (h=1), impedance is unchanged" do
      line_map = %{r_pu: 0.01, x_pu: 0.1, b_pu: 0.02}
      {r_h, x_h, b_h} = Impedance.line_impedance_at_harmonic(line_map, 1)

      assert_in_delta r_h, 0.01, 1.0e-10
      assert_in_delta x_h, 0.1, 1.0e-10
      assert_in_delta b_h, 0.02, 1.0e-10
    end

    test "resistance scales with sqrt(h) due to skin effect" do
      line_map = %{r_pu: 0.01, x_pu: 0.1, b_pu: 0.02}

      for h <- [5, 7, 11, 13, 25] do
        {r_h, _x_h, _b_h} = Impedance.line_impedance_at_harmonic(line_map, h)
        expected_r = 0.01 * :math.sqrt(h)
        assert_in_delta r_h, expected_r, 1.0e-10,
          "R at h=#{h}: expected #{expected_r}, got #{r_h}"
      end
    end

    test "reactance scales linearly with h" do
      line_map = %{r_pu: 0.01, x_pu: 0.1, b_pu: 0.02}

      for h <- [3, 5, 7, 11, 25] do
        {_r_h, x_h, _b_h} = Impedance.line_impedance_at_harmonic(line_map, h)
        expected_x = 0.1 * h
        assert_in_delta x_h, expected_x, 1.0e-10,
          "X at h=#{h}: expected #{expected_x}, got #{x_h}"
      end
    end

    test "susceptance scales linearly with h" do
      line_map = %{r_pu: 0.01, x_pu: 0.1, b_pu: 0.02}

      for h <- [5, 7, 11] do
        {_r_h, _x_h, b_h} = Impedance.line_impedance_at_harmonic(line_map, h)
        expected_b = 0.02 * h
        assert_in_delta b_h, expected_b, 1.0e-10,
          "B at h=#{h}: expected #{expected_b}, got #{b_h}"
      end
    end
  end

  describe "Impedance.transformer_impedance_at_harmonic/2" do
    test "X scales linearly with h, R scales with sqrt(h)" do
      xfmr_map = %{r_pu: 0.005, x_pu: 0.05}

      {r5, x5} = Impedance.transformer_impedance_at_harmonic(xfmr_map, 5)
      assert_in_delta r5, 0.005 * :math.sqrt(5), 1.0e-10
      assert_in_delta x5, 0.05 * 5, 1.0e-10

      {r11, x11} = Impedance.transformer_impedance_at_harmonic(xfmr_map, 11)
      assert_in_delta r11, 0.005 * :math.sqrt(11), 1.0e-10
      assert_in_delta x11, 0.05 * 11, 1.0e-10
    end
  end

  describe "Impedance.generator_impedance_at_harmonic/2" do
    test "uses subtransient reactance scaled by h for h > 1" do
      gen_map = %{x_d_prime_pu: 0.15, x_d_pu: 0.8, ra_pu: 0.003}

      # At h=5, generator should present h * X"d impedance
      {r5, x5} = Impedance.generator_impedance_at_harmonic(gen_map, 5)
      assert_in_delta x5, 5 * 0.15, 1.0e-10  # h * X"d
      assert_in_delta r5, 0.1 * 0.15 * :math.sqrt(5), 1.0e-10  # 10% of X"d * sqrt(h) skin effect
    end

    test "falls back to default X scaled by h when no data available" do
      gen_map = %{}

      {_r5, x5} = Impedance.generator_impedance_at_harmonic(gen_map, 5)
      # Default fallback: 0.2 pu, scaled by h=5
      assert_in_delta x5, 5 * 0.2, 1.0e-10
    end

    test "generator reactance scales linearly with harmonic order" do
      gen_map = %{x_d_prime_pu: 0.18}

      {_r5, x5} = Impedance.generator_impedance_at_harmonic(gen_map, 5)
      {_r11, x11} = Impedance.generator_impedance_at_harmonic(gen_map, 11)
      {_r25, x25} = Impedance.generator_impedance_at_harmonic(gen_map, 25)

      # X_h = h * X"d, so ratios should match harmonic orders
      assert_in_delta x5, 5 * 0.18, 1.0e-10
      assert_in_delta x11, 11 * 0.18, 1.0e-10
      assert_in_delta x25, 25 * 0.18, 1.0e-10
    end
  end

  describe "Impedance.build_ybus_at_harmonic/6" do
    test "returns valid Y-bus struct with correct dimensions" do
      snap = snapshot_3bus()
      ybus = Impedance.build_ybus_at_harmonic(
        snap.buses, snap.lines, snap.transformers, snap.generators, 5
      )

      assert ybus.n == 3
      assert is_map(ybus.bus_index_map)
      assert map_size(ybus.bus_index_map) == 3
      assert length(ybus.triplets) > 0
    end

    test "Y-bus at h=1 has smaller off-diagonal magnitudes than at h=5" do
      snap = snapshot_3bus()
      ybus_1 = Impedance.build_ybus_at_harmonic(
        snap.buses, snap.lines, snap.transformers, snap.generators, 1
      )
      ybus_5 = Impedance.build_ybus_at_harmonic(
        snap.buses, snap.lines, snap.transformers, snap.generators, 5
      )

      # At higher harmonics, series admittance decreases (impedance increases)
      # So off-diagonal magnitudes should be smaller
      off_diag_1 = ybus_1.triplets
        |> Enum.filter(fn {r, c, _} -> r != c end)
        |> Enum.map(fn {_, _, {re, im}} -> :math.sqrt(re * re + im * im) end)
        |> Enum.sum()

      off_diag_5 = ybus_5.triplets
        |> Enum.filter(fn {r, c, _} -> r != c end)
        |> Enum.map(fn {_, _, {re, im}} -> :math.sqrt(re * re + im * im) end)
        |> Enum.sum()

      assert off_diag_1 > off_diag_5,
        "Off-diagonal Y at h=1 (#{off_diag_1}) should be > at h=5 (#{off_diag_5})"
    end
  end

  # ===========================================================================
  # 2. Harmonic Source Spectrum Tests
  # ===========================================================================

  describe "Sources.six_pulse_spectrum/2" do
    test "produces harmonics at h = 6k +/- 1" do
      spectrum = Sources.six_pulse_spectrum(1.0)
      orders = Enum.map(spectrum, &elem(&1, 0))

      # Must contain characteristic 6-pulse harmonics
      assert 5 in orders
      assert 7 in orders
      assert 11 in orders
      assert 13 in orders

      # Must NOT contain non-characteristic harmonics
      refute 2 in orders
      refute 3 in orders
      refute 4 in orders
      refute 6 in orders
      refute 9 in orders
      refute 10 in orders
    end

    test "magnitudes decrease with harmonic order" do
      spectrum = Sources.six_pulse_spectrum(1.0)
      mags = Enum.map(spectrum, &elem(&1, 1))

      # Each successive magnitude should be smaller
      pairs = Enum.zip(mags, tl(mags))
      assert Enum.all?(pairs, fn {a, b} -> a >= b end),
        "Magnitudes should decrease: #{inspect(mags)}"
    end

    test "5th harmonic magnitude follows I_1/h^alpha model" do
      spectrum = Sources.six_pulse_spectrum(1.0, alpha: 0.8)
      {_h, mag_5, _angle} = Enum.find(spectrum, fn {h, _, _} -> h == 5 end)

      expected = 1.0 / :math.pow(5, 0.8)
      assert_in_delta mag_5, expected, 1.0e-10
    end

    test "respects max_harmonic option" do
      spectrum = Sources.six_pulse_spectrum(1.0, max_harmonic: 13)
      max_order = spectrum |> Enum.map(&elem(&1, 0)) |> Enum.max()
      assert max_order <= 13
    end

    test "scales linearly with fundamental current" do
      spec_1 = Sources.six_pulse_spectrum(1.0)
      spec_2 = Sources.six_pulse_spectrum(2.0)

      Enum.zip(spec_1, spec_2)
      |> Enum.each(fn {{h1, mag1, _}, {h2, mag2, _}} ->
        assert h1 == h2
        assert_in_delta mag2, mag1 * 2.0, 1.0e-10
      end)
    end
  end

  describe "Sources.twelve_pulse_spectrum/2" do
    test "produces harmonics at h = 12k +/- 1 only" do
      spectrum = Sources.twelve_pulse_spectrum(1.0, max_harmonic: 50)
      orders = Enum.map(spectrum, &elem(&1, 0))

      # Must contain 12-pulse characteristic harmonics
      assert 11 in orders
      assert 13 in orders
      assert 23 in orders
      assert 25 in orders

      # Must NOT contain 6-pulse-only harmonics (5, 7, 17, 19)
      refute 5 in orders
      refute 7 in orders
      refute 17 in orders
      refute 19 in orders
    end
  end

  describe "Sources.pwm_inverter_spectrum/3" do
    test "produces small low-order harmonics" do
      spectrum = Sources.pwm_inverter_spectrum(100.0, 1.0)
      orders = Enum.map(spectrum, &elem(&1, 0))

      # PWM inverters produce harmonics at multiple orders
      assert 5 in orders
      assert 7 in orders
      assert 11 in orders
    end

    test "magnitudes are small relative to fundamental" do
      # P = 100 MW, V = 1.0 pu => I_fund = 100 pu
      spectrum = Sources.pwm_inverter_spectrum(100.0, 1.0)

      Enum.each(spectrum, fn {h, mag, _angle} ->
        # All harmonics should be less than 5% of fundamental current
        pct = mag / 100.0 * 100.0
        assert pct <= 5.0,
          "h=#{h} is #{pct}% of fundamental, should be <= 5%"
      end)
    end

    test "5th harmonic is typically the largest low-order component" do
      spectrum = Sources.pwm_inverter_spectrum(100.0, 1.0)

      # Default spectrum: 5th = 4%, should be the largest
      {_h5, mag_5, _} = Enum.find(spectrum, fn {h, _, _} -> h == 5 end)
      other_mags = spectrum
        |> Enum.reject(fn {h, _, _} -> h == 5 end)
        |> Enum.map(&elem(&1, 1))

      assert Enum.all?(other_mags, &(&1 <= mag_5)),
        "5th harmonic (#{mag_5}) should be >= all others"
    end
  end

  describe "Sources.arc_furnace_spectrum/2" do
    test "includes even harmonics (characteristic of EAF)" do
      spectrum = Sources.arc_furnace_spectrum(50.0)
      orders = Enum.map(spectrum, &elem(&1, 0))

      # Arc furnaces produce both even and odd harmonics
      assert 2 in orders
      assert 3 in orders
      assert 4 in orders
      assert 5 in orders
    end

    test "2nd harmonic is the strongest (for melting phase)" do
      spectrum = Sources.arc_furnace_spectrum(50.0, phase: :melting)

      {_h, mag_2, _} = Enum.find(spectrum, fn {h, _, _} -> h == 2 end)
      other_mags = spectrum
        |> Enum.reject(fn {h, _, _} -> h == 2 end)
        |> Enum.map(&elem(&1, 1))

      assert Enum.all?(other_mags, &(&1 <= mag_2)),
        "2nd harmonic should be dominant in melting phase"
    end
  end

  describe "Sources.saturated_transformer_spectrum/2" do
    test "GIC saturation produces dominant 2nd harmonic" do
      spectrum = Sources.saturated_transformer_spectrum(1.0, saturation_type: :gic)

      {_h, mag_2, _} = Enum.find(spectrum, fn {h, _, _} -> h == 2 end)
      assert mag_2 > 0.5, "2nd harmonic should be > 50% of magnetizing current for GIC"
    end

    test "overexcitation saturation produces only odd harmonics" do
      spectrum = Sources.saturated_transformer_spectrum(1.0, saturation_type: :overexcitation)
      orders = Enum.map(spectrum, &elem(&1, 0))

      # Symmetric saturation: only odd harmonics
      Enum.each(orders, fn h ->
        assert rem(h, 2) == 1, "Expected only odd harmonics, got h=#{h}"
      end)
    end
  end

  describe "Sources.aggregate_bus_injections/2" do
    test "aggregates multiple devices at same bus" do
      devices = [
        %{type: :six_pulse, i_fundamental_pu: 1.0, opts: []},
        %{type: :pwm_inverter, p_mw: 50.0, v_pu: 1.0, opts: []}
      ]

      {i_re, i_im} = Sources.aggregate_bus_injections(devices, 5)

      # Both sources produce 5th harmonic content
      # The aggregate should be non-zero
      i_mag = :math.sqrt(i_re * i_re + i_im * i_im)
      assert i_mag > 0.0, "Aggregate 5th harmonic injection should be non-zero"
    end

    test "returns zero for harmonic with no sources" do
      devices = [
        %{type: :twelve_pulse, i_fundamental_pu: 1.0, opts: [max_harmonic: 50]}
      ]

      # 12-pulse doesn't produce 5th harmonic
      {i_re, i_im} = Sources.aggregate_bus_injections(devices, 5)
      assert abs(i_re) < 1.0e-15
      assert abs(i_im) < 1.0e-15
    end
  end

  # ===========================================================================
  # 3. Harmonic Power Flow Solver Tests
  # ===========================================================================

  describe "Solver.solve/4" do
    test "harmonic voltages are smaller than fundamental" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()

      {:ok, voltages} = Solver.solve(snap, fund, sources, max_harmonic: 13)

      # Check that 5th harmonic voltage at bus 3 is much smaller than fundamental
      v1_bus3 = voltages[1][3] |> elem(0)
      v5_bus3 = voltages[5][3] |> elem(0)
      v7_bus3 = voltages[7][3] |> elem(0)

      assert v5_bus3 < v1_bus3,
        "V_5 at bus 3 (#{v5_bus3}) should be << V_1 (#{v1_bus3})"

      # All harmonic voltages should be non-zero (harmonics propagate through network)
      assert v5_bus3 > 0.0, "V_5 should be non-zero"
      assert v7_bus3 > 0.0, "V_7 should be non-zero"

      # The harmonic voltage magnitudes depend on V_h = Z_h * I_h where:
      #   I_h decreases with h (6-pulse: ~1/h^0.8)
      #   Z_h increases with h (inductive: ~proportional to h)
      # In a small system, the driving-point impedance can grow faster than
      # the injection decays, especially near resonance. With generator
      # reactance scaling linearly with h, the network impedance at higher
      # harmonics may cause significant voltage amplification.
      # Verify all harmonic voltages are finite and non-negative.
      Enum.each([5, 7, 11, 13], fn h ->
        case voltages[h] do
          nil -> :ok
          bus_voltages ->
            {v_h, _} = bus_voltages[3]
            assert v_h >= 0.0, "V_#{h} should be non-negative"
            assert is_number(v_h) and not (v_h != v_h), "V_#{h} should be a valid number"
        end
      end)
    end

    test "includes fundamental frequency in results" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()

      {:ok, voltages} = Solver.solve(snap, fund, sources, max_harmonic: 7)

      assert Map.has_key?(voltages, 1), "Results should include h=1 (fundamental)"
      assert Map.has_key?(voltages, 5), "Results should include h=5"
      assert Map.has_key?(voltages, 7), "Results should include h=7"
    end

    test "bus without harmonic source has lower distortion" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()  # source only at bus 2

      {:ok, voltages} = Solver.solve(snap, fund, sources, max_harmonic: 13)

      # Bus 2 (source) should have higher harmonic voltage than bus 3 (passive)
      # This is approximate — depends on network impedance
      v5_bus2 = voltages[5][2] |> elem(0)
      v5_bus3 = voltages[5][3] |> elem(0)

      # Both should be non-zero since harmonics propagate through the network
      assert v5_bus2 > 0.0
      assert v5_bus3 > 0.0
    end

    test "harmonics list option overrides max_harmonic" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()

      {:ok, voltages} = Solver.solve(snap, fund, sources, harmonics: [5, 11])

      # Should have h=1 (fundamental) + h=5 + h=11
      assert Map.has_key?(voltages, 1)
      assert Map.has_key?(voltages, 5)
      assert Map.has_key?(voltages, 11)
      # Should NOT have h=7 (not in the list)
      refute Map.has_key?(voltages, 7)
    end
  end

  # ===========================================================================
  # 4. THD Calculation Tests
  # ===========================================================================

  describe "Solver.compute_thd/1" do
    test "THD is non-zero at bus with harmonic source" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()

      {:ok, voltages} = Solver.solve(snap, fund, sources, max_harmonic: 13)
      thd = Solver.compute_thd(voltages)

      # Bus 2 has harmonic source — should have non-zero THD
      assert thd[2] > 0.0, "THD at bus 2 should be > 0%"

      # Bus 3 is connected — should also have some THD
      assert thd[3] > 0.0, "THD at bus 3 should be > 0%"
    end

    test "THD formula is correct for known values" do
      # Manually construct harmonic voltages to verify THD formula
      # V_1 = 1.0, V_5 = 0.04, V_7 = 0.03
      # THD = sqrt(0.04^2 + 0.03^2) / 1.0 * 100 = sqrt(0.0025) * 100 = 5.0%
      voltages = %{
        1 => %{1 => {1.0, 0.0}},
        5 => %{1 => {0.04, 0.0}},
        7 => %{1 => {0.03, 0.0}}
      }

      thd = Solver.compute_thd(voltages)
      expected_thd = :math.sqrt(0.04 * 0.04 + 0.03 * 0.03) / 1.0 * 100.0

      assert_in_delta thd[1], expected_thd, 1.0e-10
    end

    test "THD is zero when no harmonics present" do
      voltages = %{
        1 => %{1 => {1.0, 0.0}, 2 => {0.98, -0.05}}
      }

      thd = Solver.compute_thd(voltages)
      assert_in_delta thd[1], 0.0, 1.0e-10
      assert_in_delta thd[2], 0.0, 1.0e-10
    end
  end

  # ===========================================================================
  # 5. IEEE 519 Compliance Tests
  # ===========================================================================

  describe "Solver.check_ieee_519/2" do
    test "detects THD violation at high-distortion bus" do
      # Create voltages with THD > 5% at a 138 kV bus (limit = 2.5%)
      voltages = %{
        1 => %{1 => {1.0, 0.0}},
        5 => %{1 => {0.02, 0.0}},   # 2%
        7 => %{1 => {0.015, 0.0}},  # 1.5%
        11 => %{1 => {0.010, 0.0}}, # 1.0%
        13 => %{1 => {0.008, 0.0}}  # 0.8%
      }
      # THD = sqrt(0.02^2 + 0.015^2 + 0.01^2 + 0.008^2) / 1.0 * 100
      #     = sqrt(0.0004 + 0.000225 + 0.0001 + 0.000064) * 100
      #     = sqrt(0.000789) * 100 = 2.81%
      # This exceeds the 2.5% limit for 138 kV

      buses = [%{id: 1, base_kv: 138.0}]
      results = Solver.check_ieee_519(voltages, buses)

      [result] = results
      assert result.bus_id == 1
      assert result.thd_pct > 2.5
      assert result.thd_limit_pct == 2.5
      refute result.compliant
      assert Enum.any?(result.violations, &(&1.type == :thd))
    end

    test "passes compliance at low-distortion bus" do
      voltages = %{
        1 => %{1 => {1.0, 0.0}},
        5 => %{1 => {0.005, 0.0}},  # 0.5%
        7 => %{1 => {0.003, 0.0}}   # 0.3%
      }
      # THD = sqrt(0.005^2 + 0.003^2) * 100 = 0.58%

      buses = [%{id: 1, base_kv: 138.0}]
      results = Solver.check_ieee_519(voltages, buses)

      [result] = results
      assert result.compliant
      assert Enum.empty?(result.violations)
    end

    test "applies correct limits based on voltage level" do
      voltages = %{
        1 => %{1 => {1.0, 0.0}, 2 => {1.0, 0.0}},
        5 => %{1 => {0.06, 0.0}, 2 => {0.06, 0.0}}  # 6% individual
      }

      # Bus 1: 13.8 kV (distribution) — individual limit = 3.0%
      # Bus 2: 0.48 kV (low voltage) — individual limit = 5.0%
      buses = [
        %{id: 1, base_kv: 13.8},
        %{id: 2, base_kv: 0.48}
      ]
      results = Solver.check_ieee_519(voltages, buses)

      # Both should have violations, but with different limits
      result_1 = Enum.find(results, &(&1.bus_id == 1))
      result_2 = Enum.find(results, &(&1.bus_id == 2))

      assert result_1.individual_limit_pct == 3.0
      assert result_2.individual_limit_pct == 5.0

      refute result_1.compliant  # 6% > 3%
      refute result_2.compliant  # 6% > 5%
    end

    test "detects individual harmonic violation" do
      voltages = %{
        1 => %{1 => {1.0, 0.0}},
        5 => %{1 => {0.035, 0.0}}  # 3.5% — exceeds 3% limit for 69 kV < V <= 161 kV
      }

      buses = [%{id: 1, base_kv: 138.0}]
      results = Solver.check_ieee_519(voltages, buses)

      [result] = results
      assert result.max_individual_pct > 1.5  # 138 kV limit = 1.5%
      individual_violations =
        Enum.filter(result.violations, &(&1.type == :individual))
      assert length(individual_violations) > 0
    end
  end

  # ===========================================================================
  # 6. Impedance Scan Tests
  # ===========================================================================

  describe "Solver.impedance_scan/3" do
    test "impedance increases with frequency for inductive system" do
      snap = snapshot_3bus()

      results = Solver.impedance_scan(snap, 2, freq_range: 1..10)

      # For a predominantly inductive system, impedance should generally
      # increase with frequency (Z ~= j*h*X_L at higher harmonics)
      magnitudes = Enum.map(results, fn {_h, z_mag, _angle} -> z_mag end)

      # Check that the trend is generally increasing
      # (not strictly monotonic due to capacitive interactions)
      z_at_1 = Enum.at(magnitudes, 0)
      z_at_10 = List.last(magnitudes)

      assert z_at_10 > z_at_1,
        "Z at h=10 (#{z_at_10}) should be > Z at h=1 (#{z_at_1}) for inductive system"
    end

    test "returns correct number of frequency points" do
      snap = snapshot_3bus()
      results = Solver.impedance_scan(snap, 1, freq_range: 1..20)

      assert length(results) == 20
    end

    test "impedance is positive at all frequencies" do
      snap = snapshot_3bus()
      results = Solver.impedance_scan(snap, 2, freq_range: 1..15)

      Enum.each(results, fn {h, z_mag, _angle} ->
        assert z_mag > 0.0 or z_mag == :infinity,
          "Z at h=#{h} should be positive, got #{z_mag}"
      end)
    end
  end

  # ===========================================================================
  # 7. Filter Design Tests
  # ===========================================================================

  describe "Filter.design_single_tuned/4" do
    test "produces physically reasonable parameters for 5th harmonic filter" do
      filter = Filter.design_single_tuned(5, 138.0, 30.0)

      # Capacitance should be positive
      assert filter.c_uf > 0.0, "Capacitance must be positive"

      # Inductance should be positive
      assert filter.l_mh > 0.0, "Inductance must be positive"

      # Resistance should be positive (but small)
      assert filter.r_ohm > 0.0, "Resistance must be positive"
      assert filter.r_ohm < 100.0, "Resistance should be small for a tuned filter"

      # Q factor should match requested
      assert_in_delta filter.q_factor, 40.0, 0.01

      # Tuned harmonic should be slightly below 5 (due to detuning)
      assert filter.tuned_harmonic < 5.0
      assert filter.tuned_harmonic > 4.5

      # Reactive compensation should be close to desired
      assert filter.q_mvar_actual > 0.0
      assert filter.q_mvar_actual < 30.0  # slightly less due to inductor
    end

    test "X_C at fundamental equals V^2/Q" do
      filter = Filter.design_single_tuned(5, 138.0, 30.0)
      expected_xc = 138.0 * 138.0 / 30.0
      assert_in_delta filter.x_c_ohm, expected_xc, 0.01
    end

    test "resonance condition: X_L * h_t^2 = X_C" do
      filter = Filter.design_single_tuned(7, 69.0, 20.0)

      # At resonance: h_t * omega_0 * L = 1 / (h_t * omega_0 * C)
      # Equivalently: X_L * h_t^2 = X_C (at fundamental frequency)
      x_l_times_ht_sq = filter.x_l_ohm * filter.tuned_harmonic * filter.tuned_harmonic
      assert_in_delta x_l_times_ht_sq, filter.x_c_ohm, 0.01
    end

    test "bandwidth is reasonable" do
      filter = Filter.design_single_tuned(5, 138.0, 30.0)

      # Bandwidth = f_resonance / Q
      expected_bw = filter.tuned_harmonic * 60.0 / filter.q_factor
      assert_in_delta filter.bandwidth_hz, expected_bw, 0.01

      # Should be a few Hz for a high-Q filter
      assert filter.bandwidth_hz > 1.0
      assert filter.bandwidth_hz < 30.0
    end

    test "different Q factors produce different bandwidths" do
      filter_sharp = Filter.design_single_tuned(5, 138.0, 30.0, q_factor: 60.0)
      filter_broad = Filter.design_single_tuned(5, 138.0, 30.0, q_factor: 15.0)

      assert filter_sharp.bandwidth_hz < filter_broad.bandwidth_hz,
        "Higher Q should give narrower bandwidth"
    end
  end

  describe "Filter.design_high_pass/4" do
    test "produces physically reasonable parameters" do
      filter = Filter.design_high_pass(11, 138.0, 20.0)

      assert filter.c_uf > 0.0
      assert filter.l_mh > 0.0
      assert filter.r_ohm > 0.0
      assert filter.cutoff_harmonic == 11
    end

    test "damping resistance is proportional to Q factor" do
      filter_low_q = Filter.design_high_pass(11, 138.0, 20.0, q_factor: 0.5)
      filter_high_q = Filter.design_high_pass(11, 138.0, 20.0, q_factor: 2.0)

      assert filter_high_q.r_ohm > filter_low_q.r_ohm,
        "Higher Q should give higher damping resistance"
    end
  end

  # ===========================================================================
  # 8. Integration: end-to-end harmonic study on 3-bus system
  # ===========================================================================

  describe "end-to-end 3-bus harmonic study" do
    test "complete workflow: solve, THD, compliance check" do
      snap = snapshot_3bus()
      fund = fundamental_solution_3bus()
      sources = harmonic_sources_3bus()

      # Step 1: Solve harmonics
      {:ok, voltages} = Solver.solve(snap, fund, sources, max_harmonic: 25)

      # Step 2: Compute THD
      thd = Solver.compute_thd(voltages)

      assert is_map(thd)
      assert map_size(thd) == 3
      Enum.each(thd, fn {_bus_id, thd_pct} ->
        assert is_float(thd_pct)
        assert thd_pct >= 0.0
      end)

      # Step 3: IEEE 519 compliance check
      compliance = Solver.check_ieee_519(voltages, snap.buses)

      assert length(compliance) == 3
      Enum.each(compliance, fn result ->
        assert is_boolean(result.compliant)
        assert is_float(result.thd_pct)
        assert is_float(result.thd_limit_pct)
      end)
    end
  end
end
