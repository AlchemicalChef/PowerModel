defmodule Mix.Tasks.PowerModel.Replay do
  @moduledoc """
  Runs deterministic cascade replay validation cases and prints scores.

  Examples:

      mix power_model.replay --list
      mix power_model.replay --case generator_trip_ufls_response
      mix power_model.replay
  """

  use Mix.Task

  alias PowerModel.Validation.{Case, Harness}

  @shortdoc "Run deterministic cascade replay validation"

  @switches [
    case: :string,
    list: :boolean,
    json: :boolean
  ]

  @aliases [
    c: :case,
    l: :list,
    j: :json
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    cond do
      opts[:list] ->
        print_case_list()

      opts[:case] ->
        run_single_case(opts[:case], opts)

      true ->
        run_all_cases(opts)
    end
  end

  defp print_case_list do
    Mix.shell().info("Available validation cases:")

    Case.fixtures()
    |> Enum.each(fn validation_case ->
      Mix.shell().info("  #{validation_case.id}  #{validation_case.description}")
    end)
  end

  defp run_single_case(case_id, opts) do
    case Harness.run_fixture(case_id) do
      {:ok, result} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(single_case_json(result), pretty: true))
        else
          print_single_case(result)
        end

      :error ->
        Mix.raise("unknown case #{inspect(case_id)}. Use --list to see valid IDs.")
    end
  end

  defp run_all_cases(opts) do
    run = Harness.run_all()

    if opts[:json] do
      Mix.shell().info(Jason.encode!(all_cases_json(run), pretty: true))
    else
      print_all_cases(run)
    end
  end

  defp print_single_case(result) do
    score = result.score

    Mix.shell().info("Case: #{result.case_id}")
    Mix.shell().info("Description: #{result.description}")
    Mix.shell().info("Score: #{score.score} (#{pass_fail(score.passed)})")

    metrics =
      score.metrics
      |> Enum.sort_by(fn {metric, _} -> metric_name(metric) end)

    Enum.each(metrics, fn {metric, data} ->
      Mix.shell().info(
        "  #{metric}: observed=#{inspect(data.observed)} target=#{inspect(data.target)} " <>
          "comparator=#{data.comparator} #{pass_fail(data.passed)}"
      )
    end)
  end

  defp print_all_cases(run) do
    summary = run.summary

    Mix.shell().info(
      "Replay Summary: #{summary.passing_case_count}/#{summary.case_count} passing, " <>
        "avg score #{summary.average_score}"
    )

    Enum.each(run.results, fn result ->
      Mix.shell().info(
        "  #{result.case_id}: #{result.score.score} #{pass_fail(result.score.passed)}"
      )
    end)
  end

  defp single_case_json(result) do
    %{
      case_id: result.case_id,
      description: result.description,
      score: result.score,
      metrics: result.replay.metrics
    }
  end

  defp all_cases_json(run) do
    %{
      summary: run.summary,
      results:
        Enum.map(run.results, fn result ->
          %{
            case_id: result.case_id,
            description: result.description,
            score: result.score,
            metrics: result.replay.metrics
          }
        end)
    }
  end

  defp pass_fail(true), do: "PASS"
  defp pass_fail(false), do: "FAIL"

  defp metric_name(metric) when is_atom(metric), do: Atom.to_string(metric)
  defp metric_name(metric) when is_binary(metric), do: metric
end
