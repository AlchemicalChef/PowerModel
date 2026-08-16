defmodule PowerModel.Grid.BtmSolar do
  @moduledoc """
  Behind-the-meter (rooftop/distributed) solar PV capacity sitting at a bus.

  ## Why this table exists

  All 122.9 GW of PV in the EIA-860 fleet is utility-metered plant. The ~50 GW
  of US rooftop PV appears nowhere as generation — and it is not missing from
  the energy balance, because EIA-930 demand is metered NET of behind-the-meter
  output. Rooftop already lives invisibly inside the demand signal the model
  replays.

  ## THE REPRESENTATION RULE (the double-counting guard)

  Conceptually this layer is a bus-level **gross-up/generation pair**: the load
  a bus really carries is `EIA-930 net demand + btm_output`, with `btm_output`
  injected back at the same bus.

  **NEITHER SIDE OF THAT PAIR IS MATERIALIZED.** It cancels exactly, so the
  snapshot carries plain EIA-930 net demand and NO BTM generator exists in
  `snapshot.generators`. There is nothing to find and nothing to subtract:

  > Solvers and load scaling MUST NOT read `:btm_solar`. Every steady-state
  > solve is byte-identical whether the layer is present or absent.

  Reading `output_mw` as extra generation (or grossing the load up without
  injecting the output back) double-counts rooftop against demand that already
  nets it out. The layer exists so that *something that perturbs* `output_mw` —
  IEEE 1547 inverter tripping during a cascade (ROADMAP item 31), a cloud-cover
  scenario — has a quantity to perturb. Until something perturbs it, it is
  inert by construction. `test/power_model/grid/btm_solar_identity_test.exs`
  pins this.

  ### Corollary for anything that trips BTM

  Because nothing is materialized, **tripping rooftop is a LOAD INCREASE, not a
  generation loss**. "Remove the generation" is a silent no-op — that generator
  was never in the snapshot. To trip, ADD the lost `output_mw` to the load at
  the same bus. That is the Blue Cut mechanism, and it is the entire reason
  this table exists.

  Three things that follow, for callers doing the tripping:

    * Trip against `output_mw`, never `capacity_mw`. Capacity is nameplate;
      output is what is actually flowing and therefore what disappears.
    * A bus appears once per sector (up to three rows), so aggregate per bus
      before applying or the same bus is handled three times.
    * `output_mw == 0.0` is correct, not an error — night hours, a BA with no
      fuel data, a bus with no BA. Tripping a zero-output entry is a legitimate
      no-op, which is physically right: rooftop tripping at 3am releases
      nothing. The vicious 59.3 Hz pairing (an island shedding its legacy
      rooftop fleet before the first UFLS stage arms) is a DAYTIME phenomenon.

  ## Rows

  One row per `{bus_id, sector}`. Capacity is the SUM of every EIA-861 utility
  whose service territory reaches that bus, so `utility_id`/`state` name only
  the largest contributor (provenance). See
  `PowerModel.Ingestion.EIA.Form861` for the allocation chain.

  Data caveat: these rows never read the `generators` table, but a >= 1 MW C&I
  rooftop array can be reported BOTH here (via 861's non-net-metered file) and
  as an EIA-860 onsite unit (`utility_scale: false`). The overlap is bounded
  above by the whole onsite PV fleet — ~0.75 GW of 55.8 GW, about 1.3% — and is
  harmless in steady state, where the rule above holds regardless. It matters
  only to a caller tripping BTM, where at worst that fraction of tripped MW is
  also modeled as a dispatchable onsite unit.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias PowerModel.Repo

  @sectors ~w(residential commercial industrial)

  # EIA-860 fuel code for solar. The BTM hourly shape is the BA's own
  # utility-solar capacity factor, so the denominator is the capability of the
  # units whose output EIA-930 reports in its solar column.
  @solar_fuel_code "SUN"

  # ROADMAP item 31: the share of the BTM fleet on IEEE 1547-2003 inverters,
  # which MUST trip at 59.3 Hz / 0.88 pu, versus 1547-2018 units that must ride
  # through. Carried on every snapshot entry so the cascade never has to guess.
  # Configurable until per-vintage EIA-861 history can refine it:
  #
  #     config :power_model, :btm_legacy_fraction, 0.30
  @default_legacy_fraction 0.30

  schema "btm_solar" do
    field :sector, :string
    field :capacity_mw, :float
    field :state, :string
    field :utility_id, :string

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(btm_solar, attrs) do
    btm_solar
    |> cast(attrs, [:bus_id, :sector, :capacity_mw, :state, :utility_id])
    |> validate_required([:sector, :capacity_mw])
    |> validate_inclusion(:sector, @sectors)
    |> validate_number(:capacity_mw, greater_than_or_equal_to: 0.0)
    |> unique_constraint([:bus_id, :sector])
    |> foreign_key_constraint(:bus_id)
  end

  @doc "The sector values a row may carry."
  def sectors, do: @sectors

  @doc """
  Share of BTM capacity on legacy (IEEE 1547-2003, must-trip) inverters.

  Override with `config :power_model, :btm_legacy_fraction, 0.25`. Clamped to
  [0, 1] — a nonsense config value must not hand the cascade a negative or
  greater-than-whole fleet.
  """
  def legacy_fraction do
    :power_model
    |> Application.get_env(:btm_legacy_fraction, @default_legacy_fraction)
    |> clamp01(@default_legacy_fraction)
  end

  @doc """
  Expand stored capacity rows into snapshot entries for `hour`.

  Returns a list of

      %{bus_id: id, sector: s, capacity_mw: mw, output_mw: mw, legacy_fraction: f}

  `output_mw` is `capacity_mw` times the capacity factor of the bus's own
  balancing authority for that hour — the BA's EIA-930 utility-solar net
  generation divided by its utility-solar capability, clamped to [0, 1]. Same
  sun falls on the rooftops as on the BA's solar farms; a Phase 5 HRRR
  irradiance upgrade replaces this proxy.

  Nil-safe by design, because a snapshot must assemble regardless of data
  coverage: a nil `hour`, a BA with no fuel row for that hour, a bus with no
  BA, and a BA with no solar capability ALL yield `output_mw: 0.0`. Zero output
  is the correct inert state — the representation rule means it changes no
  solve. One summary line reports how much capacity fell back (DAT-20: never a
  line per row).

  Options:

    * `:bus_to_ba` — precomputed `%{bus_id => ba_code}`, to skip the lookup
      when the caller already holds the buses.
  """
  def output_at(entries, hour, opts \\ [])

  def output_at([], _hour, _opts), do: []

  def output_at(entries, hour, opts) do
    fraction = legacy_fraction()

    # Rows whose bus was deleted are stranded capacity, not grid capacity.
    entries = Enum.reject(entries, &is_nil(Map.get(&1, :bus_id)))

    cf_by_bus = capacity_factor_by_bus(entries, hour, opts)

    Enum.map(entries, fn entry ->
      capacity = Map.get(entry, :capacity_mw) || 0.0
      cf = Map.get(cf_by_bus, Map.get(entry, :bus_id), 0.0)

      %{
        bus_id: Map.get(entry, :bus_id),
        sector: Map.get(entry, :sector),
        capacity_mw: capacity,
        output_mw: capacity * cf,
        legacy_fraction: fraction
      }
    end)
  end

  # No hour requested: the snapshot is not pinned to a moment, so there is no
  # insolation to shape by.
  defp capacity_factor_by_bus(_entries, nil, _opts), do: %{}

  defp capacity_factor_by_bus(entries, %DateTime{} = hour, opts) do
    bus_ids = entries |> Enum.map(&Map.get(&1, :bus_id)) |> Enum.uniq()
    bus_to_ba = opts[:bus_to_ba] || bus_to_ba(bus_ids)

    cf_by_ba =
      bus_to_ba
      |> Map.values()
      |> Enum.uniq()
      |> capacity_factors(hour)

    {cf_by_bus, uncovered_mw} =
      Enum.reduce(entries, {%{}, 0.0}, fn entry, {acc, uncovered} ->
        bus_id = Map.get(entry, :bus_id)

        case bus_to_ba[bus_id] && cf_by_ba[bus_to_ba[bus_id]] do
          nil -> {acc, uncovered + (Map.get(entry, :capacity_mw) || 0.0)}
          cf -> {Map.put(acc, bus_id, cf), uncovered}
        end
      end)

    if uncovered_mw > 0.0 do
      Logger.debug(fn ->
        "BTM solar: #{Float.round(uncovered_mw, 1)} MW of capacity has no BA solar " <>
          "data for #{DateTime.to_iso8601(hour)}; held at 0 MW output."
      end)
    end

    cf_by_bus
  end

  # BA capacity factor = EIA-930 utility-solar net generation / utility-solar
  # capability. Both sides come from the BA's own fleet, so systematic biases
  # (AC vs DC rating, curtailment) largely divide out.
  defp capacity_factors([], _hour), do: %{}

  defp capacity_factors(ba_codes, hour) do
    ba_codes = Enum.reject(ba_codes, &is_nil/1)
    generation = solar_generation(ba_codes, hour)
    capability = solar_capability(ba_codes, hour)

    for code <- ba_codes,
        gen = generation[code],
        cap = capability[code],
        not is_nil(gen) and not is_nil(cap) and cap > 0.0,
        into: %{} do
      {code, clamp01(gen / cap, 0.0)}
    end
  end

  defp solar_generation(ba_codes, hour) do
    hour = DateTime.truncate(hour, :second)

    from(f in PowerModel.Demand.BAFuelHour,
      where: f.fuel == "solar" and f.ba_code in ^ba_codes and f.timestamp_utc == ^hour,
      select: {f.ba_code, f.net_generation_mw}
    )
    |> Repo.all()
    |> Map.new()
  end

  # EIA-860 seasonal net capability, nameplate as the fallback EIA did not
  # report one for (~0.3% of units).
  #
  # UTILITY-SCALE ONLY, to match the numerator: EIA-930's solar column reports
  # utility-scale generation, and `PowerModel.Dispatch` allocates it to
  # utility-scale units on the same grounds (ROADMAP item 29). Including the
  # onsite fleet (325 PV units / 0.74 GW nationally) would divide utility-scale
  # generation by a larger capability and bias every rooftop capacity factor
  # low. NULL means the unit never went through the EIA-860 ingest — MATPOWER
  # imports, import pseudo-generators — and reads as utility-scale, which is
  # the convention item 29 established.
  defp solar_capability(ba_codes, hour) do
    season_field = if hour.month in 4..9, do: :summer_capacity_mw, else: :winter_capacity_mw

    from(g in PowerModel.Grid.Generator,
      join: b in PowerModel.Grid.Bus,
      on: g.bus_id == b.id,
      join: ba in PowerModel.Grid.BalancingAuthority,
      on: b.balancing_authority_id == ba.id,
      where: g.status == "in_service" and g.fuel_type == ^@solar_fuel_code,
      where: is_nil(g.utility_scale) or g.utility_scale,
      where: ba.code in ^ba_codes,
      group_by: ba.code,
      select: {ba.code, sum(coalesce(field(g, ^season_field), g.p_max_mw))}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp bus_to_ba([]), do: %{}

  defp bus_to_ba(bus_ids) do
    from(b in PowerModel.Grid.Bus,
      join: ba in PowerModel.Grid.BalancingAuthority,
      on: b.balancing_authority_id == ba.id,
      where: b.id in ^bus_ids,
      select: {b.id, ba.code}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp clamp01(value, _fallback) when is_number(value) do
    cond do
      value < 0.0 -> 0.0
      value > 1.0 -> 1.0
      true -> value * 1.0
    end
  end

  defp clamp01(_value, fallback), do: fallback

  # ===========================================================================
  # IEEE 1547 voltage trips — the voltage half of Blue Cut (ROADMAP item 31)
  # ===========================================================================

  # Voltage trip functions, as `{element, side, threshold_pu, clearing_s}`,
  # most severe first per side. `side` is the pickup test: `:under` picks up
  # below the threshold, `:over` at or above it.
  #
  # ## Legacy — IEEE Std 1547-2003, Table 1 (Interconnection system response
  # to abnormal voltages), transcribed verbatim:
  #
  #     Voltage range (% of base)   Clearing time (s)
  #            V < 50                     0.16
  #          50 <= V < 88                 2.00
  #         110 < V < 120                 1.00
  #           V >= 120                    0.16
  #
  # Maximum clearing times for DR <= 30 kW, default clearing times above that —
  # i.e. exactly the rooftop fleet this table models. This is the SAME table
  # that gives the 59.3 Hz frequency must-trip (1547-2003 Table 2, DR <= 30 kW),
  # so the two halves of the Blue Cut mechanism come from one standard and one
  # vintage.
  #
  # ## Modern — IEEE Std 1547-2018 must-trip settings
  #
  # 1547-2018 replaces the single table with per-category defaults (Tables 11,
  # 12 and 13 for Categories I, II and III), naming the four elements UV2/UV1/
  # OV1/OV2, which is why they are named that here:
  #
  #                    2003    Cat I   Cat II   Cat III
  #     OV2 (pu)        1.2      1.2     1.2      1.2      clearing 0.16 s all
  #     OV1 (pu)        1.1      1.1     1.1      1.1      1 / 2 / 2 / 13 s
  #     UV1 (pu)       0.88      0.7     0.7     0.88      2 / 2 / 10 / 21 s
  #     UV2 (pu)        0.5     0.45    0.45      0.5      0.16 / 0.16 / 0.16 / 2 s
  #
  # These are must-trip settings, the direct successor of the 2003 table, NOT
  # the ride-through obligations of clause 6.4.2 — a DER in the mandatory or
  # permissive operation regions is doing something more nuanced than "still
  # connected", and none of that nuance survives into a bus-level MW number.
  #
  # The default modern category is III, not II, and the choice is load-bearing:
  # Category II's UV2 sits at 0.45 pu with a 0.16 s clearing time, so a 0.40 pu
  # bus trips a Category II fleet almost as fast as a legacy one, while
  # Category III holds it for 2 s. NERC's reliability guidance on adopting
  # 1547-2018 recommends Category III precisely because bulk-system events are
  # the case that matters, and that is the case this model simulates.
  @voltage_trip_settings %{
    legacy: [
      {:uv2, :under, 0.50, 0.16},
      {:uv1, :under, 0.88, 2.00},
      {:ov2, :over, 1.20, 0.16},
      {:ov1, :over, 1.10, 1.00}
    ],
    category_i: [
      {:uv2, :under, 0.45, 0.16},
      {:uv1, :under, 0.70, 2.00},
      {:ov2, :over, 1.20, 0.16},
      {:ov1, :over, 1.10, 2.00}
    ],
    category_ii: [
      {:uv2, :under, 0.45, 0.16},
      {:uv1, :under, 0.70, 10.0},
      {:ov2, :over, 1.20, 0.16},
      {:ov1, :over, 1.10, 2.00}
    ],
    category_iii: [
      {:uv2, :under, 0.50, 2.00},
      {:uv1, :under, 0.88, 21.0},
      {:ov2, :over, 1.20, 0.16},
      {:ov1, :over, 1.10, 13.0}
    ]
  }

  @default_modern_category :category_iii

  @vintages [:legacy, :modern]

  @doc """
  The IEEE 1547 voltage trip functions for a vintage, as
  `[{element, side, threshold_pu, clearing_s}]`.

  `vintage` is `:legacy` (1547-2003 Table 1), or `:category_i`,
  `:category_ii`, `:category_iii` (1547-2018 Tables 11/12/13). Single source
  of truth for the thresholds.
  """
  def voltage_trip_settings(vintage \\ :legacy)

  def voltage_trip_settings(vintage) when is_map_key(@voltage_trip_settings, vintage),
    do: Map.fetch!(@voltage_trip_settings, vintage)

  @doc """
  The 1547-2018 abnormal-operating-performance category the modern share of
  the fleet is assumed to carry. Override with

      config :power_model, :btm_modern_category, :category_ii
  """
  def modern_category do
    category = Application.get_env(:power_model, :btm_modern_category, @default_modern_category)

    if is_map_key(@voltage_trip_settings, category) and category != :legacy do
      category
    else
      @default_modern_category
    end
  end

  @doc """
  Fold snapshot entries into a per-bus fleet split by inverter vintage:

      %{bus_id => %{legacy_mw: float(), modern_mw: float()}}

  The input is `output_at/3`'s shape. Splitting is by each entry's own
  `legacy_fraction` (falling back to `legacy_fraction/0`), so the split is
  applied once per row and the per-bus totals are summed afterwards — a bus
  appears once per sector and must not be handled three times.

  Buses with nothing to lose are dropped rather than carried as zeros: night
  hours, a BA with no fuel row, a bus with no BA. That is the common, correct
  state and it costs a caller nothing to be absent.

  Note this splits `output_mw`, never `capacity_mw` — capacity is nameplate,
  output is what is actually flowing and therefore what disappears.
  """
  @spec fleet_by_bus(list(map())) :: map()
  def fleet_by_bus(entries) do
    default_fraction = legacy_fraction()

    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      bus_id = Map.get(entry, :bus_id)
      output_mw = Map.get(entry, :output_mw) || 0.0
      fraction = Map.get(entry, :legacy_fraction) || default_fraction

      if is_nil(bus_id) or output_mw <= 0.0 do
        acc
      else
        legacy = output_mw * fraction

        Map.update(
          acc,
          bus_id,
          %{legacy_mw: legacy, modern_mw: output_mw - legacy},
          fn current ->
            %{
              legacy_mw: current.legacy_mw + legacy,
              modern_mw: current.modern_mw + (output_mw - legacy)
            }
          end
        )
      end
    end)
    |> Map.filter(fn {_bus_id, mw} -> mw.legacy_mw > 0.0 or mw.modern_mw > 0.0 end)
  end

  @doc """
  A fresh BTM voltage-protection state: no bus has armed a timer, nothing has
  tripped.

  Shape:

      %{
        buses: %{
          bus_id => %{
            legacy: %{timers: %{element => seconds}, tripped: boolean()},
            modern: %{timers: %{element => seconds}, tripped: boolean()}
          }
        },
        elapsed_s: float()
      }

  Keyed by BUS, exactly like `PowerModel.Failure.Cascade`'s existing
  `btm_tripped_buses` set, which is why it survives island re-splits without
  apportioning: see `split_voltage_state/2`.
  """
  @spec fresh_voltage_state() :: map()
  def fresh_voltage_state, do: %{buses: %{}, elapsed_s: 0.0}

  @doc """
  Advance the IEEE 1547 voltage protection of a behind-the-meter fleet over
  one `dt_s` segment.

  Returns `{trips_by_bus, state}`.

  ## Parameters

    * `fleet_by_bus` — `%{bus_id => %{legacy_mw:, modern_mw:}}`, from
      `fleet_by_bus/1`. This is what is still THERE to lose; buses whose
      vintage the state already records as tripped are skipped whatever the
      map says.
    * `vm_by_bus` — a `%{bus_id => vm_pu}` map, or a single float applied to
      every bus. A bus MISSING from the map has no measurement: its timers are
      held exactly as they were rather than reset, because a missing reading
      is not a recovered voltage.
    * `state` — from a previous call, or `nil`
    * `dt_s` — simulated seconds this segment advanced

  ## Options

    * `:modern_category` — override `modern_category/0` for this call

  ## Returns

  `trips_by_bus` is `%{bus_id => detail}`, one entry per bus that lost
  something THIS segment:

      %{
        tripped_mw: float(),                     # legacy + modern
        by_vintage: %{legacy: float(), modern: float()},
        vm_pu: float(),
        elements: [%{vintage:, element:, threshold_pu:, clearing_s:, time_s:}]
      }

  Use `tripped_mw_by_bus/1` for the flat `%{bus_id => mw}` a gross-up needs,
  and `voltage_trip_event/1` for one island-level event.

  ## Tripped BTM is a LOAD INCREASE

  See the module doc's representation rule. Nothing is materialized, so
  "remove the generation" is a silent no-op — the caller must ADD
  `tripped_mw` to the load at the same bus. Identical mechanism to the 59.3 Hz
  frequency trip; only the cause differs.

  ## Timer semantics: definite-time, resets on dropout

  Each element is an ordinary definite-time relay: it times up while picked
  up and resets to zero the moment the voltage clears its threshold. It fires
  when its accumulated time REACHES the clearing time, because 1547 states a
  time by which the DER must have ceased to energize.

  This is the opposite convention from
  `PowerModel.Failure.Protection.generator_voltage_trips/4`, whose PRC-024
  timers are cumulative across an excursion and fire only once the allowance
  is EXCEEDED. The asymmetry is real and deliberate: PRC-024 draws a no-trip
  zone a generator must stay inside, 1547 sets a deadline an inverter must
  clear by.
  """
  @spec voltage_trips(map(), map() | number(), map() | nil, number(), keyword()) ::
          {map(), map()}
  def voltage_trips(fleet_by_bus, vm_by_bus, state, dt_s, opts \\ []) do
    state = state || fresh_voltage_state()
    dt = max(dt_s * 1.0, 0.0)

    settings = %{
      legacy: voltage_trip_settings(:legacy),
      modern: voltage_trip_settings(Keyword.get(opts, :modern_category) || modern_category())
    }

    {bus_states, trips} =
      Enum.reduce(fleet_by_bus, {state.buses, %{}}, fn {bus_id, mw}, {acc, trips} ->
        case bus_voltage(vm_by_bus, bus_id) do
          nil ->
            {acc, trips}

          vm_pu ->
            advance_bus_vintages(bus_id, mw, vm_pu, dt, settings, acc, trips)
        end
      end)

    {trips, %{state | buses: bus_states, elapsed_s: state.elapsed_s + dt}}
  end

  defp advance_bus_vintages(bus_id, mw, vm_pu, dt, settings, acc, trips) do
    prior = Map.get(acc, bus_id) || fresh_bus_voltage_state()

    {advanced, fired} =
      Enum.reduce(@vintages, {prior, []}, fn vintage, {bus_state, fired} ->
        vintage_state = Map.fetch!(bus_state, vintage)
        available = vintage_mw(mw, vintage)

        if vintage_state.tripped or available <= 0.0 do
          {bus_state, fired}
        else
          timers =
            advance_elements(vintage_state.timers, Map.fetch!(settings, vintage), vm_pu, dt)

          case fired_element(timers, Map.fetch!(settings, vintage)) do
            nil ->
              {Map.put(bus_state, vintage, %{vintage_state | timers: timers}), fired}

            element ->
              {Map.put(bus_state, vintage, %{timers: timers, tripped: true}),
               [{vintage, available, element} | fired]}
          end
        end
      end)

    acc = Map.put(acc, bus_id, advanced)

    case fired do
      [] -> {acc, trips}
      fired -> {acc, Map.put(trips, bus_id, trip_detail(fired, vm_pu))}
    end
  end

  defp trip_detail(fired, vm_pu) do
    by_vintage =
      Enum.reduce(fired, %{legacy: 0.0, modern: 0.0}, fn {vintage, mw, _element}, acc ->
        Map.update!(acc, vintage, &(&1 + mw))
      end)

    %{
      tripped_mw: by_vintage.legacy + by_vintage.modern,
      by_vintage: by_vintage,
      vm_pu: vm_pu,
      elements:
        Enum.map(fired, fn {vintage, _mw, {element, _side, threshold, clearing, time_s}} ->
          %{
            vintage: vintage,
            element: element,
            threshold_pu: threshold,
            clearing_s: clearing,
            time_s: time_s
          }
        end)
    }
  end

  defp vintage_mw(mw, :legacy), do: Map.get(mw, :legacy_mw) || 0.0
  defp vintage_mw(mw, :modern), do: Map.get(mw, :modern_mw) || 0.0

  defp fresh_bus_voltage_state do
    Map.new(@vintages, fn vintage -> {vintage, %{timers: %{}, tripped: false}} end)
  end

  # A definite-time element times up while picked up and resets on dropout.
  defp advance_elements(timers, settings, vm_pu, dt) do
    Map.new(settings, fn {element, side, threshold, _clearing} ->
      if picked_up?(side, vm_pu, threshold) do
        {element, Map.get(timers, element, 0.0) + dt}
      else
        {element, 0.0}
      end
    end)
  end

  defp picked_up?(:under, vm_pu, threshold), do: vm_pu < threshold
  defp picked_up?(:over, vm_pu, threshold), do: vm_pu >= threshold

  # Settings are listed most severe first, so the first element to have
  # reached its clearing time is the one to report.
  defp fired_element(timers, settings) do
    Enum.find_value(settings, fn {element, side, threshold, clearing} ->
      time_s = Map.get(timers, element, 0.0)

      if time_s >= clearing and clearing > 0.0 do
        {element, side, threshold, clearing, time_s}
      end
    end)
  end

  defp bus_voltage(voltages, _bus_id) when is_number(voltages), do: voltages * 1.0
  defp bus_voltage(voltages, bus_id) when is_map(voltages), do: Map.get(voltages, bus_id)
  defp bus_voltage(_voltages, _bus_id), do: nil

  @doc """
  Flatten `voltage_trips/5`'s result to the `%{bus_id => mw}` a load gross-up
  needs.
  """
  @spec tripped_mw_by_bus(map()) :: map()
  def tripped_mw_by_bus(trips_by_bus) do
    Map.new(trips_by_bus, fn {bus_id, detail} -> {bus_id, detail.tripped_mw} end)
  end

  @doc """
  Record a trip that happened by some other route into a voltage state, so the
  voltage protection cannot trip the same megawatts a second time.

  This is the double-counting guard between the two Blue Cut halves. The
  frequency trip lives in the cascade and knows nothing about these timers; if
  a bus loses its legacy fleet at 59.3 Hz, marking it here stops the voltage
  side from tripping it again when the voltage sags a step later.

  `vintages` defaults to `[:legacy]`, which is what the 59.3 Hz frequency
  must-trip takes.
  """
  @spec mark_tripped(map() | nil, term(), list(atom())) :: map()
  def mark_tripped(state, bus_id, vintages \\ [:legacy]) do
    state = state || fresh_voltage_state()
    bus_state = Map.get(state.buses, bus_id) || fresh_bus_voltage_state()

    bus_state =
      Enum.reduce(vintages, bus_state, fn vintage, acc ->
        Map.put(acc, vintage, %{timers: %{}, tripped: true})
      end)

    %{state | buses: Map.put(state.buses, bus_id, bus_state)}
  end

  @doc """
  Restrict a voltage state to a set of bus ids — the SPLIT half of island
  state threading.

  These timers are keyed by bus and are INTENSIVE: "this bus has been below
  0.88 pu for 1.4 s" is a property of the bus, not a quantity to share out. So
  unlike the frequency state's cumulative megawatts, which
  `PowerModel.Failure.Cascade` apportions by load share on a split, this needs
  no scaling — partitioning by key is the whole operation, and every timer is
  conserved exactly.
  """
  @spec split_voltage_state(map() | nil, Enumerable.t()) :: map()
  def split_voltage_state(nil, _bus_ids), do: fresh_voltage_state()

  def split_voltage_state(state, bus_ids) do
    keep = MapSet.new(bus_ids)

    %{state | buses: Map.filter(state.buses, fn {id, _} -> MapSet.member?(keep, id) end)}
  end

  @doc """
  Combine voltage states from islands that have re-joined — the MERGE half.

  Islands partition the bus set, so no key should appear twice; a collision is
  still resolved deterministically, with a tripped vintage staying tripped and
  the longer-timed entry otherwise winning, so a merge can never hand a bus
  back ride-through time it has already spent.
  """
  @spec merge_voltage_states(list(map() | nil)) :: map()
  def merge_voltage_states(states) do
    states
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(fresh_voltage_state(), fn state, acc ->
      %{
        buses: Map.merge(acc.buses, state.buses, &merge_bus_voltage_state/3),
        elapsed_s: max(acc.elapsed_s, Map.get(state, :elapsed_s, 0.0))
      }
    end)
  end

  defp merge_bus_voltage_state(_bus_id, a, b) do
    Map.new(@vintages, fn vintage ->
      {vintage, merge_vintage_state(Map.fetch!(a, vintage), Map.fetch!(b, vintage))}
    end)
  end

  defp merge_vintage_state(a, b) do
    cond do
      a.tripped -> a
      b.tripped -> b
      max_timer(a) >= max_timer(b) -> a
      true -> b
    end
  end

  defp max_timer(%{timers: timers}), do: timers |> Map.values() |> Enum.max(fn -> 0.0 end)

  @doc """
  One island-level event for a segment's voltage trips, or `nil` when nothing
  tripped.

  ONE event for the whole island, never one per bus: a national snapshot has
  tens of thousands of BTM buses and per-bus events would bury every other
  cause in the timeline (the DAT-20 counter pattern). Matches the shape of the
  cascade's existing frequency-caused `"btm_trip"` event, with the cause
  carried in `failure_cause` and repeated in `details.cause` so a breakdown
  can group on it without string matching.
  """
  @spec voltage_trip_event(map()) :: map() | nil
  def voltage_trip_event(trips_by_bus) when map_size(trips_by_bus) == 0, do: nil

  def voltage_trip_event(trips_by_bus) do
    details = Map.values(trips_by_bus)
    tripped_mw = details |> Enum.map(& &1.tripped_mw) |> Enum.sum()

    %{
      component_type: "btm_solar",
      component_id: trips_by_bus |> Map.keys() |> Enum.min(),
      failure_cause: "btm_voltage_trip",
      details: %{
        cause: :voltage,
        tripped_mw: tripped_mw,
        bus_count: map_size(trips_by_bus),
        legacy_mw: details |> Enum.map(& &1.by_vintage.legacy) |> Enum.sum(),
        modern_mw: details |> Enum.map(& &1.by_vintage.modern) |> Enum.sum(),
        vm_pu_min: details |> Enum.map(& &1.vm_pu) |> Enum.min()
      }
    }
  end

  @doc """
  A fresh cause-tagged breakdown of tripped behind-the-meter megawatts.

  Shape `%{frequency_mw:, voltage_mw:, total_mw:}`, with the invariant
  `frequency_mw + voltage_mw == total_mw`.

  ## Why a breakdown rather than a second conservation term

  The cascade's conservation identity is

      served + shed + blackout == original + btm_tripped

  and its SHAPE must not change: `btm_tripped` stays one number, and
  `total_mw` here is exactly that number. The breakdown is a strictly additive
  refinement that says how the one number was arrived at, so a cascade with
  mixed frequency and voltage trips still balances against the same identity
  it balanced against when only the frequency mechanism existed.
  """
  @spec fresh_trip_breakdown() :: map()
  def fresh_trip_breakdown, do: %{frequency_mw: 0.0, voltage_mw: 0.0, total_mw: 0.0}

  @doc """
  Add `mw` of tripped behind-the-meter solar to a breakdown under its cause
  (`:frequency` or `:voltage`).
  """
  @spec record_trip(map() | nil, :frequency | :voltage, number()) :: map()
  def record_trip(breakdown, cause, mw) when cause in [:frequency, :voltage] do
    breakdown = breakdown || fresh_trip_breakdown()
    key = if cause == :frequency, do: :frequency_mw, else: :voltage_mw

    breakdown
    |> Map.update!(key, &(&1 + mw))
    |> Map.update!(:total_mw, &(&1 + mw))
  end

  @doc """
  Does a breakdown still satisfy `frequency_mw + voltage_mw == total_mw`?

  `tolerance_mw` defaults to 1e-6 MW — the accumulation is a sum of floats and
  is expected to drift in the last bits, not to disagree.
  """
  @spec trip_breakdown_balanced?(map(), number()) :: boolean()
  def trip_breakdown_balanced?(breakdown, tolerance_mw \\ 1.0e-6) do
    abs(breakdown.frequency_mw + breakdown.voltage_mw - breakdown.total_mw) <= tolerance_mw
  end
end
