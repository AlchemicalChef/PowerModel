defmodule PowerModel.Network.GridKit do
  @moduledoc """
  Read the GridKit extraction of the ENTSO-E interactive map — the continental
  European network — into this repo's snapshot map.

  8,807 buses and 11,151 lines across Continental Europe, the Nordics, GB,
  Ireland and the Baltics, plus 62 HVDC links. Shipped in PyPSA-Eur at
  `data/entsoegridkit/`, **CC-BY-4.0** (SPDX annotation in that repo's
  `REUSE.toml`, copyright "The PyPSA-Eur Authors").

  ## This is a substrate, not a validated model — its own README says so

  The dataset is an **unofficial** extract of the ENTSO-E map from March 2022,
  "neither approved nor endorsed by ENTSO-E", and it names its own defects:
  coordinates come from a map that chooses topological clarity over geographic
  accuracy; **voltage is the LOWER BOUND of the range ENTSO-E publishes**;
  line-structure conflicts are resolved by taking the first; transformers are
  not in the source at all and were inferred from voltage differences; and the
  generator-to-bus assignment is a nearest-station guess. Those caveats are
  carried here rather than in a commit message because they change how every
  number out of this reader should be read.

  ## Why it needs an estimator where `Network.PyPSA` does not

  A PyPSA export carries `r_ohmkm`/`x_ohmkm`/`c_nfkm` per line. This does not:
  it has `voltage`, `circuits`, `length`, `underground` and nothing electrical.
  So impedance is DERIVED, exactly as `Ingestion.ParameterEstimator` derives it
  for HIFLD — which makes this a like-for-like test of that recipe on another
  continent's topology rather than a way to avoid it.

  The per-km values come from PyPSA's standard type library (Oeding & Oswald),
  keyed on the nearest voltage class, so the estimate is at least anchored in a
  published conductor table rather than in this repo's own assumptions.

  ## What is filtered, and why

    * `under_construction` buses and lines are DROPPED. They are not network.
    * DC buses and the `links.csv` HVDC set are dropped for now: this repo
      models HVDC as scheduled injections (`Ingestion.HvdcTies`) and wiring
      them as AC branches would be wrong. Reported in `:dropped` so the missing
      62 links are visible rather than assumed absent.
    * Lines whose endpoints are missing or equal are dropped, and counted.

  ## Frequency

  Stamped 50 Hz, so `Grid.SystemStandard.compatible!/2` refuses a cascade until
  the frequency layer is ported. Steady-state power flow is unaffected.
  """

  require Logger

  NimbleCSV.define(GridKitParser, separator: ",", escape: "'")

  @base_mva 100.0
  @frequency_hz 50.0
  @load_power_factor 0.95

  # PyPSA standard line types (Oeding & Oswald), by nominal kV:
  # {r_ohm_per_km, x_ohm_per_km, c_nf_per_km, i_nom_kA}
  @line_types %{
    380.0 => {0.03, 0.246, 13.8, 2.58},
    330.0 => {0.04, 0.265, 13.2, 1.935},
    300.0 => {0.04, 0.265, 13.2, 1.935},
    220.0 => {0.06, 0.301, 12.5, 1.29},
    150.0 => {0.12, 0.33, 11.5, 1.05},
    132.0 => {0.12, 0.33, 11.5, 1.05},
    110.0 => {0.12, 0.33, 11.5, 1.05}
  }

  @doc """
  Read a `data/entsoegridkit` directory.

  Options: `:base_mva`, `:load_power_factor`, `:min_kv` (drop buses below it,
  default 0.0), `:loads` (`%{bus_id => mw}`; none by default — this dataset
  carries no demand, and inventing it silently is how a study starts measuring
  its own assumptions).
  """
  @spec load!(Path.t(), keyword()) :: map()
  def load!(dir, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, @base_mva)
    min_kv = Keyword.get(opts, :min_kv, 0.0)
    load_map = Keyword.get(opts, :loads, %{})
    load_pf = Keyword.get(opts, :load_power_factor, @load_power_factor)

    bus_rows = read!(Path.join(dir, "buses.csv"))

    {keep_rows, skipped_buses} =
      Enum.split_with(bus_rows, fn r ->
        truthy?(r["under_construction"]) == false and truthy?(r["dc"]) == false and
          (num(r["voltage"]) || 0.0) >= min_kv
      end)

    id_by_key = keep_rows |> Enum.with_index(1) |> Map.new(fn {r, i} -> {r["bus_id"], i} end)

    buses =
      Enum.map(keep_rows, fn r ->
        %{
          id: Map.fetch!(id_by_key, r["bus_id"]),
          name: r["bus_id"],
          station_id: r["station_id"],
          base_kv: num(r["voltage"]) || 0.0,
          bus_type: 1,
          vm_pu: 1.0,
          va_rad: 0.0,
          gs_mw: 0.0,
          bs_mvar: 0.0,
          lon: num(r["x"]),
          lat: num(r["y"]),
          country: tag(r["tags"], "country")
        }
      end)

    {lines, dropped_lines} =
      dir
      |> Path.join("lines.csv")
      |> read!()
      |> Enum.with_index(1)
      |> Enum.map(&line(&1, id_by_key, base_mva))
      |> split_dropped()

    {transformers, dropped_transformers} =
      dir
      |> Path.join("transformers.csv")
      |> read_optional()
      |> Enum.with_index(1)
      |> Enum.map(&transformer(&1, id_by_key, base_mva))
      |> split_dropped()

    links = dir |> Path.join("links.csv") |> read_optional()

    loads =
      load_map
      |> Enum.with_index(1)
      |> Enum.map(fn {{bus_id, mw}, i} ->
        %{
          id: i,
          bus_id: bus_id,
          p_mw: mw * 1.0,
          q_mvar: mw * :math.tan(:math.acos(load_pf)),
          load_type: "constant_power",
          status: "in_service"
        }
      end)

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      # The source has no generator table; a caller supplies dispatch.
      generators: [],
      loads: loads,
      base_mva: base_mva,
      nominal_hz: @frequency_hz,
      system_standard: PowerModel.Grid.SystemStandard.for_frequency(@frequency_hz),
      source: {:entsoe_gridkit, Path.basename(Path.expand(dir))},
      provenance: %{
        licence: "CC-BY-4.0",
        attribution: "The PyPSA-Eur Authors; unofficial extract of the ENTSO-E interactive map",
        vintage: "map extract March 2022",
        endorsed: false,
        known_defects: [
          "coordinates favour topological clarity over geographic accuracy",
          "voltage is the LOWER BOUND of the ENTSO-E range",
          "transformers are inferred from voltage differences, not in the source",
          "impedance is DERIVED here, not measured"
        ]
      },
      dropped: %{
        buses: length(skipped_buses),
        lines: dropped_lines,
        transformers: dropped_transformers,
        hvdc_links: length(links)
      }
    }
  end

  @doc "Per-km {r, x, c, i_nom} for the nearest standard class to `kv`."
  @spec line_type(number()) :: {float(), float(), float(), float()}
  def line_type(kv) when is_number(kv) and kv > 0.0 do
    closest = @line_types |> Map.keys() |> Enum.min_by(&abs(&1 - kv))
    Map.fetch!(@line_types, closest)
  end

  def line_type(_), do: Map.fetch!(@line_types, 220.0)

  defp line({row, idx}, id_by_key, base_mva) do
    with false <- truthy?(row["under_construction"]),
         {:ok, from} <- Map.fetch(id_by_key, row["bus0"]),
         {:ok, to} <- Map.fetch(id_by_key, row["bus1"]),
         true <- from != to,
         kv when is_number(kv) and kv > 0.0 <- num(row["voltage"]),
         length_m when is_number(length_m) and length_m > 0.0 <- num(row["length"]) do
      circuits = max(num(row["circuits"]) || 1.0, 1.0)
      {r_km, x_km, c_km, i_nom_ka} = line_type(kv)
      km = length_m / 1000.0
      z_base = kv * kv / base_mva

      c_farad = c_km * 1.0e-9 * km * circuits
      b_siemens = 2.0 * :math.pi() * @frequency_hz * c_farad

      %{
        id: idx,
        name: row["line_id"],
        from_bus_id: from,
        to_bus_id: to,
        voltage_kv: kv,
        r_pu: r_km * km / circuits / z_base,
        x_pu: x_km * km / circuits / z_base,
        b_pu: b_siemens * z_base,
        # S = sqrt(3) * V * I, with I in kA and V in kV giving MVA.
        rating_a_mva: :math.sqrt(3.0) * kv * i_nom_ka * circuits,
        length_km: km,
        num_parallel: circuits,
        underground: truthy?(row["underground"]),
        status: "in_service",
        source: "entsoe_gridkit"
      }
    else
      _ -> {:dropped, row["line_id"]}
    end
  end

  defp transformer({row, idx}, id_by_key, base_mva) do
    with false <- truthy?(row["under_construction"]),
         {:ok, from} <- Map.fetch(id_by_key, row["bus0"]),
         {:ok, to} <- Map.fetch(id_by_key, row["bus1"]),
         true <- from != to do
      # The source carries no rating or impedance — the transformers are
      # themselves inferred. A generic 12% on a 1000 MVA bank is a placeholder
      # and is labelled one.
      s_nom = 1000.0

      %{
        id: idx,
        name: row["transformer_id"] || "T#{idx}",
        from_bus_id: from,
        to_bus_id: to,
        r_pu: 0.0,
        x_pu: 0.12 * base_mva / s_nom,
        rated_mva: s_nom,
        tap_ratio: 1.0,
        status: "in_service",
        estimated: true
      }
    else
      _ -> {:dropped, row["transformer_id"]}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp read!(path) do
    [header | rows] = path |> File.read!() |> GridKitParser.parse_string(skip_headers: false)
    Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
  end

  defp read_optional(path), do: if(File.regular?(path), do: read!(path), else: [])

  defp split_dropped(rows) do
    {dropped, kept} = Enum.split_with(rows, &match?({:dropped, _}, &1))
    {kept, length(dropped)}
  end

  defp truthy?(v) when v in ["t", "T", "true", "True", "TRUE", "1"], do: true
  defp truthy?(_), do: false

  # hstore-ish: '"country"=>"DE", ...'
  defp tag(nil, _key), do: nil

  defp tag(tags, key) do
    case Regex.run(~r/"#{key}"\s*=>\s*"([^"]*)"/, tags) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp num(nil), do: nil
  defp num(""), do: nil

  defp num(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: nil
end
