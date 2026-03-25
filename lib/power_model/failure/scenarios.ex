defmodule PowerModel.Failure.Scenarios do
  @moduledoc """
  Geographic and weather-based correlated failure scenarios.

  Generates modifications to grid parameters that simulate real-world
  stress events affecting multiple components simultaneously. Each scenario
  function returns a `%Scenario{}` struct describing the changes to apply,
  and `apply_scenario/2` applies those changes to a `%Cascade{}` state.

  ## Scenario types

  - `heat_wave/2` — summer extreme heat (line derating + load increase)
  - `ice_storm/2` — winter ice accumulation (line trips + derating)
  - `wildfire/2`  — fire near transmission corridor (forced line trips)
  - `earthquake/2` — seismic event (substation damage, connected lines trip)

  ## Usage

      scenario = Scenarios.heat_wave(snapshot, north: 42, south: 30, east: -80, west: -100)
      cascade  = Scenarios.apply_scenario(cascade_state, scenario)
  """

  defstruct [
    line_deratings: %{},
    load_multipliers: %{},
    forced_trips: [],
    generator_deratings: %{},
    description: ""
  ]

  @type t :: %__MODULE__{
    line_deratings: %{integer() => float()},
    load_multipliers: %{integer() => float()},
    forced_trips: [integer()],
    generator_deratings: %{integer() => float()},
    description: String.t()
  }

  # ---------------------------------------------------------------------------
  # Coordinate helpers
  # ---------------------------------------------------------------------------

  @doc false
  def bus_coords(bus) do
    case Map.get(bus, :coordinates) do
      %{coordinates: {lon, lat}} when is_number(lon) and is_number(lat) -> {lat, lon}
      _ -> nil
    end
  end

  @doc false
  def in_bbox?({lat, lon}, north, south, east, west) do
    lat >= south and lat <= north and lon >= west and lon <= east
  end

  @doc false
  def haversine_km({lat1, lon1}, {lat2, lon2}) do
    r = 6371.0
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)
    a = :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
        :math.sin(dlon / 2) * :math.sin(dlon / 2)
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  defp deg_to_rad(d), do: d * :math.pi() / 180.0

  # ---------------------------------------------------------------------------
  # Build a bus-coordinate index from the snapshot
  # ---------------------------------------------------------------------------

  defp bus_coord_index(buses) do
    Map.new(buses, fn bus -> {bus.id, bus_coords(bus)} end)
  end

  defp line_bus_ids(lines) do
    Enum.map(lines, fn l -> {l.id, l.from_bus_id, l.to_bus_id} end)
  end

  defp generator_bus_ids(generators) do
    Enum.map(generators, fn g -> {g.id, g.bus_id} end)
  end

  defp load_bus_ids(loads) do
    Enum.map(loads, fn l -> {l.id, l.bus_id} end)
  end

  # Deterministic pseudo-random float in [lo, hi) seeded from an id
  defp det_random(id, lo, hi) do
    h = :erlang.phash2({:scenario, id}, 1_000_000) / 1_000_000
    lo + h * (hi - lo)
  end

  # ---------------------------------------------------------------------------
  # Heat wave
  # ---------------------------------------------------------------------------

  @doc """
  Simulate summer extreme heat in a geographic region.

  All lines in the affected region are derated to 80-90% of their normal
  thermal rating (higher ambient temperature reduces ampacity). All loads
  increase by 10-20% (air conditioning demand surge).

  ## Options

    * `:north, :south, :east, :west` — bounding box (lat/lon). If omitted,
      the scenario applies system-wide.
  """
  @spec heat_wave(map(), keyword()) :: t()
  def heat_wave(snapshot, opts \\ []) do
    north = Keyword.get(opts, :north)
    south = Keyword.get(opts, :south)
    east = Keyword.get(opts, :east)
    west = Keyword.get(opts, :west)

    has_bbox = north != nil and south != nil and east != nil and west != nil

    bus_coords_map = bus_coord_index(snapshot.buses)

    in_region? = fn bus_id ->
      if has_bbox do
        case Map.get(bus_coords_map, bus_id) do
          nil -> true  # no coords => include (conservative)
          coords -> in_bbox?(coords, north, south, east, west)
        end
      else
        true
      end
    end

    # Derate lines whose either endpoint is in the region
    line_deratings =
      line_bus_ids(Map.get(snapshot, :lines, []))
      |> Enum.filter(fn {_id, from_id, to_id} ->
        in_region?.(from_id) or in_region?.(to_id)
      end)
      |> Map.new(fn {id, _from, _to} ->
        {id, det_random(id, 0.80, 0.90)}
      end)

    # Increase loads in the region by 10-20%
    load_multipliers =
      load_bus_ids(Map.get(snapshot, :loads, []))
      |> Enum.filter(fn {_id, bus_id} -> in_region?.(bus_id) end)
      |> Map.new(fn {id, _bus_id} ->
        {id, det_random(id, 1.10, 1.20)}
      end)

    # Thermal generators in hot region derate slightly (cooling water temp)
    gen_deratings =
      generator_bus_ids(Map.get(snapshot, :generators, []))
      |> Enum.filter(fn {_id, bus_id} -> in_region?.(bus_id) end)
      |> Map.new(fn {id, _bus_id} ->
        {id, det_random(id, 0.92, 0.98)}
      end)

    region_desc = if has_bbox,
      do: "region [#{south}-#{north}N, #{west}-#{east}E]",
      else: "system-wide"

    %__MODULE__{
      line_deratings: line_deratings,
      load_multipliers: load_multipliers,
      forced_trips: [],
      generator_deratings: gen_deratings,
      description: "Heat wave: #{map_size(line_deratings)} lines derated, " <>
        "#{map_size(load_multipliers)} loads increased, #{region_desc}"
    }
  end

  # ---------------------------------------------------------------------------
  # Ice storm
  # ---------------------------------------------------------------------------

  @doc """
  Simulate winter ice accumulation in a geographic region.

  A fraction of lines in the affected region trip outright (conductor galloping
  or breakage). Remaining lines are derated to ~90% (ice adds weight and sag).
  Loads increase due to electric heating demand surge (heat pumps, space heaters).

  ## Options

    * `:severity` — 1-5 scale (default 3). Controls trip percentage (5-15%).
    * `:north, :south, :east, :west` — bounding box.
  """
  @spec ice_storm(map(), keyword()) :: t()
  def ice_storm(snapshot, opts \\ []) do
    severity = Keyword.get(opts, :severity, 3) |> max(1) |> min(5)
    north = Keyword.get(opts, :north)
    south = Keyword.get(opts, :south)
    east = Keyword.get(opts, :east)
    west = Keyword.get(opts, :west)

    has_bbox = north != nil and south != nil and east != nil and west != nil
    bus_coords_map = bus_coord_index(snapshot.buses)

    in_region? = fn bus_id ->
      if has_bbox do
        case Map.get(bus_coords_map, bus_id) do
          nil -> true
          coords -> in_bbox?(coords, north, south, east, west)
        end
      else
        true
      end
    end

    # Trip percentage scales linearly from 5% (severity 1) to 15% (severity 5)
    trip_pct = 0.05 + (severity - 1) * 0.025

    affected_lines =
      line_bus_ids(Map.get(snapshot, :lines, []))
      |> Enum.filter(fn {_id, from_id, to_id} ->
        in_region?.(from_id) or in_region?.(to_id)
      end)

    # Deterministic selection of which lines trip
    {tripped, survived} =
      Enum.split_with(affected_lines, fn {id, _from, _to} ->
        det_random(id, 0.0, 1.0) < trip_pct
      end)

    forced_trips = Enum.map(tripped, fn {id, _from, _to} -> id end)

    # Surviving lines derated to 85-95% (worse at higher severity)
    derate_lo = max(0.75, 0.95 - severity * 0.04)
    derate_hi = max(0.80, 1.0 - severity * 0.02)

    line_deratings =
      survived
      |> Map.new(fn {id, _from, _to} -> {id, det_random(id, derate_lo, derate_hi)} end)

    # Loads increase due to electric heating demand (5-15% based on severity)
    load_increase_lo = 0.05 + (severity - 1) * 0.025
    load_increase_hi = load_increase_lo + 0.05
    load_multipliers =
      load_bus_ids(Map.get(snapshot, :loads, []))
      |> Enum.filter(fn {_id, bus_id} -> in_region?.(bus_id) end)
      |> Map.new(fn {id, _bus_id} ->
        {id, 1.0 + det_random(id, load_increase_lo, load_increase_hi)}
      end)

    region_desc = if has_bbox,
      do: "region [#{south}-#{north}N, #{west}-#{east}E]",
      else: "system-wide"

    %__MODULE__{
      line_deratings: line_deratings,
      load_multipliers: load_multipliers,
      forced_trips: forced_trips,
      generator_deratings: %{},
      description: "Ice storm (severity #{severity}): #{length(forced_trips)} lines tripped, " <>
        "#{map_size(line_deratings)} derated, #{region_desc}"
    }
  end

  # ---------------------------------------------------------------------------
  # Wildfire
  # ---------------------------------------------------------------------------

  @doc """
  Simulate a wildfire near a transmission corridor.

  Lines crossing the fire perimeter are de-energized (forced trip) for
  public safety (PSPS protocol). Nearby lines may be derated due to
  smoke reducing cooling efficiency.

  ## Options

    * `:center_lat, :center_lon` — fire center (required)
    * `:radius_km` — fire perimeter radius (default 30 km)
  """
  @spec wildfire(map(), keyword()) :: t()
  def wildfire(snapshot, opts \\ []) do
    center_lat = Keyword.fetch!(opts, :center_lat)
    center_lon = Keyword.fetch!(opts, :center_lon)
    radius_km = Keyword.get(opts, :radius_km, 30.0)
    center = {center_lat, center_lon}

    bus_coords_map = bus_coord_index(snapshot.buses)

    # A line crosses the fire zone if either endpoint is within radius
    lines_with_distance =
      line_bus_ids(Map.get(snapshot, :lines, []))
      |> Enum.map(fn {id, from_id, to_id} ->
        from_coords = Map.get(bus_coords_map, from_id)
        to_coords = Map.get(bus_coords_map, to_id)

        min_dist = min(
          (if from_coords, do: haversine_km(center, from_coords), else: :infinity),
          (if to_coords, do: haversine_km(center, to_coords), else: :infinity)
        )

        {id, min_dist}
      end)

    # Lines within fire radius are tripped
    forced_trips =
      lines_with_distance
      |> Enum.filter(fn {_id, dist} -> dist <= radius_km end)
      |> Enum.map(fn {id, _dist} -> id end)

    # Lines within 2x radius are derated (smoke reduces cooling)
    line_deratings =
      lines_with_distance
      |> Enum.filter(fn {id, dist} -> dist > radius_km and dist <= radius_km * 2.0 and id not in forced_trips end)
      |> Map.new(fn {id, dist} ->
        # Closer to fire => more derate (0.85 at edge of fire, 0.95 at 2x radius)
        frac = (dist - radius_km) / radius_km
        derate = 0.85 + frac * 0.10
        {id, derate}
      end)

    %__MODULE__{
      line_deratings: line_deratings,
      load_multipliers: %{},
      forced_trips: forced_trips,
      generator_deratings: %{},
      description: "Wildfire at (#{center_lat}, #{center_lon}) r=#{radius_km}km: " <>
        "#{length(forced_trips)} lines tripped, #{map_size(line_deratings)} derated"
    }
  end

  # ---------------------------------------------------------------------------
  # Earthquake
  # ---------------------------------------------------------------------------

  @doc """
  Simulate a seismic event.

  Substations near the epicenter lose all connected lines. Damage radius
  scales with earthquake magnitude using a simplified attenuation model.

  ## Options

    * `:epicenter_lat, :epicenter_lon` — epicenter (required)
    * `:magnitude` — Richter magnitude (default 6.0)
  """
  @spec earthquake(map(), keyword()) :: t()
  def earthquake(snapshot, opts \\ []) do
    epicenter_lat = Keyword.fetch!(opts, :epicenter_lat)
    epicenter_lon = Keyword.fetch!(opts, :epicenter_lon)
    magnitude = Keyword.get(opts, :magnitude, 6.0)
    epicenter = {epicenter_lat, epicenter_lon}

    # Damage radius: ~10km at M5, ~50km at M7, ~200km at M8
    # Simplified: radius_km = 10^(0.5 * magnitude - 1.5)
    damage_radius_km = :math.pow(10, 0.5 * magnitude - 1.5)

    # Find buses (representing substations) within damage radius
    damaged_bus_ids =
      snapshot.buses
      |> Enum.filter(fn bus ->
        case bus_coords(bus) do
          nil -> false
          coords -> haversine_km(epicenter, coords) <= damage_radius_km
        end
      end)
      |> MapSet.new(& &1.id)

    # All lines connected to damaged buses are tripped
    forced_trips =
      Map.get(snapshot, :lines, [])
      |> Enum.filter(fn line ->
        MapSet.member?(damaged_bus_ids, line.from_bus_id) or
        MapSet.member?(damaged_bus_ids, line.to_bus_id)
      end)
      |> Enum.map(& &1.id)

    # Generators at damaged buses are derated heavily
    gen_deratings =
      Map.get(snapshot, :generators, [])
      |> Enum.filter(fn g -> MapSet.member?(damaged_bus_ids, g.bus_id) end)
      |> Map.new(fn g -> {g.id, det_random(g.id, 0.0, 0.3)} end)

    %__MODULE__{
      line_deratings: %{},
      load_multipliers: %{},
      forced_trips: forced_trips,
      generator_deratings: gen_deratings,
      description: "Earthquake M#{magnitude} at (#{epicenter_lat}, #{epicenter_lon}): " <>
        "#{MapSet.size(damaged_bus_ids)} buses damaged, #{length(forced_trips)} lines tripped, " <>
        "r=#{Float.round(damage_radius_km, 1)}km"
    }
  end

  # ---------------------------------------------------------------------------
  # Apply scenario to cascade state
  # ---------------------------------------------------------------------------

  @doc """
  Apply a scenario to a cascade state.

  Modifies line ratings (deratings), load power (multipliers), generator
  capacity (deratings), and adds forced trips to `tripped_lines`.

  Returns an updated `%Cascade{}` struct ready for cascade simulation.
  """
  @spec apply_scenario(struct(), t()) :: struct()
  def apply_scenario(cascade_state, %__MODULE__{} = scenario) do
    # Apply line deratings — reduce rating_a_mva
    updated_lines =
      Enum.map(cascade_state.lines, fn line ->
        case Map.get(scenario.line_deratings, line.id) do
          nil -> line
          factor ->
            rating = Map.get(line, :rating_a_mva) || 0.0
            %{line | rating_a_mva: rating * factor}
        end
      end)

    # Apply load multipliers — scale p_mw and q_mvar
    updated_loads =
      Enum.map(cascade_state.loads, fn load ->
        case Map.get(scenario.load_multipliers, load.id) do
          nil -> load
          mult ->
            q = Map.get(load, :q_mvar) || 0.0
            %{load | p_mw: load.p_mw * mult, q_mvar: q * mult}
        end
      end)

    # Apply generator deratings — reduce p_max_mw
    updated_generators =
      Enum.map(cascade_state.generators, fn gen ->
        case Map.get(scenario.generator_deratings, gen.id) do
          nil -> gen
          factor ->
            %{gen | p_max_mw: gen.p_max_mw * factor}
        end
      end)

    # Add forced trips
    new_tripped = Enum.reduce(scenario.forced_trips, cascade_state.tripped_lines, fn line_id, acc ->
      MapSet.put(acc, line_id)
    end)

    %{cascade_state |
      lines: updated_lines,
      loads: updated_loads,
      generators: updated_generators,
      tripped_lines: new_tripped
    }
  end
end
