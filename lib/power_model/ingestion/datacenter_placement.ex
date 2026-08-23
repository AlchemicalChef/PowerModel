defmodule PowerModel.Ingestion.DatacenterPlacement do
  @moduledoc """
  Where a datacenter campus connects to the grid (DAT-22).

  The rule this replaces was "nearest bus of any kind within 30 km", with no
  voltage, no capability and no yard consolidation — the rule `LoadEstimator`
  was rewritten away from for exactly the same reasons, and worse here because
  the MW involved is not a spatial weight that a demand scaler can rescale.
  `Demand.scale_loads/3` holds datacenter load FLAT (a campus runs 24/7 and its
  MW is subtracted from its BA's demand before the hourly factor is computed),
  so a badly placed campus is badly placed at every hour of every study, at
  full size. It put 400 MW on a 13.8 kV bus, 350 MW on a PV bus with no branch
  at all, and 15,850 MW across 43 campuses standing above the class ceiling of
  the bus under them.

  ## The two rules

  **An interconnection floor**, from the campus's size. A load this size is a
  transmission customer and the utility builds it a dedicated interconnection;
  nobody serves 400 MW off a distribution feeder. The floor is not a new table
  — it is read off `LoadEstimator`'s delivery ceilings, as the lowest class
  whose ceiling is worth building for:

      <= 50 MW    -> 60 kV   the load-serving floor; a small colocation hall is
                             an ordinary sub-transmission customer
      <= 250 MW   -> 100 kV  above one 69 kV yard's 50 MW delivery ceiling
      >  250 MW   -> 230 kV  above the 161-229 kV class ceiling

  The floor stops at 230 kV rather than continuing to 345 and 500: past this
  point the constraint that bites is how much one yard can deliver, not what
  class the campus interconnects at, and that is the ceiling's job. Requiring
  500 kV for the largest campuses would exile them — Council Bluffs sits in a
  345 kV part of MISO and has no 500 kV bus anywhere near it.

  **The delivery ceiling**, per yard, exactly as `LoadEstimator` applies it:
  `min(0.8 x connected capability, class ceiling)`. A campus takes ONE
  interconnection whenever a yard in reach can carry the whole of it — the
  nearest such yard, even if a closer one could have taken part of it, since
  two feeds 20 m apart in reach of a substation that could have served the
  campus outright is a modelling artifact rather than how it gets built. Only
  when no single yard fits is the campus **split across the nearest eligible
  yards**, which is what happens on the ground too: a 900 MW campus takes
  several transmission feeds, frequently from different substations.

  ## Two circuits

  A yard is preferred only if it carries at least TWO lines of its own. A
  campus of this size is not interconnected off a single circuit — one trip
  would take the whole of it — and the old rule left 600 MW hanging on a
  degree-1 345 kV bus. A campus that finds nothing meshed at any radius falls
  back to a single-line yard rather than going unplaced, and the census's
  "radial above 200 MW" section is where that shows.

  ## Search

  Start at `max_km` and DOUBLE the radius until eligible headroom appears,
  rather than dropping to a lower class the moment the first ring comes up
  empty — a campus 40 km from a 230 kV yard interconnects to that yard, not to
  the 69 kV tap next door. Three campuses need more than 30 km; none needs more
  than 60. Past `#{120}` km the search gives up and the campus stays unmapped
  rather than being parked somewhere arbitrary.

  ## Ordering

  Campuses are placed **largest first**. High-voltage headroom near a
  datacenter cluster is scarce and shared, and a 60 MW hall taking a 230 kV
  yard's ceiling first can strand the 900 MW campus behind it. Within a campus,
  yards fill nearest-first, so the split stays local.

  ## What this pass does NOT reserve

  Headroom is measured against the class ceiling alone, not against the
  synthetic baseline `LoadEstimator` has already spread onto the same buses.
  The campus is the real, sited, immovable thing and the county spread is the
  filler: `LoadEstimator.committed_load_by_bus/0` subtracts datacenter MW from
  its own ceilings, so re-running the estimator after this pass is what makes
  the two agree. Run it in that order — this pass, then `estimate_loads` — or
  the buses this pass fills keep whatever share of their county they were
  holding.

  ## The anchor bus

  `Datacenter.bus_id` records the yard carrying the LARGEST share, not the
  whole campus. The `loads` rows carry the real split. A consumer that needs
  exact partial-loss behaviour for a split campus (`get_datacenters_for_buses/1`
  has no caller today) would need a campus-to-bus share table; at present two
  campuses are split, into two yards each.
  """

  import Ecto.Query
  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.{Datacenter, Load}
  alias PowerModel.Ingestion.LoadEstimator

  # Interconnection floor, keyed on campus MW. See the moduledoc: each entry is
  # the class above the delivery ceiling of the class below it.
  # MW below which a remainder is rounding, not load.
  @mw_epsilon 1.0e-6

  @interconnection_floor_kv [
    {250.0, 230.0},
    {50.0, 100.0},
    {0.0, 60.0}
  ]

  # Widen to here before giving up. 60 km covers every campus on the ingested
  # network; the rest is headroom for a fleet that grows.
  @max_search_km 120.0

  @doc """
  Re-map every active campus and rebuild its `datacenter` load rows.

  Returns `{mapped, load_rows, unmapped}` to keep
  `Grid.map_datacenters_to_grid/1`'s contract.
  """
  def run(opts \\ []) do
    %{allocations: allocations, unmapped: unmapped, partial: partial} = allocate(opts)

    {mapped, load_rows} =
      Repo.transaction(fn -> write(allocations) end) |> then(fn {:ok, result} -> result end)

    if unmapped != [] do
      Logger.warning(
        "#{length(unmapped)} datacenter campus(es) found no yard at or above their " <>
          "interconnection floor within #{@max_search_km} km: " <>
          Enum.map_join(Enum.take(unmapped, 5), ", ", & &1.name)
      )
    end

    if partial != [] do
      lost = Enum.reduce(partial, 0.0, fn p, acc -> acc + (p.mw - p.placed_mw) end)

      Logger.warning(
        "#{length(partial)} datacenter campus(es) could not be placed in full within " <>
          "#{@max_search_km} km — #{Float.round(lost, 1)} MW has no yard with headroom and is " <>
          "NOT in the load table: " <>
          Enum.map_join(Enum.take(partial, 5), ", ", fn p ->
            "#{p.name} (#{Float.round(p.placed_mw, 1)} of #{Float.round(p.mw, 1)} MW)"
          end)
      )
    end

    {mapped, load_rows, length(unmapped)}
  end

  @doc """
  Work out the placement without writing it.

  `%{allocations: [%{datacenter_id, name, mw, placed_mw, shares: [%{bus_id, mw,
  km}]}], unmapped: [campus], partial: [%{name, mw, placed_mw}]}`.

  `partial` is campuses that found SOME yard but not enough headroom for their
  whole load even at `#{@max_search_km}` km. They are not `unmapped` — rows are
  written for what fit — and before this list existed the remainder simply
  vanished: the campus reported as mapped, `unmapped` stayed 0, and
  `Datacenter.power_mw` no longer equalled the sum of its load rows. Losing
  load is allowed here only because the alternative is inventing delivery
  capacity that does not exist; losing it SILENTLY is not.
  """
  def allocate(opts \\ []) do
    max_km = Keyword.get(opts, :max_km, 30) * 1.0
    campuses = campuses()
    yards = yards()

    # Largest first: high-voltage headroom is shared and scarce, and a small
    # hall that takes a 230 kV yard's ceiling can strand the campus behind it.
    # The id breaks ties so a re-run places the fleet the same way.
    campuses
    |> Enum.sort_by(&{-&1.mw, &1.id})
    |> Enum.reduce(%{used: %{}, allocations: [], unmapped: [], partial: []}, fn campus, acc ->
      case place(campus, yards, acc.used, max_km) do
        [] ->
          %{acc | unmapped: [campus | acc.unmapped]}

        shares ->
          used =
            Enum.reduce(shares, acc.used, fn s, used ->
              Map.update(used, s.bus_id, s.mw, &(&1 + s.mw))
            end)

          placed_mw = placed(shares)

          entry = %{
            datacenter_id: campus.id,
            name: campus.name,
            mw: campus.mw,
            placed_mw: placed_mw,
            shares: shares
          }

          partial =
            if placed_mw < campus.mw - @mw_epsilon do
              [%{name: campus.name, mw: campus.mw, placed_mw: placed_mw} | acc.partial]
            else
              acc.partial
            end

          %{acc | used: used, allocations: [entry | acc.allocations], partial: partial}
      end
    end)
    |> then(fn acc ->
      %{
        allocations: Enum.reverse(acc.allocations),
        unmapped: Enum.reverse(acc.unmapped),
        partial: Enum.reverse(acc.partial)
      }
    end)
  end

  @doc """
  The lowest transmission class a campus of `mw` is interconnected at.
  """
  def interconnection_floor_kv(mw) when is_number(mw) and mw > 0.0 do
    {_mw, kv} = Enum.find(@interconnection_floor_kv, fn {over, _kv} -> mw > over end)
    kv
  end

  # A non-positive or non-numeric MW has no band, and `Enum.find/2` returning
  # nil made this documented public function raise an opaque MatchError. The
  # lowest floor is the answer that cannot over-constrain a placement.
  def interconnection_floor_kv(_),
    do: @interconnection_floor_kv |> Enum.map(&elem(&1, 1)) |> Enum.min()

  # ---------------------------------------------------------------------------
  # Placement
  # ---------------------------------------------------------------------------

  # Fill the nearest eligible yards until the campus is placed, doubling the
  # search radius while nothing eligible has room. `[]` means the campus found
  # no yard at or above its floor inside @max_search_km.
  defp place(campus, yards, used, max_km) do
    floor_kv = interconnection_floor_kv(campus.mw)

    # A campus big enough to matter is not interconnected off a single circuit:
    # the utility builds it two, because one trip otherwise takes the whole
    # campus. Tried first over the whole search; a campus that finds nothing
    # meshed anywhere falls back rather than going unplaced, and the census's
    # radial section is where that shows up.
    case search(campus, yards, used, floor_kv, 2, max_km) do
      [] -> search(campus, yards, used, floor_kv, 1, max_km)
      shares -> shares
    end
  end

  defp search(campus, yards, used, floor_kv, min_lines, radius_km)
       when radius_km <= @max_search_km do
    open = eligible(campus, yards, used, floor_kv, min_lines, radius_km)
    shares = fill(open, campus.mw)

    # Widen while the reachable yards cannot take the WHOLE campus, not merely
    # while none is reachable. `split_fill/2` fills what it can and returns; if
    # the caller accepted that as a placement, the remainder vanished — the
    # campus reported as mapped, `unmapped` stayed 0, and `Datacenter.power_mw`
    # no longer equalled the sum of its load rows. A farther yard that could
    # have taken the rest was never searched.
    if placed(shares) >= campus.mw - @mw_epsilon do
      shares
    else
      case search(campus, yards, used, floor_kv, min_lines, radius_km * 2.0) do
        [] -> shares
        wider -> if placed(wider) > placed(shares), do: wider, else: shares
      end
    end
  end

  defp search(_campus, _yards, _used, _floor_kv, _min_lines, _radius_km), do: []

  defp placed(shares), do: Enum.reduce(shares, 0.0, &(&2 + &1.mw))

  # Eligible yards, nearest first: at or above the campus's floor, inside the
  # radius, with headroom left after everything already placed this pass, and
  # ONE bus per substation — its lowest qualifying level, since that is the
  # level a load is delivered from.
  defp eligible(campus, yards, used, floor_kv, min_lines, radius_km) do
    radius_m = radius_km * 1000.0

    yards
    # `is_number/1` first: `nil >= floor_kv` is TRUE under Elixir term ordering
    # (atoms sort above numbers), so a voltage-less bus would clear every floor.
    |> Enum.filter(
      &(is_number(&1.base_kv) and &1.base_kv >= floor_kv and &1.line_degree >= min_lines)
    )
    |> Enum.map(&{&1, distance_m(campus.lon, campus.lat, &1.lon, &1.lat)})
    |> Enum.filter(fn {_yard, d} -> d <= radius_m end)
    |> Enum.group_by(fn {yard, _d} -> yard.yard_key end)
    |> Enum.map(fn {_key, levels} ->
      Enum.min_by(levels, fn {yard, _d} -> {yard.base_kv, yard.id} end)
    end)
    |> Enum.map(fn {yard, d} ->
      %{
        bus_id: yard.id,
        km: d / 1000.0,
        headroom: max(yard.delivery_cap_mw - Map.get(used, yard.id, 0.0), 0.0)
      }
    end)
    |> Enum.filter(&(&1.headroom > 1.0e-6))
    |> Enum.sort_by(&{&1.km, &1.bus_id})
  end

  # A campus takes ONE interconnection when one yard in reach can carry it, even
  # if a nearer yard could carry part: two feeds 20 m apart in reach of a
  # substation that could have taken the whole campus is a modelling artifact,
  # not how it gets built. `open` is nearest-first, so this picks the nearest
  # yard that fits. Only when none fits does the campus split.
  defp fill([], _mw), do: []

  defp fill(open, mw) do
    case Enum.find(open, &(&1.headroom >= mw - @mw_epsilon)) do
      nil -> split_fill(open, mw)
      yard -> [%{bus_id: yard.bus_id, mw: mw, km: Float.round(yard.km, 2)}]
    end
  end

  defp split_fill(open, mw) do
    {shares, _left} =
      Enum.reduce_while(open, {[], mw}, fn yard, {shares, left} ->
        if left <= @mw_epsilon do
          {:halt, {shares, left}}
        else
          take = min(left, yard.headroom)

          {:cont,
           {[%{bus_id: yard.bus_id, mw: take, km: Float.round(yard.km, 2)} | shares], left - take}}
        end
      end)

    Enum.reverse(shares)
  end

  # ---------------------------------------------------------------------------
  # Inputs
  # ---------------------------------------------------------------------------

  defp campuses do
    from(d in Datacenter,
      where: d.status == "active" and not is_nil(d.coordinates) and d.power_mw > 0.0,
      select: %{
        id: d.id,
        name: d.name,
        mw: d.power_mw,
        lon: fragment("ST_X(?)", d.coordinates),
        lat: fragment("ST_Y(?)", d.coordinates)
      }
    )
    |> Repo.all(timeout: :infinity)
  end

  # The buses a campus may connect to: PQ, geolocated, and carrying a LINE of
  # their own. A bus reached only through banks is the far side of a
  # transformer, not a point the network delivers from — the same test
  # `LoadEstimator` applies, and the reason a 350 MW campus was sitting on a
  # branchless PV bus.
  defp yards do
    network = LoadEstimator.network()
    caps = LoadEstimator.capability(network)

    network.buses
    |> Enum.filter(fn bus ->
      cap = Map.get(caps, bus.id)

      bus.bus_type == 1 and not is_nil(bus.lon) and cap != nil and cap.line_degree > 0 and
        cap.delivery_cap_mw > 0.0
    end)
    |> Enum.map(fn bus ->
      %{
        id: bus.id,
        lon: bus.lon,
        lat: bus.lat,
        base_kv: bus.base_kv,
        delivery_cap_mw: Map.fetch!(caps, bus.id).delivery_cap_mw,
        line_degree: Map.fetch!(caps, bus.id).line_degree,
        yard_key: LoadEstimator.yard_key(bus)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  @q_ratio :math.tan(:math.acos(0.95))

  defp write(allocations) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # The anchor FK: the yard carrying the largest share. A campus that found
    # nowhere loses its bus_id rather than keeping a stale one.
    placed_ids =
      Enum.map(allocations, fn %{datacenter_id: id, shares: shares} ->
        anchor = Enum.max_by(shares, & &1.mw)
        Repo.update_all(from(d in Datacenter, where: d.id == ^id), set: [bus_id: anchor.bus_id])
        id
      end)

    from(d in Datacenter, where: d.status == "active" and d.id not in ^placed_ids)
    |> Repo.update_all(set: [bus_id: nil])

    Repo.delete_all(from l in Load, where: l.load_type == "datacenter")

    rows =
      allocations
      |> Enum.flat_map(& &1.shares)
      |> Enum.reduce(%{}, fn s, acc -> Map.update(acc, s.bus_id, s.mw, &(&1 + s.mw)) end)
      |> Enum.map(fn {bus_id, p_mw} ->
        %{
          bus_id: bus_id,
          p_mw: Float.round(p_mw, 2),
          q_mvar: Float.round(p_mw * @q_ratio, 2),
          load_type: "datacenter",
          status: "in_service",
          inserted_at: now,
          updated_at: now
        }
      end)

    {load_rows, _} = Repo.insert_all(Load, rows)
    {length(placed_ids), load_rows}
  end

  # ---------------------------------------------------------------------------
  # Geometry
  # ---------------------------------------------------------------------------

  @earth_radius_m 6_371_000.0

  defp distance_m(lon1, lat1, lon2, lat2) do
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    mean_lat = (lat1 + lat2) / 2.0 * :math.pi() / 180.0

    x = dlon * :math.cos(mean_lat)
    @earth_radius_m * :math.sqrt(x * x + dlat * dlat)
  end
end
