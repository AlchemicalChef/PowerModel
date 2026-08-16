defmodule PowerModelWeb.GridLiveMetricsTest do
  @moduledoc """
  What the panels are allowed to claim (REVIEW UIW-3 / UIW-5 / UIW-6 / UIW-7).

  Four displayed facts were wrong or missing before this package, and each one
  is pinned here:

    * the balance identity `served + shed + blackout == original + btm_tripped`
      held in the engine and broke on the display, which dropped the BTM term
      and over-counted demand by exactly the rooftop MW that tripped
    * a cascade cut off at its step budget rendered as "Unstable", identical
      to a settled collapse -- the false-10x hazard
    * frequency was a session minimum latch, so a cascade AGC had restored to
      60.00 Hz kept showing its nadir in critical red forever
    * most emitted failure causes had no colour, and the Affected panel showed
      the OLDEST fifty events, hiding every terminal-phase trip
  """

  use PowerModelWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest

  alias PowerModelWeb.GridLive.AffectedList

  defp metrics(view), do: :sys.get_state(view.pid).socket.assigns.system_metrics

  defp step(overrides) do
    Map.merge(
      %{
        step: 1,
        simulated_time: 0.5,
        islands: 1,
        trips: [],
        tripped_line_ids: [],
        tripped_transformer_ids: [],
        tripped_generator_ids: [],
        trip_count: 0,
        balance: nil
      },
      overrides
    )
  end

  # The measured reference balance: 597.33 MW of rooftop PV tripped off, and
  # 40,206.8 + 3,043.53 + 0.0 == 42,653.0 + 597.33 exactly.
  defp btm_balance do
    %{
      original_load_mw: 42_653.0,
      served_load_mw: 40_206.8,
      shed_load_mw: 3_043.53,
      blackout_load_mw: 0.0,
      btm_tripped_mw: 597.33
    }
  end

  defp done(overrides) do
    Map.merge(
      %{
        steps: 3,
        stable: true,
        total_events: 3,
        tripped_count: 1,
        balance: nil,
        reason: :settled
      },
      overrides
    )
  end

  describe "the displayed balance identity (UIW-3 / UIW-6)" do
    test "rooftop MW that tripped is carried, so the panel totals reconcile",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_cascade_done, done(%{balance: btm_balance()})})
      _ = render(view)

      m = metrics(view)

      # The engine's conservation identity, now on the display side.
      residual = m.served_mw + m.shed_mw + m.blackout_mw - (m.demand_mw + m.btm_tripped_mw)
      assert abs(residual) < 1.0

      assert m.btm_tripped_mw == 597.33

      # And the reader can see the term that closes it.
      html = render(view)
      assert html =~ "BTM"
      assert render(element(view, "#metric-btm")) =~ "597 MW"
    end

    test "the BTM row splits frequency-driven from voltage-driven dropout",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_done,
         done(%{
           balance: btm_balance(),
           btm_trip_breakdown: %{frequency_mw: 597.33, voltage_mw: 0.0, total_mw: 597.33}
         })}
      )

      html = render(element(view, "#metric-btm"))
      assert html =~ "597 MW freq"
      assert html =~ "0 MW volt"
    end

    test "no BTM row at all when nothing behind the meter tripped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_done,
         done(%{
           balance: %{
             original_load_mw: 1000.0,
             served_load_mw: 1000.0,
             shed_load_mw: 0.0,
             blackout_load_mw: 0.0,
             btm_tripped_mw: 0.0
           }
         })}
      )

      _ = render(view)
      refute has_element?(view, "#metric-btm")
    end
  end

  describe "how a cascade ended (UIW-3)" do
    test "budget exhaustion, collapse and solve failure are three strings",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_done, done(%{stable: false, reason: :budget_exhausted})}
      )

      assert render(view) =~ "Unstable (step budget)"
      assert has_element?(view, ~s(#solver-badge[data-status="truncated"]))

      send(view.pid, {:simulation_cascade_done, done(%{stable: false, reason: :settled})})
      html = render(view)
      assert html =~ "Unstable"
      refute html =~ "Unstable (step budget)"
      assert has_element?(view, ~s(#solver-badge[data-status="unstable"]))

      send(view.pid, {:simulation_cascade_done, done(%{stable: false, reason: :solve_failed})})
      assert render(view) =~ "Solve failed"
      assert has_element?(view, ~s(#solver-badge[data-status="solve_failed"]))
    end

    test "a settled stable cascade is still Stable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_cascade_done, done(%{stable: true, reason: :settled})})
      assert has_element?(view, ~s(#solver-badge[data-status="stable"]))
    end

    test "a payload with no reason keeps the original two-state reading",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_cascade_done, Map.delete(done(%{stable: false}), :reason)})
      assert has_element?(view, ~s(#solver-badge[data-status="unstable"]))
    end

    test "the partial AC overlay is never labelled AC Converged", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_ac_update, %{partial_ac: true, ac_overlay: %{islands: []}}})
      assert render(view) =~ "AC (partial)"
      refute render(view) =~ "AC Converged"
    end
  end

  describe "frequency: current and nadir (UIW-5)" do
    test "the nadir does not survive settlement as the headline number",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # The dip...
      send(
        view.pid,
        {:simulation_cascade_step, step(%{frequency: %{f_hz: 59.212, nadir_hz: 59.212}})}
      )

      assert render(element(view, "#metric-frequency")) =~ "59.21"

      # ...and the recovery AGC drove.
      send(
        view.pid,
        {:simulation_cascade_step, step(%{step: 2, frequency: %{f_hz: 60.0, nadir_hz: 59.212}})}
      )

      send(view.pid, {:simulation_cascade_done, done(%{})})

      html = render(element(view, "#metric-frequency"))
      assert html =~ "60.00 Hz"
      assert html =~ "nadir 59.21"

      m = metrics(view)
      assert_in_delta m.frequency_hz, 60.0, 1.0e-9
      assert_in_delta m.frequency_nadir_hz, 59.212, 1.0e-9
    end

    test "shed-event nadirs still feed the running minimum", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # The aggregate a collapse-scale step carries: ONE synthetic event whose
      # frequency_nadir is the MINIMUM over the group, so aggregation cannot
      # raise the reported nadir.
      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           trips: [
             %{
               component_type: "island",
               component_id: 4126,
               failure_cause: "ufls_shed",
               details: %{aggregated: true, count: 5650, shed_mw: 3043.5, frequency_nadir: 59.212}
             }
           ],
           trip_count: 5650
         })}
      )

      assert_in_delta metrics(view).frequency_nadir_hz, 59.212, 1.0e-9
      assert render(element(view, "#metric-frequency")) =~ "nadir 59.21"
    end

    test "a sparkline appears once there is a trace to draw", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step, step(%{frequency: %{f_hz: 59.4, nadir_hz: 59.4}})}
      )

      _ = render(view)
      refute has_element?(view, "#freq-sparkline")

      send(
        view.pid,
        {:simulation_cascade_step, step(%{step: 2, frequency: %{f_hz: 59.9, nadir_hz: 59.4}})}
      )

      assert has_element?(view, "#freq-sparkline")
      assert render(element(view, "#freq-sparkline")) =~ "polyline"
    end

    test "a new injection re-arms the nadir at nominal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step, step(%{frequency: %{f_hz: 59.2, nadir_hz: 59.2}})}
      )

      assert metrics(view).frequency_nadir_hz < 59.5

      render_hook(view, "inject_failure", %{"type" => "generator", "id" => "999999"})

      assert metrics(view).frequency_nadir_hz == 60.0
      assert metrics(view).freq_history == []
    end
  end

  describe "AGC and AC coverage (UIW-3 / UIW-6)" do
    test "secondary control reports what it dispatched and what is left",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           agc: [
             %{
               island_id: 1,
               dispatched_mw: 1376.0,
               reserve_remaining_mw: 1200.0,
               saturated?: false
             }
           ]
         })}
      )

      html = render(element(view, "#metric-agc"))
      assert html =~ "1.4 GW"
      assert html =~ "1.2 GW reserve"
      refute html =~ "saturated"
    end

    test "a saturated controller says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           agc: [
             %{island_id: 1, dispatched_mw: 900.0, reserve_remaining_mw: 0.0, saturated?: true}
           ]
         })}
      )

      assert render(element(view, "#metric-agc")) =~ "saturated"
    end

    test "AC coverage is a fraction of island solves, and absent when none ran",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _ = render(view)
      refute has_element?(view, "#metric-ac-coverage")

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           voltage_layer: %{
             islands_ac: 2,
             ac_solves: 2,
             islands_dc_only: 5,
             ac_diverged: 4,
             ac_skipped: 1
           }
         })}
      )

      assert render(element(view, "#metric-ac-coverage")) =~ "2/7"
    end

    test "a step without a voltage layer does not zero the last reading",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           voltage_layer: %{islands_ac: 1, islands_dc_only: 1, ac_diverged: 1, ac_skipped: 0}
         })}
      )

      # Absence means "no information", never zero: reading a missing key as 0
      # would report "no AC coverage" for a step that simply did not measure.
      send(view.pid, {:simulation_cascade_step, step(%{step: 2})})

      assert render(element(view, "#metric-ac-coverage")) =~ "1/2"
    end
  end

  describe "the Affected panel (UIW-5 / UIW-7)" do
    test "the newest events are on top", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           trips: [
             %{
               component_type: "transmission_line",
               component_id: 11,
               failure_cause: "thermal_overload",
               details: %{}
             }
           ],
           trip_count: 1
         })}
      )

      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           step: 2,
           trips: [
             %{
               component_type: "bus",
               component_id: 22,
               failure_cause: "undervoltage_trip",
               details: %{}
             }
           ],
           trip_count: 1
         })}
      )

      html = render(element(view, ".affected-scroll"))
      newest = :binary.match(html, "#22") |> elem(0)
      oldest = :binary.match(html, "#11") |> elem(0)

      assert newest < oldest, "the terminal-phase event must be at the top of the panel"
    end

    test "the header counts real events, not the aggregated panel view",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # One synthetic row standing for 5,650 shed loads.
      send(
        view.pid,
        {:simulation_cascade_step,
         step(%{
           trips: [
             %{
               component_type: "island",
               component_id: 4126,
               failure_cause: "ufls_shed",
               details: %{aggregated: true, count: 5650, shed_mw: 3043.5}
             }
           ],
           trip_count: 5650
         })}
      )

      assert render(element(view, ".affected-count")) =~ "5650"
      # The row names the group, not a single load.
      assert render(element(view, ".affected-scroll")) =~ "5650 loads"
    end
  end

  describe "cause vocabulary (UIW-7)" do
    # The pin-the-list test: every failure_cause literal the engine can emit
    # must land on a real class. A cause added later without a class here
    # renders neutral rather than invisible, and this test says so out loud.
    test "every emitted failure_cause has a class" do
      causes = emitted_causes()

      assert length(causes) > 15,
             "the grep found #{length(causes)} causes; the engine emits far more"

      events =
        causes
        |> Enum.with_index()
        |> Enum.map(fn {cause, i} ->
          %{component_type: "transmission_line", component_id: i, failure_cause: cause, step: 1}
        end)

      html =
        render_component(AffectedList, id: "affected-list", events: events, total: length(events))

      refute html =~ "cause-unknown",
             "some emitted cause fell through to the neutral fallback: #{inspect(causes)}"
    end

    test "a cause this build has never seen still renders as a row" do
      html =
        render_component(AffectedList,
          id: "affected-list",
          events: [
            %{
              component_type: "quantum_flux_capacitor",
              component_id: 1,
              failure_cause: "tachyon_inversion",
              step: 4
            }
          ],
          total: 1
        )

      assert html =~ "cause-unknown"
      assert html =~ "Tachyon inversion"
    end

    test "the dynamic distance-zone causes are covered for every zone" do
      events =
        for zone <- 1..3 do
          %{
            component_type: "transmission_line",
            component_id: zone,
            failure_cause: "distance_zone#{zone}",
            step: 1
          }
        end

      html = render_component(AffectedList, id: "affected-list", events: events, total: 3)
      refute html =~ "cause-unknown"
    end
  end

  # Every `failure_cause: "..."` literal in the engine, plus the two dynamic
  # distance-relay zones protection.ex builds by interpolation.
  defp emitted_causes do
    "lib/power_model/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      ~r/failure_cause: "([a-z0-9_]+)"/
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, cause] -> cause end)
    end)
    |> Enum.concat(["distance_zone2", "distance_zone3"])
    |> Enum.uniq()
    |> Enum.sort()
  end
end
