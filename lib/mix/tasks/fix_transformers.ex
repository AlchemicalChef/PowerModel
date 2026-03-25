defmodule Mix.Tasks.PowerModel.FixTransformers do
  @moduledoc """
  Repairs transformer topology in the power grid database.

  Step 1: Fixes impedances on existing transformers (default x_pu=0.1 is wrong).
  Step 2: Creates missing transformers between multi-voltage substation buses.

  ## Usage

      mix power_model.fix_transformers
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Transformer}

  @shortdoc "Fix transformer impedances and create missing inter-voltage transformers"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("=== Step 1: Fix existing transformer impedances ===")
    updated_count = fix_existing_impedances()
    Mix.shell().info("Updated #{updated_count} existing transformers.\n")

    Mix.shell().info("=== Step 2: Create missing transformers ===")
    created_count = create_missing_transformers()
    Mix.shell().info("Created #{created_count} new transformers.\n")

    Mix.shell().info("Done. Updated: #{updated_count}, Created: #{created_count}")
  end

  # ---------------------------------------------------------------------------
  # Step 1 — recalculate impedances for every existing transformer
  # ---------------------------------------------------------------------------

  defp fix_existing_impedances do
    transformers = Repo.all(from(t in Transformer, select: t))
    Mix.shell().info("Found #{length(transformers)} existing transformers.")

    transformers
    |> Enum.reduce(0, fn xfmr, acc ->
      {x_pu, r_pu} = compute_impedance(xfmr.rated_mva)

      if x_pu != xfmr.x_pu or r_pu != xfmr.r_pu do
        xfmr
        |> Transformer.changeset(%{x_pu: x_pu, r_pu: r_pu})
        |> Repo.update!()

        acc + 1
      else
        acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Step 2 — create transformers for multi-voltage substations missing them
  # ---------------------------------------------------------------------------

  defp create_missing_transformers do
    # Gather all substation-sourced buses with their parsed substation id
    buses =
      from(b in Bus,
        where: b.source == "substation" and not is_nil(b.source_id),
        select: %{id: b.id, base_kv: b.base_kv, source_id: b.source_id}
      )
      |> Repo.all()

    Mix.shell().info("Found #{length(buses)} substation buses.")

    # Group by substation id (the part before the underscore)
    grouped =
      buses
      |> Enum.group_by(fn bus -> extract_substation_id(bus.source_id) end)
      |> Enum.filter(fn {sub_id, group} -> sub_id != nil and length(group) >= 2 end)

    Mix.shell().info("Found #{length(grouped)} multi-voltage substations.")

    # Collect existing transformer pairs for dedup
    existing_pairs = load_existing_pairs()
    Mix.shell().info("Loaded #{MapSet.size(existing_pairs)} existing transformer bus pairs.")

    # For each substation, create adjacent-voltage-pair transformers
    {created, _} =
      grouped
      |> Enum.reduce({0, existing_pairs}, fn {_sub_id, bus_list}, {count, pairs} ->
        sorted = Enum.sort_by(bus_list, & &1.base_kv, :desc)
        create_adjacent_pairs(sorted, count, pairs)
      end)

    created
  end

  defp create_adjacent_pairs([_single], count, pairs), do: {count, pairs}

  defp create_adjacent_pairs([high | [low | _rest] = tail], count, pairs) do
    pair_key = ordered_pair(high.id, low.id)

    {new_count, new_pairs} =
      if MapSet.member?(pairs, pair_key) do
        {count, pairs}
      else
        high_kv = high.base_kv || 0.0
        rated_mva = estimate_rating(high_kv)
        {x_pu, r_pu} = compute_impedance(rated_mva)

        attrs = %{
          from_bus_id: high.id,
          to_bus_id: low.id,
          rated_mva: rated_mva,
          x_pu: x_pu,
          r_pu: r_pu,
          tap_ratio: 1.0,
          status: "in_service"
        }

        case %Transformer{}
             |> Transformer.changeset(attrs)
             |> Repo.insert(on_conflict: :nothing) do
          {:ok, _} ->
            {count + 1, MapSet.put(pairs, pair_key)}

          {:error, changeset} ->
            Mix.shell().info(
              "  Warning: failed to insert transformer #{high.id}->#{low.id}: #{inspect(changeset.errors)}"
            )

            {count, pairs}
        end
      end

    create_adjacent_pairs(tail, new_count, new_pairs)
  end

  defp create_adjacent_pairs([], count, pairs), do: {count, pairs}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp compute_impedance(rated_mva) when is_number(rated_mva) and rated_mva > 0 do
    x_nameplate =
      cond do
        rated_mva >= 500 -> 0.15
        rated_mva >= 200 -> 0.12
        rated_mva >= 100 -> 0.10
        true -> 0.08
      end

    x_pu = x_nameplate * (100.0 / rated_mva)
    r_pu = x_pu * 0.005
    {x_pu, r_pu}
  end

  defp compute_impedance(_), do: {0.10, 0.0005}

  defp estimate_rating(high_kv) do
    cond do
      high_kv >= 500 -> 1000.0
      high_kv >= 345 -> 600.0
      high_kv >= 230 -> 400.0
      high_kv >= 138 -> 200.0
      true -> 100.0
    end
  end

  defp extract_substation_id(source_id) when is_binary(source_id) do
    case String.split(source_id, "_", parts: 2) do
      [sub_id, _voltage] -> sub_id
      _ -> nil
    end
  end

  defp extract_substation_id(_), do: nil

  defp load_existing_pairs do
    from(t in Transformer, select: {t.from_bus_id, t.to_bus_id})
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn {a, b}, acc ->
      MapSet.put(acc, ordered_pair(a, b))
    end)
  end

  defp ordered_pair(a, b) when a <= b, do: {a, b}
  defp ordered_pair(a, b), do: {b, a}
end
