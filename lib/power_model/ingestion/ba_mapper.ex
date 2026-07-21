defmodule PowerModel.Ingestion.BAMapper do
  @moduledoc """
  Populates `balancing_authorities` from the eGRID PLNT sheet and assigns every
  bus to a balancing authority.

  BA boundary geometries are not available in the database, so assignment is
  two-stage:

  1. **Plant vote** — buses hosting generators take the majority BA of their
     generators' plants (ORISPL -> BACODE from the eGRID PLNT sheet).
  2. **Nearest neighbor** — remaining buses with coordinates take the BA of
     the nearest already-assigned bus within the same interconnection.

  Buses without coordinates stay unassigned and are simply never scaled by
  the EIA-930 demand profiles (they keep their baseline load).
  """

  NimbleCSV.define(EGridPLNTParser, separator: ",", escape: "\"")

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{BalancingAuthority, Bus, Generator}
  alias PowerModel.Ingestion.BusMapper
  alias PowerModel.Ingestion.EPA.EGrid

  @doc """
  Full pipeline: ingest BAs from eGRID, then assign all buses.
  `path` is a directory containing an `egrid*.xlsx` file, or the file itself.
  """
  def run(path \\ "data") do
    case plant_ba_map(path) do
      {:ok, plant_bas} ->
        code_to_id = upsert_balancing_authorities(plant_bas)
        assign_buses(plant_bas, code_to_id)
        reconciled = BusMapper.reconcile_interconnections_from_ba()
        IO.puts("  Buses reassigned to interconnection from BA: #{reconciled}")
        report()
        :ok

      {:error, reason} = error ->
        IO.puts("BA mapping failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Build %{orispl => {ba_code, ba_name}} from the eGRID PLNT sheet.
  """
  def plant_ba_map(path) do
    with {:ok, xlsx} <- find_egrid_file(path),
         csv when is_binary(csv) <- EGrid.extract_sheet_to_csv(xlsx, "PLNT") do
      rows = EGridPLNTParser.parse_string(csv, skip_headers: false)

      # Row 0 is human-readable descriptions, row 1 is field names, data follows
      case rows do
        [_descriptions, field_names | data] ->
          oris_idx = Enum.find_index(field_names, &(&1 == "ORISPL"))
          bacode_idx = Enum.find_index(field_names, &(&1 == "BACODE"))
          baname_idx = Enum.find_index(field_names, &(&1 == "BANAME"))

          if oris_idx && bacode_idx do
            plant_bas =
              Enum.reduce(data, %{}, fn cols, acc ->
                orispl = cols |> Enum.at(oris_idx, "") |> normalize_plant_id()
                code = cols |> Enum.at(bacode_idx, "") |> String.trim()
                name = if baname_idx, do: Enum.at(cols, baname_idx, ""), else: ""

                if orispl != "" and code != "" do
                  Map.put(acc, orispl, {code, String.trim(name)})
                else
                  acc
                end
              end)

            IO.puts("  eGRID plants with BA codes: #{map_size(plant_bas)}")
            {:ok, plant_bas}
          else
            {:error, {:columns_not_found, field_names}}
          end

        _ ->
          {:error, :plnt_sheet_too_short}
      end
    else
      nil -> {:error, :plnt_sheet_extraction_failed}
      {:error, _} = error -> error
    end
  end

  @doc """
  Upsert distinct balancing authorities; returns %{code => ba_id}.
  """
  def upsert_balancing_authorities(plant_bas) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      plant_bas
      |> Map.values()
      |> Enum.uniq_by(fn {code, _name} -> code end)
      |> Enum.map(fn {code, name} ->
        %{
          code: code,
          name: if(name == "", do: code, else: name),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(BalancingAuthority, entries,
      on_conflict: :nothing,
      conflict_target: [:code]
    )

    IO.puts("  Balancing authorities in database: #{Repo.aggregate(BalancingAuthority, :count)}")

    Repo.all(from ba in BalancingAuthority, select: {ba.code, ba.id}) |> Map.new()
  end

  @doc """
  Assign buses to BAs: plant majority vote first, nearest-neighbor fill for
  buses with coordinates, then topology propagation for the rest (buses
  without coordinates inherit the BA of an electrically connected neighbor).
  """
  def assign_buses(plant_bas, code_to_id) do
    direct = assign_buses_by_plant_vote(plant_bas, code_to_id)
    filled = assign_buses_by_nearest_neighbor()
    propagated = assign_buses_by_topology()

    IO.puts(
      "  Buses assigned by plant vote: #{direct}, by nearest neighbor: #{filled}, " <>
        "by topology: #{propagated}"
    )

    {direct, filled, propagated}
  end

  defp assign_buses_by_plant_vote(plant_bas, code_to_id) do
    gen_rows =
      Repo.all(
        from g in Generator,
          where: not is_nil(g.bus_id) and not is_nil(g.eia_plant_id),
          select: {g.bus_id, g.eia_plant_id}
      )

    bus_ba_votes =
      Enum.reduce(gen_rows, %{}, fn {bus_id, plant_id}, acc ->
        case Map.get(plant_bas, normalize_plant_id(plant_id)) do
          {code, _name} ->
            Map.update(acc, bus_id, %{code => 1}, &Map.update(&1, code, 1, fn n -> n + 1 end))

          nil ->
            acc
        end
      end)

    bus_ba_votes
    |> Enum.map(fn {bus_id, votes} ->
      {code, _count} = Enum.max_by(votes, fn {_code, count} -> count end)
      {bus_id, Map.get(code_to_id, code)}
    end)
    |> Enum.reject(fn {_bus_id, ba_id} -> is_nil(ba_id) end)
    |> Enum.group_by(fn {_bus_id, ba_id} -> ba_id end, fn {bus_id, _} -> bus_id end)
    |> Enum.reduce(0, fn {ba_id, bus_ids}, count ->
      {n, _} =
        from(b in Bus, where: b.id in ^bus_ids)
        |> Repo.update_all(set: [balancing_authority_id: ba_id])

      count + n
    end)
  end

  # One pass of nearest-neighbor fill using the buses_coordinates_gist index.
  # Prefers a donor bus in the same interconnection when known.
  defp assign_buses_by_nearest_neighbor do
    {:ok, %{num_rows: n}} =
      Repo.query("""
      UPDATE buses b SET balancing_authority_id = (
        SELECT b2.balancing_authority_id FROM buses b2
        WHERE b2.balancing_authority_id IS NOT NULL
          AND b2.coordinates IS NOT NULL
          AND (b.interconnection_id IS NULL
               OR b2.interconnection_id = b.interconnection_id)
        ORDER BY b2.coordinates <-> b.coordinates
        LIMIT 1
      )
      WHERE b.balancing_authority_id IS NULL AND b.coordinates IS NOT NULL
      """)

    n
  end

  # Propagate BA assignments across the network graph: an unassigned bus takes
  # the BA of any bus it shares a transmission line or transformer with.
  # Iterates to a fixpoint so chains of coordinate-less buses are reached.
  defp assign_buses_by_topology(total \\ 0, iteration \\ 0)

  defp assign_buses_by_topology(total, iteration) when iteration >= 50, do: total

  defp assign_buses_by_topology(total, iteration) do
    n =
      Enum.reduce(topology_fill_statements(), 0, fn sql, acc ->
        {:ok, %{num_rows: n}} = Repo.query(sql)
        acc + n
      end)

    if n == 0 do
      total
    else
      assign_buses_by_topology(total + n, iteration + 1)
    end
  end

  defp topology_fill_statements do
    for {table, a, b} <- [
          {"transmission_lines", "from_bus_id", "to_bus_id"},
          {"transmission_lines", "to_bus_id", "from_bus_id"},
          {"transformers", "from_bus_id", "to_bus_id"},
          {"transformers", "to_bus_id", "from_bus_id"}
        ] do
      """
      UPDATE buses b SET balancing_authority_id = nb.ba
      FROM (
        SELECT t.#{a} AS bus_id, max(b2.balancing_authority_id) AS ba
        FROM #{table} t
        JOIN buses b2 ON b2.id = t.#{b}
        WHERE b2.balancing_authority_id IS NOT NULL
        GROUP BY t.#{a}
      ) nb
      WHERE b.id = nb.bus_id AND b.balancing_authority_id IS NULL
      """
    end
  end

  defp report do
    unassigned =
      Repo.one(from b in Bus, where: is_nil(b.balancing_authority_id), select: count())

    no_coords =
      Repo.one(
        from b in Bus,
          where: is_nil(b.balancing_authority_id) and is_nil(b.coordinates),
          select: count()
      )

    total = Repo.aggregate(Bus, :count)

    IO.puts("""
      Bus -> BA assignment report:
        Total buses:      #{total}
        Unassigned:       #{unassigned} (#{no_coords} without coordinates)
    """)
  end

  defp find_egrid_file(path) do
    cond do
      File.regular?(path) and String.ends_with?(path, ".xlsx") ->
        {:ok, path}

      File.dir?(path) ->
        case Path.wildcard(Path.join(path, "egrid*.xlsx")) do
          [found | _] -> {:ok, found}
          [] -> {:error, {:no_egrid_file, path}}
        end

      true ->
        {:error, {:no_egrid_file, path}}
    end
  end

  # openpyxl renders integer cells as "613" but float cells as "613.0";
  # eia_plant_id is stored as the integer string form.
  defp normalize_plant_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_suffix(".0", "")
  end
end
