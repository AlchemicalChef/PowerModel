defmodule PowerModel.Ingestion.ParameterEstimatorTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.ParameterEstimator

  # 0.1 deg of latitude ~= 11.12 km
  @part_len_km 11.12

  describe "estimate_length/1" do
    test "computes geodesic length for a 2-tuple LineString" do
      line = %Geo.LineString{coordinates: [{-119.0, 35.0}, {-119.0, 35.1}], srid: 4326}

      assert_in_delta ParameterEstimator.estimate_length(line), @part_len_km, 0.1
    end

    test "accepts 3-tuple (Z) coordinates without crashing (LIN-11)" do
      line = %Geo.LineString{
        coordinates: [{-119.0, 35.0, 812.5}, {-119.0, 35.1, 830.0}],
        srid: 4326
      }

      assert_in_delta ParameterEstimator.estimate_length(line), @part_len_km, 0.1
    end

    test "accepts mixed 2- and 3-tuple coordinates" do
      line = %Geo.LineString{
        coordinates: [{-119.0, 35.0}, {-119.0, 35.05, 820.0}, {-119.0, 35.1}],
        srid: 4326
      }

      assert_in_delta ParameterEstimator.estimate_length(line), @part_len_km, 0.1
    end

    test "sums MultiLineString parts without bridging between them (LIN-9)" do
      multi = %Geo.MultiLineString{
        coordinates: [
          [{-119.0, 35.0}, {-119.0, 35.1}],
          # ~180 km away; a bridge segment would dwarf the real length
          [{-117.0, 35.0}, {-117.0, 35.1}]
        ],
        srid: 4326
      }

      assert_in_delta ParameterEstimator.estimate_length(multi), 2 * @part_len_km, 0.3
    end

    test "returns nil for missing or degenerate geometry" do
      assert ParameterEstimator.estimate_length(nil) == nil

      assert ParameterEstimator.estimate_length(%Geo.LineString{coordinates: [{-119.0, 35.0}]}) ==
               nil

      assert ParameterEstimator.estimate_length(%Geo.MultiLineString{coordinates: []}) == nil
    end

    test "floors tiny lengths at 0.1 km" do
      line = %Geo.LineString{
        coordinates: [{-119.0, 35.0}, {-119.0000001, 35.0}],
        srid: 4326
      }

      assert ParameterEstimator.estimate_length(line) == 0.1
    end
  end
end
