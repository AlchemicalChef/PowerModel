defmodule PowerModel.Solver.FDPFTest do
  @moduledoc """
  Fast-decoupled AC power flow (ROADMAP Phase 4 item 19).

  The accuracy contract is inherited, not invented: FDPF terminates on the same
  AC mismatch the Newton path does, so on any case both solve they must produce
  the same voltages to solver tolerance. Most of what is checked here is
  therefore agreement with `NewtonRaphson` — on a two-bus system with a
  closed-form solution, on IEEE-14, and on IEEE-118 loaded from MATPOWER
  source — plus the mechanisms FDPF adds: cached B'/B'' factorization, B''
  rebuilt when a Q-limit switch changes its dimension, and the fallback to the
  dense path.

  The IEEE-14 data below is transcribed rather than shared with
  `PowerModel.Solver.IEEE14BusTest`: a fixture that both solvers' tests read
  from one place is a fixture that can be quietly bent to fit whichever solver
  fails first.
  """

  use ExUnit.Case, async: true

  alias PowerModel.Solver.{FDPF, NewtonRaphson, Solution}
  alias PowerModel.Test.MATPOWER

  @base_mva 100.0

  # ── IEEE 14-bus (University of Washington archive) ────────────────────

  @ieee14_buses [
    %{id: 1, bus_type: 3, base_kv: 132.0, vm_pu: 1.060, va_rad: 0.0},
    %{id: 2, bus_type: 2, base_kv: 132.0, vm_pu: 1.045, va_rad: 0.0},
    %{id: 3, bus_type: 2, base_kv: 132.0, vm_pu: 1.010, va_rad: 0.0},
    %{id: 4, bus_type: 1, base_kv: 132.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 5, bus_type: 1, base_kv: 132.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 6, bus_type: 2, base_kv: 12.0, vm_pu: 1.070, va_rad: 0.0},
    %{id: 7, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 8, bus_type: 2, base_kv: 12.0, vm_pu: 1.090, va_rad: 0.0},
    %{id: 9, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0, bs_mvar: 19.0},
    %{id: 10, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 11, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 12, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 13, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0},
    %{id: 14, bus_type: 1, base_kv: 12.0, vm_pu: 1.0, va_rad: 0.0}
  ]

  @ieee14_generators [
    %{id: 1, bus_id: 1, p_max_mw: 332.4, capacity_factor: 0.7, q_max_mvar: 10.0, q_min_mvar: 0.0},
    %{
      id: 2,
      bus_id: 2,
      p_max_mw: 40.0,
      capacity_factor: 1.0,
      q_max_mvar: 50.0,
      q_min_mvar: -40.0
    },
    %{id: 3, bus_id: 3, p_max_mw: 0.0, capacity_factor: 1.0, q_max_mvar: 40.0, q_min_mvar: 0.0},
    %{id: 4, bus_id: 6, p_max_mw: 0.0, capacity_factor: 1.0, q_max_mvar: 24.0, q_min_mvar: -6.0},
    %{id: 5, bus_id: 8, p_max_mw: 0.0, capacity_factor: 1.0, q_max_mvar: 24.0, q_min_mvar: -6.0}
  ]

  @ieee14_loads [
    %{id: 1, bus_id: 2, p_mw: 21.7, q_mvar: 12.7},
    %{id: 2, bus_id: 3, p_mw: 94.2, q_mvar: 19.0},
    %{id: 3, bus_id: 4, p_mw: 47.8, q_mvar: -3.9},
    %{id: 4, bus_id: 5, p_mw: 7.6, q_mvar: 1.6},
    %{id: 5, bus_id: 6, p_mw: 11.2, q_mvar: 7.5},
    %{id: 6, bus_id: 9, p_mw: 29.5, q_mvar: 16.6},
    %{id: 7, bus_id: 10, p_mw: 9.0, q_mvar: 5.8},
    %{id: 8, bus_id: 11, p_mw: 3.5, q_mvar: 1.8},
    %{id: 9, bus_id: 12, p_mw: 6.1, q_mvar: 1.6},
    %{id: 10, bus_id: 13, p_mw: 13.5, q_mvar: 5.8},
    %{id: 11, bus_id: 14, p_mw: 14.9, q_mvar: 5.0}
  ]

  @ieee14_lines [
    %{id: 1, from_bus_id: 1, to_bus_id: 2, r_pu: 0.01938, x_pu: 0.05917, b_pu: 0.0528},
    %{id: 2, from_bus_id: 1, to_bus_id: 5, r_pu: 0.05403, x_pu: 0.22304, b_pu: 0.0492},
    %{id: 3, from_bus_id: 2, to_bus_id: 3, r_pu: 0.04699, x_pu: 0.19797, b_pu: 0.0438},
    %{id: 4, from_bus_id: 2, to_bus_id: 4, r_pu: 0.05811, x_pu: 0.17632, b_pu: 0.0340},
    %{id: 5, from_bus_id: 2, to_bus_id: 5, r_pu: 0.05695, x_pu: 0.17388, b_pu: 0.0346},
    %{id: 6, from_bus_id: 3, to_bus_id: 4, r_pu: 0.06701, x_pu: 0.17103, b_pu: 0.0128},
    %{id: 7, from_bus_id: 4, to_bus_id: 5, r_pu: 0.01335, x_pu: 0.04211, b_pu: 0.0},
    %{id: 8, from_bus_id: 6, to_bus_id: 11, r_pu: 0.09498, x_pu: 0.19890, b_pu: 0.0},
    %{id: 9, from_bus_id: 6, to_bus_id: 12, r_pu: 0.12291, x_pu: 0.25581, b_pu: 0.0},
    %{id: 10, from_bus_id: 6, to_bus_id: 13, r_pu: 0.06615, x_pu: 0.13027, b_pu: 0.0},
    %{id: 11, from_bus_id: 7, to_bus_id: 8, r_pu: 0.0, x_pu: 0.17615, b_pu: 0.0},
    %{id: 12, from_bus_id: 7, to_bus_id: 9, r_pu: 0.0, x_pu: 0.11001, b_pu: 0.0},
    %{id: 13, from_bus_id: 9, to_bus_id: 10, r_pu: 0.03181, x_pu: 0.08450, b_pu: 0.0},
    %{id: 14, from_bus_id: 9, to_bus_id: 14, r_pu: 0.12711, x_pu: 0.27038, b_pu: 0.0},
    %{id: 15, from_bus_id: 10, to_bus_id: 11, r_pu: 0.08205, x_pu: 0.19207, b_pu: 0.0},
    %{id: 16, from_bus_id: 12, to_bus_id: 13, r_pu: 0.22092, x_pu: 0.19988, b_pu: 0.0},
    %{id: 17, from_bus_id: 13, to_bus_id: 14, r_pu: 0.17093, x_pu: 0.34802, b_pu: 0.0}
  ]

  @ieee14_transformers [
    %{
      id: 1,
      from_bus_id: 4,
      to_bus_id: 7,
      r_pu: 0.0,
      x_pu: 0.20912,
      rated_mva: 100.0,
      tap_ratio: 0.978
    },
    %{
      id: 2,
      from_bus_id: 4,
      to_bus_id: 9,
      r_pu: 0.0,
      x_pu: 0.55618,
      rated_mva: 100.0,
      tap_ratio: 0.969
    },
    %{
      id: 3,
      from_bus_id: 5,
      to_bus_id: 6,
      r_pu: 0.0,
      x_pu: 0.25202,
      rated_mva: 100.0,
      tap_ratio: 0.932
    }
  ]

  # Published IEEE 14-bus AC solution voltage magnitudes (pu).
  @expected_ac_vm %{
    1 => 1.060,
    2 => 1.045,
    3 => 1.010,
    4 => 1.018,
    5 => 1.020,
    6 => 1.070,
    7 => 1.062,
    8 => 1.090,
    9 => 1.056,
    10 => 1.051,
    11 => 1.057,
    12 => 1.055,
    13 => 1.050,
    14 => 1.036
  }

  defp ieee14 do
    %{
      buses: @ieee14_buses,
      lines: Enum.map(@ieee14_lines, &Map.merge(&1, %{voltage_kv: 132.0, rating_a_mva: 200.0})),
      transformers: @ieee14_transformers,
      generators: @ieee14_generators,
      loads: @ieee14_loads
    }
  end

  # Force FDPF regardless of size; the production cutoff hands small systems to
  # dense NR, which would make every assertion here a test of the other solver.
  defp fdpf_opts(extra \\ []),
    do: Keyword.merge([base_mva: @base_mva, dense_nr_max_buses: 0], extra)

  defp worst_diff(a, b),
    do: a |> Enum.zip(b) |> Enum.map(fn {x, y} -> abs(x - y) end) |> Enum.max()

  # ── A hand-checkable two-bus system ───────────────────────────────────
  #
  # Slack at 1.0 pu feeds one PQ bus through a purely reactive x = 0.1 pu
  # branch. With r = 0 and no charging the injections at the load bus are
  #
  #     P = V sin(theta) / x        Q = (V^2 - V cos(theta)) / x
  #
  # which has a closed-form solution, so this case tests the solver against
  # arithmetic rather than against another solver.

  # A plain ring of `n` buses, ids offset clear of IEEE-14's 1..14 so the two
  # can be merged into one snapshot as separate islands. Deliberately easy to
  # solve: the SOL-14 tests measure which SOLVER ran, not whether the network
  # is hard, and they force non-convergence with an iteration cap instead.
  defp ring(n) do
    off = 1_000

    %{
      buses:
        for i <- 1..n do
          %{
            id: off + i,
            bus_type: if(i == 1, do: 3, else: 1),
            base_kv: 230.0,
            vm_pu: 1.0,
            va_rad: 0.0
          }
        end,
      lines:
        for i <- 1..n do
          j = if i == n, do: 1, else: i + 1

          %{
            id: off + i,
            from_bus_id: off + i,
            to_bus_id: off + j,
            voltage_kv: 230.0,
            r_pu: 0.005,
            x_pu: 0.05,
            b_pu: 0.01,
            rating_a_mva: 400.0
          }
        end,
      transformers: [],
      generators: [
        %{
          id: off + 1,
          bus_id: off + 1,
          p_max_mw: n * 1.2,
          capacity_factor: 1.0,
          q_max_mvar: n * 1.0,
          q_min_mvar: -n * 1.0
        }
      ],
      loads: for(i <- 2..n, do: %{id: off + i, bus_id: off + i, p_mw: 1.0, q_mvar: 0.3})
    }
  end

  defp two_bus(p_mw, q_mvar) do
    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.0,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 500.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 0.0,
          capacity_factor: 1.0,
          q_max_mvar: 999.0,
          q_min_mvar: -999.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: p_mw, q_mvar: q_mvar}]
    }
  end

  # Three buses: slack, a PV generator with a tunable q_max, and the PQ load it
  # has to support. B'' has one row while bus 2 is PV and two once bus 2 hits
  # its limit and switches, so this also exercises the B'' rebuild.
  defp q_limited(q_max_mvar) do
    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0},
        %{id: 2, bus_type: 2, base_kv: 138.0, vm_pu: 1.02, va_rad: 0.0},
        %{id: 3, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
      ],
      lines: [
        %{
          id: 1,
          from_bus_id: 1,
          to_bus_id: 2,
          voltage_kv: 138.0,
          r_pu: 0.01,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 500.0
        },
        %{
          id: 2,
          from_bus_id: 2,
          to_bus_id: 3,
          voltage_kv: 138.0,
          r_pu: 0.01,
          x_pu: 0.1,
          b_pu: 0.0,
          rating_a_mva: 500.0
        }
      ],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: 0.0,
          capacity_factor: 1.0,
          q_max_mvar: 999.0,
          q_min_mvar: -999.0
        },
        %{
          id: 2,
          bus_id: 2,
          p_max_mw: 0.0,
          capacity_factor: 1.0,
          q_max_mvar: q_max_mvar,
          q_min_mvar: -100.0
        }
      ],
      loads: [%{id: 1, bus_id: 3, p_mw: 20.0, q_mvar: 40.0}]
    }
  end

  # Reactive injection of the generator at `bus_id`, recovered from the solved
  # voltages the same way the solver's own limit test does.
  defp generator_q_mvar(snapshot, solution, bus_id) do
    prep = NewtonRaphson.prepare(snapshot, base_mva: @base_mva)
    vm = :array.from_list(solution.vm_pu)
    va = :array.from_list(solution.va_rad)

    {_p, q_calc} = NewtonRaphson.power_injections(prep.y_sparse, vm, va)
    {_ps, q_sched_pre} = NewtonRaphson.scheduled_injections(prep, vm)

    idx = Map.fetch!(prep.bus_index, bus_id)
    (:array.get(idx, q_calc) - :array.get(idx, q_sched_pre)) * @base_mva
  end

  defp switching_input(overrides) do
    Map.merge(
      %{
        pv_indices: [1],
        switched: %{},
        released: MapSet.new(),
        latched: MapSet.new(),
        q_calc: :array.from_list([0.0, 0.5]),
        q_sched_pre: :array.from_list([0.0, 0.0]),
        q_limits: %{1 => {-0.3, 0.3}},
        vm: :array.from_list([1.0, 1.0]),
        v_sched: :array.from_list([1.0, 1.0])
      },
      overrides
    )
  end

  # ── Tests ─────────────────────────────────────────────────────────────

  describe "two-bus system against the closed-form solution" do
    test "matches the analytic voltage and angle" do
      {:ok, sol} = FDPF.solve(two_bus(20.0, 10.0), fdpf_opts(tolerance: 1.0e-10))

      assert sol.converged
      assert sol.max_mismatch < 1.0e-10

      %{vm_pu: v, va_rad: theta} = Solution.bus_voltage(sol, 2)

      x = 0.1
      p = -0.20
      q = -0.10

      assert_in_delta v * :math.sin(theta) / x, p, 1.0e-9
      assert_in_delta (v * v - v * :math.cos(theta)) / x, q, 1.0e-9

      # Eliminating theta between the two equations above leaves a quadratic in
      # V^2:  V^4 - V^2 (1 + 2 q x) + x^2 (p^2 + q^2) = 0.
      b = 1.0 + 2.0 * q * x
      v2 = (b + :math.sqrt(b * b - 4.0 * x * x * (p * p + q * q))) / 2.0
      assert_in_delta v, :math.sqrt(v2), 1.0e-9
    end

    test "refuses to invent a solution past the loadability limit" do
      # Maximum transferable power over this branch is about V^2/x = 10 pu at
      # unity voltage; 4,000 MW with 2,000 MVAr is far beyond the nose, so no
      # solution exists and the solver has to say so rather than return one.
      {:ok, sol} = FDPF.solve(two_bus(4_000.0, 2_000.0), fdpf_opts(max_iterations: 30))

      refute sol.converged
      assert sol.total_loss_mw == 0.0
      assert sol.mismatch_mw == nil
    end
  end

  describe "agreement with dense Newton-Raphson" do
    test "reproduces the IEEE-14 solution to solver tolerance" do
      {:ok, nr} = NewtonRaphson.solve(ieee14(), base_mva: @base_mva)
      {:ok, fd} = FDPF.solve(ieee14(), fdpf_opts())

      assert fd.converged
      assert nr.bus_ids == fd.bus_ids

      assert worst_diff(nr.vm_pu, fd.vm_pu) < 1.0e-5
      assert worst_diff(nr.va_rad, fd.va_rad) < 1.0e-5

      # Losses are the sensitive aggregate — a small difference of two large
      # numbers, so they catch a Y-bus or flow-model divergence that per-bus
      # tolerances would absorb.
      assert_in_delta fd.total_loss_mw, nr.total_loss_mw, 1.0e-3
      assert_in_delta fd.total_loss_mw, 13.393, 0.2
    end

    test "reproduces the published IEEE-14 voltage magnitudes" do
      {:ok, fd} = FDPF.solve(ieee14(), fdpf_opts())

      for {bus_id, expected} <- @expected_ac_vm do
        actual = Solution.bus_voltage(fd, bus_id).vm_pu
        pct = abs(actual - expected) / expected * 100.0

        assert pct < 0.5,
               "Vm at bus #{bus_id}: expected ~#{expected} pu, got " <>
                 "#{Float.round(actual, 4)} pu (#{Float.round(pct, 3)}%)"
      end
    end

    @tag :ieee
    test "reproduces the IEEE-118 solution, Q-limit switching included" do
      snapshot = MATPOWER.load!("test/fixtures/matpower/case118.m")

      {:ok, nr} = NewtonRaphson.solve(snapshot, base_mva: snapshot.base_mva)
      {:ok, fd} = FDPF.solve(snapshot, base_mva: snapshot.base_mva, dense_nr_max_buses: 0)

      assert fd.converged
      assert worst_diff(nr.vm_pu, fd.vm_pu) < 1.0e-5
      assert worst_diff(nr.va_rad, fd.va_rad) < 1.0e-5
      assert_in_delta fd.total_loss_mw, nr.total_loss_mw, 1.0e-2

      # Both solvers must take the same generators off setpoint: the Q-limit
      # rule is shared, and this is where a B'' rebuilt at the wrong dimension
      # would show up.
      setpoints = Map.new(snapshot.buses, &{&1.id, &1.vm_pu})
      gen_buses = MapSet.new(snapshot.generators, & &1.bus_id)

      bound = fn sol ->
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.filter(fn {id, vm} ->
          MapSet.member?(gen_buses, id) and abs(vm - Map.fetch!(setpoints, id)) > 1.0e-4
        end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()
      end

      assert bound.(fd) == bound.(nr)
      assert MapSet.size(bound.(fd)) == 6
    end
  end

  describe "ACTIVSg2000, the case dense Newton-Raphson could not afford" do
    @describetag :ieee

    setup do
      snapshot = MATPOWER.load!("test/fixtures/matpower/case_ACTIVSg2000.m")

      reference =
        "test/fixtures/matpower/case_ACTIVSg2000_reference.json"
        |> File.read!()
        |> Jason.decode!()

      {:ok, snapshot: snapshot, reference: reference}
    end

    test "solves, and its losses and served load match the reference", %{
      snapshot: snapshot,
      reference: ref
    } do
      # Dense Newton-Raphson takes 347 s and 3.2 GB on this case for the same
      # answer (agreeing to 8e-9 pu); the whole point of item 19 is that this
      # now costs ~130 ms.
      {:ok, sol} =
        FDPF.solve(snapshot,
          base_mva: snapshot.base_mva,
          dense_nr_max_buses: 0,
          q_limit_policy: :matpower
        )

      assert sol.converged
      assert sol.max_mismatch < 1.0e-6

      expected_loss = ref["ac"]["total_loss_mw"]
      loss_pct = abs(sol.total_loss_mw - expected_loss) / expected_loss * 100.0

      assert loss_pct < 1.0,
             "losses #{Float.round(sol.total_loss_mw, 2)} MW vs reference " <>
               "#{expected_loss} MW (#{Float.round(loss_pct, 4)}%)"

      assert_in_delta sol.total_load_mw, ref["ac"]["total_load_mw"], 1.0
      assert_in_delta sol.total_gen_mw, ref["ac"]["total_gen_mw"], expected_loss / 100.0
    end

    test "under MATPOWER's Q-limit policy it reproduces the reference's switching set", %{
      snapshot: snapshot,
      reference: ref
    } do
      # The reference was generated by PYPOWER with `enforce_q_lims`, which
      # never returns a generator to voltage control. Matching that policy is
      # what isolates the modeling (identical) from the switching rule (a
      # deliberate difference — see `NewtonRaphson.pv_pq_switching/1`).
      {:ok, sol} =
        FDPF.solve(snapshot,
          base_mva: snapshot.base_mva,
          dense_nr_max_buses: 0,
          q_limit_policy: :matpower
        )

      setpoints = Map.new(snapshot.buses, &{&1.id, &1.vm_pu})
      gen_buses = MapSet.new(snapshot.generators, & &1.bus_id)
      # Two predicates, because the two sides are not measured the same way.
      # A bus this solver still regulates is pinned EXACTLY at its setpoint —
      # 197 of the 392 generator buses come back bit-equal — so "was it
      # demoted" needs no tolerance on our side. The reference's converged
      # voltages carry its own residue (smallest genuine switch, bus 5444, is
      # only 2.3e-4 pu off), so it does need one.
      #
      # Applying our tolerance to both sides made the comparison a knife edge.
      # Bus 6257 sits 9.7e-5 pu off setpoint here and 2.9e-4 in the reference.
      # MEASURED against the old 1.0e-3 reactance floor: the floor moved that
      # bus by 6.3e-6 pu, from 1.035e-4 to 9.7e-5 — across a 1.0e-4 cut it was
      # already sitting 3% above. Under the exact test the demoted SET is
      # bit-identical at both floors (195 buses, empty symmetric difference);
      # only the 1.0e-4 measurement of it changed. Re-baselining the counts
      # would have recorded a measurement artifact as a switching result, and
      # would have put a single-generator bus into `ref_only`, contradicting
      # the multi-generator property the next test exists to assert.
      demoted? = fn vm, id -> vm != Map.fetch!(setpoints, id) end
      off? = fn vm, id -> abs(vm - Map.fetch!(setpoints, id)) > 1.0e-4 end

      mine =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.filter(fn {id, vm} -> MapSet.member?(gen_buses, id) and demoted?.(vm, id) end)
        |> MapSet.new(&elem(&1, 0))

      theirs =
        gen_buses
        |> Enum.filter(&off?.(Map.fetch!(ref["ac"]["buses"], Integer.to_string(&1))["vm_pu"], &1))
        |> MapSet.new()

      agree = MapSet.size(MapSet.intersection(mine, theirs))

      assert MapSet.size(theirs) == 195
      assert MapSet.size(mine) == 195

      assert agree >= 191,
             "only #{agree} of #{MapSet.size(theirs)} generator buses agree with the " <>
               "reference on whether a Q limit bound"

      worst_angle =
        sol.bus_ids
        |> Enum.zip(sol.va_rad)
        |> Enum.map(fn {id, a} ->
          expected =
            Map.fetch!(ref["ac"]["buses"], Integer.to_string(id))["va_deg"] * :math.pi() / 180.0

          abs(a - expected)
        end)
        |> Enum.max()

      assert worst_angle < 5.0e-3, "worst angle deviation #{worst_angle} rad"
    end

    test "every remaining switching disagreement is a multi-generator bus", %{
      snapshot: snapshot,
      reference: ref
    } do
      # This is the shape of the residual, and it is the assertion that matters:
      # matching the reference's *policy* still leaves 4 of 392 generator buses
      # disagreeing, and every one of them carries several generators.
      #
      # MATPOWER and PYPOWER enforce reactive limits per GENERATOR and then
      # demote the whole BUS. A plant with nine units of very different sizes
      # therefore stops regulating its bus the moment its smallest unit
      # saturates, with the rest of the plant frozen where it happened to be.
      # This solver enforces the aggregate limit, so the plant keeps regulating
      # until the whole station is out of reactive capability.
      #
      # The reference's version is not merely different, it is non-physical:
      # at its own solution bus 4192 sits 1.06% BELOW its setpoint with
      # 640.5 MVAr of unused reactive capability, and 7422 sits above setpoint
      # with 619.5 MVAr of unused absorption. Reproducing that would mean
      # importing the artifact, so the disagreement is asserted rather than
      # engineered away — but it is asserted precisely, so it cannot grow or
      # change cause unnoticed.
      {:ok, sol} =
        FDPF.solve(snapshot,
          base_mva: snapshot.base_mva,
          dense_nr_max_buses: 0,
          q_limit_policy: :matpower
        )

      setpoints = Map.new(snapshot.buses, &{&1.id, &1.vm_pu})
      gens_by_bus = Enum.group_by(snapshot.generators, & &1.bus_id)
      gen_buses = MapSet.new(Map.keys(gens_by_bus))
      # Two predicates, because the two sides are not measured the same way.
      # A bus this solver still regulates is pinned EXACTLY at its setpoint —
      # 197 of the 392 generator buses come back bit-equal — so "was it
      # demoted" needs no tolerance on our side. The reference's converged
      # voltages carry its own residue (smallest genuine switch, bus 5444, is
      # only 2.3e-4 pu off), so it does need one.
      #
      # Applying our tolerance to both sides made the comparison a knife edge.
      # Bus 6257 sits 9.7e-5 pu off setpoint here and 2.9e-4 in the reference.
      # MEASURED against the old 1.0e-3 reactance floor: the floor moved that
      # bus by 6.3e-6 pu, from 1.035e-4 to 9.7e-5 — across a 1.0e-4 cut it was
      # already sitting 3% above. Under the exact test the demoted SET is
      # bit-identical at both floors (195 buses, empty symmetric difference);
      # only the 1.0e-4 measurement of it changed. Re-baselining the counts
      # would have recorded a measurement artifact as a switching result, and
      # would have put a single-generator bus into `ref_only`, contradicting
      # the multi-generator property the next test exists to assert.
      demoted? = fn vm, id -> vm != Map.fetch!(setpoints, id) end
      off? = fn vm, id -> abs(vm - Map.fetch!(setpoints, id)) > 1.0e-4 end

      mine =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.filter(fn {id, vm} -> MapSet.member?(gen_buses, id) and demoted?.(vm, id) end)
        |> MapSet.new(&elem(&1, 0))

      theirs =
        gen_buses
        |> Enum.filter(&off?.(Map.fetch!(ref["ac"]["buses"], Integer.to_string(&1))["vm_pu"], &1))
        |> MapSet.new()

      # Direction one: the reference takes a bus off voltage control and we do
      # not. Measured: 4 buses (4192, 5444, 7422, 7428), every one of them
      # multi-generator. The case has only 9 such buses, so this is not
      # coincidence, and a disagreement at a single-generator bus would mean
      # the per-generator explanation had stopped covering the residual.
      ref_only = MapSet.difference(theirs, mine)
      multi_gen? = &(length(Map.fetch!(gens_by_bus, &1)) > 1)

      assert MapSet.size(ref_only) <= 4,
             "#{MapSet.size(ref_only)} buses switched by the reference but not here " <>
               "(was 4): #{inspect(Enum.sort(ref_only))}"

      assert Enum.all?(ref_only, multi_gen?),
             "single-generator bus(es) #{inspect(Enum.reject(ref_only, multi_gen?))} are now " <>
               "switched by the reference and not here - the multi-generator rule no longer " <>
               "explains the residual"

      # Direction two is an artifact of this compatibility mode itself, not of
      # the solver. Never releasing a generator makes enforcement path
      # dependent: a bus clamped in some round can never be let go, even once
      # the operating point that justified it is gone. The default policy
      # exists precisely to release those, so it must.
      mine_only = MapSet.difference(mine, theirs)

      assert MapSet.size(mine_only) <= 4,
             "#{MapSet.size(mine_only)} buses switched here but not by the reference " <>
               "(was 4): #{inspect(Enum.sort(mine_only))}"

      {:ok, default_policy} =
        FDPF.solve(snapshot, base_mva: snapshot.base_mva, dense_nr_max_buses: 0)

      default_vm = Map.new(Enum.zip(default_policy.bus_ids, default_policy.vm_pu))
      still_clamped = Enum.filter(mine_only, fn id -> off?.(Map.fetch!(default_vm, id), id) end)

      # Only bus 5324 survives, and it is a knife edge: its generator sits at
      # exactly q_max (144.59 MVAr) where the reference has 144.587 - the two
      # solutions land either side of the same limit, 0.002% of range apart.
      assert length(still_clamped) <= 1,
             "#{length(still_clamped)} of the buses only this solver switches are still " <>
               "off setpoint under the default policy (#{inspect(still_clamped)}) - " <>
               "back-switching is supposed to release them"
    end

    test "the Vm deviation from the reference stays where the switching rule put it", %{
      snapshot: snapshot,
      reference: ref
    } do
      # The 0.5% Vm contract IEEE-14 and IEEE-118 hold cannot hold here, and the
      # reason is the multi-generator rule above, not the power flow. Measured:
      # 34 of 2000 buses over 0.5%, worst 1.0707% (bus 4126, a load bus two hops
      # from 4192), mean 0.0602%. The error decays monotonically with distance
      # from the buses where the rules differ — 0.27% mean at the bus itself,
      # 0.015% eight hops out — which is what "local consequence of a known
      # difference" looks like, as against a modeling error, which would not
      # care about distance.
      {:ok, sol} =
        FDPF.solve(snapshot,
          base_mva: snapshot.base_mva,
          dense_nr_max_buses: 0,
          q_limit_policy: :matpower
        )

      errors =
        sol.bus_ids
        |> Enum.zip(sol.vm_pu)
        |> Enum.map(fn {id, vm} ->
          expected = Map.fetch!(ref["ac"]["buses"], Integer.to_string(id))["vm_pu"]
          {id, abs(vm - expected) / expected * 100.0}
        end)

      {worst_bus, worst} = Enum.max_by(errors, &elem(&1, 1))
      mean = Enum.sum(Enum.map(errors, &elem(&1, 1))) / length(errors)
      over_contract = Enum.count(errors, fn {_id, pct} -> pct > 0.5 end)

      assert worst < 1.1,
             "worst Vm error #{Float.round(worst, 4)}% at bus #{worst_bus} (was 1.0707%)"

      assert mean < 0.07, "mean Vm error #{Float.round(mean, 5)}% (was 0.0602%)"

      assert over_contract <= 34,
             "#{over_contract} buses exceed the 0.5% Vm contract (was 34 of 2000) — " <>
               "the multi-generator disagreement has spread"
    end

    test "the default policy lands on a Q-limit state the reference's own is not", %{
      snapshot: snapshot
    } do
      # Every generator bus must satisfy one of the three complementarity
      # cases: regulating within its range, at q_max with V no higher than
      # setpoint, or at q_min with V no lower. The reference violates this at
      # 48 of its 195 off-setpoint buses; this solver's default policy exists
      # so that it does not.
      {:ok, sol} =
        FDPF.solve(snapshot, base_mva: snapshot.base_mva, dense_nr_max_buses: 0)

      assert sol.converged

      prep = NewtonRaphson.prepare(snapshot, base_mva: snapshot.base_mva)
      vm = :array.from_list(sol.vm_pu)
      va = :array.from_list(sol.va_rad)

      {_p, q_calc} = NewtonRaphson.power_injections(prep.y_sparse, vm, va)
      {_ps, q_sched_pre} = NewtonRaphson.scheduled_injections(prep, vm)

      setpoints = Map.new(snapshot.buses, &{&1.id, &1.vm_pu})
      gen_buses = MapSet.new(snapshot.generators, & &1.bus_id)
      tol = 1.0e-4

      violations =
        prep.bus_ids
        |> Enum.with_index()
        |> Enum.filter(fn {id, _} -> MapSet.member?(gen_buses, id) end)
        |> Enum.reject(fn {id, idx} ->
          q = :array.get(idx, q_calc) - :array.get(idx, q_sched_pre)
          {q_min, q_max} = Map.get(prep.q_limits, idx, {-99.99, 99.99})
          v = :array.get(idx, vm)
          sp = Map.fetch!(setpoints, id)

          (abs(v - sp) <= tol and q >= q_min - tol and q <= q_max + tol) or
            (q >= q_max - tol and v <= sp + tol) or
            (q <= q_min + tol and v >= sp - tol)
        end)
        |> Enum.map(&elem(&1, 0))

      assert violations == [],
             "#{length(violations)} generator buses are held at a reactive limit their " <>
               "voltage says should not bind, e.g. #{inspect(Enum.take(violations, 5))}"
    end
  end

  describe "solution contents for the voltage-driven protection layer" do
    test "every branch carries P and Q at the from terminal, every bus a Vm" do
      {:ok, fd} = FDPF.solve(ieee14(), fdpf_opts())

      assert map_size(fd.line_flows) == 20

      for {key, flow} <- fd.line_flows do
        assert is_number(flow.p_flow_mw), "no P for #{inspect(key)}"
        assert is_number(flow.q_flow_mvar), "no Q for #{inspect(key)}"
        assert flow.q_flow_mvar == flow.q_flow_mvar, "NaN Q for #{inspect(key)}"
        assert flow.s_flow_mva >= 0.0
        assert is_number(flow.rating_mva)
        assert is_number(flow.from_bus_id) and is_number(flow.to_bus_id)
      end

      assert length(fd.vm_pu) == length(fd.bus_ids)
      assert Enum.all?(fd.vm_pu, &(&1 > 0.8 and &1 < 1.2))

      # Reported flows have to come from the solved state: the from-terminal
      # flow on line 1-2 is the published 156.88 MW.
      assert_in_delta Solution.line_flow(fd, :line, 1).p_flow_mw, 156.88, 2.0
    end

    test "a warm start from the converged solution costs almost nothing" do
      {:ok, cold} = FDPF.solve(ieee14(), fdpf_opts())
      {:ok, warm} = FDPF.solve(ieee14(), fdpf_opts(warm_start: cold))

      assert warm.converged
      assert warm.iterations < cold.iterations
      assert worst_diff(cold.vm_pu, warm.vm_pu) < 1.0e-6
    end
  end

  describe "Q-limit switching through the solver" do
    test "a binding q_max takes the bus off setpoint and holds Q at the limit" do
      snapshot = q_limited(5.0)
      {:ok, sol} = FDPF.solve(snapshot, fdpf_opts(tolerance: 1.0e-10))

      assert sol.converged
      assert sol.max_mismatch < 1.0e-10

      assert Solution.bus_voltage(sol, 2).vm_pu < 1.02,
             "a generator out of reactive headroom cannot hold its setpoint"

      assert_in_delta generator_q_mvar(snapshot, sol, 2), 5.0, 1.0e-5
    end

    test "a generous q_max leaves the bus regulating at its setpoint" do
      snapshot = q_limited(200.0)
      {:ok, sol} = FDPF.solve(snapshot, fdpf_opts(tolerance: 1.0e-10))

      assert sol.converged
      assert_in_delta Solution.bus_voltage(sol, 2).vm_pu, 1.02, 1.0e-12
      assert generator_q_mvar(snapshot, sol, 2) < 200.0
    end

    test "the switched solution is the one dense NR reaches" do
      {:ok, fd} = FDPF.solve(q_limited(5.0), fdpf_opts(tolerance: 1.0e-10))
      {:ok, nr} = NewtonRaphson.solve(q_limited(5.0), base_mva: @base_mva, tolerance: 1.0e-10)

      assert worst_diff(nr.vm_pu, fd.vm_pu) < 1.0e-8
    end
  end

  describe "pv_pq_switching/1 state machine" do
    test "a violating PV bus switches to PQ at the limit it broke" do
      {switched, released, latched} = NewtonRaphson.pv_pq_switching(switching_input(%{}))

      assert switched == %{1 => {:max, 0.3}}
      assert MapSet.size(released) == 0
      assert MapSet.size(latched) == 0
    end

    test "a bus held at q_max whose voltage rose above setpoint is released" do
      {switched, released, _latched} =
        NewtonRaphson.pv_pq_switching(
          switching_input(%{
            pv_indices: [],
            switched: %{1 => {:max, 0.3}},
            vm: :array.from_list([1.0, 1.05])
          })
        )

      assert switched == %{}
      assert MapSet.member?(released, 1)
    end

    test "back-switching can be turned off for MATPOWER-compatible references" do
      {switched, released, _latched} =
        NewtonRaphson.pv_pq_switching(
          switching_input(%{
            pv_indices: [],
            switched: %{1 => {:max, 0.3}},
            vm: :array.from_list([1.0, 1.05]),
            back_switch: false
          })
        )

      assert switched == %{1 => {:max, 0.3}}
      assert MapSet.size(released) == 0
    end

    test "a bus that violates again after being released latches at its limit" do
      # Round three: the bus is PV again (released in round two) and violates
      # once more, so it latches...
      {switched, _released, latched} =
        NewtonRaphson.pv_pq_switching(switching_input(%{released: MapSet.new([1])}))

      assert switched == %{1 => {:max, 0.3}}
      assert MapSet.member?(latched, 1)

      # ...and stays PQ even where the release test would otherwise fire, which
      # is what bounds the type changes per bus and terminates the outer loop.
      {switched, released, _latched} =
        NewtonRaphson.pv_pq_switching(
          switching_input(%{
            pv_indices: [],
            switched: switched,
            released: MapSet.new([1]),
            latched: latched,
            vm: :array.from_list([1.0, 1.05])
          })
        )

      assert switched == %{1 => {:max, 0.3}}
      assert MapSet.size(released) == 1
    end

    test "an unknown q_limit_policy is rejected rather than silently defaulted" do
      assert NewtonRaphson.back_switch?([]) == true
      assert NewtonRaphson.back_switch?(q_limit_policy: :complementary) == true
      assert NewtonRaphson.back_switch?(q_limit_policy: :matpower) == false

      assert_raise ArgumentError, fn -> NewtonRaphson.back_switch?(q_limit_policy: :nope) end
    end
  end

  describe "solver selection and fallback" do
    test "islands at or below the cutoff are solved by dense Newton-Raphson" do
      {:ok, dispatched} = FDPF.solve(ieee14(), base_mva: @base_mva)
      {:ok, direct} = NewtonRaphson.solve(ieee14(), base_mva: @base_mva)

      assert FDPF.dense_nr_max_buses() >= 14
      # Identical iteration count and voltages: this went down the Newton path.
      assert dispatched.iterations == direct.iterations
      assert dispatched.vm_pu == direct.vm_pu
    end

    test "an island FDPF cannot converge falls back to dense Newton-Raphson" do
      # The contract is that a small island is retried on the dense path rather
      # than reported unsolvable. The fallback is forced here by capping FDPF
      # at a single iteration.
      {:ok, sol} = FDPF.solve(ieee14(), fdpf_opts(max_iterations: 1))

      assert sol.converged, "the dense fallback should have finished this solve"
      assert sol.iterations > 1
      assert_in_delta sol.total_loss_mw, 13.393, 0.2
      assert FDPF.dense_nr_fallback_max_buses() >= 14
      # SOL-14: the stamp is what makes the retry visible after the fact.
      assert sol.solver == :dense_nr
    end

    test "SOL-14: an island past the fallback cutoff is refused, not retried" do
      # Above `dense_nr_fallback_max_buses` a failed FDPF must report the
      # unconverged solution immediately. Retrying densely there costs a full
      # (2n)x(2n) iteration budget and lands on the same `converged: false`.
      n = FDPF.dense_nr_fallback_max_buses() + 50
      snapshot = ring(n)

      {:ok, sol} = FDPF.solve(snapshot, fdpf_opts(max_iterations: 1))

      refute sol.converged
      assert sol.solver == :fdpf, "a dense retry would have stamped :dense_nr"
      # One capped FDPF iteration, not a dense solve's worth of them.
      assert sol.iterations <= 2
    end

    test "SOL-14: the two cutoffs answer different questions" do
      # The primary handoff is where dense NR is free; the fallback bound is
      # where a dense RETRY is affordable. They are ordered but unrelated, and
      # the fallback bound sits far below the 3,000 it used to, because the
      # cost that sets it is the failed-solve cost.
      assert FDPF.dense_nr_max_buses() < FDPF.dense_nr_fallback_max_buses()
      assert FDPF.dense_nr_fallback_max_buses() <= 500
    end
  end

  describe "SOL-14: the :solver stamp" do
    test "FDPF stamps its own solves" do
      {:ok, sol} = FDPF.solve(ieee14(), fdpf_opts())

      assert sol.converged
      assert sol.solver == :fdpf
    end

    test "the primary handoff to dense NR is stamped :dense_nr, not :fdpf" do
      {:ok, sol} = FDPF.solve(ieee14(), base_mva: @base_mva)

      assert FDPF.dense_nr_max_buses() >= 14
      assert sol.solver == :dense_nr
    end

    test "dense Newton-Raphson stamps itself" do
      {:ok, sol} = NewtonRaphson.solve(ieee14(), base_mva: @base_mva)

      assert sol.solver == :dense_nr
    end

    test "a merge whose islands took different paths is :mixed" do
      # IEEE-14 is under the primary cutoff and goes dense; a 40-bus ring is
      # over it and goes fast-decoupled. One merged solution, two solvers.
      big = ring(40)

      merged = %{
        buses: ieee14().buses ++ big.buses,
        lines: ieee14().lines ++ big.lines,
        transformers: ieee14().transformers,
        generators: ieee14().generators ++ big.generators,
        loads: ieee14().loads ++ big.loads
      }

      solution = FDPF.solve_islands(merged, base_mva: @base_mva)

      assert solution.n_islands_solved == 2
      assert solution.solver == :mixed
    end

    test "a merge whose islands agree carries the shared stamp" do
      solution = FDPF.solve_islands(ring(40), base_mva: @base_mva)

      assert solution.n_islands_solved == 1
      assert solution.solver == :fdpf
    end

    test "merged_solver/1 on an empty merge is nil, not a claim" do
      assert Solution.merged_solver([]) == nil
    end

    test "an empty snapshot throws rather than returning an empty solution" do
      empty = %{buses: [], lines: [], transformers: [], generators: [], loads: []}

      assert catch_throw(FDPF.solve(empty, fdpf_opts())) == {:error, :empty_grid}
    end

    test "duplicate bus ids are rejected loudly" do
      snapshot = ieee14()
      dup = %{snapshot | buses: snapshot.buses ++ [hd(snapshot.buses)]}

      assert_raise ArgumentError, ~r/duplicate bus ids/, fn ->
        FDPF.solve(dup, fdpf_opts())
      end
    end
  end

  describe "solve_islands/2" do
    test "solves separate islands independently and reports dead load" do
      island_a = ieee14()
      b = two_bus(15.0, 5.0)

      island_b = %{
        buses: Enum.map(b.buses, &%{&1 | id: &1.id + 100}),
        lines:
          Enum.map(b.lines, fn l ->
            %{l | id: l.id + 100, from_bus_id: l.from_bus_id + 100, to_bus_id: l.to_bus_id + 100}
          end),
        generators: Enum.map(b.generators, &%{&1 | id: &1.id + 100, bus_id: &1.bus_id + 100}),
        loads: Enum.map(b.loads, &%{&1 | id: &1.id + 100, bus_id: &1.bus_id + 100})
      }

      dead_bus = %{id: 900, bus_type: 1, base_kv: 138.0, vm_pu: 1.0, va_rad: 0.0}
      dead_load = %{id: 900, bus_id: 900, p_mw: 42.0, q_mvar: 10.0}

      merged = %{
        buses: island_a.buses ++ island_b.buses ++ [dead_bus],
        lines: island_a.lines ++ island_b.lines,
        transformers: island_a.transformers,
        generators: island_a.generators ++ island_b.generators,
        loads: island_a.loads ++ island_b.loads ++ [dead_load]
      }

      solution = FDPF.solve_islands(merged, base_mva: @base_mva)

      assert solution.converged
      assert solution.n_islands_solved == 2
      assert_in_delta solution.dead_load_mw, 42.0, 1.0e-9
      assert solution.dead_bus_count == 1
      assert length(solution.bus_ids) == 16
      assert map_size(solution.line_flows) == 21
    end
  end
end
