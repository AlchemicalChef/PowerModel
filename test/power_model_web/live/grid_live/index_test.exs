defmodule PowerModelWeb.GridLive.IndexTest do
  use PowerModelWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PowerModel.Validation.{Case, Harness}

  test "renders week 1 controls with expected defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    assert has_element?(view, "#failure-controls-panel")
    assert has_element?(view, "#model-option-use_ac")
    assert has_element?(view, "#validation-case-select")
    assert has_element?(view, "#hour-profile-select")
    assert has_element?(view, "#hour-profile-select option[selected][value='base']")

    assert has_element?(
             view,
             "#validation-case-select option[selected][value='line_trip_island_blackout']"
           )

    refute has_element?(view, ".validation-report")
  end

  test "model option toggle updates UI and clears prior cascade state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    send(
      view.pid,
      {:simulation_cascade_step, %{step: 1, trip_count: 2, frequency_hz: 59.4, islands: 2}}
    )

    assert has_element?(view, ".reset-btn")
    assert render(view) =~ "59.40 Hz"

    view
    |> element("#model-option-use_ac")
    |> render_click()

    assert has_element?(view, "#model-option-use_ac[checked]")
    refute has_element?(view, ".reset-btn")
    assert render(view) =~ "60.00 Hz"
  end

  test "week 5 load profile hour change resets prior cascade state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    send(
      view.pid,
      {:simulation_cascade_step, %{step: 1, trip_count: 2, frequency_hz: 59.4, islands: 2}}
    )

    assert has_element?(view, ".reset-btn")
    assert render(view) =~ "59.40 Hz"

    view
    |> element("#hour-profile-form")
    |> render_change(%{"hour" => "18"})

    assert has_element?(view, "#hour-profile-select option[selected][value='18']")
    refute has_element?(view, ".reset-btn")
    assert render(view) =~ "60.00 Hz"
  end

  test "validation case report can be rendered then cleared", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    validation_case = Case.fetch!("generator_trip_ufls_response")
    result = Harness.run_case(validation_case)

    send(view.pid, {:validation_case_finished, result.case_id, {:ok, result}})

    assert has_element?(view, ".validation-report")
    assert has_element?(view, ".validation-badge.ok", "PASS")
    assert render(view) =~ "generator_trip_ufls_response"

    view
    |> element("#clear-validation-report-btn")
    |> render_click()

    refute has_element?(view, ".validation-report")
  end

  test "validation suite report renders in the controls panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    view
    |> element("#validation-case-select-form")
    |> render_change(%{"case_id" => "harmonics_post_stabilization_baseline"})

    assert has_element?(
             view,
             "#validation-case-select option[selected][value='harmonics_post_stabilization_baseline']"
           )

    run = Harness.run_all()
    send(view.pid, {:validation_suite_finished, run})

    assert has_element?(view, ".validation-suite-list")
    assert render(view) =~ "harmonics_post_stabilization_baseline"
  end

  test "week 2 screening summary renders top contingency rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    view
    |> element("#failure-mode-n1-btn")
    |> render_click()

    assert has_element?(view, "#screening-config-form")

    send(
      view.pid,
      {:n1_screening_done,
       %{
         violations: 1,
         sampled_count: 2,
         worst_loading_pct: 134.2,
         worst_score: 450.3,
         top_results: [
           %{
             label: "Line 12",
             max_loading_pct: 134.2,
             overloaded_count: 2,
             mw_at_risk: 88.4,
             island_split: false,
             severe: true
           }
         ]
       }}
    )

    _ = render(view)
    assert has_element?(view, ".violation-count", "1")
    assert has_element?(view, ".screening-meta", "Sampled 2")
    assert has_element?(view, ".screening-item-header", "Line 12")
    assert has_element?(view, ".screening-item-metrics", "Risk 88.4 MW")
  end

  test "week 2 screening controls accept parameter changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    view
    |> element("#failure-mode-n1-btn")
    |> render_click()

    view
    |> element("#screening-config-form")
    |> render_change(%{
      "screening" => %{
        "k_max" => "3",
        "sample_size" => "1200",
        "top_k" => "7"
      }
    })

    assert has_element?(view, "select[name='screening[k_max]'] option[selected][value='3']")
    assert has_element?(view, "input[name='screening[sample_size]'][value='1200']")
    assert has_element?(view, "input[name='screening[top_k]'][value='7']")
  end

  test "week 3 transient analysis fields render in post-stabilization panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    send(
      view.pid,
      {:simulation_cascade_done,
       %{
         stable: true,
         steps: 2,
         total_events: 3,
         transient_checks_run: 2,
         transient_unstable_checks: 1,
         transient_failed_checks: 0,
         transient_last_stable: false,
         transient_last_oos_count: 2,
         transient_last_min_frequency_hz: 59.21,
         transient_last_max_delta_deg: 128.4
       }}
    )

    assert has_element?(view, ".analysis-grid", "Transient Checks 2")
    assert has_element?(view, ".analysis-grid", "Transient Last Unstable")
    assert has_element?(view, ".analysis-grid", "Out-of-Step Trips 2")
    assert has_element?(view, ".analysis-grid", "Transient fmin 59.21 Hz")
    assert has_element?(view, ".analysis-grid", "Delta Spread 128.4 deg")
  end

  test "week 4 voltage and small-signal fields render in post-stabilization panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grid")

    send(
      view.pid,
      {:simulation_cascade_done,
       %{
         stable: true,
         steps: 1,
         total_events: 0,
         voltage_margin_mw: 310.5,
         critical_bus_id: 17,
         small_signal_stable: true,
         stability_modes: [%{freq_hz: 0.42}, %{freq_hz: 1.27}]
       }}
    )

    assert has_element?(view, ".analysis-grid", "CPF 310.5 MW")
    assert has_element?(view, ".analysis-grid", "Small Signal Stable")
    assert has_element?(view, ".analysis-grid", "Modes 2")
    assert has_element?(view, ".analysis-grid", "Critical Bus 17")
  end
end
