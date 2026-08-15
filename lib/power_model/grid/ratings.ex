defmodule PowerModel.Grid.Ratings do
  @moduledoc """
  Thermal rating tiers for branches, and the loading percentages taken against
  them.

  A branch has three ratings, in increasing order:

    * **rate A** — normal/continuous. What the branch may carry indefinitely.
      This is the display basis and the "stressed" alarm basis.
    * **rate B** — long-term (≈4 hour) emergency. The post-contingency
      planning basis: flow above rate A is acceptable for as long as it takes
      an operator to redispatch, but flow above rate B is not.
    * **rate C** — short-time (≈15 minute) emergency. The basis a protective
      relay actually picks up on.

  The distinction matters because protection was previously armed at 100% of
  rate A, so any branch a hair over its *continuous* rating started an
  inverse-time relay timer. Real relays are set above the short-time emergency
  limit; a branch sitting at 105% of rate A is a dispatch problem, not a
  breaker operation.

  Lines carry measured B and C in `rating_b_mva`/`rating_c_mva`. Transformers
  have only `rated_mva`, and lines predating the emergency-rating columns have
  NULLs, so both fall back to the factors below.
  """

  # Ratios of rate B and rate C to rate A. Conservative middle-of-the-road
  # values: utility practice runs roughly 1.1-1.2 for the 4-hour rating and
  # 1.3-1.5 for the short-time rating, varying by conductor and season.
  @rate_b_factor 1.15
  @rate_c_factor 1.35

  @doc "Ratio of the long-term (4-hour) emergency rating to the normal rating."
  def rate_b_factor, do: @rate_b_factor

  @doc "Ratio of the short-time (15-minute) emergency rating to the normal rating."
  def rate_c_factor, do: @rate_c_factor

  @doc "Long-term emergency rating derived from a normal rating."
  def rate_b_from_a(rate_a) when is_number(rate_a) and rate_a > 0,
    do: rate_a * @rate_b_factor

  def rate_b_from_a(_), do: nil

  @doc "Short-time emergency rating derived from a normal rating."
  def rate_c_from_a(rate_a) when is_number(rate_a) and rate_a > 0,
    do: rate_a * @rate_c_factor

  def rate_c_from_a(_), do: nil

  @doc """
  Resolve `{rate_a, rate_b, rate_c}` for a branch.

  Accepts a transmission line (`rating_a_mva` plus optional stored
  `rating_b_mva`/`rating_c_mva`) or a transformer (`rated_mva` only). Stored
  emergency ratings win; anything missing is derived from rate A. An unrated
  branch yields `{nil, nil, nil}` — callers report 0% loading for it rather
  than dividing by zero.
  """
  def branch_ratings(branch) do
    rate_a = positive(Map.get(branch, :rating_a_mva)) || positive(Map.get(branch, :rated_mva))
    rate_b = positive(Map.get(branch, :rating_b_mva)) || rate_b_from_a(rate_a)
    rate_c = positive(Map.get(branch, :rating_c_mva)) || rate_c_from_a(rate_a)

    {rate_a, rate_b, rate_c}
  end

  @doc """
  Loading of `flow_mva` against `rating`, in percent.

  An unrated branch reports 0.0 rather than infinity, matching the existing
  solver convention: a branch nothing knows the rating of never registers as
  overloaded.
  """
  def loading_pct(flow_mva, rating) when is_number(rating) and rating > 0,
    do: abs(flow_mva) / rating * 100.0

  def loading_pct(_flow_mva, _rating), do: 0.0

  defp positive(value) when is_number(value) and value > 0, do: value * 1.0
  defp positive(_), do: nil
end
