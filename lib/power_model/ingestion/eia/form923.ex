defmodule PowerModel.Ingestion.EIA.Form923 do
  @moduledoc """
  Ingest capacity factors from EIA-923 Schedule 3 data.
  Updates existing generators with actual capacity factors.
  """

  NimbleCSV.define(EIA923Parser, separator: ",", escape: "\"")

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  def ingest(path) do
    gen_path = find_file(path, ~w(
      EIA923_Schedules_2_3_4_5_M_12_*.csv
      generation.csv
    ))

    if gen_path do
      gen_path
      |> File.stream!([:trim_bom])
      |> EIA923Parser.parse_stream(skip_headers: false)
      |> Stream.transform(nil, fn
        row, nil -> {[], row}
        row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
      end)
      |> Flow.from_enumerable(max_demand: 200)
      |> Flow.map(&update_capacity_factor/1)
      |> Flow.run()
    end
  end

  defp update_capacity_factor(row) do
    plant_id = Map.get(row, "Plant Id") || Map.get(row, "Plant Code")
    net_gen = parse_float(Map.get(row, "Net Generation (Megawatthours)"))

    if plant_id && net_gen do
      plant_id_str = to_string(plant_id)
      hours_in_year = 8760.0

      generators =
        from(g in Generator,
          where: g.eia_plant_id == ^plant_id_str and g.p_max_mw > 0
        )
        |> Repo.all()

      total_capacity = Enum.sum(Enum.map(generators, & &1.p_max_mw))

      if total_capacity > 0 do
        cf = net_gen / (total_capacity * hours_in_year)
        cf = max(0.0, min(1.0, cf))

        from(g in Generator,
          where: g.eia_plant_id == ^plant_id_str
        )
        |> Repo.update_all(set: [capacity_factor: cf])
      end
    end
  end

  defp find_file(path, patterns) do
    Enum.find_value(patterns, fn pattern ->
      case Path.wildcard(Path.join(path, pattern)) do
        [found | _] -> found
        [] -> nil
      end
    end)
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, _} -> f
      :error -> nil
    end
  end
end
