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

  # Prepend the (constant-size) branch entries: appending to the accumulator
  # copies it per branch, which is O(branches^2) — hours at Eastern's 64,664.
  # consolidate_triplets/2 group-sums by position, so order is irrelevant.
  defp add_line_triplets(triplets, line, bus_index_map) do
    line_triplets(line, bus_index_map) ++ triplets
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
    transformer_triplets(xfmr, bus_index_map) ++ triplets
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
    t = effective_tap_ratio(xfmr.tap_ratio)

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

  # Shared with the DC and AC flow-reporting paths: guards division by zero
  # for zero-impedance branches while preserving the sign of legitimate
  # negative reactances (3-winding transformer star-point branches).
  #
  # 1.0e-5 pu, not the 1.0e-3 this used to be. At 1.0e-3 the floor stopped
  # being a division guard and became a modeling change: it inflated the
  # reactance of 15,941 in-service lines (17% of the network), MEASURED at up
  # to 177 MW of per-branch DC flow error and enough to flip 16 branches'
  # overload flag at 115-230 kV. The invariance probe is the proof — DC flow
  # distribution is invariant under uniform scaling of every x, so solving the
  # same operating point with all reactances x1000 (lifting them clear of the
  # floor) and differencing the flows isolates the floor's error exactly.
  #
  # The smallest reactance any real branch carries is 2.5e-5 pu, so 1.0e-5
  # floors nothing physical while still keeping 1/x finite for a genuinely
  # zero-impedance branch. `Ingestion.ParameterEstimator` clamps at the same
  # value when it WRITES x: a larger write-time clamp silently becomes the
  # binding floor no matter what this one says.
  @x_floor 1.0e-5
  @doc false
  def effective_reactance(x) when is_number(x) and (x >= @x_floor or x <= -@x_floor), do: x
  def effective_reactance(x) when is_number(x) and x < 0.0, do: -@x_floor
  def effective_reactance(_), do: @x_floor

  @doc """
  The reactance magnitude below which `effective_reactance/1` substitutes a
  floor. Exposed so the ingestion write-time clamp can be asserted equal to it.
  """
  def x_floor, do: @x_floor

  defp effective_tap_ratio(t) when is_number(t) and t > 0.0, do: t
  defp effective_tap_ratio(_), do: 1.0

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
