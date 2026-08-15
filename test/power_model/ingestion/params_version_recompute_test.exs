defmodule PowerModel.Ingestion.ParamsVersionRecomputeTest do
  @moduledoc """
  REVIEW DAT-18 / ROADMAP item 8: the estimator recomputes rows written by an
  older version instead of only filling NULLs, so a corrected parameter table
  reaches rows already in the database.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Interconnection, TransmissionLine}
  alias PowerModel.Ingestion.ParameterEstimator, as: PE

  setup do
    {:ok, ic} =
      Repo.insert(%Interconnection{name: "TestIC-#{System.unique_integer([:positive])}"})

    {:ok, from} =
      Repo.insert(%Bus{
        bus_type: 1,
        base_kv: 500.0,
        interconnection_id: ic.id,
        coordinates: %Geo.Point{coordinates: {-120.0, 45.0}, srid: 4326}
      })

    {:ok, to} =
      Repo.insert(%Bus{
        bus_type: 1,
        base_kv: 500.0,
        interconnection_id: ic.id,
        coordinates: %Geo.Point{coordinates: {-119.0, 45.0}, srid: 4326}
      })

    %{from: from, to: to}
  end

  defp insert_line(ctx, attrs) do
    defaults = %{
      voltage_kv: 500.0,
      length_km: 100.0,
      from_bus_id: ctx.from.id,
      to_bus_id: ctx.to.id,
      status: "in_service",
      source: "hifld",
      source_id: "recompute-#{System.unique_integer([:positive])}"
    }

    Repo.insert!(struct(TransmissionLine, Map.merge(defaults, attrs)))
  end

  test "a stale row is recomputed, ratings and all", ctx do
    # Values a dead estimator version wrote: 500 kV carrying a 345 kV rating,
    # which is the measured defect DAT-18 describes.
    stale =
      insert_line(ctx, %{
        r_pu: 9.9,
        x_pu: 9.9,
        b_pu: 0.0,
        rating_a_mva: 900.0,
        params_version: 0
      })

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, stale.id)
    expected = PE.line_params(%{voltage_kv: 500.0, length_km: 100.0})

    assert reloaded.params_version == PE.params_version()
    assert_in_delta reloaded.rating_a_mva, expected.rating_a_mva, 1.0e-6
    assert_in_delta reloaded.x_pu, expected.x_pu, 1.0e-9
    assert reloaded.rating_a_mva > 900.0
  end

  test "a stale row gets emergency ratings it never had", ctx do
    stale = insert_line(ctx, %{r_pu: 0.1, x_pu: 0.1, rating_a_mva: 900.0, params_version: 0})

    assert stale.rating_b_mva == nil
    assert stale.rating_c_mva == nil

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, stale.id)

    assert_in_delta reloaded.rating_b_mva / reloaded.rating_a_mva, 1.15, 1.0e-9
    assert_in_delta reloaded.rating_c_mva / reloaded.rating_a_mva, 1.35, 1.0e-9
  end

  test "a row stamped at the PREVIOUS version is revisited", ctx do
    # The version-bump discipline itself: shipping a new rating recipe without
    # bumping `@params_version` leaves every already-stamped row reading as
    # current, which is REVIEW DAT-18 all over again. Stated against
    # `params_version() - 1` so it keeps testing the mechanism through future
    # bumps rather than pinning a number.
    previous =
      insert_line(ctx, %{
        r_pu: 0.1,
        x_pu: 0.1,
        rating_a_mva: 1800.0,
        params_version: PE.params_version() - 1
      })

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, previous.id)
    expected = PE.line_params(%{voltage_kv: 500.0, length_km: 100.0})

    assert reloaded.params_version == PE.params_version()
    assert_in_delta reloaded.rating_a_mva, expected.rating_a_mva, 1.0e-6

    # The item-10 recipe derates the 1,800 MVA class ceiling for ambient, so a
    # row carrying the bare class value is measurably changed by the revisit.
    assert reloaded.rating_a_mva < 1800.0
  end

  test "a row already at the current version is left alone", ctx do
    # A deliberately odd rating that the class table would never produce: if
    # the pass touched this row the value would change.
    current =
      insert_line(ctx, %{
        r_pu: 0.123,
        x_pu: 0.456,
        b_pu: 0.001,
        rating_a_mva: 4321.0,
        rating_b_mva: 4967.15,
        rating_c_mva: 5833.35,
        params_version: PE.params_version()
      })

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, current.id)

    assert reloaded.rating_a_mva == 4321.0
    assert reloaded.x_pu == 0.456
    assert reloaded.updated_at == current.updated_at
  end

  test "a row with missing impedance is still filled even at the current version", ctx do
    unparameterized =
      insert_line(ctx, %{r_pu: nil, x_pu: nil, params_version: PE.params_version()})

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, unparameterized.id)

    assert is_number(reloaded.x_pu) and reloaded.x_pu > 0
    assert is_number(reloaded.rating_c_mva)
  end

  test "imported-case rows are never overwritten, however stale", ctx do
    # MATPOWER rows carry real per-unit impedances from the published case and
    # no geometry to re-derive them from; estimating over them would replace
    # data with a guess.
    imported =
      insert_line(ctx, %{
        source: "matpower",
        r_pu: 0.00281,
        x_pu: 0.0281,
        rating_a_mva: 400.0,
        params_version: 0
      })

    PE.estimate_line_parameters()

    reloaded = Repo.get!(TransmissionLine, imported.id)

    assert reloaded.x_pu == 0.0281
    assert reloaded.rating_a_mva == 400.0
    assert reloaded.params_version == 0
  end

  test "the pass is idempotent: a second run changes nothing", ctx do
    line = insert_line(ctx, %{r_pu: 9.9, x_pu: 9.9, rating_a_mva: 900.0, params_version: 0})

    PE.estimate_line_parameters()
    after_first = Repo.get!(TransmissionLine, line.id)

    PE.estimate_line_parameters()
    after_second = Repo.get!(TransmissionLine, line.id)

    assert after_second.rating_a_mva == after_first.rating_a_mva
    assert after_second.updated_at == after_first.updated_at
  end
end
