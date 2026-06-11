defmodule PowerModel.Validation.Scoring do
  @moduledoc """
  Scores replayed metrics against expected targets.

  Supported comparators:

  - `:eq`      exact equality
  - `:approx`  absolute tolerance around target
  - `:lte`     observed <= target (+ tolerance)
  - `:gte`     observed >= target (- tolerance)
  """

  @type metric_result :: %{
          metric: atom() | String.t(),
          target: term(),
          observed: term(),
          comparator: atom(),
          tolerance: float(),
          weight: float(),
          passed: boolean(),
          error_ratio: float(),
          points: float()
        }

  @type score_result :: %{
          score: float(),
          passed: boolean(),
          earned_points: float(),
          total_points: float(),
          metrics: %{optional(atom() | String.t()) => map()}
        }

  @doc """
  Score a replay metric map against expected metric specs.
  """
  @spec score(map(), map()) :: score_result()
  def score(observed_metrics, expected_specs)
      when is_map(observed_metrics) and is_map(expected_specs) do
    metric_results =
      expected_specs
      |> Enum.map(fn {metric, spec} -> evaluate_metric(metric, spec, observed_metrics) end)

    total_points = Enum.sum_by(metric_results, & &1.weight)
    earned_points = Enum.sum_by(metric_results, & &1.points)

    pct =
      if total_points <= 0.0 do
        100.0
      else
        earned_points / total_points * 100.0
      end

    %{
      score: Float.round(pct, 2),
      passed: Enum.all?(metric_results, & &1.passed),
      earned_points: Float.round(earned_points, 4),
      total_points: Float.round(total_points, 4),
      metrics:
        Map.new(metric_results, fn result -> {result.metric, Map.delete(result, :metric)} end)
    }
  end

  defp evaluate_metric(metric, spec, observed_metrics) do
    normalized_metric = normalize_metric(metric)
    normalized_spec = normalize_spec(spec)
    observed = metric_value(observed_metrics, metric)

    {passed, error_ratio} =
      evaluate(
        observed,
        normalized_spec.target,
        normalized_spec.comparator,
        normalized_spec.tolerance
      )

    points = normalized_spec.weight * (1.0 - error_ratio)

    %{
      metric: normalized_metric,
      target: normalized_spec.target,
      observed: observed,
      comparator: normalized_spec.comparator,
      tolerance: normalized_spec.tolerance,
      weight: normalized_spec.weight,
      passed: passed,
      error_ratio: Float.round(error_ratio, 6),
      points: Float.round(points, 6)
    }
  end

  defp evaluate(observed, target, :eq, _tolerance) do
    if observed == target, do: {true, 0.0}, else: {false, 1.0}
  end

  defp evaluate(observed, target, :approx, tolerance)
       when is_number(observed) and is_number(target) do
    diff = abs(observed - target)
    tol = max(tolerance, 1.0e-9)
    passed = diff <= tol
    error_ratio = min(diff / tol, 1.0)
    {passed, error_ratio}
  end

  defp evaluate(observed, target, :lte, tolerance)
       when is_number(observed) and is_number(target) do
    limit = target + max(tolerance, 0.0)
    over = max(observed - limit, 0.0)
    scale = max(abs(target), 1.0)
    error_ratio = min(over / scale, 1.0)
    {observed <= limit, error_ratio}
  end

  defp evaluate(observed, target, :gte, tolerance)
       when is_number(observed) and is_number(target) do
    limit = target - max(tolerance, 0.0)
    under = max(limit - observed, 0.0)
    scale = max(abs(target), 1.0)
    error_ratio = min(under / scale, 1.0)
    {observed >= limit, error_ratio}
  end

  defp evaluate(_observed, _target, _comparator, _tolerance), do: {false, 1.0}

  defp normalize_spec(spec) when is_map(spec) do
    target = spec_value(spec, :target, nil)
    comparator = normalize_comparator(spec_value(spec, :comparator, default_comparator(target)))
    tolerance = spec_value(spec, :tolerance, default_tolerance(target, comparator))
    weight = spec_value(spec, :weight, 1.0)

    %{
      target: target,
      comparator: comparator,
      tolerance: numeric_or_default(tolerance, default_tolerance(target, comparator)),
      weight: numeric_or_default(weight, 1.0)
    }
  end

  defp normalize_spec(value) do
    comparator = default_comparator(value)

    %{
      target: value,
      comparator: comparator,
      tolerance: default_tolerance(value, comparator),
      weight: 1.0
    }
  end

  defp default_comparator(target) when is_number(target), do: :approx
  defp default_comparator(_target), do: :eq

  defp default_tolerance(target, :approx) when is_number(target),
    do: max(abs(target) * 0.01, 1.0e-6)

  defp default_tolerance(_target, _comparator), do: 0.0

  defp normalize_metric(metric) when is_atom(metric), do: metric
  defp normalize_metric(metric) when is_binary(metric), do: metric

  defp normalize_comparator(value) when is_atom(value), do: value

  defp normalize_comparator(value) when is_binary(value) do
    case value do
      "eq" -> :eq
      "approx" -> :approx
      "lte" -> :lte
      "gte" -> :gte
      _ -> :eq
    end
  end

  defp normalize_comparator(_value), do: :eq

  defp metric_value(metrics, metric) when is_atom(metric) do
    case Map.fetch(metrics, metric) do
      {:ok, value} ->
        value

      :error ->
        Map.get(metrics, Atom.to_string(metric))
    end
  end

  defp metric_value(metrics, metric) when is_binary(metric) do
    case Map.fetch(metrics, metric) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(metrics, fn
          {key, value} when is_atom(key) ->
            if Atom.to_string(key) == metric, do: value, else: nil

          _ ->
            nil
        end)
    end
  end

  defp spec_value(spec, key, default) when is_atom(key) do
    case Map.fetch(spec, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(spec, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  defp numeric_or_default(value, _default) when is_number(value), do: value
  defp numeric_or_default(_value, default), do: default
end
