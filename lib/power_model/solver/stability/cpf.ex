defmodule PowerModel.Solver.Stability.CPF do
  @moduledoc """
  Continuation Power Flow (CPF) for voltage stability analysis.

  Traces the P-V curve (nose curve) by parameterizing the power flow
  equations with a loading factor lambda:

      P_load(lambda) = P_load_base * (1 + lambda * load_increase_direction)
      P_gen(lambda) = P_gen_base * (1 + lambda * gen_increase_direction)

  The CPF uses a predictor-corrector method:

  1. **Predictor**: Tangent vector at current solution extrapolated forward
  2. **Corrector**: NR-like iteration to find the exact solution on the curve

  The nose point (maximum loading) is where voltage collapse occurs.
  Beyond the nose, voltages decrease with DECREASING load — the system
  is on the lower (unstable) portion of the P-V curve.

  ## Usage

      result = CPF.trace(snapshot, opts)
      # result.pv_curve — [{lambda, bus_id, vm_pu}]
      # result.nose_point — %{lambda, vm_pu, p_total_mw}
      # result.margin_mw — MW of additional load before collapse
  """

  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson}

  defstruct [
    :pv_curve,          # [{lambda, voltages_map}]
    :nose_point,        # %{lambda, min_vm_pu, total_load_mw}
    :margin_mw,         # MW margin to collapse from base case
    :critical_bus_id,   # bus with lowest voltage at nose point
    :converged,         # whether the trace completed
    :steps              # number of continuation steps taken
  ]

  @doc """
  Trace the P-V curve from the base case to the nose point.

  ## Options
    * `:base_mva` — system MVA base (default 100.0)
    * `:step_size` — initial lambda step (default 0.05)
    * `:max_steps` — maximum continuation steps (default 100)
    * `:min_step` — minimum step size before giving up (default 0.001)
    * `:monitor_bus_id` — bus to track on the P-V curve (default: weakest bus)
    * `:load_direction` — :proportional (default) or :single_bus
    * `:target_bus_id` — if load_direction is :single_bus, increase load here
    * `:solver` — :dc (default) or :ac
  """
  def trace(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    step_size = Keyword.get(opts, :step_size, 0.05)
    max_steps = Keyword.get(opts, :max_steps, 100)
    min_step = Keyword.get(opts, :min_step, 0.001)
    solver = Keyword.get(opts, :solver, :ac)

    base_load = Enum.sum_by(snapshot.loads, & &1.p_mw)

    # Solve base case (lambda = 0)
    base_solution = solve_at_lambda(snapshot, 0.0, base_mva, solver)

    if base_solution == nil do
      %__MODULE__{pv_curve: [], nose_point: nil, margin_mw: 0.0,
                  critical_bus_id: nil, converged: false, steps: 0}
    else
      initial_point = extract_point(base_solution, 0.0)

      # Trace the curve
      {curve, _nose, final_lambda, converged} =
        do_trace(snapshot, [initial_point], 0.0, step_size, max_steps, min_step,
                 base_mva, solver)

      # Find the nose point (maximum lambda where solve converges)
      nose_point = find_nose(curve)

      margin_mw = if nose_point do
        nose_point.lambda * base_load
      else
        final_lambda * base_load
      end

      critical_bus = if nose_point, do: nose_point.critical_bus_id, else: nil

      %__MODULE__{
        pv_curve: Enum.reverse(curve),
        nose_point: nose_point,
        margin_mw: Float.round(margin_mw, 1),
        critical_bus_id: critical_bus,
        converged: converged,
        steps: length(curve) - 1
      }
    end
  end

  @doc """
  Compute the voltage stability margin for a specific bus.

  Returns the MW of additional load that can be added before the bus
  voltage drops below `v_threshold` (default 0.9 pu).
  """
  def voltage_margin(cpf_result, bus_id, v_threshold \\ 0.9) do
    case cpf_result.pv_curve do
      [] -> 0.0
      curve ->
        # Find the lambda where this bus drops below threshold
        critical = Enum.find(curve, fn point ->
          v = Map.get(point.voltages, bus_id, 1.0)
          v < v_threshold
        end)

        case critical do
          nil -> cpf_result.margin_mw  # Never drops below threshold
          point -> point.total_load_mw - hd(curve).total_load_mw
        end
    end
  end

  @doc """
  Get the P-V curve data for a specific bus (for plotting).

  Returns [{total_load_mw, vm_pu}].
  """
  def pv_data(cpf_result, bus_id) do
    Enum.map(cpf_result.pv_curve, fn point ->
      {point.total_load_mw, Map.get(point.voltages, bus_id, 1.0)}
    end)
  end

  @doc """
  Find all buses below a voltage threshold at the nose point.
  """
  def weak_buses(cpf_result, v_threshold \\ 0.92) do
    case cpf_result.nose_point do
      nil -> []
      nose ->
        nose.voltages
        |> Enum.filter(fn {_id, v} -> v < v_threshold end)
        |> Enum.sort_by(fn {_id, v} -> v end)
        |> Enum.map(fn {id, v} -> %{bus_id: id, vm_pu: Float.round(v, 4)} end)
    end
  end

  # --- Private ---

  defp do_trace(_snapshot, curve, lambda, _step, max_steps, _min_step,
               _base_mva, _solver) when length(curve) > max_steps do
    {curve, nil, lambda, false}
  end

  defp do_trace(snapshot, curve, lambda, step, max_steps, min_step,
               base_mva, solver) do
    next_lambda = lambda + step

    case solve_at_lambda(snapshot, next_lambda, base_mva, solver) do
      nil ->
        # Didn't converge — reduce step size and retry
        if step / 2.0 < min_step do
          # Can't go smaller — this is approximately the nose
          {curve, nil, lambda, true}
        else
          do_trace(snapshot, curve, lambda, step / 2.0, max_steps, min_step,
                   base_mva, solver)
        end

      solution ->
        point = extract_point(solution, next_lambda)
        new_curve = [point | curve]

        # Check for voltage collapse indicator: any bus below 0.5 pu
        min_v = point.min_vm_pu

        if min_v < 0.5 do
          # Past the nose — stop
          {new_curve, nil, next_lambda, true}
        else
          # Adaptive step: increase step if far from nose, decrease if voltages dropping
          prev_min = hd(curve).min_vm_pu
          new_step = cond do
            min_v < 0.85 -> max(step * 0.5, min_step)
            min_v > prev_min -> min(step * 1.5, 0.2)
            true -> step
          end

          do_trace(snapshot, new_curve, next_lambda, new_step, max_steps, min_step,
                   base_mva, solver)
        end
    end
  end

  defp solve_at_lambda(snapshot, lambda, base_mva, solver) do
    # Scale loads by (1 + lambda). Do NOT scale generator p_max_mw (capacity).
    # Let dispatch handle the generation increase naturally.
    scaled_loads = Enum.map(snapshot.loads, fn l ->
      %{l | p_mw: l.p_mw * (1.0 + lambda)}
    end)

    scaled_snapshot = %{snapshot |
      loads: scaled_loads
    }

    try do
      case solver do
        :dc ->
          DCPowerFlow.solve(scaled_snapshot, base_mva: base_mva)

        :ac ->
          case NewtonRaphson.solve(scaled_snapshot,
                 base_mva: base_mva, max_iterations: 30, tolerance: 1.0e-3) do
            {:ok, sol} -> if sol.converged, do: sol, else: nil
            _ -> nil
          end
      end
    catch
      _, _ -> nil
    end
  end

  defp extract_point(solution, lambda) do
    voltages = Map.new(Enum.zip(solution.bus_ids, solution.vm_pu))
    min_v = Enum.min(solution.vm_pu)
    total_load = Map.get(solution, :total_load_mw) || 0.0

    {critical_id, _} = Enum.zip(solution.bus_ids, solution.vm_pu)
    |> Enum.min_by(fn {_id, v} -> v end)

    %{
      lambda: lambda,
      voltages: voltages,
      min_vm_pu: min_v,
      total_load_mw: total_load * (1.0 + lambda),
      critical_bus_id: critical_id
    }
  end

  defp find_nose(curve) when length(curve) < 2, do: nil
  defp find_nose(curve) do
    # The nose is the point with maximum lambda (last converged point before collapse)
    # Since curve is in reverse order (most recent first), it's the head
    point = hd(curve)

    %{
      lambda: point.lambda,
      min_vm_pu: point.min_vm_pu,
      total_load_mw: point.total_load_mw,
      critical_bus_id: point.critical_bus_id,
      voltages: point.voltages
    }
  end
end
