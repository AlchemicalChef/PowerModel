defmodule PowerModel.Ingestion.HvdcTies do
  @moduledoc """
  Curated table of North American HVDC links, ingested as scheduled injections
  (`PowerModel.Grid.DcTie`) rather than as AC branches. ROADMAP item 13.

  ## Why this table exists

  `PowerModel.Grid.in_service_lines/1` excludes `line_type == "dc"` rows from
  every AC snapshot (REVIEW LIN-6): a DC link carries a flow set by its
  converter controls, not by a series impedance, so modeling the Pacific DC
  Intertie as a very large AC line let it absorb Western north–south flow that
  in reality rides the AC paths. That exclusion deletes the links from the
  model without putting anything back. **This module is what puts them back.**
  The two changes are a pair — read them together.

  ## What is and is not here

  Only links whose two converter stations both sit inside the modeled US grid,
  plus the ERCOT ties whose far terminal is in the Eastern interconnection.

  The US–Mexico back-to-back ties (Eagle Pass, Laredo VFT / Railroad, Laredo
  B2B, McAllen/Sharyland) are NOT here: `PowerModel.Ingestion.InternationalConnections`
  already creates them, with foreign boundary buses and equivalent import
  generators behind them. Listing them again would double-count every megawatt
  crossing the border.

  ERCOT's **North** DC tie and its **Oklaunion** tie are one facility, not two —
  the North tie *is* the converter at Oklaunion, TX. It appears once.

  ## Schedules

  `schedule_mw` is a nominal typical flow in the link's normal direction, not a
  real-time value; each entry cites where the number comes from. Firm-contract
  links (PDCI, Intermountain, CU, Square Butte, Neptune, Cross Sound) have a
  well-defined usual direction. The ERCOT ties are market-driven and reverse
  frequently, so their nominal values are deliberately modest fractions of
  converter capacity and should be read as placeholders until scheduled
  interchange data replaces them.

  In this table each tie is described by the ROLE of its terminals —
  `receiving_*` and `sending_*` — so no reader has to track a sign. The
  receiving terminal becomes `from_bus_id` with a POSITIVE `schedule_mw`,
  which is `DcTie`'s convention (positive = injection at `from_bus`).

  ## Measured coverage (2026-08-15)

  All eight ties resolve a converter bus, but how many reach a *snapshot*
  depends on connectivity, not on this table. Against the current database:

    * **Western** — both ties (PDCI, Intermountain) land with BOTH terminals
      inside the simulated component. Net injection is therefore zero and the
      effect is pure redistribution: 1,442 of 3,587 branches shift by more
      than 1 MW once the PDCI's 3,100 MW stops riding the AC paths.
    * **Eastern** — all four ties land only their SENDING terminal; the
      receiving ends (Dickinson MN, Duffy Avenue, Shoreham) are outside the
      largest connected component. They are correctly modeled as 1,940 MW of
      export: that power really does leave the modeled region, and the load it
      serves is missing from the snapshot too.
    * **ERCOT** — both ties resolve an ERCOT converter bus, but those buses
      are outside ERCOT's simulated component, so no tie reaches the snapshot.

  ROADMAP item 12 (connectivity repair) is what brings the rest in; nothing
  here needs to change for that to happen.
  """

  import Ecto.Query
  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, DcTie, Interconnection}

  # Converter stations are well-surveyed sites, so a tight radius is right; a
  # miss is more informative than a silent snap to something 200 km away.
  @snap_radius_m 40_000

  # Highest real transmission voltage in North America. A bus above this is bad
  # voltage data (REVIEW LIN-12: Western carries a bogus 765 kV+ class), and a
  # converter must not land on one.
  @max_plausible_kv 765.0

  # Minimum AC terminal voltage for a converter of a given size. An HVDC
  # converter terminates on a bus that could plausibly carry its schedule;
  # putting a 3 GW injection on a 138 kV distribution-adjacent bus produces
  # flows that are an artifact of the snap, not of the grid. Thresholds follow
  # the class thermal ratings in
  # `PowerModel.Ingestion.ParameterEstimator` — 230 kV carries ~450 MVA per
  # circuit, 345 kV ~900, 500 kV ~1,800.
  @terminal_kv_floors [{1500.0, 345.0}, {800.0, 230.0}, {300.0, 138.0}, {0.0, 69.0}]

  @ties [
    # ── Western ──────────────────────────────────────────────────────
    %{
      name: "Pacific DC Intertie (Celilo–Sylmar)",
      # Sylmar Converter Station, Los Angeles CA (inverter for N→S flow)
      receiving_coords: {-118.48, 34.31},
      receiving_interconnection: "Western",
      # Celilo Converter Station, The Dalles OR
      sending_coords: {-120.97, 45.62},
      sending_interconnection: "Western",
      # +/-500 kV, 3,220 MW after the 2016 BPA/LADWP converter replacement
      # (1,440 MW at 1970 commissioning, 3,100 MW after the 1989 uprate).
      # WECC Path 65. Normal direction is north to south.
      rating_mva: 3220.0,
      schedule_mw: 3100.0
    },
    %{
      name: "Intermountain Power Project HVDC (IPP–Adelanto)",
      # Adelanto Converter Station, Adelanto CA
      receiving_coords: {-117.44, 34.57},
      receiving_interconnection: "Western",
      # Intermountain Generating Station, Delta UT
      sending_coords: {-112.58, 39.51},
      sending_interconnection: "Western",
      # LADWP Southern Transmission System, +/-500 kV. 1,920 MW as built
      # (1986), 2,400 MW after the uprate. WECC Path 27. Utah to California.
      rating_mva: 2400.0,
      schedule_mw: 1800.0
    },

    # ── Eastern: Dakotas → Minnesota lignite exports ─────────────────
    %{
      name: "CU HVDC (Coal Creek–Dickinson)",
      # Dickinson Converter Station, Dickinson Township near Buffalo MN
      receiving_coords: {-93.86, 45.17},
      receiving_interconnection: "Eastern",
      # Coal Creek Station, Underwood ND
      sending_coords: {-101.13, 47.38},
      sending_interconnection: "Eastern",
      # Great River Energy CU Project, +/-400 kV, 1,000 MW, in service 1979.
      rating_mva: 1000.0,
      schedule_mw: 950.0
    },
    %{
      name: "Square Butte HVDC (Center–Arrowhead)",
      # Arrowhead Converter Station, Hermantown MN (Duluth)
      receiving_coords: {-92.23, 46.81},
      receiving_interconnection: "Eastern",
      # Milton R. Young / Square Butte, Center ND
      sending_coords: {-101.20, 47.06},
      sending_interconnection: "Eastern",
      # Minnkota Power / Square Butte Electric, +/-250 kV, 500 MW,
      # in service 1977.
      rating_mva: 500.0,
      schedule_mw: 450.0
    },

    # ── Eastern: submarine cables into Long Island ───────────────────
    %{
      name: "Neptune RTS (Sayreville–Duffy Avenue)",
      # Duffy Avenue substation, Hicksville NY (Long Island)
      receiving_coords: {-73.52, 40.74},
      receiving_interconnection: "Eastern",
      # Sayreville NJ converter station (PJM side)
      sending_coords: {-74.35, 40.47},
      sending_interconnection: "Eastern",
      # Neptune Regional Transmission System, +/-500 kV, 660 MW, in service
      # 2007. Firm delivery to LIPA under a long-term contract, so it runs
      # essentially at capacity toward Long Island.
      rating_mva: 660.0,
      schedule_mw: 660.0
    },
    %{
      name: "Cross Sound Cable (New Haven–Shoreham)",
      # Shoreham NY (Long Island)
      receiving_coords: {-72.88, 40.96},
      receiving_interconnection: "Eastern",
      # New Haven CT (ISO-NE side)
      sending_coords: {-72.91, 41.29},
      sending_interconnection: "Eastern",
      # +/-150 kV, 330 MW, in service 2002 (continuous commercial 2004).
      # Bidirectional, but normal commitment is toward Long Island.
      rating_mva: 330.0,
      schedule_mw: 330.0
    },

    # ── ERCOT DC ties to the Eastern interconnection ─────────────────
    # ERCOT is asynchronous from the Eastern interconnection; every connection
    # between them is a back-to-back converter. The far terminal is a real
    # Eastern bus, and because a tie is an injection and not a branch it can
    # never fuse the two systems (see PowerModel.Solver.Partition.split/2).
    %{
      name: "ERCOT East DC Tie (Monticello)",
      # ERCOT side, Monticello switchyard, Titus County TX
      receiving_coords: {-95.05, 33.09},
      receiving_interconnection: "ERCOT",
      # SPP/MISO side at the same site
      sending_coords: {-95.05, 33.09},
      sending_interconnection: "Eastern",
      # 600 MW back-to-back, ERCOT's largest tie to the Eastern system.
      # Market-driven and frequently reversed; schedule is a nominal import.
      rating_mva: 600.0,
      schedule_mw: 200.0
    },
    %{
      # ERCOT's "North" DC tie IS the Oklaunion converter — one facility.
      name: "ERCOT North DC Tie (Oklaunion)",
      # ERCOT side, Oklaunion, Wilbarger County TX
      receiving_coords: {-99.13, 34.11},
      receiving_interconnection: "ERCOT",
      # SPP side at the same site
      sending_coords: {-99.13, 34.11},
      sending_interconnection: "Eastern",
      # 220 MW back-to-back to SPP. Market-driven; nominal import.
      rating_mva: 220.0,
      schedule_mw: 100.0
    }
  ]

  @source "hvdc"

  @doc "The curated tie definitions, for inspection and tests."
  def ties, do: @ties

  @doc """
  Upsert every curated tie. Idempotent: reruns update the existing row in
  place (keyed on `source`/`source_id`) rather than inserting duplicates, so
  a corrected schedule or a newly resolvable converter bus takes effect on the
  next ingest.

  Returns `{:ok, %{created: n, updated: n, unresolved: [names]}}`. A tie whose
  RECEIVING converter cannot be located is skipped entirely — a tie with no
  bus at either end injects nothing and would only be a confusing row. A tie
  whose SENDING converter cannot be located is still created, with
  `to_bus_id` nil: that is the ordinary "far end outside the model" case.
  """
  def run do
    interconnections = interconnection_ids()

    result =
      Enum.reduce(@ties, %{created: 0, updated: 0, unresolved: []}, fn tie, acc ->
        case upsert_tie(tie, interconnections) do
          {:ok, :created} -> %{acc | created: acc.created + 1}
          {:ok, :updated} -> %{acc | updated: acc.updated + 1}
          {:error, :unresolved} -> %{acc | unresolved: [tie.name | acc.unresolved]}
        end
      end)

    result = %{result | unresolved: Enum.reverse(result.unresolved)}

    Logger.info(
      "HVDC ties: #{result.created} created, #{result.updated} updated, " <>
        "#{length(result.unresolved)} unresolved of #{length(@ties)} curated"
    )

    # One line, not one per tie: REVIEW DAT-20 measured that OTP's logger
    # overload protection silently drops ~90% of large per-row warning bursts.
    if result.unresolved != [] do
      Logger.warning(
        "HVDC ties skipped (no bus within #{div(@snap_radius_m, 1000)} km of the receiving " <>
          "converter): #{Enum.join(result.unresolved, "; ")}"
      )
    end

    {:ok, result}
  end

  defp upsert_tie(tie, interconnections) do
    from_bus =
      find_converter_bus(
        tie.receiving_coords,
        Map.get(interconnections, tie.receiving_interconnection),
        tie.rating_mva
      )

    if is_nil(from_bus) do
      {:error, :unresolved}
    else
      to_bus =
        find_converter_bus(
          tie.sending_coords,
          Map.get(interconnections, tie.sending_interconnection),
          tie.rating_mva
        )

      # A back-to-back converter whose two terminals snapped to the same bus
      # would be a self-tie injecting and withdrawing in one place. Drop the
      # far end instead; the near-end injection is the part that matters.
      to_bus_id = if to_bus && to_bus.id != from_bus.id, do: to_bus.id

      source_id = slug(tie.name)
      existing = Repo.get_by(DcTie, source: @source, source_id: source_id)

      attrs = %{
        name: tie.name,
        from_bus_id: from_bus.id,
        to_bus_id: to_bus_id,
        schedule_mw: tie.schedule_mw,
        rating_mva: tie.rating_mva,
        status: "in_service",
        source: @source,
        source_id: source_id
      }

      {:ok, _} = (existing || %DcTie{}) |> DcTie.changeset(attrs) |> Repo.insert_or_update()

      {:ok, if(existing, do: :updated, else: :created)}
    end
  end

  @doc """
  The bus a converter of `rating_mva` at `coords` terminates on.

  Three constraints, in order of what they protect against:

    * **Interconnection** — the search is confined to the terminal's own
      system, so a back-to-back tie whose two converters share a site cannot
      resolve both ends onto the same side of an asynchronous seam (which
      would make the tie a self-loop injecting nothing).
    * **Voltage floor and ceiling** — the bus must be able to plausibly carry
      the schedule (`@terminal_kv_floors`) and must not be one of the
      bad-voltage rows above `@max_plausible_kv` (REVIEW LIN-12).
    * **Nearest of the adequate** — among the survivors the CLOSEST wins, with
      the highest voltage breaking ties for buses sharing a site. Ranking
      voltage ahead of distance instead would drag a 330 MW cable onto
      whatever 500 kV bus happens to be within the radius; the floor is what
      keeps a converter off a bus too small to carry it, and distance is what
      keeps it at its own substation.
  """
  def find_converter_bus(coords, interconnection_id, rating_mva \\ 0.0)

  def find_converter_bus(_coords, nil, _rating), do: nil

  def find_converter_bus({lon, lat}, interconnection_id, rating_mva) do
    point = %Geo.Point{coordinates: {lon, lat}, srid: 4326}
    floor_kv = terminal_kv_floor(rating_mva)

    from(b in Bus,
      where:
        b.interconnection_id == ^interconnection_id and
          b.base_kv >= ^floor_kv and b.base_kv <= ^@max_plausible_kv and
          fragment(
            "ST_DWithin(?::geography, ?::geography, ?)",
            b.coordinates,
            ^point,
            ^@snap_radius_m
          ),
      order_by: [
        asc: fragment("ST_Distance(?::geography, ?::geography)", b.coordinates, ^point),
        desc: b.base_kv,
        desc: fragment("(? = 'substation')", b.source),
        asc: b.id
      ],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Minimum AC terminal voltage for a converter of the given size, in kV."
  def terminal_kv_floor(rating_mva) do
    rating = rating_mva || 0.0
    {_threshold, kv} = Enum.find(@terminal_kv_floors, fn {mva, _kv} -> rating >= mva end)
    kv
  end

  defp interconnection_ids do
    Interconnection |> Repo.all() |> Map.new(&{&1.name, &1.id})
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim_trailing("_")
  end
end
