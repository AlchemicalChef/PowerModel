defmodule PowerModel.Ingestion.Matpower do
  @moduledoc """
  Parses MATPOWER .m case files and imports bus/gen/branch/load data.

  Supports ACTIVSg synthetic grids (200, 2000, 10k, 70k, SyntheticUSA 82k).
  These cases include solved voltage profiles and proper bus assignments,
  so Newton-Raphson converges reliably.

  MATPOWER format reference:
    bus:    [bus_i type Pd Qd Gs Bs area Vm Va baseKV zone Vmax Vmin ...]
    gen:    [bus Pg Qg Qmax Qmin Vg mBase status Pmax Pmin ...]
    branch: [fbus tbus r x b rateA rateB rateC ratio angle status ...]
    gentype/genfuel: cell arrays of strings (1-indexed, matches gen rows)
    bus_name: cell array of strings (1-indexed, matches bus rows)

  Branches with ratio > 0 are transformers; ratio == 0 are transmission lines.
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Transformer, Load, Substation, Interconnection}
  require Logger

  @batch_size 500

  @doc """
  Parse a MATPOWER .m file into structured data.
  """
  def parse(file_path) do
    content = File.read!(file_path)

    %{
      base_mva: parse_scalar(content, "mpc.baseMVA"),
      buses: parse_matrix(content, "mpc.bus"),
      gens: parse_matrix(content, "mpc.gen"),
      branches: parse_matrix(content, "mpc.branch"),
      gencost: parse_matrix(content, "mpc.gencost"),
      gentype: parse_cell_array(content, "mpc.gentype"),
      genfuel: parse_cell_array(content, "mpc.genfuel"),
      bus_name: parse_cell_array(content, "mpc.bus_name")
    }
  end

  @doc """
  Import a parsed MATPOWER case into the database.

  Options:
    - `:source` - source tag (default: "matpower")
    - `:case_name` - case identifier (default: derived from filename)
    - `:interconnection` - interconnection name (default: auto-detect)
    - `:clear_existing` - if true, delete existing matpower-sourced data first
  """
  def import(file_path, opts \\ []) do
    source = Keyword.get(opts, :source, "matpower")
    case_name = Keyword.get(opts, :case_name, Path.basename(file_path, ".m"))
    interconnection_name = Keyword.get(opts, :interconnection, nil)
    clear = Keyword.get(opts, :clear_existing, false)

    Logger.info("Parsing MATPOWER file: #{file_path}")
    data = parse(file_path)
    Logger.info("Parsed: #{length(data.buses)} buses, #{length(data.gens)} generators, #{length(data.branches)} branches")

    if clear do
      clear_matpower_data(source, case_name)
    end

    # Build bus kV lookup (avoid O(n) scan per branch)
    bus_kv_map = Map.new(data.buses, fn row -> {trunc(hd(row)), Enum.at(row, 9, 138.0)} end)

    # Build interconnection map for SyntheticUSA (area -> interconnection)
    ic_map = build_interconnection_map(data, case_name, interconnection_name)

    # Import outside a single transaction for large cases (82k+ rows)
    bus_map = import_buses_batch(data, source, case_name, ic_map)
    Logger.info("Imported #{map_size(bus_map)} buses")

    gen_count = import_generators_batch(data, bus_map, case_name)
    Logger.info("Imported #{gen_count} generators")

    {line_count, xfmr_count} = import_branches_batch(data, bus_map, bus_kv_map, source, case_name)
    Logger.info("Imported #{line_count} lines, #{xfmr_count} transformers")

    load_count = import_loads_batch(data, bus_map)
    Logger.info("Imported #{load_count} loads")

    sub_count = import_substations_batch(data, case_name)
    Logger.info("Imported #{sub_count} substations")

    {:ok, %{
      buses: map_size(bus_map),
      generators: gen_count,
      lines: line_count,
      transformers: xfmr_count,
      loads: load_count,
      substations: sub_count
    }}
  rescue
    e in [File.Error, MatchError, ArgumentError] ->
      {:error, Exception.message(e)}
  end

  # --- Parsing ---

  defp parse_scalar(content, name) do
    case Regex.run(~r/#{Regex.escape(name)}\s*=\s*([\d.]+)\s*;/, content) do
      [_, val] -> String.to_float(ensure_decimal(val))
      nil -> 100.0
    end
  end

  defp parse_matrix(content, name) do
    marker = name <> " = ["
    lines = String.split(content, "\n")

    case find_section_start(lines, marker) do
      nil -> []
      start_idx ->
        lines
        |> Enum.drop(start_idx + 1)
        |> Enum.reduce_while([], fn line, acc ->
          trimmed = String.trim(line)
          cond do
            trimmed == "];" or trimmed == "]" -> {:halt, acc}
            trimmed == "" or String.starts_with?(trimmed, "%") -> {:cont, acc}
            true -> {:cont, [parse_row(trimmed) | acc]}
          end
        end)
        |> Enum.reverse()
    end
  end

  defp find_section_start(lines, marker) do
    Enum.find_index(lines, fn line -> String.contains?(line, marker) end)
  end

  defp parse_row(line) do
    line
    |> String.trim_trailing(";")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&parse_number/1)
  end

  defp parse_number(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _} -> f
      :error ->
        case Integer.parse(s) do
          {i, _} -> i / 1
          :error -> 0.0
        end
    end
  end

  defp ensure_decimal(s) do
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  defp parse_cell_array(content, name) do
    marker = name <> " = {"
    lines = String.split(content, "\n")

    case find_section_start(lines, marker) do
      nil -> []
      start_idx ->
        lines
        |> Enum.drop(start_idx + 1)
        |> Enum.reduce_while([], fn line, acc ->
          trimmed = String.trim(line)
          cond do
            trimmed == "};" or trimmed == "}" -> {:halt, acc}
            trimmed == "" or String.starts_with?(trimmed, "%") -> {:cont, acc}
            true ->
              val = trimmed
                |> String.trim_trailing(";")
                |> String.trim()
                |> String.trim("'")
              {:cont, [val | acc]}
          end
        end)
        |> Enum.reverse()
    end
  end

  # --- Interconnection mapping ---

  defp build_interconnection_map(data, case_name, explicit_name) do
    if explicit_name do
      ic_id = ensure_interconnection(explicit_name)
      # All areas map to the same interconnection
      areas = data.buses |> Enum.map(fn row -> trunc(Enum.at(row, 6)) end) |> Enum.uniq()
      Map.new(areas, fn area -> {area, ic_id} end)
    else
      # Auto-detect from area codes (SyntheticUSA convention)
      areas = data.buses |> Enum.map(fn row -> trunc(Enum.at(row, 6)) end) |> Enum.uniq()

      if String.contains?(case_name, "SyntheticUSA") do
        eastern_id = ensure_interconnection("Eastern")
        western_id = ensure_interconnection("Western")
        ercot_id = ensure_interconnection("ERCOT")

        Map.new(areas, fn area ->
          cond do
            area >= 301 -> {area, ercot_id}
            area >= 201 -> {area, western_id}
            true -> {area, eastern_id}
          end
        end)
      else
        ic_id = detect_interconnection(case_name)
        Map.new(areas, fn area -> {area, ic_id} end)
      end
    end
  end

  # --- Batch Database Import ---

  defp import_buses_batch(data, source, case_name, ic_map) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    entries = data.buses
    |> Enum.with_index()
    |> Enum.map(fn {row, _idx} ->
      [bus_i, type, _pd, _qd, _gs, bs | rest] = row
      bus_id_mp = trunc(bus_i)
      bus_type = clamp_bus_type(trunc(type))

      {area, vm, va_deg, base_kv} = case rest do
        [area, vm, va, bkv | _] -> {trunc(area), vm, va, bkv}
        _ -> {1, 1.0, 0.0, 138.0}
      end

      ic_id = Map.get(ic_map, area)

      %{
        bus_type: bus_type,
        base_kv: base_kv,
        vm_pu: vm,
        va_rad: va_deg * :math.pi() / 180.0,
        b_shunt_mvar: if(bs != 0.0, do: bs, else: 0.0),
        source: source,
        source_id: "#{case_name}_bus_#{bus_id_mp}",
        interconnection_id: ic_id,
        inserted_at: now,
        updated_at: now
      }
    end)

    # Batch insert and collect IDs
    bus_map = entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(%{}, fn batch, acc ->
      {_count, rows} = Repo.insert_all(Bus, batch,
        on_conflict: {:replace, [:bus_type, :base_kv, :vm_pu, :va_rad, :b_shunt_mvar, :interconnection_id, :updated_at]},
        conflict_target: [:source, :source_id],
        returning: [:id, :source_id]
      )

      Enum.reduce(rows, acc, fn %{id: id, source_id: sid}, map ->
        # Extract matpower bus_id from source_id: "case_name_bus_1234"
        mp_id = sid
          |> String.split("_bus_")
          |> List.last()
          |> String.to_integer()
        Map.put(map, mp_id, id)
      end)
    end)

    bus_map
  end

  defp import_generators_batch(data, bus_map, case_name) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    entries = data.gens
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, idx} ->
      [bus_i, pg, _qg, qmax, qmin, vg, _mbase, status, pmax, pmin | _] = row
      bus_id_mp = trunc(bus_i)

      case Map.get(bus_map, bus_id_mp) do
        nil -> []
        db_bus_id ->
          gentype = Enum.at(data.gentype, idx)
          genfuel = Enum.at(data.genfuel, idx)

          [%{
            bus_id: db_bus_id,
            p_max_mw: pmax,
            p_min_mw: max(pmin, 0.0),
            q_max_mvar: qmax,
            q_min_mvar: qmin,
            v_set_pu: vg,
            capacity_factor: if(pmax > 0, do: Float.round(pg / pmax, 6), else: 0.0),
            fuel_type: normalize_fuel(genfuel),
            prime_mover: gentype || "ST",
            status: if(trunc(status) == 1, do: "in_service", else: "standby"),
            eia_plant_id: "#{case_name}_gen_#{idx}",
            inserted_at: now,
            updated_at: now
          }]
      end
    end)

    entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} = Repo.insert_all(Generator, batch, on_conflict: :nothing)
      total + count
    end)
  end

  defp import_branches_batch(data, bus_map, bus_kv_map, source, case_name) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    {line_entries, xfmr_entries} = data.branches
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {row, idx}, {lines, xfmrs} ->
      [fbus, tbus, r, x, b, rate_a, _rate_b, _rate_c, ratio, angle, status | _] = row
      from_mp = trunc(fbus)
      to_mp = trunc(tbus)

      from_id = Map.get(bus_map, from_mp)
      to_id = Map.get(bus_map, to_mp)

      if from_id == nil or to_id == nil do
        {lines, xfmrs}
      else
        is_transformer = ratio != 0.0
        in_service = trunc(status) == 1
        status_str = if(in_service, do: "in_service", else: "out_of_service")

        if is_transformer do
          from_kv = Map.get(bus_kv_map, from_mp, 138.0)
          to_kv = Map.get(bus_kv_map, to_mp, 138.0)
          rated_mva = if rate_a > 0, do: rate_a, else: estimate_xfmr_mva(max(from_kv, to_kv))

          # Note: negative x is valid for 3-winding transformer star-point models.
          # Do NOT clamp to positive — preserve sign.
          # Zero-impedance branches (bus ties) get x=0.01 (b=100), not 0.0001
          # (b=10,000) which causes phantom flows of tens of GW.
          # Tiny impedances (|x| < 0.001) get clamped to 0.001 to avoid
          # unrealistically high susceptances.
          clamped_x = cond do
            x == 0.0 -> 0.01
            x > 0.0 and x < 0.001 -> 0.001
            x < 0.0 and x > -0.001 -> -0.001
            true -> x
          end

          entry = %{
            from_bus_id: from_id,
            to_bus_id: to_id,
            r_pu: r,
            x_pu: clamped_x,
            tap_ratio: ratio,
            phase_shift_deg: angle,
            rated_mva: rated_mva,
            status: status_str,
            inserted_at: now,
            updated_at: now
          }
          {lines, [entry | xfmrs]}
        else
          from_kv = Map.get(bus_kv_map, from_mp, 138.0)

          # Zero-impedance lines (bus ties) get x=0.01, tiny lines get x=0.001
          clamped_line_x = cond do
            x == 0.0 -> 0.01
            x > 0.0 and x < 0.001 -> 0.001
            true -> x
          end

          entry = %{
            from_bus_id: from_id,
            to_bus_id: to_id,
            voltage_kv: from_kv,
            r_pu: r,
            x_pu: clamped_line_x,
            b_pu: b,
            rating_a_mva: if(rate_a > 0, do: rate_a, else: nil),
            status: status_str,
            source: source,
            source_id: "#{case_name}_branch_#{idx}",
            inserted_at: now,
            updated_at: now
          }
          {[entry | lines], xfmrs}
        end
      end
    end)

    line_count = line_entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} = Repo.insert_all(TransmissionLine, batch,
        on_conflict: :nothing, conflict_target: [:source, :source_id])
      total + count
    end)

    xfmr_count = xfmr_entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} = Repo.insert_all(Transformer, batch)
      total + count
    end)

    {line_count, xfmr_count}
  end

  defp import_loads_batch(data, bus_map) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    entries = data.buses
    |> Enum.flat_map(fn row ->
      [bus_i, _type, pd, qd | _] = row
      bus_id_mp = trunc(bus_i)

      if (pd > 0.0 or qd > 0.0) do
        case Map.get(bus_map, bus_id_mp) do
          nil -> []
          db_bus_id ->
            [%{
              bus_id: db_bus_id,
              p_mw: pd,
              q_mvar: qd,
              load_type: "constant_power",
              status: "in_service",
              inserted_at: now,
              updated_at: now
            }]
        end
      else
        []
      end
    end)

    entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} = Repo.insert_all(Load, batch)
      total + count
    end)
  end

  defp import_substations_batch(data, case_name) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    entries = data.bus_name
    |> Enum.with_index()
    |> Enum.group_by(fn {name, _idx} -> substation_name(name) end)
    |> Enum.map(fn {sub_name, bus_entries} ->
      voltages = Enum.map(bus_entries, fn {_name, idx} ->
        row = Enum.at(data.buses, idx)
        if row, do: Enum.at(row, 9, 138.0), else: 138.0
      end)

      max_kv = Enum.max(voltages, fn -> 138.0 end)
      min_kv = Enum.min(voltages, fn -> max_kv end)

      %{
        name: sub_name,
        max_voltage_kv: max_kv,
        min_voltage_kv: if(min_kv != max_kv, do: min_kv, else: nil),
        hifld_id: "#{case_name}_sub_#{slug(sub_name)}",
        status: "in_service",
        inserted_at: now,
        updated_at: now
      }
    end)

    entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} = Repo.insert_all(Substation, batch,
        on_conflict: :nothing, conflict_target: [:hifld_id])
      total + count
    end)
  end

  # --- Helpers ---

  defp clamp_bus_type(1), do: 1
  defp clamp_bus_type(2), do: 2
  defp clamp_bus_type(3), do: 3
  defp clamp_bus_type(_), do: 1

  defp estimate_xfmr_mva(max_kv) when max_kv >= 500, do: 1000.0
  defp estimate_xfmr_mva(max_kv) when max_kv >= 345, do: 600.0
  defp estimate_xfmr_mva(max_kv) when max_kv >= 230, do: 400.0
  defp estimate_xfmr_mva(max_kv) when max_kv >= 115, do: 200.0
  defp estimate_xfmr_mva(_), do: 100.0

  defp normalize_fuel(nil), do: "UNK"
  defp normalize_fuel("coal"), do: "COL"
  defp normalize_fuel("ng"), do: "NG"
  defp normalize_fuel("nuclear"), do: "NUC"
  defp normalize_fuel("wind"), do: "WND"
  defp normalize_fuel("solar"), do: "SUN"
  defp normalize_fuel("hydro"), do: "WAT"
  defp normalize_fuel("oil"), do: "OIL"
  defp normalize_fuel("gas"), do: "NG"
  defp normalize_fuel("biomass"), do: "BIO"
  defp normalize_fuel("geothermal"), do: "GEO"
  defp normalize_fuel("dl"), do: "OIL"
  defp normalize_fuel("refuse"), do: "WDS"
  defp normalize_fuel("other"), do: "OTH"
  defp normalize_fuel("dfo"), do: "OIL"
  defp normalize_fuel("sub"), do: "COL"
  defp normalize_fuel("lig"), do: "COL"
  defp normalize_fuel("waste_coal"), do: "COL"
  defp normalize_fuel("pet_coke"), do: "COL"
  defp normalize_fuel(other), do: String.upcase(other)

  defp substation_name(name) do
    String.replace(name, ~r/\s+\d+$/, "")
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim_trailing("_")
  end

  defp ensure_interconnection(name) do
    case Repo.get_by(Interconnection, name: name) do
      %{id: id} -> id
      nil ->
        {:ok, ic} = %Interconnection{}
        |> Interconnection.changeset(%{name: name})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

        case ic.id do
          nil -> Repo.get_by!(Interconnection, name: name).id
          id -> id
        end
    end
  end

  defp detect_interconnection(case_name) do
    cond do
      String.contains?(case_name, "10k") or String.contains?(case_name, "70k") ->
        ensure_interconnection("Eastern")
      String.contains?(case_name, "2000") ->
        ensure_interconnection("ERCOT")
      true ->
        ensure_interconnection("Eastern")
    end
  end

  def clear_matpower_data(source, case_name) do
    import Ecto.Query
    prefix = "#{case_name}_"

    from(l in Load,
      join: b in Bus, on: l.bus_id == b.id,
      where: b.source == ^source and like(b.source_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    from(g in Generator, where: like(g.eia_plant_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    from(t in Transformer,
      join: b in Bus, on: t.from_bus_id == b.id,
      where: b.source == ^source and like(b.source_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    from(tl in TransmissionLine,
      where: tl.source == ^source and like(tl.source_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    from(b in Bus, where: b.source == ^source and like(b.source_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    from(s in Substation, where: like(s.hifld_id, ^"#{prefix}%"))
    |> Repo.delete_all()

    Logger.info("Cleared existing #{source}/#{case_name} data")
  end
end
