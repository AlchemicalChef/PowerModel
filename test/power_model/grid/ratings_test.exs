defmodule PowerModel.Grid.RatingsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Grid.Ratings

  describe "branch_ratings/1" do
    test "a line's stored emergency ratings win over the derived ones" do
      line = %{rating_a_mva: 100.0, rating_b_mva: 130.0, rating_c_mva: 175.0}

      assert {100.0, 130.0, 175.0} = Ratings.branch_ratings(line)
    end

    test "a line with no stored emergency ratings derives them from rate A" do
      {a, b, c} = Ratings.branch_ratings(%{rating_a_mva: 200.0})

      assert a == 200.0
      assert_in_delta b, 200.0 * Ratings.rate_b_factor(), 1.0e-9
      assert_in_delta c, 200.0 * Ratings.rate_c_factor(), 1.0e-9
    end

    test "a transformer rates off rated_mva" do
      {a, b, c} = Ratings.branch_ratings(%{rated_mva: 400.0})

      assert a == 400.0
      assert_in_delta b, 400.0 * Ratings.rate_b_factor(), 1.0e-9
      assert_in_delta c, 400.0 * Ratings.rate_c_factor(), 1.0e-9
    end

    test "an unrated branch yields no ratings rather than zeros" do
      assert {nil, nil, nil} = Ratings.branch_ratings(%{rating_a_mva: nil})
      assert {nil, nil, nil} = Ratings.branch_ratings(%{rating_a_mva: 0.0})
      assert {nil, nil, nil} = Ratings.branch_ratings(%{})
    end

    test "the emergency tiers are ordered above the normal rating" do
      assert Ratings.rate_b_factor() > 1.0
      assert Ratings.rate_c_factor() > Ratings.rate_b_factor()
    end
  end

  describe "loading_pct/2" do
    test "reports flow against the rating in percent, ignoring direction" do
      assert_in_delta Ratings.loading_pct(50.0, 100.0), 50.0, 1.0e-9
      assert_in_delta Ratings.loading_pct(-150.0, 100.0), 150.0, 1.0e-9
    end

    test "an unrated branch reports zero rather than dividing by zero" do
      assert Ratings.loading_pct(500.0, nil) == 0.0
      assert Ratings.loading_pct(500.0, 0.0) == 0.0
    end
  end
end
