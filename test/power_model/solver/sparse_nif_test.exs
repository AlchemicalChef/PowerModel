defmodule PowerModel.Solver.SparseNifTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.Sparse

  @tolerance 1.0e-9

  test "preserves earlier L multipliers when partial pivoting swaps a later row" do
    matrix = [
      [2.0, 4.0, 1.0],
      [4.0, 8.0, 3.0],
      [1.0, 3.0, 2.0]
    ]

    rhs = [1.0, 2.0, 3.0]
    solution = solve!(matrix, rhs)

    assert_vector_close(solution, [-4.5, 2.5, 0.0])
    assert_vector_close(residual(matrix, solution, rhs), [0.0, 0.0, 0.0])
  end

  test "still solves a system that does not require row swaps" do
    matrix = [
      [4.0, 1.0, 2.0],
      [1.0, 5.0, 1.0],
      [2.0, 1.0, 6.0]
    ]

    rhs = [8.0, -6.0, 18.0]
    solution = solve!(matrix, rhs)

    assert_vector_close(solution, [1.0, -2.0, 3.0])
    assert_vector_close(residual(matrix, solution, rhs), [0.0, 0.0, 0.0])
  end

  test "rejects singular systems during factorization or solve" do
    result =
      case Sparse.lu_factorize([[1.0, 1.0], [1.0, 1.0]], 2) do
        {:ok, l, u, perm} -> Sparse.lu_solve(l, u, perm, [1.0, 2.0])
        error -> error
      end

    refute match?({:ok, _solution}, result)
    assert result == {:error, :singular_matrix}

    l = [[1.0, 0.0], [0.0, 1.0]]
    singular_u = [[1.0, 1.0], [0.0, 0.0]]

    assert {:error, :singular_matrix} =
             Sparse.lu_solve(l, singular_u, [0, 1], [1.0, 2.0])
  end

  defp solve!(matrix, rhs) do
    assert {:ok, l, u, perm} = Sparse.lu_factorize(matrix, length(matrix))
    assert {:ok, solution} = Sparse.lu_solve(l, u, perm, rhs)
    solution
  end

  defp residual(matrix, solution, rhs) do
    matrix
    |> Enum.zip(rhs)
    |> Enum.map(fn {row, expected} ->
      actual =
        row
        |> Enum.zip(solution)
        |> Enum.reduce(0.0, fn {coefficient, value}, sum ->
          sum + coefficient * value
        end)

      actual - expected
    end)
  end

  defp assert_vector_close(actual, expected) do
    assert length(actual) == length(expected)

    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {actual_value, expected_value} ->
      assert_in_delta actual_value, expected_value, @tolerance
    end)
  end
end
