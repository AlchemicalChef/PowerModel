defmodule PowerModel.Validation.Harness do
  @moduledoc """
  High-level orchestration for replaying and scoring validation cases.
  """

  alias PowerModel.Validation.{Case, Replay, Scoring}

  @type case_result :: %{
          case_id: String.t(),
          description: String.t(),
          replay: map(),
          score: map()
        }

  @type run_result :: %{
          summary: map(),
          results: [case_result()]
        }

  @doc """
  Run and score one case.
  """
  @spec run_case(Case.t(), keyword()) :: case_result()
  def run_case(%Case{} = validation_case, opts \\ []) do
    replay = Replay.run_case(validation_case, opts)
    score = Scoring.score(replay.metrics, validation_case.expected)

    %{
      case_id: validation_case.id,
      description: validation_case.description,
      replay: replay,
      score: score
    }
  end

  @doc """
  Run and score every built-in fixture case.
  """
  @spec run_all(keyword()) :: run_result()
  def run_all(opts \\ []) do
    run_cases(Case.fixtures(), opts)
  end

  @doc """
  Run and score a list of cases.
  """
  @spec run_cases([Case.t()], keyword()) :: run_result()
  def run_cases(cases, opts \\ []) when is_list(cases) do
    results = Enum.map(cases, &run_case(&1, opts))

    %{
      summary: summarize(results),
      results: results
    }
  end

  @doc """
  Run and score one built-in fixture case by ID.
  """
  @spec run_fixture(String.t() | atom(), keyword()) :: {:ok, case_result()} | :error
  def run_fixture(case_id, opts \\ []) do
    case Case.fetch(case_id) do
      {:ok, validation_case} ->
        {:ok, run_case(validation_case, opts)}

      :error ->
        :error
    end
  end

  defp summarize(results) do
    scores = Enum.map(results, & &1.score.score)
    passing = Enum.filter(results, & &1.score.passed)
    failing = Enum.reject(results, & &1.score.passed)

    average_score =
      if scores == [] do
        0.0
      else
        scores |> Enum.sum() |> Kernel./(length(scores))
      end

    %{
      case_count: length(results),
      passing_case_count: length(passing),
      failing_case_count: length(failing),
      passing_case_ids: Enum.map(passing, & &1.case_id),
      failing_case_ids: Enum.map(failing, & &1.case_id),
      average_score: Float.round(average_score, 2),
      min_score: scores |> Enum.min(fn -> 0.0 end) |> Float.round(2),
      max_score: scores |> Enum.max(fn -> 0.0 end) |> Float.round(2),
      all_passed: failing == []
    }
  end
end
