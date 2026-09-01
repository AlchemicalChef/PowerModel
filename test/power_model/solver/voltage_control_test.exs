defmodule PowerModel.Solver.VoltageControlTest do
  @moduledoc """
  Switched shunts and LTC transformers as an outer loop around the AC solve
  (REVIEW CAS-28: the network has no controllable reactive plant).

  Every case here is small enough to solve densely, so the loop's behaviour is
  checked against exact physics rather than against a large-case fixture:
  which way a tap has to move to raise its low side, that a capacitor step
  comes in for a sag and a reactor step for a rise, that the LTC has first
  claim on its bus, and that a device which keeps reversing is latched rather
  than left to hunt forever.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{FDPF, VoltageControl}
  alias PowerModel.Test.MATPOWER

  @base_mva 100.0
  @opts [base_mva: @base_mva, load_compensation: 0.0]

  # ── fixtures ──────────────────────────────────────────────────────────

  # Slack (230 kV) —line— 230 kV bus —xfmr— 115 kV load bus. The load is
  # reactive-heavy so the 115 kV side sags below 0.95 with the tap at nominal
  # (measured: 30 MVAr puts it at ~0.93; 90 MVAr at 0.73, beyond what the tap
  # range can recover). `orientation: :high_from` stamps the transformer as
  # the live model does (from = high side); `:low_from` mirrors it.
  defp sagging_case(orientation, extra \\ []) do
    {from, to} = if orientation == :high_from, do: {2, 3}, else: {3, 2}

    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 230.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 1, base_kv: 230.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 3, bus_type: 1, base_kv: 115.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.01,
          x_pu: 0.05,
          b_pu: 0.0,
          rating_a_mva: 500.0
        }
      ],
      transformers: [
        %{
          id: 1,
          from_bus_id: from,
          to_bus_id: to,
          r_pu: 0.005,
          x_pu: 0.12,
          tap_ratio: 1.0,
          rated_mva: 300.0
        }
      ],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 500.0,
          capacity_factor: 1.0,
          q_max_mvar: 400.0,
          q_min_mvar: -400.0
        }
      ],
      loads: [%{id: 1, bus_id: 3, p_mw: 60.0, q_mvar: Keyword.get(extra, :q_mvar, 30.0)}],
      load_compensation: 0.0
    }
  end

  # A long lightly loaded 345 kV line: charging lifts the far end well over
  # 1.05 with nothing to absorb it.
  defp ferranti_case do
    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 345.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 1, base_kv: 345.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          r_pu: 0.01,
          x_pu: 0.25,
          b_pu: 2.4,
          rating_a_mva: 1000.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 500.0,
          capacity_factor: 1.0,
          q_max_mvar: 400.0,
          q_min_mvar: -400.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: 5.0, q_mvar: 1.0}],
      load_compensation: 0.0
    }
  end

  defp vm(sol, bus_id), do: PowerModel.Solver.Solution.bus_voltage(sol, bus_id).vm_pu

  defp tap_at(sol, xfmr_id), do: sol.voltage_control.state.positions[{:ltc, xfmr_id}]

  defp shunt_pos(sol, bus_id), do: sol.voltage_control.state.positions[{:shunt, bus_id}]

  # ── device derivation ────────────────────────────────────────────────

  describe "devices/2" do
    test "an LTC controls the low side and is oriented from the stamped ends" do
      [ltc] = VoltageControl.devices(sagging_case(:high_from), capacitors: false)
      assert ltc.type == :ltc
      assert ltc.controlled_bus_id == 3
      # V_to ≈ V_from / t: with the low side at `to`, raising it means lowering t.
      assert ltc.raise_sign == -1.0

      [ltc] = VoltageControl.devices(sagging_case(:low_from), capacitors: false)
      assert ltc.controlled_bus_id == 3
      assert ltc.raise_sign == 1.0
    end

    test "no LTC when the low side holds its own voltage, and none on a bus tie" do
      gen_low =
        sagging_case(:high_from)
        |> Map.update!(:generators, fn gens ->
          gens ++
            [
              %{
                id: 2,
                bus_id: 3,
                p_max_mw: 0.0,
                capacity_factor: 1.0,
                q_max_mvar: 50.0,
                q_min_mvar: -50.0
              }
            ]
        end)

      assert [] == VoltageControl.devices(gen_low, capacitors: false)

      tie =
        sagging_case(:high_from)
        |> update_in([:buses], fn bs -> Enum.map(bs, &%{&1 | base_kv: 230.0}) end)

      assert [] == VoltageControl.devices(tie, capacitors: false)
    end

    # Bus 3 hangs on one 0.12 pu transformer: strength 100/0.12 = 833 MVA, so a
    # step is held to at most 2 % of that — 16.67 MVAr — rather than the 30
    # MVAr class step a strong 115 kV bus would get. Steps are equal and cover
    # the capacity exactly, so 40 MVAr is three steps of 13.33.
    @weak_step 100.0 / 0.12 * 0.02

    test "capacitor capacity scales with the peak multiplier, is stepped and held to the class ceiling" do
      snap = sagging_case(:high_from, q_mvar: 40.0)

      [%{type: :switched_shunt} = one] = VoltageControl.devices(snap, ltc: false)
      assert one.bus_id == 3
      assert one.cap_steps == 3
      assert_in_delta one.cap_step_mvar, 40.0 / 3, 1.0e-9
      assert one.cap_step_mvar <= @weak_step

      [two] = VoltageControl.devices(snap, ltc: false, peak_multiplier: 2.0)
      assert two.cap_steps == 5
      assert_in_delta two.cap_step_mvar * two.cap_steps, 80.0, 1.0e-9

      # 40 × 10 = 400 MVAr; the 115 kV ceiling is 250 → 15 steps of 16.67.
      [capped] = VoltageControl.devices(snap, ltc: false, peak_multiplier: 10.0)
      assert capped.cap_steps == 15
      assert_in_delta capped.cap_step_mvar, @weak_step, 1.0e-9

      # Below one step the installation is a single step of its own size.
      [small] = VoltageControl.devices(sagging_case(:high_from, q_mvar: 7.0), ltc: false)
      assert small.cap_step_mvar == 7.0
      assert small.cap_steps == 1

      # Below the smallest bank that gets built, nothing.
      assert [] == VoltageControl.devices(sagging_case(:high_from, q_mvar: 0.5), ltc: false)
    end

    test "a strongly connected bus gets the class step; a weak one a strength-limited step" do
      # Three more stiff 115 kV lines on bus 3: strength 833 + 3 × 10,000 MVA.
      strong =
        sagging_case(:high_from, q_mvar: 40.0)
        |> update_in(
          [:buses],
          &(&1 ++ [%{id: 4, bus_type: 1, base_kv: 115.0, vm_pu: 1.0, va_rad: 0.0}])
        )
        |> update_in([:lines], fn ls ->
          ls ++
            for i <- 1..3 do
              %{
                id: 10 + i,
                from_bus_id: 3,
                to_bus_id: 4,
                r_pu: 0.001,
                x_pu: 0.01,
                b_pu: 0.0,
                rating_a_mva: 500.0
              }
            end
        end)

      [d] = VoltageControl.devices(strong, ltc: false)
      # Not strength-limited: 40 MVAr in two 20 MVAr steps under the 30 class step.
      assert d.cap_steps == 2
      assert d.cap_step_mvar == 20.0
      assert d.cap_step_mvar > @weak_step
    end

    test "reactor capacity is the incident charging, with the stamped reactor as steps already in, at EHV only" do
      snap = ferranti_case()
      devices = VoltageControl.devices(snap, capacitors: false)
      # 2.4 pu × 100 / 2 = 120 MVAr per end, two 345 kV buses. Each hangs on
      # the one 0.25 pu line (400 MVA), so the 50 MVAr class unit is held to
      # 8 MVAr steps.
      assert length(devices) == 2

      for d <- devices do
        assert_in_delta d.reac_step_mvar, 8.0, 1.0e-9
        assert d.reac_steps == 15
      end

      # A reactor already stamped at the bus is switchable plant that starts
      # IN: 100 MVAr is 12.5 steps of 8, rounded to 13, inside the same 15.
      with_fixed = update_in(snap, [:buses], fn [a, b] -> [a, Map.put(b, :bs_mvar, -100.0)] end)
      far = VoltageControl.devices(with_fixed, capacitors: false) |> Enum.find(&(&1.bus_id == 2))
      assert_in_delta far.reac_step_mvar, 8.0, 1.0e-9
      assert far.reac_steps == 15
      assert far.initial == {0, 13}

      low_kv = update_in(snap, [:buses], fn bs -> Enum.map(bs, &%{&1 | base_kv: 138.0}) end)
      assert [] == VoltageControl.devices(low_kv, capacitors: false)
    end

    test "is a pure function of the snapshot: scaling the loads changes only the bank sizes" do
      snap = sagging_case(:high_from, q_mvar: 60.0)

      scaled =
        update_in(snap, [:loads], fn ls -> Enum.map(ls, &%{&1 | q_mvar: &1.q_mvar * 0.5}) end)

      a = VoltageControl.devices(snap)
      b = VoltageControl.devices(scaled, peak_multiplier: 2.0)
      assert a == b
    end
  end

  # ── the loop ──────────────────────────────────────────────────────────

  describe "solve/2 with an LTC" do
    test "lowers the tap to lift a sagging low side into band (high side = from)" do
      snap = sagging_case(:high_from)
      {:ok, base} = FDPF.solve(snap, @opts)
      assert base.converged
      assert vm(base, 3) < 0.95

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [capacitors: false])
      assert sol.converged
      assert vm(sol, 3) >= 0.975 and vm(sol, 3) <= 1.025
      assert tap_at(sol, 1) < 1.0
      assert sol.voltage_control.stopped == :settled
      assert sol.voltage_control.ltc.moved == 1
      assert sol.voltage_control.controlled_bus_violations == %{lo: 0, hi: 0}
    end

    test "raises the tap when the low side is the tapped end (mirror image)" do
      snap = sagging_case(:low_from)
      {:ok, base} = FDPF.solve(snap, @opts)
      assert vm(base, 3) < 0.95

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [capacitors: false])
      assert sol.converged
      assert vm(sol, 3) >= 0.975 and vm(sol, 3) <= 1.025
      assert tap_at(sol, 1) > 1.0
    end

    test "a tap stops at its range limit and reports it" do
      # A stiff 230 kV side (so the tap is not blocked) behind a high-reactance
      # transformer: the low side sags more than the tap range can recover.
      snap =
        sagging_case(:high_from, q_mvar: 40.0)
        |> update_in([:lines], fn [l] -> [%{l | x_pu: 0.005}] end)
        |> update_in([:transformers], fn [t] -> [%{t | x_pu: 0.3}] end)

      {:ok, base} = FDPF.solve(snap, @opts)
      assert base.converged and vm(base, 2) >= 0.95 and vm(base, 3) < 0.85

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [capacitors: false])
      assert sol.converged
      {t_min, _} = VoltageControl.ltc_range()
      assert_in_delta tap_at(sol, 1), t_min, 1.0e-9
      assert sol.voltage_control.ltc.at_limit == 1
      assert vm(sol, 3) < 0.975
      assert sol.voltage_control.stopped == :settled
    end

    test "resumes from carried positions" do
      snap = sagging_case(:high_from)
      {:ok, first} = VoltageControl.solve(snap, @opts ++ [capacitors: false])
      t = tap_at(first, 1)

      {:ok, again} =
        VoltageControl.solve(
          snap,
          @opts ++ [capacitors: false, control_state: first.voltage_control.state]
        )

      assert tap_at(again, 1) == t
      assert again.voltage_control.rounds == 0
      assert again.voltage_control.stopped == :settled
    end
  end

  describe "solve/2 with switched shunts" do
    test "a capacitor step comes in for a sag" do
      snap = sagging_case(:high_from, q_mvar: 60.0)
      {:ok, base} = FDPF.solve(snap, @opts)
      assert vm(base, 3) < 0.95

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [ltc: false, peak_multiplier: 2.0])
      assert sol.converged
      assert vm(sol, 3) > vm(base, 3)
      {caps, 0} = shunt_pos(sol, 3)
      assert caps >= 1
      [d] = VoltageControl.devices(snap, ltc: false, peak_multiplier: 2.0)
      assert_in_delta sol.voltage_control.shunt.cap_mvar_in, caps * d.cap_step_mvar, 0.1
    end

    test "a reactor step comes in for a Ferranti rise" do
      snap = ferranti_case()
      {:ok, base} = FDPF.solve(snap, @opts)
      assert base.converged
      assert vm(base, 2) > 1.05

      {:ok, sol} = VoltageControl.solve(snap, @opts)
      assert sol.converged
      assert vm(sol, 2) < vm(base, 2)
      assert vm(sol, 2) <= 1.05
      {0, reacs} = shunt_pos(sol, 2)
      assert reacs >= 1
      assert sol.voltage_control.shunt.reac_mvar_in >= 8.0
    end

    test "a stamped capacitor bank is switched OUT for a rise, and nothing moves means bit-identical" do
      # Half the charging of the Ferranti case (its full 2.4 pu with a bank on
      # top has no solution) plus 16 MVAr of stamped bank at the far end: the
      # loop's first act is to switch the bank out.
      snap =
        ferranti_case()
        |> update_in([:lines], fn [l] -> [%{l | b_pu: 1.2}] end)
        |> update_in([:buses], fn [a, b] -> [a, Map.put(b, :bs_mvar, 16.0)] end)

      # 16 MVAr stamped + 1 MVAr of load Q = 17 MVAr in three equal steps.
      [d] = VoltageControl.devices(snap, reactors: false)
      assert d.bus_id == 2
      assert d.initial == {3, 0}
      assert d.cap_steps == 3
      assert_in_delta d.cap_step_mvar, 17.0 / 3, 1.0e-9

      {:ok, base} = FDPF.solve(snap, @opts)
      assert base.converged
      {:ok, still} = VoltageControl.solve(snap, @opts ++ [devices: [d], max_rounds: 0])
      assert still.vm_pu == base.vm_pu

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [devices: [d]])
      assert sol.converged
      assert shunt_pos(sol, 2) == {0, 0}
      assert_in_delta sol.voltage_control.shunt.cap_mvar_in, -17.0, 1.0e-6
      assert vm(sol, 2) < vm(base, 2)
    end

    test "shunts move first; the tap acts only once no shunt wants to" do
      # Outside the shunt band: the bank steps in before any tap moves.
      snap = sagging_case(:high_from, q_mvar: 30.0)
      {:ok, base} = FDPF.solve(snap, @opts)
      assert vm(base, 3) < 0.95

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [peak_multiplier: 2.0])
      assert sol.converged
      assert vm(sol, 3) >= 0.975 and vm(sol, 3) <= 1.025
      {caps, 0} = shunt_pos(sol, 3)
      assert caps >= 1

      # Inside the shunt band but outside the LTC band: only the tap moves.
      # The load is found by scan so the case documents itself.
      q =
        Enum.find(Enum.map(1..30, &(&1 * 1.0)), fn q ->
          {:ok, s} = FDPF.solve(sagging_case(:high_from, q_mvar: q), @opts)
          v = vm(s, 3)
          v >= 0.952 and v <= 0.973
        end)

      assert q, "no load put bus 3 between the shunt and LTC bands"

      {:ok, trimmed} =
        VoltageControl.solve(sagging_case(:high_from, q_mvar: q), @opts ++ [peak_multiplier: 2.0])

      assert trimmed.converged
      assert shunt_pos(trimmed, 3) == {0, 0}
      assert tap_at(trimmed, 1) < 1.0
      assert vm(trimmed, 3) >= 0.975
    end

    test "a round whose solve diverges is backed off, and the loop still settles" do
      # A bank far beyond the bus's strength: the step diverges the solve.
      bomb = %{
        type: :switched_shunt,
        id: {:shunt, 3},
        bus_id: 3,
        cap_step_mvar: 5000.0,
        cap_steps: 1,
        reac_step_mvar: 0.0,
        reac_steps: 0,
        lo: 0.95,
        hi: 1.05
      }

      [ltc] = VoltageControl.devices(sagging_case(:high_from), capacitors: false)

      {:ok, sol} = VoltageControl.solve(sagging_case(:high_from), @opts ++ [devices: [bomb, ltc]])
      assert sol.converged
      assert sol.voltage_control.backoffs >= 1
      assert sol.voltage_control.shunt.latched == 1
      assert shunt_pos(sol, 3) == {0, 0}
      # With the bank latched out, the tap finished the job.
      assert vm(sol, 3) >= 0.975 and vm(sol, 3) <= 1.025
      assert sol.voltage_control.stopped == :settled
    end

    test "a bank step that overshoots the band is halved, not abandoned" do
      # 120 MVAr in one step at a bus that wants ~0.02 pu: straight over 1.05.
      big = %{
        type: :switched_shunt,
        id: {:shunt, 3},
        bus_id: 3,
        cap_step_mvar: 120.0,
        cap_steps: 2,
        reac_step_mvar: 0.0,
        reac_steps: 0,
        lo: 0.95,
        hi: 1.05
      }

      snap = sagging_case(:high_from)
      {:ok, base} = FDPF.solve(snap, @opts)

      {:ok, over} =
        FDPF.solve(
          update_in(snap, [:buses], fn bs ->
            Enum.map(bs, &if(&1.id == 3, do: Map.put(&1, :bs_mvar, 120.0), else: &1))
          end),
          @opts
        )

      assert vm(base, 3) < 0.95 and vm(over, 3) > 1.05, "fixture must overshoot the band"

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [devices: [big]])
      assert sol.converged
      assert sol.voltage_control.backoffs >= 1
      assert sol.voltage_control.shunt.split == 1
      assert sol.voltage_control.shunt.latched == 0
      assert sol.voltage_control.state.split[{:shunt, 3}] >= 2
      assert vm(sol, 3) >= 0.95 and vm(sol, 3) <= 1.05
      # Less than one original step went in.
      assert sol.voltage_control.shunt.cap_mvar_in < 120.0
      assert sol.voltage_control.shunt.cap_mvar_in > 0.0
    end

    test "a tap does not lower its low side while its high side is above the blocking threshold" do
      # Charging on the 230 kV line lifts bus 2 over 1.05 and bus 3 over 1.025
      # with the tap at nominal; the scan finds the charging that does it.
      b =
        Enum.find(Enum.map(1..40, &(&1 * 0.1)), fn b ->
          snap =
            sagging_case(:high_from, q_mvar: 0.0)
            |> update_in([:lines], fn [l] -> [%{l | b_pu: b}] end)
            |> update_in([:loads], fn [l] -> [%{l | p_mw: 5.0}] end)

          {:ok, s} = FDPF.solve(snap, @opts)
          s.converged and vm(s, 2) > 1.05 and vm(s, 3) > 1.025
        end)

      assert b, "no charging lifted the high side over the blocking threshold"

      snap =
        sagging_case(:high_from, q_mvar: 0.0)
        |> update_in([:lines], fn [l] -> [%{l | b_pu: b}] end)
        |> update_in([:loads], fn [l] -> [%{l | p_mw: 5.0}] end)

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [capacitors: false, reactors: false])
      assert sol.converged
      assert sol.voltage_control.ltc.moved == 0
      assert tap_at(sol, 1) == 1.0
    end

    test "a tap does not raise its low side while its high side is below the blocking threshold" do
      # A heavy real load on the 230 kV line sags bus 2 below 0.95 with bus 3
      # below 0.975; the load is found by scan so the case documents itself.
      p =
        Enum.find(Enum.map(1..40, &(&1 * 25.0)), fn p ->
          snap = sagging_case(:high_from) |> update_in([:loads], fn [l] -> [%{l | p_mw: p}] end)
          {:ok, s} = FDPF.solve(snap, @opts)
          s.converged and vm(s, 2) < 0.95 and vm(s, 3) < 0.975
        end)

      assert p, "no load sagged the high side below the blocking threshold"
      snap = sagging_case(:high_from) |> update_in([:loads], fn [l] -> [%{l | p_mw: p}] end)

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [capacitors: false])
      assert sol.converged
      assert sol.voltage_control.ltc.moved == 0
      assert tap_at(sol, 1) == 1.0
    end

    test "series taps act upstream first" do
      # slack 230 —A— 115 kV —B— 69 kV load: both low sides sag.
      snap = %{
        buses: [
          %{id: 1, bus_type: 3, base_kv: 230.0, vm_pu: 1.0, va_rad: 0.0},
          %{id: 2, bus_type: 1, base_kv: 115.0, vm_pu: 1.0, va_rad: 0.0},
          %{id: 3, bus_type: 1, base_kv: 69.0, vm_pu: 1.0, va_rad: 0.0}
        ],
        lines: [],
        transformers: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            r_pu: 0.005,
            x_pu: 0.08,
            tap_ratio: 1.0,
            rated_mva: 300.0
          },
          %{
            id: 2,
            from_bus_id: 2,
            to_bus_id: 3,
            r_pu: 0.005,
            x_pu: 0.10,
            tap_ratio: 1.0,
            rated_mva: 100.0
          }
        ],
        generators: [
          %{
            id: 1,
            bus_id: 1,
            p_max_mw: 500.0,
            capacity_factor: 1.0,
            q_max_mvar: 400.0,
            q_min_mvar: -400.0
          }
        ],
        loads: [%{id: 1, bus_id: 3, p_mw: 40.0, q_mvar: 25.0}],
        load_compensation: 0.0
      }

      [a, b] =
        VoltageControl.devices(snap, capacitors: false) |> Enum.sort_by(& &1.transformer_id)

      assert a.high_bus_id == 1 and b.high_bus_id == 2

      {:ok, base} = FDPF.solve(snap, @opts)
      assert vm(base, 2) < 0.975 and vm(base, 3) < 0.975

      {:ok, one} = VoltageControl.solve(snap, @opts ++ [devices: [a, b], max_rounds: 1])
      assert Map.keys(one.voltage_control.state.moves) == [{:ltc, 1}]

      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [devices: [a, b]])
      assert sol.converged
      assert sol.voltage_control.stopped == :settled
      assert vm(sol, 2) >= 0.975 and vm(sol, 3) >= 0.975
    end

    test "an absurd step at a weak bus is split until it fits, and the loop terminates" do
      # One 200 MVAr step at a weak 115 kV bus with a 4 % band: it overshoots
      # both ways at full size and is halved until a step fits inside.
      device = %{
        type: :switched_shunt,
        id: {:shunt, 3},
        bus_id: 3,
        cap_step_mvar: 200.0,
        cap_steps: 3,
        reac_step_mvar: 0.0,
        reac_steps: 0,
        lo: 0.98,
        hi: 1.02
      }

      {:ok, sol} =
        VoltageControl.solve(sagging_case(:high_from, q_mvar: 60.0), @opts ++ [devices: [device]])

      assert sol.converged
      assert sol.voltage_control.stopped == :settled
      assert sol.voltage_control.rounds < VoltageControl.max_rounds()
      assert sol.voltage_control.state.split[{:shunt, 3}] >= 2
      # Either it fitted, or it ran out of splits and was latched — never hunting.
      assert (vm(sol, 3) >= 0.98 and vm(sol, 3) <= 1.02) or
               sol.voltage_control.shunt.latched == 1
    end
  end

  describe "solve/2 without devices" do
    test "is a plain FDPF solve with an empty summary" do
      snap = sagging_case(:high_from)
      {:ok, plain} = FDPF.solve(snap, @opts)
      {:ok, sol} = VoltageControl.solve(snap, @opts ++ [devices: []])
      assert sol.vm_pu == plain.vm_pu
      assert sol.voltage_control.devices == 0
      assert sol.voltage_control.rounds == 0
    end
  end

  # ── a published case ─────────────────────────────────────────────────

  describe "on IEEE-118" do
    @tag :matpower
    test "controls settle, the solve stays converged, and no bus leaves the emergency band" do
      snap = MATPOWER.load!("test/fixtures/matpower/case118.m")
      {:ok, base} = FDPF.solve(snap, base_mva: @base_mva)
      assert base.converged

      {:ok, sol} = VoltageControl.solve(snap, base_mva: @base_mva)
      assert sol.converged
      assert sol.voltage_control.stopped in [:settled, :round_cap]

      out_base = Enum.count(base.vm_pu, &(&1 < 0.95 or &1 > 1.05))
      out_ctrl = Enum.count(sol.vm_pu, &(&1 < 0.95 or &1 > 1.05))
      assert out_ctrl <= out_base
      assert Enum.all?(sol.vm_pu, &(&1 >= 0.90 and &1 <= 1.10))
    end
  end
end
