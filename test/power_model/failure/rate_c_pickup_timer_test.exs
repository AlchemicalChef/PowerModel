defmodule PowerModel.Failure.RateCPickupTimerTest do
  @moduledoc """
  ROADMAP item 9, end-to-end: the inverse-time overcurrent timer arms at the
  short-time emergency rating (rate C), not at 100% of the normal rating.

  `PowerModel.Failure.EmergencyRatingProtectionTest` covers the pickup basis
  in isolation; this drives a real cascade so the arming decision is observed
  where it matters — in the trips a contingency actually produces.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Cascade

  # Two buses joined by two identical parallel lines. In the base case each
  # line carries half the load; tripping one puts all of it on the survivor,
  # so `total_mw` IS the survivor's post-contingency loading in percent when
  # the rating is 100 MVA.
  defp two_parallel_lines(total_mw) do
    line = fn id ->
      %{
        id: id,
        from_bus_id: 1,
        to_bus_id: 2,
        voltage_kv: 345.0,
        r_pu: 0.0,
        x_pu: 0.1,
        b_pu: 0.0,
        rating_a_mva: 100.0
      }
    end

    %{
      buses: [
        %{id: 1, bus_type: 3, base_kv: 345.0},
        %{id: 2, bus_type: 1, base_kv: 345.0}
      ],
      lines: [line.(1), line.(2)],
      transformers: [],
      generators: [
        %{
          id: 1,
          bus_id: 1,
          p_max_mw: total_mw,
          capacity_factor: 1.0,
          q_max_mvar: 500.0,
          q_min_mvar: -500.0
        }
      ],
      loads: [%{id: 1, bus_id: 2, p_mw: total_mw, q_mvar: 0.0}]
    }
  end

  defp thermal_trips(step_results) do
    step_results
    |> Enum.flat_map(& &1.trips)
    |> Enum.filter(&(&1.failure_cause == "thermal_overload"))
  end

  test "105% of rate A does NOT arm the timer" do
    # 105% of rate A is 77.8% of rate C. Under the old rule this branch began
    # timing out immediately; a line a few percent over its continuous rating
    # is a redispatch problem, not a breaker operation.
    state = Cascade.init(two_parallel_lines(105.0), 100.0)
    {_state, step_results} = Cascade.trip_line(state, 1)

    assert thermal_trips(step_results) == []
  end

  test "140% of rate A arms the timer and trips the branch" do
    # 140% of rate A is 103.7% of rate C — past pickup, so the inverse-time
    # curve starts integrating and the branch eventually operates.
    state = Cascade.init(two_parallel_lines(140.0), 100.0)
    {final, step_results} = Cascade.trip_line(state, 1)

    trips = thermal_trips(step_results)

    assert [trip | _] = trips
    assert trip.component_id == 2
    assert trip.component_type == "transmission_line"
    assert MapSet.member?(final.tripped_lines, 2)
  end

  test "the tripped branch reports both bases: rate A for display, rate C for the relay" do
    state = Cascade.init(two_parallel_lines(140.0), 100.0)
    {_final, step_results} = Cascade.trip_line(state, 1)

    assert [trip | _] = thermal_trips(step_results)

    # The operator-facing number stays against the normal rating...
    assert_in_delta trip.details.loading_pct, 140.0, 0.5
    # ...while the relay integrated against the short-time emergency rating.
    assert_in_delta trip.details.trip_loading_pct, 140.0 / 1.35, 0.5
    assert trip.details.trip_loading_pct > 100.0
  end

  test "neither branch is in the trip-immune set: the base case is well under pickup" do
    # Both lines sit at 70% of rate A (51.9% of rate C) before the trip, so
    # nothing is masked and the contingency is free to cascade.
    state = Cascade.init(two_parallel_lines(140.0), 100.0)

    assert MapSet.size(state.base_overloaded) == 0
  end
end
