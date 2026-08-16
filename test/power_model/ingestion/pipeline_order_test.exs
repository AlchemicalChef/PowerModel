defmodule PowerModel.Ingestion.PipelineOrderTest do
  @moduledoc """
  REVIEW DAT-26. `full_pipeline` ran `map_buses` before `estimate_parameters`,
  so DR-4's capability-ranked generator placement read `rating_a_mva` as NULL
  on every line and fell through to the pre-DR-4 nearest-any-level rule, and
  the repairing `remap_stranded_generators` pass had no pipeline caller at
  all. Neither is visible on a database that has had the migrations applied —
  only on a fresh one — so the ordering is asserted directly.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.ParameterEstimator

  defp stage_index(fragment) do
    Mix.Tasks.PowerModel.Ingest.pipeline_stages()
    |> Enum.find_index(fn {label, _fun} -> label =~ fragment end)
  end

  test "line parameters are estimated before bus mapping ranks buses on them" do
    lines = stage_index("Estimating line parameters")
    map_buses = stage_index("Mapping components to buses")

    assert is_integer(lines), "the line parameter stage is missing from the pipeline"
    assert is_integer(map_buses)

    assert lines < map_buses,
           "map_buses ranks candidate buses on summed rating_a_mva; running it first " <>
             "makes every line contribute 0.0 (DAT-26)"
  end

  test "the full parameter pass still runs after bus mapping" do
    # synthesize_line_end_reactors selects on non-null endpoints, so the pass
    # that contains it cannot move with the line pass.
    assert stage_index("Estimating electrical parameters") > stage_index("Mapping components")
  end

  test "stranded generators are re-mapped after connectivity repair" do
    repair = stage_index("Repairing network connectivity")
    remap = stage_index("Re-mapping stranded generators")

    assert is_integer(remap), "remap_stranded_generators has no pipeline caller (DAT-26)"

    assert remap > repair,
           "connectivity repair adds branch rating, which is the term the placement " <>
             "rule ranks on — the re-map has to see it"
  end

  test "validation stays last" do
    stages = Mix.Tasks.PowerModel.Ingest.pipeline_stages()
    {last_label, _} = List.last(stages)

    assert last_label =~ "Validating"
  end

  describe "the reorder's precondition" do
    test "line_params/2 does not consult the endpoint buses when geometry is present" do
      geometry = %Geo.LineString{
        coordinates: [{-100.0, 40.0}, {-100.0, 41.0}],
        srid: 4326
      }

      far_bus = %{coordinates: %Geo.Point{coordinates: {-80.0, 25.0}, srid: 4326}}

      mapped =
        ParameterEstimator.line_params(%{
          voltage_kv: 345.0,
          geometry: geometry,
          from_bus: far_bus,
          to_bus: far_bus
        })

      unmapped =
        ParameterEstimator.line_params(%{
          voltage_kv: 345.0,
          geometry: geometry,
          from_bus: nil,
          to_bus: nil
        })

      # Same rating, same impedance, same length: the endpoints are a third
      # fallback that a line with geometry never reaches. This is what makes
      # running the pass before map_buses a no-op on the numbers.
      assert mapped == unmapped
      assert mapped.rating_a_mva > 0.0
      assert_in_delta mapped.length_km, 111.0, 2.0
    end
  end
end
