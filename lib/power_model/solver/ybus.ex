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

    # Process transmission lines
    triplets =
      Enum.reduce(lines, triplets, fn line, acc ->
        add_line_triplets(acc, line, bus_index_map)
      end)

    # Process transformers
    triplets =
      Enum.reduce(transformers, triplets, fn xfmr, acc ->
        add_transformer_triplets(acc, xfmr, bus_index_map)
      end)

    # Bus shunt devices (capacitor banks, reactors): gs_mw + j*bs_mvar is the
    # power injected at V = 1.0 pu (MATPOWER convention), so the per-unit
    # admittance on the system base lands on the Y-bus diagonal.
    triplets =
      Enum.reduce(buses, triplets, fn bus, acc ->
        add_shunt_triplets(acc, bus, bus_index_map, base_mva)
      end)

    # Consolidate triplets (sum duplicates)
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
    anti_triplets =
      line_triplets(line, ybus.bus_index_map)
      |> Enum.map(fn {r, c, {re, im}} -> {r, c, {-re, -im}} end)

    updated = consolidate_triplets(ybus.triplets ++ anti_triplets, ybus.n)
    %{ybus | triplets: updated}
  end

  def remove_branch(%__MODULE__{} = ybus, %Transformer{} = xfmr) do
    anti_triplets =
      transformer_triplets(xfmr, ybus.bus_index_map)
      |> Enum.map(fn {r, c, {re, im}} -> {r, c, {-re, -im}} end)

    updated = consolidate_triplets(ybus.triplets ++ anti_triplets, ybus.n)
    %{ybus | triplets: updated}
  end

  @doc "Convert to dense Nx matrix (for small systems / testing)"
  def to_dense(%__MODULE__{n: n, triplets: triplets}) do
    real =
      Nx.broadcast(0.0, {n, n})
      |> Nx.to_batched(1)
      |> Enum.map(&Nx.to_flat_list/1)
      |> List.flatten()

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

  # Private

  defp add_line_triplets(triplets, line, bus_index_map) do
    triplets ++ line_triplets(line, bus_index_map)
  end

  defp line_triplets(line, bus_index_map) do
    i = Map.fetch!(bus_index_map, line.from_bus_id)
    j = Map.fetch!(bus_index_map, line.to_bus_id)

    r = line.r_pu || 0.0
    x = effective_reactance(line.x_pu)
    b = line.b_pu || 0.0

    # Series admittance: y_series = 1/(r + jx) = (r - jx) / (r^2 + x^2)
    denom = r * r + x * x
    g_series = r / denom
    b_series = -x / denom

    # Shunt admittance (half on each side)
    b_shunt = b / 2.0

    [
      # Diagonal elements: y_series + j*b_shunt
      {i, i, {g_series, b_series + b_shunt}},
      {j, j, {g_series, b_series + b_shunt}},
      # Off-diagonal: -y_series
      {i, j, {-g_series, -b_series}},
      {j, i, {-g_series, -b_series}}
    ]
  end

  defp add_transformer_triplets(triplets, xfmr, bus_index_map) do
    triplets ++ transformer_triplets(xfmr, bus_index_map)
  end

  # Map.get, not struct access: buses arrive both as plain maps (tests) and
  # as %Bus{} structs (production), and older fixtures lack the shunt keys.
  defp add_shunt_triplets(triplets, bus, bus_index_map, base_mva) do
    gs = Map.get(bus, :gs_mw) || 0.0
    bs = Map.get(bus, :bs_mvar) || 0.0

    if gs == 0.0 and bs == 0.0 do
      triplets
    else
      i = Map.fetch!(bus_index_map, bus.id)
      [{i, i, {gs / base_mva, bs / base_mva}} | triplets]
    end
  end

  defp transformer_triplets(xfmr, bus_index_map) do
    i = Map.fetch!(bus_index_map, xfmr.from_bus_id)
    j = Map.fetch!(bus_index_map, xfmr.to_bus_id)

    r = xfmr.r_pu || 0.0
    x = effective_reactance(xfmr.x_pu)
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

  # Same floor as DCPowerFlow.effective_reactance/1: guards division by zero
  # for zero-impedance branches while preserving the sign of legitimate
  # negative reactances (3-winding transformer star-point branches).
  @x_floor 1.0e-3
  defp effective_reactance(x) when is_number(x) and (x >= @x_floor or x <= -@x_floor), do: x
  defp effective_reactance(x) when is_number(x) and x < 0.0, do: -@x_floor
  defp effective_reactance(_), do: @x_floor

  defp consolidate_triplets(triplets, _n) do
    triplets
    |> Enum.group_by(fn {r, c, _} -> {r, c} end)
    |> Enum.map(fn {{r, c}, entries} ->
      {re_sum, im_sum} =
        Enum.reduce(entries, {0.0, 0.0}, fn {_, _, {re, im}}, {ra, ia} ->
          {ra + re, ia + im}
        end)

      {r, c, {re_sum, im_sum}}
    end)
    |> Enum.reject(fn {_, _, {re, im}} -> abs(re) < 1.0e-15 and abs(im) < 1.0e-15 end)
  end
end
