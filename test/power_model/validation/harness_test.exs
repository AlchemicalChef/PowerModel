defmodule PowerModel.Validation.HarnessTest do
  use ExUnit.Case, async: false

  alias PowerModel.Validation.{Case, Harness}

  test "fixture IDs are unique and fetchable" do
    ids = Case.ids()
    assert ids == Enum.uniq(ids)

    Enum.each(ids, fn id ->
      assert {:ok, %Case{id: ^id}} = Case.fetch(id)
    end)
  end

  test "generator UFLS fixture records expected frequency and shedding behavior" do
    validation_case = Case.fetch!("generator_trip_ufls_response")
    result = Harness.run_case(validation_case)

    assert result.score.passed
    assert_in_delta result.replay.metrics.ufls_shed_mw, 20.0, 0.05
    assert result.replay.metrics.ufls_event_count == 1
    assert result.replay.metrics.relay_81_event_count == 0
    assert result.replay.metrics.min_frequency_hz <= 58.0
  end

  test "harmonics fixture runs post-stabilization analysis" do
    validation_case = Case.fetch!("harmonics_post_stabilization_baseline")
    result = Harness.run_case(validation_case)

    assert result.score.passed
    assert result.replay.metrics.harmonics_result_present
    assert result.replay.metrics.harmonics_violations == 18
    assert_in_delta result.replay.metrics.harmonics_worst_thd_pct, 23.05735, 0.05
  end

  test "transient screening fixture records transient diagnostics" do
    validation_case = Case.fetch!("transient_screening_line_trip")
    result = Harness.run_case(validation_case)

    assert result.score.passed
    assert result.replay.metrics.transient_checks_run >= 1
    assert result.replay.metrics.transient_screen_event_count >= 1
    assert result.replay.metrics.transient_failed_checks == 0
  end

  test "week 4 fixture records CPF and small-signal diagnostics" do
    validation_case = Case.fetch!("voltage_small_signal_post_stabilization")
    result = Harness.run_case(validation_case)

    assert result.score.passed
    assert result.replay.metrics.cpf_result_present
    assert result.replay.metrics.small_signal_result_present
    assert result.replay.metrics.small_signal_stable == true
    assert result.replay.metrics.stability_modes_count >= 1
    assert result.replay.metrics.voltage_margin_mw >= 200.0
  end

  test "all fixtures pass baseline replay scoring" do
    run = Harness.run_all()

    assert run.summary.case_count == length(Case.fixtures())
    assert run.summary.all_passed
    assert run.summary.passing_case_count == run.summary.case_count
    assert run.summary.average_score >= 99.0
  end
end
