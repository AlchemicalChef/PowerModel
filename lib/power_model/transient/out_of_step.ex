defmodule PowerModel.Transient.OutOfStep do
  @moduledoc """
  Out-of-step (pole slip) detection for transient stability.

  A generator is considered out of step when its rotor angle deviates
  more than pi radians from the Center of Inertia (COI) angle.
  """

  @oos_threshold :math.pi()

  @doc """
  Check for out-of-step generators.

  Returns a list of generator indices that have slipped a pole
  (|delta_i - delta_COI| > pi).
  """
  def detect(delta, h, n_gen) do
    delta_coi = center_of_inertia(delta, h, n_gen)

    for i <- 0..(n_gen - 1),
        abs(Enum.at(delta, i) - delta_coi) > @oos_threshold,
        do: i
  end

  @doc """
  Compute the Center of Inertia angle.

      delta_COI = sum(H_i * delta_i) / sum(H_i)
  """
  def center_of_inertia(delta, h, n_gen) do
    {weighted_sum, total_h} =
      Enum.reduce(0..(n_gen - 1), {0.0, 0.0}, fn i, {ws, th} ->
        hi = Enum.at(h, i)
        di = Enum.at(delta, i)
        {ws + hi * di, th + hi}
      end)

    if total_h > 0.0, do: weighted_sum / total_h, else: 0.0
  end
end
