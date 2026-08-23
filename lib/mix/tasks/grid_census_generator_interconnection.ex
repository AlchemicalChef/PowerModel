defmodule Mix.Tasks.Grid.Census.GeneratorInterconnection do
  @moduledoc """
  Whether a plant's output can physically leave the bus it sits on, scored
  against `PowerModel.Reference`.

      mix grid.census generator_interconnection
      mix grid.census generator_interconnection --format json

  This is the generation-side mirror of `load_placement`. That census gates
  load against the per-voltage-class DELIVERY ceiling derived from
  C57.12.00; this one gates generation against the point-of-interconnection
  floor observed in the reference cases.

  ## Why the check is POI voltage and not degree

  The obvious version of this census — "buses holding generation with no line
  of their own" — is WRONG, and measuring it against reference is what showed
  that. 22.4% of `case_ACTIVSg2000`'s buses carry no same-level line, because
  it models every machine at its 13.8 kV terminal behind an explicit step-up.
  A generator bus with no line is normal. What is not normal is a generator
  whose output, having crossed that step-up, still has nowhere to go but
  sub-transmission.

  So the metric is: for each bus carrying generation, the highest voltage
  reachable across ONE branch (line or transformer) — the plant's POI. That
  question has the same meaning under both modelling conventions, which is
  what makes the reference comparison legitimate.

  ## The floor

  `Reference.poi_floor_kv/1` returns the LOWEST POI any reference case uses at
  a given plant size — currently 115 kV above 25 MW, 138 kV above 200 MW,
  230 kV above 800 MW. It is the most permissive reading available, chosen so
  that a flagged bus is one no reference case would produce even at its most
  generous. A 525 MW plant exporting through 69 kV is not a borderline call.

  When the corpus is absent the floor is `nil` and the section reports
  `unscored` rather than passing vacuously.

  ## This is a SCREEN, not a verdict — and it flags two different defects

  A flagged bus is a candidate. Measured 2026-08-23 against a targeted OSM pull
  over the 25 largest flagged yards, cross-checked against escape CAPACITY
  (plant MW vs the summed rating of every branch at its bus):

    * **10 of 25 yards (40.7% of MW) have an OSM circuit ABOVE their floor** —
      a missing higher-voltage circuit, which is what this census is looking
      for.
    * **Most of the rest are still real defects, of a different kind.** Where
      OSM AGREES with the model's escape voltage, the plant genuinely does
      interconnect at 138 kV — but the model gives it far too FEW circuits at
      that voltage. Bus 70528 carries 1,082 MW on ONE 200 MVA branch (5.4x its
      rating); 75342 carries 640 MW on one 116 MVA branch (5.5x).
    * Across the 23 generator buses at those yards, **19 are tight or stranded
      on capacity (13 outright)** — so as a screen for "this plant cannot
      export its output through the modelled network", precision is ~83%, not
      the ~41% the voltage test alone suggests.

  So the voltage test under-reads its own hit rate: it names the right buses
  and mis-names the defect at roughly half of them. Missing parallel circuits
  at the correct voltage and a missing higher-voltage circuit are both "HIFLD
  has too few circuits at this plant", and both are worth finding.

  The floor itself does over-read at the top band, and that is a corpus limit
  (REVIEW DAT-33): >800 MW → 230 kV rests on ten plants across two reference
  cases, neither of which pairs a 138 kV level with a large plant. Real
  practice interconnects large plants at 138 kV routinely.

  Read alongside `mix grid.census stranding`, which scores generation against
  summed branch ratings. That census sees the capacity defect and is blind to
  voltage class; this one sees voltage class and misreads multi-circuit plants.
  Neither subsumes the other, and the cross-check above is what separated the
  two failure modes.

  ## Which graph — this census is DB-wide, unlike its siblings

  `load_placement` defaults to `--graph main-island` and `stranding` offers the
  choice. This one has no `--graph` flag and always measures every bus in the
  database, including components that never reach a simulation. That is the
  right default for a DATA-QUALITY census — a stranded plant in a fragment is
  still a stranded plant — but it means the totals here OVERSTATE what any
  solve sees. Measured 2026-08-23: of the 145 OSM-confirmed yards, 130 fall in
  a simulated island and 15 do not. Compare against a solver result only after
  intersecting with `Grid.get_grid_snapshot/2`.

  ## Sections

    * **below the reference POI floor** — the screen (see the precision note
      above). Plants whose escape voltage is under the floor for their size.
    * **no branch at all** — buses holding generation with neither a line nor
      a transformer. Their MW cannot reach the network under any convention.
    * **load outside the reference bus-kV band** — an OBSERVATION, not a gate.
      Reference models place load
      only between #{"115"} and #{"345"} kV, because they terminate at the
      distribution substation. Ours does not, and the MW outside that band is
      reported here for the same reason.
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.{Grid, Reference, Repo}
  alias PowerModel.Grid.{Bus, Generator, Load, Substation, Transformer, TransmissionLine}

  require Logger

  @shortdoc "Plant output against the reference point-of-interconnection floor"

  @default_limit 20

  # Nominal voltage classes differ by utility within the same class: SCE runs
  # 220 kV where PG&E runs 230, and 66 kV against 69 is the same split one
  # level down. Comparing raw numbers flags those as violations, so the check
  # allows this much slack -- wide enough to absorb a class variant (220/230 =
  # 0.957) and far too narrow to absorb a real class gap (115/138 = 0.833).
  @class_tolerance 0.95

  @switches [interconnection: :keep, format: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [],
      do: Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    format = Keyword.get(opts, :format, "text")

    unless format in ~w(text json),
      do: Mix.raise("--format must be text or json, got #{inspect(format)}")

    # Nothing but JSON may reach stdout in JSON mode -- same rule as the rest
    # of the census family.
    if format == "json", do: Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")
    Logger.configure(level: if(format == "json", do: :warning, else: :info))

    if format == "json" do
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    end

    r = report(opts)

    case format do
      "json" -> IO.puts(Jason.encode!(r, pretty: true))
      "text" -> render_text(r)
    end
  end

  @doc """
  Build the report without printing it. Mirrors the other censuses so tests
  can assert on numbers rather than formatted output.
  """
  def report(opts \\ []) do
    names = Map.new(Repo.all(from s in Substation, select: {s.id, s.name}))

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Grid.list_interconnections()
        given -> Enum.map(given, &fetch_interconnection!/1)
      end

    buses =
      Repo.all(
        from b in Bus,
          select: %{id: b.id, kv: b.base_kv, ic: b.interconnection_id, src: b.source_id}
      )

    kv = Map.new(buses, &{&1.id, &1.kv || 0.0})

    # `from != to` is not decoration: a self-loop would make a bus its own
    # neighbour, so `poi` would report the bus's OWN voltage as its escape and
    # a stranded plant would silently pass. There are zero in service today
    # (checked 2026-08-23) and the export queries filter them for the same
    # reason; this keeps the census honest if they come back.
    branches =
      Repo.all(
        from l in TransmissionLine,
          where:
            l.status == "in_service" and not is_nil(l.from_bus_id) and
              not is_nil(l.to_bus_id) and l.from_bus_id != l.to_bus_id,
          select: {l.from_bus_id, l.to_bus_id, "line"}
      ) ++
        Repo.all(
          from t in Transformer,
            where:
              t.status == "in_service" and not is_nil(t.from_bus_id) and
                not is_nil(t.to_bus_id) and t.from_bus_id != t.to_bus_id,
            select: {t.from_bus_id, t.to_bus_id, "transformer"}
        )

    # Highest voltage reachable across one branch, per bus.
    poi =
      Enum.reduce(branches, %{}, fn {a, b, _kind}, acc ->
        acc
        |> Map.update(a, Map.get(kv, b, 0.0), &max(&1, Map.get(kv, b, 0.0)))
        |> Map.update(b, Map.get(kv, a, 0.0), &max(&1, Map.get(kv, a, 0.0)))
      end)

    gen_by_bus =
      Repo.all(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          group_by: g.bus_id,
          select: {g.bus_id, sum(g.p_max_mw), count(g.id)}
      )
      |> Map.new(fn {bus, mw, n} -> {bus, {(mw || 0.0) * 1.0, n}} end)

    load_by_bus =
      Repo.all(
        from l in Load,
          where: l.status == "in_service",
          group_by: l.bus_id,
          select: {l.bus_id, sum(l.p_mw)}
      )
      |> Map.new(fn {bus, mw} -> {bus, (mw || 0.0) * 1.0} end)

    band = Reference.stats() && get_in(Reference.stats(), ["derived", "load_bus_kv_range"])

    sections =
      Enum.map(interconnections, fn ic ->
        ic_buses = Enum.filter(buses, &(&1.ic == ic.id))

        below =
          ic_buses
          |> Enum.flat_map(fn b ->
            case Map.get(gen_by_bus, b.id) do
              nil ->
                []

              {mw, units} ->
                floor_kv = Reference.poi_floor_kv(mw)
                escape = Map.get(poi, b.id)

                if floor_kv && escape && escape < floor_kv * @class_tolerance do
                  [row(b, names, mw, units, escape, floor_kv)]
                else
                  []
                end
            end
          end)
          |> Enum.sort_by(& &1.mw, :desc)
          |> with_reach()

        unconnected =
          ic_buses
          |> Enum.flat_map(fn b ->
            case Map.get(gen_by_bus, b.id) do
              nil ->
                []

              {mw, units} ->
                if Map.has_key?(poi, b.id), do: [], else: [row(b, names, mw, units, nil, nil)]
            end
          end)
          |> Enum.sort_by(& &1.mw, :desc)

        outside =
          if band do
            [lo, hi] = band

            ic_buses
            |> Enum.flat_map(fn b ->
              mw = Map.get(load_by_bus, b.id, 0.0)
              if mw > 0 and (b.kv < lo or b.kv > hi), do: [{b, mw}], else: []
            end)
          else
            []
          end

        %{
          name: ic.name,
          poi_floor_unscored: is_nil(Reference.poi_floor_kv(1000)),
          below_floor_count: length(below),
          below_floor_mw: sum_mw(below),
          below_floor: below,
          unconnected_count: length(unconnected),
          unconnected_mw: sum_mw(unconnected),
          unconnected: unconnected,
          below_floor_within_50km_mw:
            below
            |> Enum.filter(&(&1[:reach_km] && &1.reach_km <= 50.0))
            |> sum_mw(),
          load_outside_band_buses: length(outside),
          load_outside_band_mw: outside |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> r1(),
          load_below_band_mw:
            outside
            |> Enum.filter(fn {b, _} -> band && b.kv < hd(band) end)
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()
            |> r1(),
          load_above_band_mw:
            outside
            |> Enum.filter(fn {b, _} -> band && b.kv > List.last(band) end)
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()
            |> r1()
        }
      end)

    %{
      census: "generator_interconnection",
      reference_cases: Reference.cases(),
      poi_floor_kv: floor_table(),
      load_bus_kv_band: band,
      interconnections: sections,
      total_below_floor: Enum.sum(Enum.map(sections, & &1.below_floor_count)),
      total_below_floor_mw: sections |> Enum.map(& &1.below_floor_mw) |> Enum.sum() |> r1(),
      total_unconnected_mw: sections |> Enum.map(& &1.unconnected_mw) |> Enum.sum() |> r1(),
      total_load_outside_band_mw:
        sections |> Enum.map(& &1.load_outside_band_mw) |> Enum.sum() |> r1(),
      total_below_floor_within_50km_mw:
        sections |> Enum.map(& &1.below_floor_within_50km_mw) |> Enum.sum() |> r1()
    }
  end

  defp row(b, names, mw, units, escape, floor_kv) do
    yard =
      case b.src do
        nil -> nil
        src -> src |> String.split("_") |> List.first() |> Integer.parse() |> elem_or_nil()
      end

    %{
      bus: b.id,
      kv: b.kv,
      mw: r1(mw),
      units: units,
      escape_kv: escape,
      floor_kv: floor_kv,
      source_id: b.src,
      name: yard && Map.get(names, yard)
    }
  end

  defp elem_or_nil({n, _}), do: n
  defp elem_or_nil(_), do: nil

  # How far is the fix? For each flagged bus, the distance to the nearest bus
  # that already carries lines at or above the floor voltage it needs.
  #
  # This is what turns the section from a tally into a work list: a 525 MW
  # plant whose floor is 29 km away is a missing circuit somebody can go and
  # find, while one with no adequate bus within 200 km is a different problem
  # and should not sit in the same queue.
  defp with_reach([]), do: []

  defp with_reach(rows) do
    Enum.map(rows, fn r ->
      %{rows: found} =
        Repo.query!(
          """
          select b.id, b.base_kv,
                 round((ST_Distance(b.coordinates::geography, o.coordinates::geography) / 1000.0)::numeric, 1)
          from buses b
          cross join (select coordinates from buses where id = $1) o
          where b.id <> $1
            and b.coordinates is not null
            and o.coordinates is not null
            and b.base_kv >= $2
            and exists (
              select 1 from transmission_lines t
              where t.status = 'in_service' and (t.from_bus_id = b.id or t.to_bus_id = b.id)
            )
          order by b.coordinates <-> o.coordinates
          limit 1
          """,
          [r.bus, r.floor_kv * @class_tolerance],
          timeout: :infinity
        )

      case found do
        [[id, kv, km]] -> Map.merge(r, %{reach_bus: id, reach_kv: kv, reach_km: to_float(km)})
        _ -> Map.merge(r, %{reach_bus: nil, reach_kv: nil, reach_km: nil})
      end
    end)
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(x) when is_number(x), do: x * 1.0
  defp to_float(_), do: nil

  defp sum_mw(rows), do: rows |> Enum.map(& &1.mw) |> Enum.sum() |> r1()

  defp r1(x) when is_number(x), do: Float.round(x * 1.0, 1)

  defp floor_table do
    case Reference.stats() do
      %{"derived" => %{"generator_poi_floor_kv" => t}} -> t
      _ -> nil
    end
  end

  defp fetch_interconnection!(name) do
    case Repo.get_by(Grid.Interconnection, name: name) do
      nil -> Mix.raise("no interconnection named #{inspect(name)}")
      ic -> ic
    end
  end

  @doc false
  def render_text(report) do
    IO.puts("""

    ══ generator interconnection census ══
    reference cases: #{Enum.join(report.reference_cases, ", ")}
    POI floor (plant MW above -> minimum kV): #{inspect(report.poi_floor_kv)}
    reference load bus band: #{inspect(report.load_bus_kv_band)} kV
    """)

    if report.poi_floor_kv == nil do
      IO.puts("  UNSCORED: no reference corpus. Run `mix grid.reference_stats`.\n")
    end

    for s <- report.interconnections do
      IO.puts("── #{s.name} ──")

      IO.puts(
        "  below the reference POI floor [SCREEN — see moduledoc; ~83% are tight or " <>
          "stranded on capacity, ~41% specifically missing a higher-voltage circuit]: " <>
          "#{s.below_floor_count} buses, " <>
          "#{s.below_floor_mw} MW (#{s.below_floor_within_50km_mw} MW of it within 50 km of an " <>
          "adequate bus)"
      )

      for r <- Enum.take(s.below_floor, @default_limit) do
        reach =
          if r[:reach_km],
            do: " | #{r.reach_kv}kV bus #{r.reach_bus} is #{r.reach_km}km away",
            else: " | no adequate bus found"

        IO.puts(
          "    bus #{r.bus} kv=#{r.kv} #{r.mw}MW on #{r.units} unit(s) " <>
            "escapes at #{r.escape_kv}kV, floor #{r.floor_kv}kV#{reach}  #{r.name || r.source_id}"
        )
      end

      if s.below_floor_count > @default_limit do
        IO.puts("    ... #{s.below_floor_count - @default_limit} more")
      end

      IO.puts(
        "  generation on a bus with NO branch: #{s.unconnected_count} buses, #{s.unconnected_mw} MW"
      )

      for r <- Enum.take(s.unconnected, 5) do
        IO.puts("    bus #{r.bus} kv=#{r.kv} #{r.mw}MW  #{r.name || r.source_id}")
      end

      IO.puts(
        "  [observation, not a gate] load outside the reference kV band: " <>
          "#{s.load_outside_band_buses} buses, #{s.load_outside_band_mw} MW " <>
          "(#{s.load_below_band_mw} below, #{s.load_above_band_mw} above)"
      )

      IO.puts("")
    end

    IO.puts(
      "TOTAL below the POI floor: #{report.total_below_floor} buses, " <>
        "#{report.total_below_floor_mw} MW — of which " <>
        "#{report.total_below_floor_within_50km_mw} MW sits within 50 km of a bus that " <>
        "already carries lines at the voltage it needs"
    )

    IO.puts("TOTAL generation with no branch: #{report.total_unconnected_mw} MW")

    IO.puts(
      "TOTAL load outside the reference kV band: #{report.total_load_outside_band_mw} MW " <>
        "(observation: reference models terminate at the distribution substation and this " <>
        "one does not, so a large number here is a CONVENTION difference until something " <>
        "ties it to a defect)"
    )
  end
end
