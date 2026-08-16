defmodule PowerModel.Solver.BranchNormalizationTest do
  use ExUnit.Case, async: true

  alias PowerModel.Grid.Transformer
  alias PowerModel.Ingestion.ParameterEstimator
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson, Solution, YBus}

  @base_mva 100.0

  defp bus(id, bus_type) do
    %{id: id, bus_type: bus_type, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
  end

  defp transformer_snapshot(tap_ratio) do
    %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [],
      transformers: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.0,
          x_pu: 0.1,
          tap_ratio: tap_ratio,
          rated_mva: 100.0
        }
      ],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 50.0,
          capacity_factor: 1.0,
          q_max_mvar: 100.0,
          q_min_mvar: -100.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: 50.0, q_mvar: 0.0}]
    }
  end

  test "a zero transformer tap in a DC snapshot behaves as a nominal tap" do
    zero_tap = DCPowerFlow.solve(transformer_snapshot(0.0), base_mva: @base_mva)
    nominal_tap = DCPowerFlow.solve(transformer_snapshot(1.0), base_mva: @base_mva)

    zero_flow = Solution.line_flow(zero_tap, :transformer, 1)
    nominal_flow = Solution.line_flow(nominal_tap, :transformer, 1)

    assert_in_delta Enum.at(zero_tap.va_rad, 1), Enum.at(nominal_tap.va_rad, 1), 1.0e-12
    assert_in_delta zero_flow.p_flow_mw, nominal_flow.p_flow_mw, 1.0e-9
    assert_in_delta zero_flow.p_flow_mw, 50.0, 1.0e-9
  end

  test "transformer changesets reject a present non-positive tap ratio" do
    changeset =
      Transformer.changeset(%Transformer{}, %{
        rated_mva: 100.0,
        x_pu: 0.1,
        tap_ratio: 0.0,
        from_bus_id: 1,
        to_bus_id: 2
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :tap_ratio)
  end

  test "the shared reactance floor preserves zero and negative branch semantics" do
    assert YBus.x_floor() == 1.0e-5
    assert YBus.effective_reactance(0.0) == 1.0e-5
    assert YBus.effective_reactance(-1.0e-9) == -1.0e-5
    assert YBus.effective_reactance(-0.2) == -0.2
  end

  test "the floor does not touch any reactance a real branch carries" do
    # The smallest |x| stored anywhere in the network is 2.531e-5 pu (a
    # connectivity-repair joint). A floor at or above that is not a
    # division guard, it is a modeling change applied to real branches —
    # which is what the old 1.0e-3 floor was, on 15,941 in-service lines.
    assert YBus.effective_reactance(2.531e-5) == 2.531e-5
    assert YBus.effective_reactance(-2.531e-5) == -2.531e-5
  end

  test "the estimator's write-time clamp equals the solver's floor" do
    # Whichever of the two is larger is the one the network actually feels: a
    # write-time clamp above the solver floor silently becomes the binding
    # floor, and lowering the solver's does nothing (SOL12-SCALE). The
    # estimator deliberately does not reference YBus at compile time, so this
    # is where the two are pinned together.
    # 0.28 ohm/km x 0.05 km / (765^2/100) = 2.4e-6 pu, below the clamp.
    short = %{voltage_kv: 765.0, length_km: 0.05, geometry: nil, from_bus: nil, to_bus: nil}

    assert ParameterEstimator.line_params(short).x_pu == YBus.x_floor(),
           "a jumper whose recipe reactance is below the clamp must report the " <>
             "solver's floor, not a larger one"

    # 0.25 km lands at 1.2e-5 pu, just above: the clamp must not touch it.
    longer = %{short | length_km: 0.25}
    assert ParameterEstimator.line_params(longer).x_pu > YBus.x_floor()
  end

  describe "sub-transmission rating class" do
    test "a rating below the lowest class scales linearly with voltage" do
      # Constant ampacity: half the voltage carries half the MVA. The 69 kV
      # class rating is the reference, so 34.5 kV is exactly half of it.
      assert_in_delta ParameterEstimator.rating_a_mva(34.5, 10.0),
                      ParameterEstimator.rating_a_mva(69.0, 10.0) / 2.0,
                      1.0e-9

      assert_in_delta ParameterEstimator.rating_a_mva(13.8, 10.0),
                      ParameterEstimator.rating_a_mva(69.0, 10.0) / 5.0,
                      1.0e-9
    end

    test "sub-50 kV lines no longer inherit the full 69 kV class rating" do
      # 1,957 in-service lines are below 50 kV, and every one of them used to
      # read as good for the 69 kV class's 116.3 MVA. A 33 kV line carrying
      # 60 MW was therefore invisible to every overload screen.
      full = ParameterEstimator.rating_a_mva(69.0, 20.0)

      for kv <- [3.0, 13.8, 33.0, 34.5, 46.0] do
        rating = ParameterEstimator.rating_a_mva(kv, 20.0)

        assert rating < full,
               "#{kv} kV still rated #{rating} MVA against the 69 kV class's #{full}"

        assert_in_delta rating, full * kv / 69.0, 1.0e-9
      end
    end

    test "at and above 69 kV the class table is untouched" do
      for kv <- [69.0, 115.0, 138.0, 230.0, 345.0, 500.0] do
        {_r, _x, _b, thermal, _n} = ParameterEstimator.lookup_line_params(kv)
        assert ParameterEstimator.low_voltage_thermal_mva(thermal, kv) == thermal
      end
    end

    test "the impedance recipe is untouched by the rating change" do
      # The rule is a RATING rule. Stored reactances must not move, which is
      # what keeps ROADMAP item 8 a no-op on x: a 33 kV line's large per-unit
      # reactance is the small z_base, not a bad parameter.
      line = %{voltage_kv: 33.0, length_km: 27.79, geometry: nil, from_bus: nil, to_bus: nil}
      z_base = 33.0 * 33.0 / 100.0
      {_r, x_per_km, _b, _thermal, _n} = ParameterEstimator.lookup_line_params(33.0)

      assert_in_delta ParameterEstimator.line_params(line).x_pu,
                      x_per_km * 27.79 / z_base,
                      1.0e-9
    end
  end

  describe "EHV line-end reactors" do
    test "a terminal reactor absorbs its class fraction of the charging it sees" do
      # b_pu = 0.5 is 50 MVAr of charging on the whole line, 25 at each end.
      # At 500 kV (K = 0.6) each terminal absorbs 0.6 x 25 = 15 MVAr.
      assert_in_delta ParameterEstimator.line_end_reactor_mvar(500.0, 0.5), -15.0, 1.0e-9

      # 230 kV compensates less, 345 kV in between; all negative (absorbing).
      assert ParameterEstimator.line_end_reactor_mvar(230.0, 0.5) < 0.0

      assert ParameterEstimator.line_end_reactor_mvar(230.0, 0.5) >
               ParameterEstimator.line_end_reactor_mvar(500.0, 0.5)
    end

    test "compensation is looked up by closest class, like every other table" do
      assert ParameterEstimator.terminal_compensation(500.0) ==
               Map.fetch!(ParameterEstimator.reactor_compensation(), 500)

      assert ParameterEstimator.terminal_compensation(300.0) ==
               Map.fetch!(ParameterEstimator.reactor_compensation(), 345)

      # 287 kV is 57 kV from the 230 class and 58 from the 345 one, so it
      # compensates as 230. Closest-class ties this fine are why the table is
      # per class rather than interpolated.
      assert ParameterEstimator.terminal_compensation(287.0) ==
               Map.fetch!(ParameterEstimator.reactor_compensation(), 230)

      assert ParameterEstimator.terminal_compensation(238.0) ==
               Map.fetch!(ParameterEstimator.reactor_compensation(), 230)
    end

    test "a nil susceptance yields no reactor rather than raising" do
      assert ParameterEstimator.line_end_reactor_mvar(500.0, nil) == 0.0
    end

    test "DC power flow is blind to bus shunts, so reactors cannot move a DC solve" do
      # This is what makes the reactor migration safe to land next to the
      # reactance-floor change: DC never reads bs_mvar, so the DC re-baseline
      # measured for the floor is the only one either change produces.
      plain = %{
        buses: [bus(1, 3), bus(2, 1)],
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            voltage_kv: 500.0,
            r_pu: 0.001,
            x_pu: 0.02,
            b_pu: 1.2,
            rating_a_mva: 1000.0
          }
        ],
        transformers: [],
        generators: [
          %{
            id: 1,
            bus_id: 1,
            p_max_mw: 300.0,
            capacity_factor: 1.0,
            q_max_mvar: 400.0,
            q_min_mvar: -400.0
          }
        ],
        loads: [%{id: 1, bus_id: 2, p_mw: 300.0, q_mvar: 50.0}]
      }

      with_reactors = %{
        plain
        | buses: [
            Map.put(bus(1, 3), :bs_mvar, -36.0),
            Map.put(bus(2, 1), :bs_mvar, -36.0)
          ]
      }

      a = DCPowerFlow.solve(plain, base_mva: @base_mva)
      b = DCPowerFlow.solve(with_reactors, base_mva: @base_mva)

      assert a.va_rad == b.va_rad

      assert Solution.line_flow(a, :line, 1).p_flow_mw ==
               Solution.line_flow(b, :line, 1).p_flow_mw

      # And the AC solve is not blind to them, or the reactors would be inert.
      {:ok, ac_plain} = NewtonRaphson.solve(plain, base_mva: @base_mva, tolerance: 1.0e-10)

      {:ok, ac_shunt} =
        NewtonRaphson.solve(with_reactors, base_mva: @base_mva, tolerance: 1.0e-10)

      assert ac_plain.converged and ac_shunt.converged

      # Bus 1 is the slack and is held at 1.0 either way; bus 2 is where the
      # reactor has to show up, absorbing the charging that was propping it up.
      vm_at = fn sol, id -> Enum.at(sol.vm_pu, Enum.find_index(sol.bus_ids, &(&1 == id))) end

      assert vm_at.(ac_shunt, 2) < vm_at.(ac_plain, 2)
    end
  end

  test "AC zero-reactance flow reporting matches the floored Y-bus model" do
    snapshot = %{
      buses: [bus(1, 3), bus(2, 1)],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.0,
          x_pu: 0.0,
          b_pu: 0.0,
          rating_a_mva: 100.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 10.0,
          capacity_factor: 1.0,
          q_max_mvar: 100.0,
          q_min_mvar: -100.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: 10.0, q_mvar: 5.0}]
    }

    {:ok, solution} =
      NewtonRaphson.solve(snapshot, base_mva: @base_mva, tolerance: 1.0e-10)

    assert solution.converged
    assert solution.max_mismatch < 1.0e-10

    flow = Solution.line_flow(solution, :line, 1)
    [from_vm, to_vm] = solution.vm_pu
    [from_angle, to_angle] = solution.va_rad
    theta = from_angle - to_angle
    x_pu = YBus.effective_reactance(0.0)
    susceptance = -1.0 / x_pu

    expected_p_pu =
      -from_vm * to_vm * susceptance * :math.sin(theta)

    expected_q_pu =
      -from_vm * from_vm * susceptance +
        from_vm * to_vm * susceptance * :math.cos(theta)

    for value <- [flow.p_flow_mw, flow.q_flow_mvar, flow.s_flow_mva] do
      assert is_float(value)
      assert value == value
      assert abs(value) < 1.0e100
    end

    assert_in_delta flow.p_flow_mw, expected_p_pu * @base_mva, 1.0e-8
    assert_in_delta flow.q_flow_mvar, expected_q_pu * @base_mva, 1.0e-8
  end
end
