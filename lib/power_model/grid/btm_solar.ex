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
end
