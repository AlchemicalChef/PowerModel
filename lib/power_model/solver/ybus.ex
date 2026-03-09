defmodule PowerModel.Solver.YBus do
  @moduledoc """
  Builds the bus admittance matrix (Y-bus) from grid topology.
  Supports both dense (Nx) and sparse (NIF) representations.
  """

  alias PowerModel.Grid.{TransmissionLine, Transformer}

  defstruct [:n, :triplets, :bus_index_map, :base_mva]

  @doc """
  Build Y-bus from lists of in-service branches.
  Returns triplets (row, col, value) for sparse construction.
  bus_index_map maps bus_id -> 0-based matrix index.
  """
  def build(buses, lines, transformers, base_mva \\ 100.0) do
    bus_index_map =
      buses
      |> Enum.with_index()
      |> Map.new(fn {bus, idx} -> {bus.id, idx} end)

    n = map_size(bus_index_map)
    triplets = []

    triplets = Enum.reduce(lines, triplets, fn line, acc ->
      add_line_triplets(acc, line, bus_index_map)
    end)

    triplets = Enum.reduce(transformers, triplets, fn xfmr, acc ->
      add_transformer_triplets(acc, xfmr, bus_index_map)
    end)

    consolidated = consolidate_triplets(triplets, n)

    %__MODULE__{
      n: n,
      triplets: consolidated,
      bus_index_map: bus_index_map,
      base_mva: base_mva
    }
  end

  @doc "Remove a branch and return updated triplets (for cascade simulation)"
  def remove_branch(%__MODULE__{} = ybus, %TransmissionLine{} = line) do
    anti_triplets = line_triplets(line, ybus.bus_index_map)
    |> Enum.map(fn {r, c, {re, im}} -> {r, c, {-re, -im}} end)

    updated = consolidate_triplets(ybus.triplets ++ anti_triplets, ybus.n)
    %{ybus | triplets: updated}
  end

  def remove_branch(%__MODULE__{} = ybus, %Transformer{} = xfmr) do
    anti_triplets = transformer_triplets(xfmr, ybus.bus_index_map)
    |> Enum.map(fn {r, c, {re, im}} -> {r, c, {-re, -im}} end)

    updated = consolidate_triplets(ybus.triplets ++ anti_triplets, ybus.n)
    %{ybus | triplets: updated}
  end

  @doc "Convert to dense Nx matrix (for small systems / testing)"
  def to_dense(%__MODULE__{n: n, triplets: triplets}) do
    real = Nx.broadcast(0.0, {n, n}) |> Nx.to_batched(1) |> Enum.map(&Nx.to_flat_list/1) |> List.flatten()
    imag = List.duplicate(0.0, n * n)

    {real_list, imag_list} =
      Enum.reduce(triplets, {real, imag}, fn {r, c, {re, im}}, {rl, il} ->
        idx = r * n + c
        {List.update_at(rl, idx, &(&1 + re)), List.update_at(il, idx, &(&1 + im))}
      end)

    {Nx.tensor(real_list, type: :f64) |> Nx.reshape({n, n}),
     Nx.tensor(imag_list, type: :f64) |> Nx.reshape({n, n})}
  end

  @doc "Extract real/imaginary triplets for sparse NIF"
  def to_sparse_triplets(%__MODULE__{triplets: triplets, n: n}) do
    rows = Enum.map(triplets, &elem(&1, 0))
    cols = Enum.map(triplets, &elem(&1, 1))
    {reals, imags} = Enum.unzip(Enum.map(triplets, &elem(&1, 2)))
    %{rows: rows, cols: cols, reals: reals, imags: imags, n: n}
  end

  defp add_line_triplets(triplets, line, bus_index_map) do
    triplets ++ line_triplets(line, bus_index_map)
  end

  defp line_triplets(line, bus_index_map) do
    i = Map.fetch!(bus_index_map, line.from_bus_id)
    j = Map.fetch!(bus_index_map, line.to_bus_id)

    r = line.r_pu || 0.0
    x = line.x_pu || 0.001
    b = line.b_pu || 0.0

    denom = r * r + x * x
    g_series = r / denom
    b_series = -x / denom

    b_shunt = b / 2.0

    [
      {i, i, {g_series, b_series + b_shunt}},
      {j, j, {g_series, b_series + b_shunt}},
      {i, j, {-g_series, -b_series}},
      {j, i, {-g_series, -b_series}}
    ]
  end

  defp add_transformer_triplets(triplets, xfmr, bus_index_map) do
    triplets ++ transformer_triplets(xfmr, bus_index_map)
  end

  defp transformer_triplets(xfmr, bus_index_map) do
    i = Map.fetch!(bus_index_map, xfmr.from_bus_id)
    j = Map.fetch!(bus_index_map, xfmr.to_bus_id)

    r = xfmr.r_pu || 0.0
    x = xfmr.x_pu
    t = xfmr.tap_ratio || 1.0

    denom = r * r + x * x
    g = r / denom
    b = -x / denom

    [
      {i, i, {g / (t * t), b / (t * t)}},
      {j, j, {g, b}},
      {i, j, {-g / t, -b / t}},
      {j, i, {-g / t, -b / t}}
    ]
  end

  defp consolidate_triplets(triplets, _n) do
    triplets
    |> Enum.group_by(fn {r, c, _} -> {r, c} end)
    |> Enum.map(fn {{r, c}, entries} ->
      {re_sum, im_sum} = Enum.reduce(entries, {0.0, 0.0}, fn {_, _, {re, im}}, {ra, ia} ->
        {ra + re, ia + im}
      end)
      {r, c, {re_sum, im_sum}}
    end)
    |> Enum.reject(fn {_, _, {re, im}} -> abs(re) < 1.0e-15 and abs(im) < 1.0e-15 end)
  end
end
