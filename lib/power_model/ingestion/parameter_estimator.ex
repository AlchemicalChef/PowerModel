defmodule PowerModel.Ingestion.ParameterEstimator do
  @moduledoc """
  Estimates electrical parameters for transmission lines and generators
  using IEEE/EPRI standard per-unit-length values by voltage class.

  Key features:
  - Uses bus-to-bus haversine distance when line geometry is missing
  - Accounts for parallel circuits (500 kV+ lines often double-circuit)
  - Applies temperature derating to resistance for summer conditions
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{TransmissionLine, Generator, Bus}

  # IEEE/EPRI standard values per voltage class
  # {R (ohm/km), X (ohm/km), B (uS/km), Thermal rating (MVA), typical_circuits}
  # typical_circuits: number of parallel circuits common at this voltage class.
  # NOTE: US EHV (500/765 kV) is overwhelmingly SINGLE-circuit construction --
  # the entire AEP 765 kV network is single circuit. Assuming 2 halves
  # impedance and doubles ratings, systematically understating EHV loading.
  @line_params %{
    69 => {0.170, 0.450, 2.7, 130.0, 1},
    115 => {0.100, 0.420, 2.9, 200.0, 1},
    138 => {0.075, 0.400, 3.0, 250.0, 1},
    161 => {0.060, 0.390, 3.1, 300.0, 1},
    230 => {0.040, 0.370, 3.3, 450.0, 1},
    345 => {0.020, 0.335, 3.6, 900.0, 1},
    500 => {0.010, 0.300, 4.0, 1800.0, 1},
    765 => {0.006, 0.280, 4.5, 3200.0, 1}
  }

  @base_mva 100.0

  # Default ambient temperature for summer derating (Celsius)
  @default_ambient_temp_c 35.0

  # Temperature coefficient of resistance for aluminium conductor (per degree C)
  @alpha_resistance 0.004

  def run do
    estimate_line_parameters()
    estimate_generator_q_limits()
  end

  @doc """
  Estimate per-unit parameters for all transmission lines.

  Options:
  - `:ambient_temp_c` — ambient temperature for resistance derating (default 35 C)
  """
  def estimate_line_parameters(opts \\ []) do
    ambient_temp = Keyword.get(opts, :ambient_temp_c, @default_ambient_temp_c)

    lines =
      from(tl in TransmissionLine,
        where: is_nil(tl.r_pu) or is_nil(tl.x_pu),
        preload: [:from_bus, :to_bus]
      )
      |> Repo.all()

    Enum.each(lines, fn line ->
      voltage_kv = line.voltage_kv || 0.0

      if voltage_kv > 0 do
        {r_per_km, x_per_km, b_per_km, rating, typical_circuits} =
          lookup_line_params(voltage_kv)

        length_km =
          line.length_km ||
            estimate_length(line.geometry) ||
            estimate_length_from_buses(line.from_bus, line.to_bus)

        z_base = voltage_kv * voltage_kv / @base_mva

        # Apply temperature derating to resistance
        # R_actual = R_25C * (1 + alpha * (T_ambient - 25))
        temp_factor = 1.0 + @alpha_resistance * (ambient_temp - 25.0)
        r_per_km_derated = r_per_km * temp_factor

        # Apply parallel circuit factor: impedance halves, rating doubles
        n_circuits = typical_circuits
        r_pu = r_per_km_derated * length_km / (z_base * n_circuits)
        x_pu = x_per_km * length_km / (z_base * n_circuits)
        b_pu = b_per_km * 1.0e-6 * length_km * z_base * n_circuits

        effective_rating = (line.rating_a_mva || rating) * n_circuits

        line
        |> Ecto.Changeset.change(%{
          r_pu: r_pu,
          x_pu: max(x_pu, 0.0001),
          b_pu: b_pu,
          rating_a_mva: effective_rating,
          length_km: length_km
        })
        |> Repo.update()
      end
    end)
  end

  @doc "Estimate reactive power limits for generators"
  def estimate_generator_q_limits do
    generators =
      from(g in Generator,
        where: is_nil(g.q_max_mvar)
      )
      |> Repo.all()

    Enum.each(generators, fn gen ->
      {q_max, q_min} = estimate_q_limits(gen)

      gen
      |> Ecto.Changeset.change(%{q_max_mvar: q_max, q_min_mvar: q_min})
      |> Repo.update()
    end)
  end

  @doc "Look up standard parameters for a voltage level"
  def lookup_line_params(voltage_kv) do
    # Find closest voltage class
    closest =
      @line_params
      |> Map.keys()
      |> Enum.min_by(&abs(&1 - voltage_kv))

    Map.fetch!(@line_params, closest)
  end

  @doc "Convert physical parameters to per-unit"
  def to_per_unit(
        r_ohm_per_km,
        x_ohm_per_km,
        b_us_per_km,
        length_km,
        base_kv,
        base_mva \\ @base_mva
      ) do
    z_base = base_kv * base_kv / base_mva

    %{
      r_pu: r_ohm_per_km * length_km / z_base,
      x_pu: x_ohm_per_km * length_km / z_base,
      b_pu: b_us_per_km * 1.0e-6 * length_km * z_base
    }
  end

  # Private

  defp estimate_q_limits(gen) do
    p_max = gen.p_max_mw

    case categorize_prime_mover(gen.prime_mover) do
      :synchronous ->
        # Synchronous machines: power factor ~0.85 lagging
        q_max = p_max * 0.6
        q_min = -p_max * 0.3
        {q_max, q_min}

      :inverter ->
        # Inverter-based (solar, wind): limited reactive capability
        q_max = p_max * 0.33
        q_min = -p_max * 0.33
        {q_max, q_min}

      :induction ->
        # Induction generators (some wind): consume reactive
        q_max = 0.0
        q_min = -p_max * 0.3
        {q_max, q_min}
    end
  end

  defp categorize_prime_mover(nil), do: :synchronous

  defp categorize_prime_mover(pm) do
    pm_upper = String.upcase(pm)

    cond do
      pm_upper in ~w(PV BA) -> :inverter
      pm_upper in ~w(WT WS) -> :inverter
      pm_upper in ~w(ST GT IC CA CT CS) -> :synchronous
      pm_upper in ~w(HY PS) -> :synchronous
      pm_upper == "IG" -> :induction
      true -> :synchronous
    end
  end

  @doc """
  Estimate geodesic length (km) from line geometry. Returns nil when geometry
  is missing or degenerate so the caller can fall back to bus-to-bus distance.

  Accepts both 2-tuple `{lon, lat}` and 3-tuple `{lon, lat, z}` coordinates
  (Z is dropped). MultiLineString parts are summed independently -- no
  segment is counted between parts.
  """
  def estimate_length(nil), do: nil

  def estimate_length(%Geo.LineString{coordinates: coords}) do
    case part_length_km(coords) do
      nil -> nil
      km -> max(km, 0.1)
    end
  end

  def estimate_length(%Geo.MultiLineString{coordinates: parts}) when is_list(parts) do
    lengths =
      parts
      |> Enum.map(&part_length_km/1)
      |> Enum.reject(&is_nil/1)

    case lengths do
      [] -> nil
      _ -> max(Enum.sum(lengths), 0.1)
    end
  end

  def estimate_length(_), do: nil

  # Length within a single part; nil when fewer than 2 valid points.
  defp part_length_km(coords) when is_list(coords) do
    points =
      coords
      |> Enum.map(fn
        {lon, lat} -> {lon, lat}
        {lon, lat, _z} -> {lon, lat}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case points do
      [_, _ | _] ->
        points
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{lon1, lat1}, {lon2, lat2}] -> haversine_km(lat1, lon1, lat2, lon2) end)
        |> Enum.sum()

      _ ->
        nil
    end
  end

  defp part_length_km(_), do: nil

  # Estimate line length from the coordinates of the from_bus and to_bus.
  # Falls back to a conservative 10.0 km default when coordinates are unavailable.
  defp estimate_length_from_buses(
         %Bus{coordinates: %Geo.Point{coordinates: {lon1, lat1}}},
         %Bus{coordinates: %Geo.Point{coordinates: {lon2, lat2}}}
       ) do
    dist = haversine_km(lat1, lon1, lat2, lon2)
    max(dist, 0.1)
  end

  defp estimate_length_from_buses(
         %{coordinates: %Geo.Point{coordinates: {lon1, lat1}}},
         %{coordinates: %Geo.Point{coordinates: {lon2, lat2}}}
       ) do
    dist = haversine_km(lat1, lon1, lat2, lon2)
    max(dist, 0.1)
  end

  defp estimate_length_from_buses(_, _), do: 10.0

  defp haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    lat1_r = lat1 * :math.pi() / 180.0
    lat2_r = lat2 * :math.pi() / 180.0

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end
end
