defmodule PowerModel.Failure.ProtectionTest do
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Protection

  describe "overcurrent_trip_time/2" do
    test "returns infinity at or below pickup" do
      assert Protection.overcurrent_trip_time(99.0) == :infinity
      assert Protection.overcurrent_trip_time(100.0) == :infinity
    end

    test "follows the IEC standard-inverse curve" do
      assert_in_delta Protection.overcurrent_trip_time(110.0), 73.4, 0.734
      assert_in_delta Protection.overcurrent_trip_time(150.0), 17.2, 0.172
      assert_in_delta Protection.overcurrent_trip_time(200.0), 10.0, 0.1
    end

    test "returns a large finite time just above pickup" do
      trip_time = Protection.overcurrent_trip_time(100.0001)

      assert is_float(trip_time)
      assert trip_time > 1_000_000.0
    end

    test "decreases monotonically as loading increases" do
      times = Enum.map([100.0001, 110.0, 150.0, 200.0], &Protection.overcurrent_trip_time/1)

      assert Enum.chunk_every(times, 2, 1, :discard)
             |> Enum.all?(fn [earlier, later] -> earlier > later end)
    end
  end

  describe "zone3_trip_probability/2" do
    test "matches the documented loading and voltage anchors" do
      assert_in_delta Protection.zone3_trip_probability(100.0, 0.8), 0.833, 0.001
      assert Protection.zone3_trip_probability(120.0, 0.75) == 1.0
    end

    test "is zero when neither loading nor voltage contributes" do
      assert Protection.zone3_trip_probability(80.0, 0.9) == 0.0
    end

    test "equals the voltage factor alone at exactly 80 percent loading" do
      expected_voltage_factor = (0.9 - 0.8) / 0.15

      assert_in_delta Protection.zone3_trip_probability(80.0, 0.8),
                      expected_voltage_factor,
                      1.0e-12
    end
  end

  describe "check_zone3_encroachment/6" do
    test "uses flow endpoints when line and transformer IDs collide" do
      line_flows = %{
        {:line, 42} => %{
          from_bus_id: 1,
          to_bus_id: 2,
          p_flow_mw: 100.0,
          loading_pct: 100.0
        },
        {:transformer, 42} => %{
          from_bus_id: 3,
          to_bus_id: 4,
          p_flow_mw: 100.0,
          loading_pct: 100.0
        }
      }

      mixed_components = [
        %{id: 42, from_bus_id: 1, to_bus_id: 2},
        %{id: 42, from_bus_id: 3, to_bus_id: 4}
      ]

      trips =
        Protection.check_zone3_encroachment(
          line_flows,
          mixed_components,
          [],
          [0.8, 0.85, 1.0, 1.0],
          [0.0, 0.0, 0.0, 0.0],
          %{1 => 0, 2 => 1, 3 => 2, 4 => 3}
        )

      assert [trip] = trips
      assert trip.component_type == "transmission_line"
      assert trip.component_id == 42
      assert trip.details.v_from_pu == 0.8
      assert trip.details.v_to_pu == 0.85
      assert trip.details.trip_probability > 0.5
    end
  end

  describe "existing protection behavior" do
    test "retains the canonical UFLS first stage" do
      assert Protection.ufls_schedule(59.0) == [stage: 1, shed_fraction: 0.075]
    end

    test "retains the steady-state frequency estimate" do
      assert_in_delta Protection.estimate_frequency(90.0, 100.0), 59.7, 1.0e-12
    end
  end
end
