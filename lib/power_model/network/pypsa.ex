defmodule PowerModel.Network.PyPSA do
  @moduledoc """
  Read a PyPSA network export into the snapshot map this repo's solvers
  consume — `%{buses:, lines:, transformers:, generators:, loads:}`.

  ## Why a reader and not an ingest pipeline

  Europe publishes more grid data than the US does, and the open modelling
  ecosystem there has already spent years turning it into networks: PyPSA-Eur
  builds a continental transmission model from OpenStreetMap and ENTSO-E, and
  ships it in this CSV format. Rebuilding that as a second HIFLD-style pipeline
  into our own tables would duplicate a mature effort and inherit none of it.

  What is genuinely MISSING from that ecosystem is what this repo has: PyPSA is
  a capacity-expansion and dispatch optimiser, and does not do AC contingency
  cascades, protection relays, UFLS/UVLS, voltage collapse or frequency
  dynamics. So the useful seam is a reader that produces the snapshot contract
  — after which `Solver.FDPF`, `Failure.Cascade` and the whole protection stack
  work on a European network with no further plumbing. Same shape as
  `PowerModel.Test.MATPOWER`, for the same reason, but in `lib` because this is
  a simulation substrate rather than a test fixture.

  ## What the data is like, measured against ours

  `examples/networks/scigrid-de` (585 buses, 852 lines, 1,423 generators) is
  the German transmission grid from SciGRID. Read against what this repo fights
  with in HIFLD:

    * **Real per-circuit impedance.** `r_ohmkm`/`x_ohmkm`/`c_nfkm` per line,
      with `length`, `num_parallel` and `cables`. No estimation from a voltage
      class, which is the root of REVIEW LIN-13 on our side. Measured median
      `x_ohmkm` 0.32, against the 0.335-0.50 our own estimator produces — an
      independent corroboration of that recipe.
    * **`num_parallel`.** The parallel-circuit count whose absence produced the
      "missing parallel circuits" half of the POI census findings.
    * **Real ratings** (`s_nom`), not a class table.
    * **Per-bus hourly load** (`loads-p_set.csv`). The entire load-ALLOCATION
      problem — county population weights, delivery ceilings, capability caps —
      simply does not arise. Load arrives already on the bus.
    * **A curated 220/380 kV backbone**, so the sub-115 kV population that pins
      our alpha ceiling is absent. That is a limitation as much as a gift: no
      sub-transmission means no sub-transmission failure modes.

  ## What it does NOT carry, and what this reader does about it

  Both gaps are filled explicitly and reported in the returned map, because
  silently synthesizing them is how a study starts measuring its own defaults:

    * **No reactive limits on generators.** PyPSA generators have no q_max/q_min.
      Left as `nil` by default, which the solver reads as unconstrained — so
      Q-limit switching never fires and any voltage study on an unmodified
      import is OPTIMISTIC. `:gen_power_factor` opts into a synthesized
      capability and says so in `:synthesized`.
    * **No reactive demand on loads.** `p_set` is real; there is no `q_set`.
      Synthesized at `:load_power_factor` (default 0.95), which is the same
      fiction `Ingestion.LoadEstimator` applies to our own network — and
      therefore the reason this reader does NOT stamp `load_compensation: 0.0`
      the way `Test.MATPOWER` does. A published MATPOWER case states Qd NET of
      distribution capacitors, so compensating it again double-counts; a
      synthesized 0.95 has no compensation in it yet, so the model default
      correctly applies. Getting that backwards is REVIEW's compensation seam
      in reverse.

  ## Units

  PyPSA is SI with per-unit transformer reactance. This reader converts to the
  solver's convention (per-unit on `:base_mva`, MW/MVAr):

      Z_base = v_nom^2 / base_mva
      r_pu   = r_ohmkm * length / num_parallel / Z_base
      b_pu   = 2*pi*f * (c_nfkm * 1e-9 * length * num_parallel) * Z_base

  Transformer `x` is already per-unit on the transformer's own `s_nom`, so it
  is rebased by `base_mva / s_nom` — NOT treated as ohms, which would be wrong
  by four orders of magnitude.

  Lines whose per-km columns are blank fall back to the standard type library
  (`line_types.csv`, Oeding & Oswald via PyPSA) keyed on the `type` string;
  204 of scigrid-de's 852 lines need it.
  """

  require Logger

  NimbleCSV.define(PyPSAParser, separator: ",", escape: "\"")

  @base_mva 100.0
  @default_frequency 50.0
  @load_power_factor 0.95

  @doc """
  Read a PyPSA CSV export directory.

  Options:
    * `:base_mva` — per-unit base, default #{@base_mva}
    * `:snapshot` — index into the time series for `p_set`, default 0
    * `:load_power_factor` — for synthesized load Q, default #{@load_power_factor}
    * `:gen_power_factor` — synthesize generator q limits at this pf; default
      `nil`, meaning unconstrained
    * `:line_types` — path to a `line_types.csv`; defaults to `line_types.csv`
      inside `dir` when present

  Returns the snapshot map plus `:source`, `:synthesized` and `:dropped` so a
  caller can see what was invented and what was discarded.
  """
  @spec load!(Path.t(), keyword()) :: map()
  def load!(dir, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, @base_mva)
    snapshot_idx = Keyword.get(opts, :snapshot, 0)
    load_pf = Keyword.get(opts, :load_power_factor, @load_power_factor)
    gen_pf = Keyword.get(opts, :gen_power_factor)

    bus_rows = read_csv!(Path.join(dir, "buses.csv"))
    types = line_types(dir, opts)

    # PyPSA keys everything by NAME, which is a string. Solver code indexes
    # buses positionally off an integer id, so map names to ids once and keep
    # the name alongside for traceability back to the source row.
    id_by_name =
      bus_rows |> Enum.with_index(1) |> Map.new(fn {row, i} -> {row["name"], i} end)

    buses =
      Enum.map(bus_rows, fn row ->
        %{
          id: Map.fetch!(id_by_name, row["name"]),
          name: row["name"],
          base_kv: num(row["v_nom"]) || 0.0,
          bus_type: bus_type(row["control"]),
          vm_pu: 1.0,
          va_rad: 0.0,
          gs_mw: 0.0,
          bs_mvar: 0.0,
          lon: num(row["x"]),
          lat: num(row["y"])
        }
      end)

    kv_by_id = Map.new(buses, &{&1.id, &1.base_kv})

    {lines, dropped_lines} =
      dir
      |> Path.join("lines.csv")
      |> read_csv!()
      |> Enum.with_index(1)
      |> Enum.map(&line(&1, id_by_name, kv_by_id, types, base_mva))
      |> split_dropped()

    {transformers, dropped_transformers} =
      dir
      |> Path.join("transformers.csv")
      |> read_csv_optional()
      |> Enum.with_index(1)
      |> Enum.map(&transformer(&1, id_by_name, base_mva))
      |> split_dropped()

    {generators, dropped_generators} =
      dir
      |> Path.join("generators.csv")
      |> read_csv_optional()
      |> Enum.with_index(1)
      |> Enum.map(&generator(&1, id_by_name, gen_pf))
      |> split_dropped()

    p_set = time_series(Path.join(dir, "loads-p_set.csv"), snapshot_idx)
    nominal_hz = nominal_frequency(lines, opts)

    {loads, dropped_loads} =
      dir
      |> Path.join("loads.csv")
      |> read_csv_optional()
      |> Enum.with_index(1)
      |> Enum.map(&load(&1, id_by_name, p_set, load_pf))
      |> split_dropped()

    %{
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads,
      base_mva: base_mva,
      source: {:pypsa, Path.basename(Path.expand(dir))},
      snapshot_index: snapshot_idx,
      # Stamped so `Grid.SystemStandard.compatible!/2` can refuse to run a
      # 50 Hz network through the 60 Hz protection model. Steady-state power
      # flow is unaffected — frequency enters only through line charging, which
      # is already handled above — but every UFLS and ride-through threshold in
      # this repo is North American, and a healthy 50 Hz system sits below all
      # of them.
      nominal_hz: nominal_hz,
      system_standard: PowerModel.Grid.SystemStandard.for_frequency(nominal_hz),
      # Deliberately NOT `load_compensation: 0.0` — see the moduledoc. Load Q
      # here is synthesized at a flat power factor with no compensation netted
      # out, exactly like our own network, so the model default applies.
      synthesized: %{
        load_q_power_factor: load_pf,
        generator_q_power_factor: gen_pf,
        generator_q_limits: if(gen_pf, do: :synthesized, else: :unconstrained)
      },
      dropped: %{
        lines: dropped_lines,
        transformers: dropped_transformers,
        generators: dropped_generators,
        loads: dropped_loads
      }
    }
  end

  # ── rows ────────────────────────────────────────────────────────────────

  defp line({row, idx}, id_by_name, kv_by_id, types, base_mva) do
    with {:ok, from} <- bus_id(row["bus0"], id_by_name),
         {:ok, to} <- bus_id(row["bus1"], id_by_name),
         kv when is_number(kv) and kv > 0.0 <- Map.get(kv_by_id, from),
         length_km when is_number(length_km) <- num(row["length"]),
         {:ok, %{r: r_km, x: x_km, c: c_km}} <- per_km(row, types) do
      n = max(num(row["num_parallel"]) || 1.0, 1.0e-6)
      f = num(row["frequency"]) || @default_frequency
      z_base = kv * kv / base_mva

      # Farads for the whole circuit group: capacitance adds in parallel, so it
      # scales UP with num_parallel while series impedance scales down.
      c_farad = c_km * 1.0e-9 * length_km * n
      b_siemens = 2.0 * :math.pi() * f * c_farad

      %{
        id: idx,
        name: row["name"],
        from_bus_id: from,
        to_bus_id: to,
        voltage_kv: (num(row["voltage"]) || kv * 1000.0) / 1000.0,
        r_pu: r_km * length_km / n / z_base,
        x_pu: x_km * length_km / n / z_base,
        b_pu: b_siemens * z_base,
        rating_a_mva: num(row["s_nom"]),
        length_km: length_km,
        num_parallel: n,
        frequency_hz: f,
        status: "in_service",
        source: "pypsa"
      }
    else
      _ -> {:dropped, row["name"]}
    end
  end

  defp transformer({row, idx}, id_by_name, base_mva) do
    with {:ok, from} <- bus_id(row["bus0"], id_by_name),
         {:ok, to} <- bus_id(row["bus1"], id_by_name),
         x when is_number(x) <- num(row["x"]),
         s_nom when is_number(s_nom) and s_nom > 0.0 <- num(row["s_nom"]) do
      # PyPSA transformer impedance is per-unit on the transformer's OWN s_nom.
      rebase = base_mva / s_nom

      %{
        id: idx,
        name: row["name"],
        from_bus_id: from,
        to_bus_id: to,
        r_pu: (num(row["r"]) || 0.0) * rebase,
        x_pu: x * rebase,
        rated_mva: s_nom,
        tap_ratio: num(row["tap_ratio"]) || 1.0,
        status: "in_service"
      }
    else
      _ -> {:dropped, row["name"]}
    end
  end

  defp generator({row, idx}, id_by_name, gen_pf) do
    with {:ok, bus} <- bus_id(row["bus"], id_by_name),
         p_nom when is_number(p_nom) <- num(row["p_nom"]) do
      {q_max, q_min} = gen_q_limits(p_nom, gen_pf)

      %{
        id: idx,
        name: row["name"],
        bus_id: bus,
        p_max_mw: p_nom,
        capacity_factor: 1.0,
        q_max_mvar: q_max,
        q_min_mvar: q_min,
        fuel_type: row["carrier"],
        status: "in_service"
      }
    else
      _ -> {:dropped, row["name"]}
    end
  end

  defp load({row, idx}, id_by_name, p_set, load_pf) do
    with {:ok, bus} <- bus_id(row["bus"], id_by_name),
         p_mw when is_number(p_mw) <- Map.get(p_set, row["name"]) do
      %{
        id: idx,
        name: row["name"],
        bus_id: bus,
        p_mw: p_mw,
        q_mvar: p_mw * q_ratio(load_pf),
        load_type: "constant_power",
        status: "in_service"
      }
    else
      _ -> {:dropped, row["name"]}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # tan(acos(pf)) — MVAr per MW at that power factor.
  defp q_ratio(pf) when is_number(pf) and pf > 0.0 and pf <= 1.0,
    do: :math.tan(:math.acos(pf))

  defp q_ratio(_), do: 0.0

  defp gen_q_limits(_p_nom, nil), do: {nil, nil}

  defp gen_q_limits(p_nom, pf) do
    q = abs(p_nom) * q_ratio(pf)
    {q, -q}
  end

  defp bus_type("Slack"), do: 3
  defp bus_type("PV"), do: 2
  defp bus_type(_), do: 1

  defp bus_id(nil, _map), do: :error
  defp bus_id("", _map), do: :error

  defp bus_id(name, map) do
    case Map.fetch(map, name) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  # Explicit per-km columns win; the standard type library is the fallback.
  defp per_km(row, types) do
    r = num(row["r_ohmkm"])
    x = num(row["x_ohmkm"])
    c = num(row["c_nfkm"])

    cond do
      is_number(r) and is_number(x) ->
        {:ok, %{r: r, x: x, c: c || 0.0}}

      is_map_key(types, row["type"]) ->
        {:ok, Map.fetch!(types, row["type"])}

      true ->
        :error
    end
  end

  defp line_types(dir, opts) do
    path = Keyword.get(opts, :line_types, Path.join(dir, "line_types.csv"))

    if File.regular?(path) do
      path
      |> read_csv!()
      |> Map.new(fn row ->
        {row["name"],
         %{
           r: num(row["r_per_length"]) || 0.0,
           x: num(row["x_per_length"]) || 0.0,
           c: num(row["c_per_length"]) || 0.0
         }}
      end)
    else
      %{}
    end
  end

  # Wide time series: first column is the snapshot index, the rest are
  # component names.
  defp time_series(path, idx) do
    if File.regular?(path) do
      [header | rows] = path |> File.read!() |> PyPSAParser.parse_string(skip_headers: false)
      names = tl(header)

      case Enum.at(rows, idx) do
        nil -> %{}
        row -> names |> Enum.zip(tl(row)) |> Map.new(fn {n, v} -> {n, num(v)} end)
      end
    else
      %{}
    end
  end

  defp read_csv!(path) do
    [header | rows] = path |> File.read!() |> PyPSAParser.parse_string(skip_headers: false)
    Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
  end

  defp read_csv_optional(path), do: if(File.regular?(path), do: read_csv!(path), else: [])

  defp split_dropped(rows) do
    {dropped, kept} = Enum.split_with(rows, &match?({:dropped, _}, &1))
    {kept, Enum.map(dropped, fn {:dropped, name} -> name end)}
  end

  # The modal `frequency` across imported lines. PyPSA carries it per branch
  # rather than per network, and a mixed set would mean two synchronous areas in
  # one file, so the mode is the honest summary and the caller can override.
  defp nominal_frequency(lines, opts) do
    case Keyword.get(opts, :nominal_hz) do
      hz when is_number(hz) ->
        hz * 1.0

      _ ->
        lines
        |> Enum.map(&Map.get(&1, :frequency_hz))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.max_by(&elem(&1, 1), fn -> {@default_frequency, 0} end)
        |> elem(0)
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
