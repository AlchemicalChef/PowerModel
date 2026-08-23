defmodule Mix.Tasks.Grid.ReferenceStats do
  @moduledoc """
  Regenerate `priv/reference/structural_stats.json` from the vendored
  MATPOWER reference cases.

      mix grid.reference_stats
      mix grid.reference_stats --out /tmp/stats.json
      mix grid.reference_stats --print

  See `PowerModel.Reference` for what the corpus is for and where it must not
  be trusted. This task exists because a measured artifact without a committed
  producer goes stale silently (REVIEW DAT-31, logged against the reactive
  support study for exactly that reason).

  ## Reading the case files

  The MATPOWER parser lives in `test/support/matpower.ex` and is compiled only
  in the test environment, so this task loads it with `Code.require_file/1`.
  That is deliberate: the corpus is a DEV-TIME artifact generated from test
  fixtures and shipped as JSON, and `PowerModel.Reference` reads only the
  JSON. Nothing in `lib` depends on test code at runtime.

  ## Two structural decisions, both of which change the numbers

  **Transformers are identified by voltage crossing, not by tap ratio.**
  `case_ACTIVSg2000` carries every branch at tap 1.0, including its 847
  generator step-ups and 115/230 kV banks, so the parser's tap-based split
  reports zero transformers. Splitting on `base_kv(from) != base_kv(to)`
  recovers them, and without that split every "line x_pu at 13.8 kV" figure is
  really a step-up and every generator appears to interconnect at its own
  terminal voltage.

  **A plant's POI is the highest voltage reachable across ONE branch from the
  machine terminal.** This is what makes the number comparable to our own
  network, where generators sit directly on a substation bus: in both
  conventions the question "what does this plant's output have to leave
  through" has the same answer.

  **Plant size is NAMEPLATE (Pmax), not the dispatched Pg the parser puts in
  `p_max_mw`.** The consumer of this table is a census scoring
  `generators.p_max_mw` from our own schema, which IS nameplate. Deriving the
  table from Pg would compare one plant's rating against another's dispatch —
  a 1.40x error here, since `case_ACTIVSg2000` sums to 96,292 MW of Pmax
  against 68,725 MW of Pg, and it moves 34 of its 390 plants into a different
  POI band. Measured and corrected 2026-08-23.
  """

  use Mix.Task

  @shortdoc "Rebuild the reference structural-statistics corpus"

  @cases [
    "test/fixtures/matpower/case_ACTIVSg2000.m",
    "test/fixtures/matpower/case118.m"
  ]

  # Cumulative plant-size thresholds the POI floor is reported against.
  @poi_thresholds [25, 50, 100, 200, 400, 800]

  @switches [out: :string, print: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [],
      do: Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    Code.require_file("test/support/matpower.ex")

    parsed = Enum.map(@cases, &{&1, apply(PowerModel.Test.MATPOWER, :load!, [&1])})
    per_case = Enum.map(parsed, fn {path, c} -> {path, c, analyse(c)} end)

    corpus = %{
      "schema_version" => 1,
      "generated_by" => "mix grid.reference_stats",
      "generation_basis" =>
        "NAMEPLATE (MATPOWER Pmax), not the dispatched Pg. The consumer scores " <>
          "generators.p_max_mw from this repo's schema, which is nameplate; deriving " <>
          "from Pg would compare one plant's rating to another's dispatch (1.40x in " <>
          "case_ACTIVSg2000).",
      "sources" => Enum.map(per_case, fn {path, c, a} -> source_entry(path, c, a) end),
      "metrics" => metrics(per_case),
      "derived" => %{
        "generator_poi_floor_kv" => poi_floor(per_case),
        "generator_poi_floor_kv_note" =>
          "[[above_mw, min_kv], ...]: the LOWEST point-of-interconnection voltage any " <>
            "reference case uses for a plant above that size. Most permissive reading — " <>
            "a bus failing it is one no reference case would produce.",
        "load_bus_kv_range" => load_kv_range(per_case),
        "load_bus_kv_range_note" =>
          "[min_kv, max_kv] over every bus carrying load in any reference case. " <>
            "Reference models terminate at the distribution substation: they place no " <>
            "load below the low end and none above the high end."
      }
    }

    json = Jason.encode_to_iodata!(corpus, pretty: true)
    out = Keyword.get(opts, :out, Path.join(["priv", "reference", "structural_stats.json"]))

    if opts[:print] do
      IO.puts(json)
    else
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, json)
      Mix.shell().info("Wrote #{out}")

      Enum.each(per_case, fn {path, c, a} ->
        Mix.shell().info(
          "  #{c.case_name}: #{length(c.buses)} buses, #{round(a.load_mw)} MW load, " <>
            "#{length(a.lines)} same-level lines, #{length(a.transformers)} level-crossing " <>
            "(#{Path.basename(path)})"
        )
      end)

      Mix.shell().info("  POI floor: #{inspect(corpus["derived"]["generator_poi_floor_kv"])}")
      Mix.shell().info("  load bus kV range: #{inspect(corpus["derived"]["load_bus_kv_range"])}")
    end
  end

  # ── analysis ────────────────────────────────────────────────────────────

  defp analyse(c) do
    kv = Map.new(c.buses, &{&1.id, &1.base_kv})

    # See the moduledoc: split by voltage crossing, not tap ratio.
    {transformers, lines} =
      Enum.split_with(c.lines ++ tap_transformers(c), fn b ->
        Map.get(kv, b.from_bus_id) != Map.get(kv, b.to_bus_id)
      end)

    all = lines ++ transformers

    poi =
      all
      |> Enum.flat_map(fn b ->
        [{b.from_bus_id, Map.get(kv, b.to_bus_id)}, {b.to_bus_id, Map.get(kv, b.from_bus_id)}]
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {k, v} -> {k, v |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)} end)

    plants =
      c.generators
      |> Enum.group_by(& &1.bus_id, &nameplate/1)
      |> Enum.map(fn {bus, mws} ->
        %{bus: bus, mw: Enum.sum(mws), terminal_kv: Map.get(kv, bus), poi_kv: Map.get(poi, bus)}
      end)
      |> Enum.filter(&(&1.mw > 0))

    %{
      kv: kv,
      lines: lines,
      transformers: transformers,
      plants: plants,
      load_mw: c.loads |> Enum.map(& &1.p_mw) |> Enum.sum(),
      hops: hops(c, kv, all)
    }
  end

  # Any transformers the parser DID split out on tap ratio still belong in the
  # branch set; shaping them like lines keeps the analysis uniform.
  defp tap_transformers(c) do
    Enum.map(c.transformers, fn t ->
      %{
        id: {:xfmr, t.id},
        from_bus_id: t.from_bus_id,
        to_bus_id: t.to_bus_id,
        x_pu: t.x_pu,
        b_pu: 0.0
      }
    end)
  end

  defp hops(c, kv, branches) do
    top = kv |> Map.values() |> Enum.max()

    adj =
      Enum.reduce(branches, %{}, fn b, acc ->
        acc
        |> Map.update(b.from_bus_id, [b.to_bus_id], &[b.to_bus_id | &1])
        |> Map.update(b.to_bus_id, [b.from_bus_id], &[b.from_bus_id | &1])
      end)

    seeds = for b <- c.buses, b.base_kv >= top, do: b.id
    {bfs(Map.new(seeds, &{&1, 0}), seeds, adj), top}
  end

  defp bfs(dist, [], _adj), do: dist

  defp bfs(dist, frontier, adj) do
    {dist, next} =
      Enum.reduce(frontier, {dist, []}, fn n, {d, acc} ->
        hop = Map.fetch!(d, n) + 1

        Enum.reduce(Map.get(adj, n, []), {d, acc}, fn nb, {da, a} ->
          if Map.has_key?(da, nb), do: {da, a}, else: {Map.put(da, nb, hop), [nb | a]}
        end)
      end)

    bfs(dist, next, adj)
  end

  # ── shaping ─────────────────────────────────────────────────────────────

  defp source_entry(path, c, a) do
    %{
      "case" => c.case_name,
      "path" => path,
      "buses" => length(c.buses),
      "same_level_lines" => length(a.lines),
      "level_crossing_branches" => length(a.transformers),
      "generators" => length(c.generators),
      "plants" => length(a.plants),
      "load_mw" => round1(a.load_mw),
      "voltage_levels_kv" => a.kv |> Map.values() |> Enum.uniq() |> Enum.sort()
    }
  end

  defp metrics(per_case) do
    %{
      "load_mw_share_by_bus_kv" =>
        by_case(per_case, fn c, a ->
          share_by(c.loads, & &1.p_mw, &Map.get(a.kv, &1.bus_id))
        end),
      "generation_mw_share_by_bus_kv" =>
        by_case(per_case, fn c, a ->
          share_by(c.generators, &nameplate/1, &Map.get(a.kv, &1.bus_id))
        end),
      "generation_mw_share_by_poi_kv" =>
        by_case(per_case, fn _c, a ->
          share_by(a.plants, & &1.mw, & &1.poi_kv)
        end),
      "load_mw_share_by_hops_from_top_kv" =>
        by_case(per_case, fn c, a ->
          {dist, _top} = a.hops
          share_by(c.loads, & &1.p_mw, &hop_bucket(Map.get(dist, &1.bus_id)))
        end),
      "top_kv" => by_case(per_case, fn _c, a -> elem(a.hops, 1) end),
      "line_x_pu_by_bus_kv" =>
        by_case(per_case, fn _c, a ->
          a.lines
          |> Enum.group_by(&Map.get(a.kv, &1.from_bus_id))
          |> Map.new(fn {k, ls} ->
            xs = ls |> Enum.map(& &1.x_pu) |> Enum.sort()
            n = length(xs)

            {to_string(k),
             %{
               "n" => n,
               "p50" => round4(Enum.at(xs, div(n, 2))),
               "p95" => round4(Enum.at(xs, min(n - 1, div(n * 95, 100)))),
               "max" => round4(List.last(xs))
             }}
          end)
        end),
      "line_degree" =>
        by_case(per_case, fn c, a ->
          deg = a.lines |> Enum.flat_map(&[&1.from_bus_id, &1.to_bus_id]) |> Enum.frequencies()
          degs = c.buses |> Enum.map(&Map.get(deg, &1.id, 0)) |> Enum.sort()
          n = length(degs)

          %{
            "mean" => round4(Enum.sum(degs) / n),
            "median" => Enum.at(degs, div(n, 2)),
            "share_degree_0" => round1(Enum.count(degs, &(&1 == 0)) / n * 100),
            "share_degree_1" => round1(Enum.count(degs, &(&1 == 1)) / n * 100)
          }
        end),
      "poi_kv_by_plant_mw_band" =>
        by_case(per_case, fn _c, a ->
          bands = Enum.zip([0 | @poi_thresholds], @poi_thresholds ++ [:infinity])

          bands
          |> Enum.map(fn {lo, hi} ->
            inb =
              Enum.filter(a.plants, fn p ->
                p.mw > lo and (hi == :infinity or p.mw <= hi) and p.poi_kv
              end)

            label = if hi == :infinity, do: "#{lo}+", else: "#{lo}-#{hi}"

            if inb == [] do
              nil
            else
              ks = inb |> Enum.map(& &1.poi_kv) |> Enum.sort()
              n = length(ks)

              {label,
               %{
                 "n" => n,
                 "min" => List.first(ks),
                 "p50" => Enum.at(ks, div(n, 2)),
                 "max" => List.last(ks)
               }}
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new()
        end)
    }
  end

  defp by_case(per_case, fun),
    do: Map.new(per_case, fn {_p, c, a} -> {c.case_name, fun.(c, a)} end)

  # Every generation figure in this corpus is on the NAMEPLATE basis, because
  # the consumer scores `generators.p_max_mw` from our schema, which is
  # nameplate. Mixing bases across metrics is the bug this function exists to
  # prevent: `generation_mw_share_by_poi_kv` was moved to nameplate first and
  # left `generation_mw_share_by_bus_kv` on dispatched Pg for one commit.
  defp nameplate(gen), do: Map.get(gen, :p_nameplate_mw) || gen.p_max_mw

  defp share_by(items, mw_fun, key_fun) do
    total = items |> Enum.map(mw_fun) |> Enum.sum()

    if total <= 0 do
      %{}
    else
      items
      |> Enum.group_by(key_fun, mw_fun)
      |> Enum.reject(fn {k, _} -> is_nil(k) end)
      |> Map.new(fn {k, v} -> {to_string(k), round1(Enum.sum(v) / total * 100)} end)
    end
  end

  defp hop_bucket(nil), do: "unreached"
  defp hop_bucket(0), do: "0"
  defp hop_bucket(n) when n <= 2, do: "1-2"
  defp hop_bucket(n) when n <= 4, do: "3-4"
  defp hop_bucket(n) when n <= 6, do: "5-6"
  defp hop_bucket(_), do: "7+"

  # The floor is the minimum across cases, so it stays the most permissive
  # reading as more cases are added.
  defp poi_floor(per_case) do
    plants = Enum.flat_map(per_case, fn {_p, _c, a} -> a.plants end)

    @poi_thresholds
    |> Enum.map(fn t ->
      kvs = plants |> Enum.filter(&(&1.mw > t and &1.poi_kv)) |> Enum.map(& &1.poi_kv)
      if kvs == [], do: nil, else: [t, Enum.min(kvs)]
    end)
    |> Enum.reject(&is_nil/1)
    |> dedupe_floor()
  end

  # Only keep a threshold when it RAISES the floor: [[25,115],[50,115],[100,115],
  # [200,161]] carries no more information than [[25,115],[200,161]].
  defp dedupe_floor(bands) do
    bands
    |> Enum.reduce({[], nil}, fn [t, kv], {acc, last} ->
      if kv == last, do: {acc, last}, else: {[[t, kv] | acc], kv}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp load_kv_range(per_case) do
    kvs =
      Enum.flat_map(per_case, fn {_p, c, a} ->
        c.loads |> Enum.filter(&(&1.p_mw > 0)) |> Enum.map(&Map.get(a.kv, &1.bus_id))
      end)
      |> Enum.reject(&is_nil/1)

    if kvs == [], do: nil, else: [Enum.min(kvs), Enum.max(kvs)]
  end

  defp round1(x) when is_number(x), do: Float.round(x * 1.0, 1)
  defp round4(x) when is_number(x), do: Float.round(x * 1.0, 4)
end
