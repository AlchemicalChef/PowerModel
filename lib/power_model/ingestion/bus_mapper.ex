defmodule PowerModel.Ingestion.BusMapper do
  @moduledoc """
  Maps generators, transmission lines to buses via substations.

  Strategy:
  1. One bus per substation per voltage level
  2. Map generators to nearest substation bus (10km radius)
  3. Map transmission line endpoints via HIFLD SUB_1/SUB_2 + fallback to nearest
  4. Create transformers between voltage-level buses at multi-voltage substations
  """

  import Ecto.Query
  require Logger
  alias PowerModel.Repo

  alias PowerModel.Grid.{
    Bus,
    BalancingAuthority,
    Generator,
    TransmissionLine,
    Substation,
    Transformer
  }

  @gen_match_radius_m 10_000
  @line_match_radius_m 5_000

  # Balancing authorities in the Western Interconnection. A bus whose BA is in
  # this set belongs to Western no matter where its geographic fallback box
  # placed it. ERCO is the sole ERCOT balancing authority; every other BA is
  # Eastern (SPP, MISO, PJM, SERC, ...). Consumed by
  # reconcile_interconnections_from_ba/0.
  @wecc_ba_codes ~w(
    AVA AZPS BANC BPAT CHPD CISO DEAA DOPD EPE GCPD GRID GRIF GWA HGMA IID
    IPCO LDWP NEVP NWMT PACE PACW PGE PNM PSCO PSEI SCL SRP TEPC TIDC TPWR
    WACM WALC WAUW WWA
  )

  def run do
    create_substation_buses()
    map_generators_to_buses()
    map_transmission_line_buses()
    create_substation_transformers()
  end

  defp create_substation_buses do
    substations = Repo.all(Substation)

    Enum.each(substations, fn sub ->
      voltage_levels = determine_voltage_levels(sub)

      Enum.each(voltage_levels, fn kv ->
        attrs = %{
          bus_type: 1,
          base_kv: kv,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: sub.coordinates,
          source: "substation",
          # LIN-10: one-decimal kv keeps distinct near-integer levels
          # (138.0 vs 138.4) from colliding into one source_id the way
          # round/1 did.
          source_id: "#{sub.id}_#{format_kv(kv)}kV",
          interconnection_id: determine_interconnection(sub.coordinates)
        }

        %Bus{}
        |> Bus.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :source_id])
      end)
    end)
  end

  defp determine_voltage_levels(sub) do
    levels = []
    levels = if sub.max_voltage_kv, do: [sub.max_voltage_kv | levels], else: levels

    levels =
      if sub.min_voltage_kv && sub.min_voltage_kv != sub.max_voltage_kv do
        [sub.min_voltage_kv | levels]
      else
        levels
      end

    case levels do
      [] -> [138.0]
      l -> l
    end
  end

  defp map_generators_to_buses do
    generators =
      from(g in Generator, where: is_nil(g.bus_id) and not is_nil(g.coordinates))
      |> Repo.all()

    Enum.each(generators, fn gen ->
      nearest_bus = find_nearest_bus(gen.coordinates, @gen_match_radius_m)

      if nearest_bus do
        gen
        |> Ecto.Changeset.change(%{bus_id: nearest_bus.id})
        |> Repo.update()
      else
        # Create synthetic bus at generator location
        {:ok, bus} =
          %Bus{}
          |> Bus.changeset(%{
            bus_type: 2,
            base_kv: 13.8,
            coordinates: gen.coordinates,
            source: "synthetic",
            source_id: "gen_#{gen.id}"
          })
          |> Repo.insert()

        gen
        |> Ecto.Changeset.change(%{bus_id: bus.id})
        |> Repo.update()
      end
    end)
  end

  defp map_transmission_line_buses do
    lines =
      from(tl in TransmissionLine,
        where: is_nil(tl.from_bus_id) or is_nil(tl.to_bus_id)
      )
      |> Repo.all()

    Enum.each(lines, fn line ->
      from_point = get_line_endpoint(line.geometry, :from)
      to_point = get_line_endpoint(line.geometry, :to)

      from_bus = find_nearest_bus_at_voltage(from_point, line.voltage_kv, @line_match_radius_m)
      to_bus = find_nearest_bus_at_voltage(to_point, line.voltage_kv, @line_match_radius_m)

      resolved_from = if from_bus, do: from_bus.id, else: line.from_bus_id
      resolved_to = if to_bus, do: to_bus.id, else: line.to_bus_id

      if not is_nil(resolved_from) and resolved_from == resolved_to do
        # Both endpoints snapped to the same bus: mapping this would create a
        # self-loop, which is electrically meaningless. Leave the line
        # unmapped/flagged so the cleanup pass can retry with a wider radius.
        Logger.warning(
          "BusMapper: skipping self-loop on transmission line #{line.id} " <>
            "(both endpoints snapped to bus #{resolved_from})"
        )
      else
        changes = %{}
        changes = if from_bus, do: Map.put(changes, :from_bus_id, from_bus.id), else: changes
        changes = if to_bus, do: Map.put(changes, :to_bus_id, to_bus.id), else: changes

        if map_size(changes) > 0 do
          line
          |> Ecto.Changeset.change(changes)
          |> Repo.update()
        end
      end
    end)
  end

  defp create_substation_transformers do
    # Find substations with multiple voltage-level buses
    buses_by_source =
      from(b in Bus,
        where: b.source == "substation",
        select: b
      )
      |> Repo.all()
      |> Enum.group_by(fn b ->
        # Group by substation (extract sub id from source_id)
        b.source_id |> String.split("_") |> List.first()
      end)

    Enum.each(buses_by_source, fn {_sub_id, buses} ->
      if length(buses) >= 2 do
        sorted = Enum.sort_by(buses, & &1.base_kv, :desc)
        # Create transformer between each adjacent voltage pair
        sorted
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [high, low] ->
          rated_mva = estimate_transformer_rating(high.base_kv)

          # LIN-3: a typical bank has ~10% reactance / 0.3% resistance on its
          # OWN MVA base. Stored impedances are on the 100 MVA system base, so
          # rebase by 100/rated_mva — otherwise a 1000 MVA bank is 10x too
          # impedant and sits at its steady-state stability limit at nameplate.
          %Transformer{}
          |> Transformer.changeset(%{
            from_bus_id: high.id,
            to_bus_id: low.id,
            rated_mva: rated_mva,
            r_pu: 0.003 * (100.0 / rated_mva),
            x_pu: 0.1 * (100.0 / rated_mva),
            tap_ratio: 1.0
          })
          # LIN-4/DAT-1: real conflict target so map_buses re-runs cannot
          # duplicate a bank between the same two buses (unique index on
          # (from_bus_id, to_bus_id)).
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:from_bus_id, :to_bus_id])
        end)
      end
    end)
  end

  defp find_nearest_bus(point, radius_m) do
    from(b in Bus,
      where:
        fragment("ST_DWithin(?::geography, ?::geography, ?)", b.coordinates, ^point, ^radius_m),
      order_by: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
  end

  defp find_nearest_bus_at_voltage(nil, _kv, _radius), do: nil

  defp find_nearest_bus_at_voltage(point, voltage_kv, radius_m) do
    tolerance = voltage_kv * 0.1

    from(b in Bus,
      where:
        fragment("ST_DWithin(?::geography, ?::geography, ?)", b.coordinates, ^point, ^radius_m) and
          b.base_kv >= ^(voltage_kv - tolerance) and
          b.base_kv <= ^(voltage_kv + tolerance),
      order_by: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
      limit: 1
    )
    |> Repo.one()
  end

  defp get_line_endpoint(%Geo.LineString{coordinates: coords}, :from) do
    case List.first(coords) do
      {lon, lat} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      {lon, lat, _} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      _ -> nil
    end
  end

  defp get_line_endpoint(%Geo.LineString{coordinates: coords}, :to) do
    case List.last(coords) do
      {lon, lat} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      {lon, lat, _} -> %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      _ -> nil
    end
  end

  defp get_line_endpoint(_, _), do: nil

  defp determine_interconnection(nil), do: nil

  defp determine_interconnection(%Geo.Point{coordinates: {lon, lat}}) do
    get_or_create_interconnection(interconnection_from_box(lon, lat))
  end

  defp determine_interconnection(_), do: nil

  @doc """
  Coarse geographic interconnection guess from a coordinate. This is only a
  FALLBACK for buses that never receive a balancing-authority assignment;
  `reconcile_interconnections_from_ba/0` overrides it wherever a BA is known.

  The ERCOT box is deliberately conservative so it does not swallow
  Eastern-interconnection territory that sits inside the geographic footprint
  of Texas: deep East Texas (Entergy/MISO, lon > -94.0), the Texas Panhandle
  (SPP, lat > 35.0 west of -100.5), and El Paso (Western, lon < -104.0).
  """
  def interconnection_from_box(lon, lat) do
    cond do
      # El Paso and everything west of the Texas grid is Western.
      lon < -104.0 ->
        "Western"

      # ERCOT: the Texas grid, minus the Eastern/Western pockets noted above.
      lat >= 25.8 and lat <= 36.5 and lon >= -104.0 and lon <= -94.0 and
          not (lat > 35.0 and lon < -100.5) ->
        "ERCOT"

      # Everything else in CONUS is Eastern.
      true ->
        "Eastern"
    end
  end

  @doc """
  Map a balancing-authority code to its interconnection name: ERCO -> ERCOT,
  the WECC balancing authorities -> Western, every other BA -> Eastern (SPP,
  MISO, PJM, SERC, ...).
  """
  def interconnection_for_ba_code(code) do
    normalized = code |> to_string() |> String.trim() |> String.upcase()

    cond do
      normalized == "ERCO" -> "ERCOT"
      normalized in @wecc_ba_codes -> "Western"
      true -> "Eastern"
    end
  end

  @doc """
  Reassign each bus's interconnection from its balancing authority.

  Interconnection is first set from a coarse geographic box when the bus is
  created (before any BA is known). A bus's BA is a far more reliable signal of
  which asynchronous system the bus belongs to, so once BA assignment has run
  this pass overrides the box result for every bus that has a BA. Buses without
  a BA keep their box-derived interconnection.

  Returns the number of buses whose interconnection actually changed.
  """
  def reconcile_interconnections_from_ba do
    ic_ids = %{
      "ERCOT" => get_or_create_interconnection("ERCOT"),
      "Western" => get_or_create_interconnection("Western"),
      "Eastern" => get_or_create_interconnection("Eastern")
    }

    ba_ids_by_interconnection =
      from(ba in BalancingAuthority, select: {ba.id, ba.code})
      |> Repo.all()
      |> Enum.group_by(
        fn {_id, code} -> interconnection_for_ba_code(code) end,
        fn {id, _code} -> id end
      )

    Enum.reduce(ba_ids_by_interconnection, 0, fn {ic_name, ba_ids}, changed ->
      ic_id = Map.fetch!(ic_ids, ic_name)

      {n, _} =
        from(b in Bus,
          where:
            b.balancing_authority_id in ^ba_ids and
              fragment("? IS DISTINCT FROM ?", b.interconnection_id, ^ic_id)
        )
        |> Repo.update_all(set: [interconnection_id: ic_id])

      changed + n
    end)
  end

  defp get_or_create_interconnection(name) do
    alias PowerModel.Grid.Interconnection

    case Repo.get_by(Interconnection, name: name) do
      %{id: id} ->
        id

      nil ->
        {:ok, ic} =
          %Interconnection{}
          |> Interconnection.changeset(%{name: name})
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

        # on_conflict: :nothing may return nil id, so re-fetch
        case ic.id do
          nil -> Repo.get_by!(Interconnection, name: name).id
          id -> id
        end
    end
  end

  # One-decimal kv string for bus source_ids ("138.0", "138.4"). See LIN-10.
  defp format_kv(kv), do: :erlang.float_to_binary(kv * 1.0, decimals: 1)

  defp estimate_transformer_rating(high_kv) do
    cond do
      high_kv >= 500 -> 1000.0
      high_kv >= 345 -> 600.0
      high_kv >= 230 -> 400.0
      high_kv >= 138 -> 200.0
      true -> 100.0
    end
  end
end
