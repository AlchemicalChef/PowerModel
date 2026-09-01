defmodule Mix.Tasks.PowerModel.Loadings do
  @moduledoc """
  Dump an interconnection's branch loadings at real demand to CSV — the model
  side of the external congestion score (REVIEW EXT-1,
  `scripts/score_congestion.py`).

      mix power_model.loadings --interconnection ERCOT --out loadings.csv
      mix power_model.loadings --interconnection Eastern --out e.csv --buses buses.csv --ac
      mix power_model.loadings --interconnection ERCOT --out c.csv --redispatch
      mix power_model.loadings --interconnection ERCOT --out m.csv --cems

  `--cems` pins the fossil fleet to its measured CEMS operation at the hour
  (ROADMAP C1, `PowerModel.Ingestion.Epa.Cems`).

  One row per rated branch of the main island at the latest ingested hour
  (`--hour` to choose): DC loading, AC loading when `--ac` (the controlled
  solve with the load-ramp continuation; slow on Eastern), flow, rating,
  `inferred_circuits`, source, endpoint bus ids and coordinates, HIFLD endpoint
  names. `--buses` also writes every bus's id, class and coordinates, which the
  scorer uses to locate real stations by proximity.
  """

  use Mix.Task

  require Logger

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Dispatch.Redispatch
  alias PowerModel.Failure.Cascade
  alias PowerModel.Solver.{DCPowerFlow, Partition, VoltageControl}

  @shortdoc "Branch loadings at real demand, to CSV, for the congestion score"

  @switches [
    interconnection: :string,
    out: :string,
    buses: :string,
    stations: :string,
    hour: :string,
    ac: :boolean,
    redispatch: :boolean,
    cems: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unrecognised option(s): #{inspect(invalid)}")
    name = opts[:interconnection] || Mix.raise("--interconnection is required")
    out = opts[:out] || Mix.raise("--out is required")

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()
    ic = Repo.get_by(Grid.Interconnection, name: name) || Mix.raise("no interconnection #{name}")
    snap = Grid.get_grid_snapshot(ic.id, hour: hour)
    state = Cascade.init(snap, 100.0, hour: hour, cems: opts[:cems] == true)

    {subs, _} =
      Partition.split(%{
        buses: state.buses,
        lines: state.lines,
        transformers: state.transformers,
        generators: Cascade.dispatched_generators(state),
        loads: state.loads
      })

    island = Enum.max_by(subs, &length(&1.buses))

    # `--redispatch`: the transmission-constrained operating point (REVIEW
    # EXT-1) — generation shifted until no rated branch is over its rating.
    island =
      if opts[:redispatch] do
        {isl, rep} = Redispatch.relieve(island)

        Mix.shell().info(
          "redispatch: #{rep.iterations} iterations, #{round(rep.shifted_mw)} MW shifted, " <>
            "#{length(rep.relieved)} branches relieved, #{length(rep.residual)} residual (#{rep.stopped})"
        )

        isl
      else
        island
      end

    dc = DCPowerFlow.solve(island, base_mva: 100.0)

    ac =
      if opts[:ac] do
        try do
          {:ok, s} =
            VoltageControl.solve(island,
              base_mva: 100.0,
              dense_nr_max_buses: 0,
              max_iterations: 400,
              ramp: true
            )

          if s.converged, do: s
        catch
          _, _ -> nil
        end
      end

    bus = Map.new(island.buses, &{&1.id, &1})

    coords = fn b ->
      case b.coordinates do
        %{coordinates: {lo, la}} -> {la, lo}
        _ -> {nil, nil}
      end
    end

    rows =
      for l <- island.lines,
          f = dc.line_flows[{:line, l.id}],
          is_number(f.rating_mva) and f.rating_mva > 0 do
        a = ac && ac.line_flows[{:line, l.id}]
        {lat1, lon1} = coords.(bus[l.from_bus_id])
        {lat2, lon2} = coords.(bus[l.to_bus_id])

        [
          l.id,
          l.voltage_kv,
          l.sub_1 || "",
          l.sub_2 || "",
          round(f.loading_pct),
          if(a, do: round(a.loading_pct), else: ""),
          round(abs(f.p_flow_mw)),
          round(f.rating_mva),
          Map.get(l, :inferred_circuits) || 1,
          l.source,
          l.source_id || "",
          l.from_bus_id,
          l.to_bus_id,
          lat1,
          lon1,
          lat2,
          lon2
        ]
      end

    xrows =
      for t <- island.transformers,
          f = dc.line_flows[{:transformer, t.id}],
          is_number(f.rating_mva) and f.rating_mva > 0 do
        a = ac && ac.line_flows[{:transformer, t.id}]
        b1 = bus[t.from_bus_id]
        b2 = bus[t.to_bus_id]
        {lat1, lon1} = coords.(b1)
        {lat2, lon2} = coords.(b2)

        [
          "T#{t.id}",
          "#{b1.base_kv}/#{b2.base_kv}",
          "",
          "",
          round(f.loading_pct),
          if(a, do: round(a.loading_pct), else: ""),
          round(abs(f.p_flow_mw)),
          round(f.rating_mva),
          Map.get(t, :inferred_circuits) || 1,
          "",
          "",
          t.from_bus_id,
          t.to_bus_id,
          lat1,
          lon1,
          lat2,
          lon2
        ]
      end

    header =
      "id,kv,sub_1,sub_2,dc_loading_pct,ac_loading_pct,dc_flow_mw,rating_mva,inferred_circuits,source,source_id,from_bus_id,to_bus_id,from_lat,from_lon,to_lat,to_lon"

    File.write!(out, Enum.join([header | Enum.map(rows ++ xrows, &csv_row/1)], "\n") <> "\n")

    if opts[:buses] do
      lines =
        for b <- island.buses, {lat, lon} = coords.(b), lat != nil do
          "#{b.id},#{b.base_kv},#{lat},#{lon}"
        end

      File.write!(opts[:buses], Enum.join(["id,kv,lat,lon" | lines], "\n") <> "\n")
    end

    # `--stations`: the model's named yards (name, coords, kv levels) as a
    # second geocoding source for the scorer (`--stations` there too) — OSM's
    # named-yard coverage is its bottleneck.
    if opts[:stations] do
      rows =
        Repo.all(
          from(s in "substations",
            where:
              not like(s.name, "UNKNOWN%") and not like(s.name, "TAP%") and
                not is_nil(s.coordinates),
            select: {s.name, s.coordinates, s.voltage_levels}
          )
        )

      lines =
        for {name, geom, levels} <- rows, %Geo.Point{coordinates: {lon, lat}} <- [geom] do
          clean = String.replace(name, ",", " ")
          kvs = Enum.map_join(levels || [], ";", &trunc/1)
          "#{clean},#{Float.round(lat, 5)},#{Float.round(lon, 5)},#{kvs}"
        end

      File.write!(opts[:stations], Enum.join(lines, "\n") <> "\n")
      Mix.shell().info("#{length(lines)} named stations written to #{opts[:stations]}")
    end

    Mix.shell().info(
      "#{name} @ #{hour}: #{length(rows) + length(xrows)} rated branches written to #{out}" <>
        if(opts[:ac], do: " (AC #{if ac, do: "converged", else: "did not converge"})", else: "")
    )
  end

  defp csv_row(fields) do
    Enum.map_join(fields, ",", fn v ->
      s = to_string(v)
      if String.contains?(s, [",", "\""]), do: "\"#{String.replace(s, "\"", "\"\"")}\"", else: s
    end)
  end

  defp parse_hour(nil), do: nil

  defp parse_hour(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> Mix.raise("--hour must be ISO8601")
    end
  end
end
