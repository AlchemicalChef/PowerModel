defmodule PowerModel.Solver.Frequency do
  @moduledoc """
  Frequency dynamics simulation using the swing equation with governor response.

  Models the system frequency response after a power imbalance event (e.g.,
  generator trip or sudden load change) by integrating:

      d(df)/dt = (P_mech - P_elec) / (2 * H_sys * S_sys)

  Key components:
  - **System inertia (H)**: Weighted average of generator inertia constants.
    Determines the initial rate of frequency decline. Wind/solar/storage
    (inverter-based) contribute zero inertia.
  - **Governor droop**: Generators increase mechanical output proportional to
    frequency drop, with a first-order time delay (governor time constant),
    a governor deadband, a per-fuel primary-duty share, and a per-fuel
    delivery rate limit — see "Deliverable primary response" below.
  - **Load damping**: Loads naturally reduce ~D% per 1% frequency drop
    (D coefficient, typically ~1.0). Damping acts on the load that is still
    connected (baseline minus cumulative UFLS shed).
  - **UFLS**: Under-Frequency Load Shedding at staged thresholds with time
    delays to prevent nuisance tripping. Each stage sheds a fraction of the
    CURRENTLY-CONNECTED load, not the pre-event total.

  Numerical stability: the explicit-Euler step is proven stable iff
  `beta = dt * D * Pload / (2 * H_sys * S_sys) < 2` (see
  `proofs/Proofs/Swing.lean`, theorem `beta_lt_two_iff`). `simulate/5`
  computes `beta` per simulation and shrinks `dt` so that `beta <= 1`.

  ## Deliverable primary response (ROADMAP item 14)

  Droop demands what it demands; DELIVERY is limited. Three mechanisms sit
  between the droop demand and the MW a unit actually puts on the system,
  all driven by the per-fuel table in `machine_constants/0`:

  1. **Governor duty** (`governor_duty?`). A unit whose fuel carries no
     governor duty contributes nothing: nuclear (base-loaded, governor
     response not credited in US practice), wind, solar, batteries (unless
     the fast-frequency-response hook below is armed) and tie-line imports.
  2. **Primary duty share** (`primary_duty_fraction`). The share of a fuel's
     ONLINE capability that is actually under responsive governor control.
     This is the calibration constant, and it is named as such — see the
     "Why a duty share" note below.
  3. **Delivery rate limit** (`primary_response_rate_pct_per_s`), applied as
     a hard MW/s ramp limit on each unit's governor output, plus a ceiling on
     the sustained primary response of
     `rate * nadir_window_seconds/0` MW. The rate limit is what shapes the
     NADIR (a machine cannot slam its valves open instantly); the ceiling
     only binds in deep excursions, where droop would otherwise demand tens
     of percent of nameplate within seconds.

  ### Why a duty share

  Assuming every synchronous machine online answers at its nameplate 5% droop
  produces 3.33% of online rating per 0.1 Hz. Measured against the modelled
  Eastern fleet that is ≈14,700 MW/0.1 Hz, versus a NERC BAL-003 Frequency
  Response Obligation of ≈923 MW/0.1 Hz and a measured real response in the
  low thousands — a 5–16x over-delivery (REVIEW/ROADMAP, 2026-08-15). Real
  interconnections deliver far less than textbook droop because most units
  are base-loaded with governors blocked or on outer-loop MW control that
  WITHDRAWS the governor's contribution within seconds of it appearing.
  `primary_duty_fraction` is the lumped representation of that: the fleet
  fraction whose response actually survives to the settling point. Read as an
  effective droop it says the fleet behaves like R_eff = R / duty — tens of
  percent, not 5% — which is the range NERC's frequency-response analyses
  report for the Eastern Interconnection.

  These are fleet statistics, deliberately not machine data: a single fixture
  gas machine given `duty = 0.40` delivers two fifths of textbook droop, which
  is a statement about fleets, not about that machine. The rate and ramp
  columns beside it ARE machine data.

  The size of the over-delivery depends on the operating point, because
  nameplate droop is only collectable where a unit has headroom: on the
  Eastern fleet as committed by `frequency_beta_test.exs` it is
  ≈7,800 MW/0.1 Hz, at the fuel-anchored dispatch's own operating point
  ≈6,700, and on the whole online fleet the review measured ≈14,700. Every one
  of them is multiples of the obligation, which is the point.

  ## Persistent frequency state (ROADMAP item 15)

  `simulate_with_state/4` returns `{trajectory, final_state}` and accepts
  `initial_state:`, so a second disturbance seconds after the first starts
  from the depressed frequency, the governor output already deployed, and the
  UFLS stages already spent — instead of restarting at 60.0 Hz with fresh
  reserves. `simulate/3..6` is the trajectory-only form and is unchanged for
  existing callers.

  ### State shape

      %{
        time: float(),                  # seconds on this island's frequency clock
        frequency: float(),             # Hz at the end of the segment
        df: float(),                    # frequency - 60.0
        gov_state: %{key => float()},   # per-unit governor MW deviation from dispatch
        ufls_state: [%{armed_at: float() | nil, tripped: boolean()}],
        cumulative_shed_mw: float(),    # UFLS MW shed since the state was created
        total_load_mw: float(),         # load base the damping term rides on
        lost_mw: float(),               # cumulative imbalance the state is answering
        collapsed: boolean()            # sticky 55/65 Hz clamp flag
      }

  `gov_state` is keyed by each generator's `:id` when it has one, else by
  `{:index, i}`. Keyed state is what lets the fleet CHANGE between segments:
  a unit still present resumes at its deployed MW, a unit that tripped simply
  drops out, a unit that came online starts at 0.0. Positional keys are only
  stable while the generator list is unchanged, so callers that thread state
  across trips should pass generators carrying `:id`.

  ### Resuming: what the caller owns and what the state owns

  * `lost_mw` on a resumed call is the **new** imbalance only. The state
    carries everything already lost and the two are added; passing the total
    again would double-count.
  * `loads` on a resumed call must be the **currently connected** loads. The
    damping base is reconstructed as `sum(loads) + state.cumulative_shed_mw`,
    so load shed between segments (by UFLS here or by the cascade's own
    force-shed tier) correctly shrinks the base, while the shed already
    credited to the swing balance is not lost.
  * The resumed trajectory's first record repeats the resume point (same
    `time`, same frequency) so a caller can concatenate segments and read a
    continuous clock.
  """

  require Logger

  # Nominal frequency (Hz)
  @f0 60.0

  # ---------------------------------------------------------------------------
  # Machine constants
  # ---------------------------------------------------------------------------
  #
  # One row per fuel CLASS (see `normalize_fuel/1` for the EIA-code mapping).
  # Columns:
  #
  #   :inertia_h_s                   Inertia constant H on the machine MVA base
  #                                  (seconds). Inverter-based plant is 0.0.
  #   :gov_time_s                    First-order governor/turbine lag (seconds).
  #   :governor_duty?                Whether this class is on primary frequency
  #                                  control at all.
  #   :primary_duty_fraction         Share of ONLINE capability under responsive
  #                                  governor control (fleet statistic — see the
  #                                  moduledoc's "Why a duty share").
  #   :primary_response_rate_pct_per_s
  #                                  Delivery rate limit for PRIMARY response,
  #                                  percent of nameplate per second. Times
  #                                  `nadir_window_seconds/0` this is also the
  #                                  ceiling on sustained primary response.
  #   :secondary_ramp_pct_per_min    Sustained ramp for SECONDARY/tertiary
  #                                  reserve, percent of nameplate per minute.
  #                                  Not used by the swing model; it is the
  #                                  constant the cascade's reserve tiers
  #                                  (ROADMAP item 16) ramp on.
  #
  # Sources and reasoning:
  #
  #   * Inertia constants: standard machine-class H ranges (Kundur, *Power
  #     System Stability and Control*, Table 3.2) — steam 4–6 s, hydro 2–4 s,
  #     combustion/combined-cycle 3–4 s; inverter-coupled plant contributes no
  #     synchronous rotor.
  #   * Governor time constants: turbine-governor lag by prime mover — fast
  #     valve action on combustion turbines, reheat-limited steam, and the
  #     water-column-limited hydro governor.
  #   * Secondary ramp rates: order-of-magnitude technology values consistent
  #     with the NREL/Intertek cycling-cost study (NREL/SR-5500-55433, 2012)
  #     and ISO market ramp-rate defaults — steam a few %/min, combined cycle
  #     and CT in the high single to low double digits, hydro and batteries
  #     effectively unconstrained over a dispatch interval.
  #   * Primary response rates: the fraction of nameplate a class can actually
  #     put on the system per second of a governor event, which is well above
  #     its sustained ramp (it is drawn from stored steam/water energy) but
  #     far below instantaneous.
  #   * Primary duty fractions: CALIBRATED so the interconnection-level
  #     β = ΔP/Δf reproduces the NERC BAL-003 anchors — see
  #     `test/power_model/solver/frequency_beta_test.exs`, which is the
  #     acceptance gate for these five numbers. Ordering is physical: hydro is
  #     the most reliably frequency-responsive class, gas next, base-loaded
  #     steam and small biomass/waste plant the least.
  #
  # ENE-14: OIL and the biomass/waste codes used to fall through to gas
  # dynamics (~15 GW of geolocated plant given a 0.5 s combustion-turbine
  # governor it does not have). They now carry steam-plant dynamics. The
  # `COL` code is mapped for completeness only: the 268 GW that carried it sat
  # entirely on coordinate-less MATPOWER buses which are excluded from every
  # simulation, and no row carries it in the re-ingested database at all.
  @machine_constants %{
    "nuclear" => %{
      inertia_h_s: 6.0,
      gov_time_s: 5.0,
      # US practice: nuclear units run base-loaded with governor response not
      # credited. The measured over-delivery finding called this out by name.
      governor_duty?: false,
      primary_duty_fraction: 0.0,
      primary_response_rate_pct_per_s: 0.0,
      secondary_ramp_pct_per_min: 1.0
    },
    "coal" => %{
      inertia_h_s: 4.0,
      gov_time_s: 5.0,
      governor_duty?: true,
      primary_duty_fraction: 0.20,
      primary_response_rate_pct_per_s: 0.20,
      secondary_ramp_pct_per_min: 2.0
    },
    # oil-fired steam units: steam-turbine-like rotor, steam-turbine governor
    "oil" => %{
      inertia_h_s: 4.0,
      gov_time_s: 5.0,
      governor_duty?: true,
      primary_duty_fraction: 0.20,
      primary_response_rate_pct_per_s: 0.25,
      secondary_ramp_pct_per_min: 3.0
    },
    # ENE-14: solid and liquid biomass, municipal/industrial waste, waste heat
    # and boiler-fired process gases. Steam-cycle dynamics, and the least
    # frequency-responsive class in the fleet — these units run flat out on
    # whatever fuel their host process delivers.
    "biomass" => %{
      inertia_h_s: 4.0,
      gov_time_s: 5.0,
      governor_duty?: true,
      primary_duty_fraction: 0.06,
      primary_response_rate_pct_per_s: 0.10,
      secondary_ramp_pct_per_min: 1.5
    },
    # ENE-14: landfill gas and other biogas, burned in reciprocating engines
    # or small turbines. Lower rotor inertia than a utility steam turbine and
    # NO primary duty: the fuel supply is whatever the digester or landfill
    # produces, so the unit cannot be asked for more.
    "waste_gas" => %{
      inertia_h_s: 2.0,
      gov_time_s: 1.0,
      governor_duty?: false,
      primary_duty_fraction: 0.0,
      primary_response_rate_pct_per_s: 0.0,
      secondary_ramp_pct_per_min: 2.0
    },
    # geothermal: small steam turbines, run base-loaded on the resource
    "geothermal" => %{
      inertia_h_s: 3.5,
      gov_time_s: 5.0,
      governor_duty?: true,
      primary_duty_fraction: 0.06,
      primary_response_rate_pct_per_s: 0.10,
      secondary_ramp_pct_per_min: 1.5
    },
    # gas turbine / combined cycle, fast valve action
    "gas" => %{
      inertia_h_s: 3.5,
      gov_time_s: 0.5,
      governor_duty?: true,
      primary_duty_fraction: 0.40,
      primary_response_rate_pct_per_s: 1.00,
      secondary_ramp_pct_per_min: 8.0
    },
    "hydro" => %{
      inertia_h_s: 3.0,
      gov_time_s: 2.0,
      governor_duty?: true,
      primary_duty_fraction: 0.70,
      primary_response_rate_pct_per_s: 1.50,
      secondary_ramp_pct_per_min: 25.0
    },
    # Inverter-based storage: no synchronous rotor, and no governor duty
    # UNLESS the fast-frequency-response hook is armed on the unit — see
    # `fast_frequency_response?/1`. The rate and ramp columns describe what a
    # battery can do once it is asked, which is essentially instantaneous.
    "storage" => %{
      inertia_h_s: 0.0,
      gov_time_s: 0.2,
      governor_duty?: false,
      primary_duty_fraction: 1.0,
      primary_response_rate_pct_per_s: 10.0,
      secondary_ramp_pct_per_min: 100.0
    },
    "wind" => %{
      inertia_h_s: 0.0,
      gov_time_s: 999.0,
      governor_duty?: false,
      primary_duty_fraction: 0.0,
      primary_response_rate_pct_per_s: 0.0,
      secondary_ramp_pct_per_min: 20.0
    },
    "solar" => %{
      inertia_h_s: 0.0,
      gov_time_s: 999.0,
      governor_duty?: false,
      primary_duty_fraction: 0.0,
      primary_response_rate_pct_per_s: 0.0,
      secondary_ramp_pct_per_min: 20.0
    },
    # tie-line imports: no local rotor, no local governor, no local ramp
    "import" => %{
      inertia_h_s: 0.0,
      gov_time_s: 999.0,
      governor_duty?: false,
      primary_duty_fraction: 0.0,
      primary_response_rate_pct_per_s: 0.0,
      secondary_ramp_pct_per_min: 0.0
    }
  }

  # Fuel class used for any code the table and the heuristics both miss.
  @fallback_fuel "gas"

  # EIA-860/923 energy source codes as stored on generators (PLT-3).
  # Checked BEFORE the substring heuristics so that e.g. "SUB" (subbituminous
  # coal) does not fall through to the "gas" default. MWH (batteries) maps to
  # storage: zero inertia and no governor.
  @eia_fuel_codes %{
    # --- coal -----------------------------------------------------------
    "SUB" => "coal",
    "LIG" => "coal",
    "RC" => "coal",
    "WC" => "coal",
    "BIT" => "coal",
    "SC" => "coal",
    "ANT" => "coal",
    # MATPOWER-era code. Every row that carried it sat on a coordinate-less
    # bus (268 GW, REVIEW ENE-14) and no simulation has ever seen one; the
    # re-ingested database has none. Mapped so it can never silently become
    # a gas turbine if such rows return.
    "COL" => "coal",
    # --- oil ------------------------------------------------------------
    "DFO" => "oil",
    "RFO" => "oil",
    "KER" => "oil",
    "JF" => "oil",
    "WO" => "oil",
    "PG" => "oil",
    # --- biomass / waste, steam cycle (ENE-14) ---------------------------
    "BLQ" => "biomass",
    "WDS" => "biomass",
    "WDL" => "biomass",
    "MSW" => "biomass",
    "MSB" => "biomass",
    "MSN" => "biomass",
    "OBS" => "biomass",
    "OBL" => "biomass",
    "AB" => "biomass",
    "SLW" => "biomass",
    "TDF" => "biomass",
    "PC" => "biomass",
    "WH" => "biomass",
    "BFG" => "biomass",
    "SGC" => "biomass",
    "SGP" => "biomass",
    "PUR" => "biomass",
    "OTH" => "biomass",
    # --- biogas in reciprocating engines (ENE-14) ------------------------
    "LFG" => "waste_gas",
    "OBG" => "waste_gas",
    "OG" => "waste_gas",
    # --- everything else -------------------------------------------------
    "MWH" => "storage",
    "GEO" => "geothermal",
    "NUC" => "nuclear",
    "NG" => "gas",
    "WAT" => "hydro",
    "WND" => "wind",
    "SUN" => "solar"
  }

  # Droop coefficient (5% means 5% frequency deviation -> 100% power change)
  @droop 0.05

  # Governor deadband (Hz). NERC BAL-003 guidance caps the intentional
  # governor deadband at ±0.036 Hz; a unit sees only the excursion beyond it.
  # This is why small disturbances draw proportionally less primary response
  # than large ones — the response is not a pure slope through the origin.
  @governor_deadband_hz 0.036

  # The window over which "primary response" is defined (seconds). NERC's
  # BAL-003 value-B measurement reads the settling point 20–52 s after the
  # event; the deliverable primary response is what a machine can put on the
  # system in the first few seconds of that, which is the nadir window.
  @nadir_window_s 10.0

  # Load damping coefficient (D = 1.0 means 1% load reduction per 1% freq drop)
  @load_damping 1.0

  # Physical clamp band for the simulated frequency (Hz)
  @f_min 55.0
  @f_max 65.0

  # Sane upper bound on the number of Euler steps a single simulation may take
  # after the stability-driven dt shrink (ENE-5).
  @max_total_steps 10_000

  # UFLS stages: {threshold_hz, shed_fraction, arming_delay_s}
  # NERC PRC-006-style regional program: staged shedding beginning at 59.3 Hz,
  # each stage shedding a further 7.5% of the currently-connected load —
  # ~30% cumulative by 58.1 Hz.
  @ufls_stages [
    {59.3, 0.075, 0.1},
    {58.9, 0.075, 0.1},
    {58.5, 0.075, 0.1},
    {58.1, 0.075, 0.1}
  ]

  @doc """
  The canonical UFLS program: `{threshold_hz, shed_fraction, arming_delay_s}`
  per stage, shed fractions incremental. Single source of truth — the static
  nadir-based schedule in `PowerModel.Failure.Protection.ufls_schedule/1`
  derives its cumulative fractions from this table.
  """
  def ufls_stages, do: @ufls_stages

  @doc """
  Load damping coefficient D (fractional load change per fractional frequency
  deviation). Exposed so the static steady-state frequency estimate in
  `PowerModel.Failure.Protection.estimate_frequency/3` stays consistent with
  the dynamic model.
  """
  def load_damping, do: @load_damping

  @doc """
  Nominal system frequency (Hz).
  """
  def nominal_frequency, do: @f0

  @doc """
  Governor deadband in Hz. A unit answers only the part of the excursion
  beyond this.
  """
  def governor_deadband_hz, do: @governor_deadband_hz

  @doc """
  Governor droop coefficient R (per unit): the fractional frequency deviation
  that commands 100% of rated output. Exposed so secondary control
  (`PowerModel.Controls.AGC`) can derive an island's natural frequency
  response β from the same slope the swing model integrates, instead of
  hard-coding a second copy of it.
  """
  def droop, do: @droop

  @doc """
  The window (seconds) over which primary response is defined. Multiplying a
  unit's primary response RATE by this window gives the MW of sustained
  primary response it can be asked for.
  """
  def nadir_window_seconds, do: @nadir_window_s

  @doc """
  The full per-fuel machine-constants table, keyed by fuel class.

  See the module attribute's comment block for column meanings, sources, and
  the calibration status of each column. Reserve tiering (ROADMAP item 16)
  should read `:primary_response_rate_pct_per_s` for the primary tier and
  `:secondary_ramp_pct_per_min` for the secondary/tertiary tiers rather than
  inventing its own numbers.
  """
  @spec machine_constants() :: %{String.t() => map()}
  def machine_constants, do: @machine_constants

  @doc """
  Machine constants for one generator map or fuel string/code.

  Accepts an EIA energy-source code (`"NG"`), a free-text fuel description
  (`"natural gas"`), a fuel class (`"gas"`), `nil`, or a generator map with a
  `:fuel_type` key. Always returns a row — unrecognised fuels fall to the
  `#{@fallback_fuel}` class, the same default the dynamics have always used.
  """
  @spec machine_constants(map() | String.t() | nil) :: map()
  def machine_constants(generator_or_fuel) do
    Map.fetch!(@machine_constants, fuel_class(generator_or_fuel))
  end

  @doc """
  Canonical fuel class for a generator map or fuel string/code — one of the
  keys of `machine_constants/0`.
  """
  @spec fuel_class(map() | String.t() | nil) :: String.t()
  def fuel_class(generator) when is_map(generator),
    do: normalize_fuel(Map.get(generator, :fuel_type))

  def fuel_class(fuel), do: normalize_fuel(fuel)

  @doc """
  Whether this generator is on primary frequency control.

  False for nuclear (base-loaded, response not credited), wind, solar,
  tie-line imports and biogas engines. Batteries are false unless the
  fast-frequency-response hook is armed — see `fast_frequency_response?/1`.
  """
  @spec governor_duty?(map()) :: boolean()
  def governor_duty?(generator) when is_map(generator) do
    class = fuel_class(generator)
    row = Map.fetch!(@machine_constants, class)

    row.governor_duty? or (class == "storage" and fast_frequency_response?(generator))
  end

  @doc """
  Whether a battery is armed for fast frequency response (FFR).

  Batteries answer a frequency excursion far faster than any turbine, but
  what they can answer WITH is their state of charge and their current
  charge/discharge point, neither of which this module models — that is
  ROADMAP item 17. The hook is therefore opt-in per unit: a generator map
  carrying `ffr_enabled: true` is treated as being on primary duty with the
  `"storage"` row's rate (10%/s) and full duty share, and its headroom is
  read from dispatch state exactly like a turbine's.

  Until item 17 lands, nothing in the codebase sets the flag, so batteries
  contribute zero primary response by default. That is the conservative
  choice: crediting an unmodelled state of charge would over-deliver response
  in precisely the deep excursions where a depleted battery has none.
  """
  @spec fast_frequency_response?(map()) :: boolean()
  def fast_frequency_response?(generator) when is_map(generator),
    do: Map.get(generator, :ffr_enabled, false) == true

  @doc """
  Primary response delivery rate for one generator, in MW per second.

  This is the rate limit the swing model imposes on the unit's governor
  output. It rides on nameplate (`:p_nameplate_mw` when the cascade has
  reshaped the map for the solver, else `:p_max_mw`).
  """
  @spec primary_response_rate_mw_per_s(map()) :: float()
  def primary_response_rate_mw_per_s(generator) when is_map(generator) do
    machine_constants(generator).primary_response_rate_pct_per_s / 100.0 *
      nameplate_mw(generator)
  end

  @doc """
  Sustained primary response one generator can be asked for, in MW: its
  delivery rate over `nadir_window_seconds/0`, capped by the headroom it
  actually has above its dispatched output.

  This is the per-unit primary reserve number the cascade's reserve tiers
  (ROADMAP item 16) should sum, not `p_max_mw - p_dispatch_mw`.
  """
  @spec primary_response_capability_mw(map()) :: float()
  def primary_response_capability_mw(generator) when is_map(generator) do
    if governor_duty?(generator) do
      rate_limit = primary_response_rate_mw_per_s(generator) * @nadir_window_s
      min(rate_limit, headroom_mw(generator))
    else
      0.0
    end
  end

  @doc """
  Sustained secondary/tertiary ramp for one generator, in MW per minute.

  Unlike `primary_response_capability_mw/1` this is not capped by headroom —
  it is a rate, and how long it may run is the caller's clock. Units with no
  governor duty still ramp (a nuclear unit ramps, it just does not answer a
  governor), so this reads the table unconditionally.
  """
  @spec secondary_ramp_mw_per_min(map()) :: float()
  def secondary_ramp_mw_per_min(generator) when is_map(generator) do
    machine_constants(generator).secondary_ramp_pct_per_min / 100.0 *
      nameplate_mw(generator)
  end

  @doc """
  Simulate the system frequency response after a power imbalance event.

  ## Parameters

  - `generators` - list of generator maps (must have :p_max_mw, :capacity_factor;
    optionally :fuel_type for inertia/governor lookup, :id for state keying)
  - `loads` - list of load maps (must have :p_mw)
  - `lost_mw` - MW of generation lost (positive) or load lost (negative). On a
    resumed simulation this is the NEW imbalance only.
  - `dt_seconds` - requested simulation time step (default 0.1s). May be
    shrunk internally to keep the Euler step numerically stable (see below).
  - `duration_seconds` - total simulation duration (default 30.0s)
  - `opts` - `initial_state:` to resume from a previous segment's final state
    (see the moduledoc). `nil` means a fresh start at 60.0 Hz.

  ## Returns

  A list of time-step maps:
      %{
        time: float(),          # seconds
        frequency: float(),     # Hz
        gov_response_mw: float(), # total governor MW pickup
        load_shed_mw: float(),  # cumulative UFLS shed MW
        collapsed: boolean()    # true once the frequency has hit the
                                # physical clamp (55/65 Hz) — the trajectory
                                # from that point on is saturated, not a
                                # resolved swing solution
      }

  `collapsed` is sticky: once any step touches the clamp every later record
  carries `collapsed: true`, so `collapsed?/1` can read the last record.

  Use `simulate_with_state/4` when the final state is needed.

  ## Numerical stability (ENE-5)

  The explicit-Euler swing step contracts toward its equilibrium iff
  `beta = dt * D * Pload / (2 * H_sys * S_sys) < 2` — equivalently
  `dt < 4*H*S / (D * Pload)` — see `proofs/Proofs/Swing.lean`, theorem
  `beta_lt_two_iff` (and `stepDf_contracts`). We compute `beta` for each
  simulation and shrink `dt` so that `beta <= 1` (a comfortable margin below
  the proven bound), capping the total number of steps at #{@max_total_steps}.
  """
  @spec simulate(list(map()), list(map()), float(), float(), float(), keyword()) :: list(map())
  def simulate(
        generators,
        loads,
        lost_mw,
        dt_seconds \\ 0.1,
        duration_seconds \\ 30.0,
        opts \\ []
      ) do
    {trajectory, _state} =
      simulate_with_state(
        generators,
        loads,
        lost_mw,
        Keyword.merge(opts, dt_seconds: dt_seconds, duration_seconds: duration_seconds)
      )

    trajectory
  end

  @doc """
  Simulate one segment of frequency dynamics and return
  `{trajectory, final_state}`.

  The state is what makes successive disturbances COMPOUND instead of each
  one restarting from 60.0 Hz with untouched reserves — see the moduledoc for
  the state shape and the exact contract for `lost_mw` and `loads` on a
  resumed call.

  ## Options

    * `:initial_state` — a state returned by a previous call, or `nil`
    * `:dt_seconds` — requested time step (default 0.1)
    * `:duration_seconds` — segment duration (default 30.0)
  """
  @spec simulate_with_state(list(map()), list(map()), float(), keyword()) ::
          {list(map()), map()}
  def simulate_with_state(generators, loads, lost_mw, opts \\ []) do
    dt_seconds = Keyword.get(opts, :dt_seconds, 0.1)
    duration_seconds = Keyword.get(opts, :duration_seconds, 30.0)
    prior = Keyword.get(opts, :initial_state)

    online_gens =
      Enum.filter(generators, fn g ->
        (Map.get(g, :capacity_factor) || 1.0) > 0.0 and (Map.get(g, :p_max_mw) || 0.0) > 0.0
      end)

    {h_sys, s_sys} = system_inertia(online_gens)
    connected_load_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

    # Resume accounting (see moduledoc "Resuming"): the damping base is the
    # load still connected PLUS whatever this state has already shed, because
    # `cumulative_shed_mw` is carried as a credit against that same base.
    {start, total_load_mw, cumulative_shed_mw, lost_total_mw} =
      case prior do
        nil ->
          {fresh_start(), connected_load_mw, 0.0, lost_mw}

        %{} = state ->
          shed = Map.get(state, :cumulative_shed_mw, 0.0)

          {state, connected_load_mw + shed, shed, Map.get(state, :lost_mw, 0.0) + lost_mw}
      end

    # ENE-4: floor the kinetic-energy PRODUCT 2*H*S (MW·s), not the H
    # constant. Flooring H alone created a 34x discontinuity in 2HS when a
    # small fleet change crossed the old `h_sys < 0.01` threshold. The floor
    # is a minimum kinetic-energy proxy of 1 MW·s per MW of load (H_equiv =
    # 0.5 s on the load base), so a zero-inertia (all-inverter) island still
    # integrates without dividing by zero and neighboring fleets get
    # neighboring dynamics.
    two_h_s = max(2.0 * h_sys * s_sys, 1.0 * max(total_load_mw, 1.0))

    # ENE-5: enforce the proven Euler stability bound. The step contracts iff
    # beta = dt*D*Pload/(2HS) < 2 (proofs/Proofs/Swing.lean, beta_lt_two_iff);
    # we shrink dt so beta <= 1. Pload only decreases as UFLS sheds, so the
    # initial beta is the worst case.
    beta = dt_seconds * @load_damping * total_load_mw / two_h_s
    dt = if beta > 1.0, do: dt_seconds / beta, else: dt_seconds

    raw_steps = round(duration_seconds / dt)

    {dt, total_steps} =
      if raw_steps > @max_total_steps do
        {duration_seconds / @max_total_steps, @max_total_steps}
      else
        {dt, raw_steps}
      end

    # Build governor model for each generator, resuming each unit's deployed
    # MW by key so a changed fleet keeps the state of the units it shares.
    gov_units = build_governor_units(online_gens)
    gov_state = resume_gov_state(gov_units, Map.get(start, :gov_state, %{}))
    # `* 1.0`: an empty fleet sums to the integer 0, which Float.round rejects.
    initial_gov_mw = (gov_units |> Enum.map(&Map.fetch!(gov_state, &1.key)) |> Enum.sum()) * 1.0

    initial_record = %{
      time: Float.round(start.time, 4),
      frequency: Float.round(start.frequency, 6),
      gov_response_mw: Float.round(initial_gov_mw, 2),
      load_shed_mw: Float.round(cumulative_shed_mw, 2),
      collapsed: start.collapsed
    }

    state0 = %{
      time: start.time,
      frequency: start.frequency,
      df: start.df,
      gov_state: gov_state,
      ufls_state: Map.get(start, :ufls_state, fresh_ufls_state()),
      cumulative_shed_mw: cumulative_shed_mw,
      total_load_mw: total_load_mw,
      lost_mw: lost_total_mw,
      collapsed: start.collapsed
    }

    # ENE-11/SOL-7: duration shorter than one step — return just the initial
    # record instead of iterating a descending range.
    if total_steps <= 0 do
      {[initial_record], state0}
    else
      {trajectory, final_state} =
        Enum.reduce(1..total_steps//1, {[initial_record], state0}, fn step, {records, state} ->
          t = start.time + step * dt

          # 1. Governor response: each unit ramps toward its droop demand,
          # limited by duty, deadband, headroom, and its delivery rate.
          {new_gov_state, total_gov_mw} =
            update_governors(gov_units, state.gov_state, state.df, dt)

          # 2. UFLS check — each stage sheds a fraction of the load still
          # connected (ENE-6), not of the pre-event total.
          connected_mw = state.total_load_mw - state.cumulative_shed_mw

          {new_ufls_state, new_shed_mw} =
            update_ufls(state.ufls_state, state.frequency, t, connected_mw)

          cumulative_shed = state.cumulative_shed_mw + new_shed_mw
          remaining_load_mw = state.total_load_mw - cumulative_shed

          # 3. Compute power balance
          # P_mech = (total generation - lost_mw) + governor pickup
          # P_elec = remaining load + frequency damping on the remaining load
          p_mech = total_gov_mw

          # Load damping acts on the load still connected (ENE-6):
          # P_load_actual = (P_load - shed) * (1 + D * df/f0)
          load_damping_mw = remaining_load_mw * @load_damping * state.df / @f0

          # Net imbalance: positive means generation > load (frequency rises)
          # lost_mw is subtracted from generation; gov pickup adds to it;
          # UFLS shedding subtracts from the electrical load.
          p_imbalance = -state.lost_mw + p_mech - load_damping_mw + cumulative_shed

          # 4. Swing equation: df/dt = f0 * P_imbalance / (2 * H_sys * S_sys)
          # Using MW and seconds; two_h_s is the (floored) product 2*H*S.
          dfdt = @f0 * p_imbalance / two_h_s

          # 5. Euler integration
          new_df = state.df + dfdt * dt
          new_freq_raw = @f0 + new_df

          # Clamp frequency to physical bounds; a touched clamp marks the
          # trajectory as collapsed (saturated, not a resolved solution).
          new_freq = new_freq_raw |> max(@f_min) |> min(@f_max)
          new_df = new_freq - @f0
          collapsed = state.collapsed or new_freq_raw < @f_min or new_freq_raw > @f_max

          record = %{
            time: Float.round(t, 4),
            frequency: Float.round(new_freq, 6),
            gov_response_mw: Float.round(total_gov_mw, 2),
            load_shed_mw: Float.round(cumulative_shed, 2),
            collapsed: collapsed
          }

          {[record | records],
           %{
             state
             | time: t,
               frequency: new_freq,
               df: new_df,
               gov_state: new_gov_state,
               ufls_state: new_ufls_state,
               cumulative_shed_mw: cumulative_shed,
               collapsed: collapsed
           }}
        end)

      {Enum.reverse(trajectory), final_state}
    end
  end

  defp fresh_start do
    %{
      time: 0.0,
      frequency: @f0,
      df: 0.0,
      gov_state: %{},
      ufls_state: fresh_ufls_state(),
      cumulative_shed_mw: 0.0,
      collapsed: false
    }
  end

  defp fresh_ufls_state, do: Enum.map(@ufls_stages, fn _ -> %{armed_at: nil, tripped: false} end)

  # Units present in the prior state resume at their deployed MW; units that
  # were not there (newly online, or a fleet whose positional keys shifted)
  # start at zero.
  defp resume_gov_state(gov_units, prior_gov_state) do
    Map.new(gov_units, fn unit -> {unit.key, Map.get(prior_gov_state, unit.key, 0.0)} end)
  end

  @doc """
  Return the frequency nadir (minimum frequency) from a simulation trajectory.
  """
  @spec nadir(list(map())) :: float()
  def nadir(trajectory) do
    trajectory
    |> Enum.min_by(& &1.frequency)
    |> Map.get(:frequency)
  end

  @doc """
  Return the settling frequency (final value) from a simulation trajectory.
  """
  @spec settling_frequency(list(map())) :: float()
  def settling_frequency(trajectory) do
    trajectory
    |> List.last()
    |> Map.get(:frequency)
  end

  @doc """
  Whether the trajectory touched the physical frequency clamp (55/65 Hz) at
  any point — i.e. the island's frequency collapsed (or ran away) beyond what
  the linearized swing model can resolve. Callers should treat nadir/settling
  values from a collapsed trajectory as saturated bounds, not solutions.
  """
  @spec collapsed?(list(map())) :: boolean()
  def collapsed?(trajectory) do
    trajectory
    |> List.last()
    |> Map.get(:collapsed, false)
  end

  @doc """
  Mean frequency over a time window `[from_s, to_s]` of a trajectory,
  inclusive.

  This is the reading BAL-003 calls "value B": the settled frequency after a
  disturbance, averaged over a window rather than sampled at one instant so a
  residual oscillation does not decide the answer. Falls back to the last
  record when no sample falls inside the window.
  """
  @spec mean_frequency(list(map()), float(), float()) :: float()
  def mean_frequency(trajectory, from_s, to_s) do
    samples =
      Enum.filter(trajectory, fn r -> r.time >= from_s and r.time <= to_s end)

    case samples do
      [] -> settling_frequency(trajectory)
      records -> Enum.sum(Enum.map(records, & &1.frequency)) / length(records)
    end
  end

  @doc """
  Compute the system-wide inertia constant H_sys and total MVA base S_sys.

      H_sys = sum(H_i * S_i) / sum(S_i)

  where H_i is the inertia constant and S_i is the MVA rating (approximated
  as p_max_mw for each generator).
  """
  @spec system_inertia(list(map())) :: {float(), float()}
  def system_inertia(generators) do
    {weighted_sum, total_s} =
      Enum.reduce(generators, {0.0, 0.0}, fn gen, {ws, ts} ->
        h = inertia_for(gen)
        # Inertia rides on the machine MVA base (≈ nameplate MW), not the
        # currently dispatched output — a half-loaded machine spins with its
        # full rotor.
        s = nameplate_mw(gen)
        {ws + h * s, ts + s}
      end)

    if total_s > 0.0 do
      {weighted_sum / total_s, total_s}
    else
      {0.0, 0.0}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp inertia_for(gen), do: machine_constants(gen).inertia_h_s

  defp normalize_fuel(fuel) when is_binary(fuel) do
    trimmed = fuel |> String.trim() |> String.upcase()

    # PLT-3: exact EIA energy-source codes first, then the fuel-class names
    # themselves (so `machine_constants("hydro")` resolves), then substring
    # heuristics for free-text fuel descriptions.
    case Map.get(@eia_fuel_codes, trimmed) do
      nil ->
        downcased = String.downcase(trimmed)

        if Map.has_key?(@machine_constants, downcased) do
          downcased
        else
          heuristic_fuel(fuel)
        end

      code ->
        code
    end
  end

  defp normalize_fuel(_), do: @fallback_fuel

  defp heuristic_fuel(fuel) do
    f = String.downcase(fuel)

    cond do
      String.contains?(f, "nuclear") or String.contains?(f, "nuc") ->
        "nuclear"

      String.contains?(f, "coal") or String.contains?(f, "bit") ->
        "coal"

      String.contains?(f, "import") ->
        "import"

      String.contains?(f, "biomass") or String.contains?(f, "wood") or
        String.contains?(f, "waste") or String.contains?(f, "biogas") ->
        "biomass"

      String.contains?(f, "oil") or String.contains?(f, "petroleum") or
          String.contains?(f, "diesel") ->
        "oil"

      String.contains?(f, "gas") or String.contains?(f, "ng") or String.contains?(f, "ct") ->
        "gas"

      String.contains?(f, "hydro") or String.contains?(f, "wat") ->
        "hydro"

      String.contains?(f, "wind") or String.contains?(f, "wnd") ->
        "wind"

      String.contains?(f, "solar") or String.contains?(f, "sun") or String.contains?(f, "pv") ->
        "solar"

      true ->
        Logger.debug("Frequency: unrecognized fuel type #{inspect(fuel)} -- using gas dynamics")
        @fallback_fuel
    end
  end

  # Real dispatch and nameplate capability. The cascade reshapes generators
  # for the DC solver (p_max_mw = dispatched MW, capacity_factor = 1.0), which
  # read naively would zero the governor headroom and shrink the inertia base
  # to the dispatched MW; it attaches the physical values as :p_dispatch_mw /
  # :p_nameplate_mw so the frequency dynamics stay physical.
  defp dispatch_mw(gen) do
    Map.get(gen, :p_dispatch_mw) ||
      gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0)
  end

  defp nameplate_mw(gen) do
    Map.get(gen, :p_nameplate_mw) || gen.p_max_mw
  end

  defp headroom_mw(gen), do: max(nameplate_mw(gen) - dispatch_mw(gen), 0.0)

  defp build_governor_units(generators) do
    generators
    |> Enum.with_index()
    |> Enum.map(fn {gen, index} ->
      p_dispatch = dispatch_mw(gen)
      p_nameplate = nameplate_mw(gen)
      constants = machine_constants(gen)
      duty? = governor_duty?(gen)

      %{
        # Stable identity for the persistent governor state (see moduledoc).
        key: Map.get(gen, :id) || {:index, index},
        # Droop responds on the machine base (nameplate), not current output
        p_rated: p_nameplate,
        p_dispatch: p_dispatch,
        # Governor headroom: how much more the generator can ramp up from its
        # current operating point toward nameplate capability
        headroom: max(p_nameplate - p_dispatch, 0.0),
        t_gov: constants.gov_time_s,
        droop: @droop,
        has_governor: duty?,
        # Item 14: what the machine can DELIVER, as opposed to what droop asks
        # for. `duty` scales the sustained demand, `rate_mw_per_s` limits how
        # fast it may arrive, and their product over the nadir window is the
        # ceiling on sustained primary response.
        duty: constants.primary_duty_fraction,
        rate_mw_per_s: constants.primary_response_rate_pct_per_s / 100.0 * p_nameplate,
        capability_mw:
          constants.primary_response_rate_pct_per_s / 100.0 * p_nameplate * @nadir_window_s
      }
    end)
  end

  defp update_governors(gov_units, gov_state, df, dt) do
    Enum.reduce(gov_units, {gov_state, 0.0}, fn unit, {states, total_mw} ->
      current_dp = Map.fetch!(states, unit.key)

      if not unit.has_governor do
        {states, total_mw + current_dp}
      else
        dp_new = governor_step(unit, current_dp, df, dt)
        {Map.put(states, unit.key, dp_new), total_mw + dp_new}
      end
    end)
  end

  # One unit's governor over one step: droop demand, then everything that
  # stands between the demand and the megawatts.
  defp governor_step(unit, current_dp, df, dt) do
    # Deadband: only the excursion beyond ±deadband is seen at all.
    df_eff =
      cond do
        df < -@governor_deadband_hz -> df + @governor_deadband_hz
        df > @governor_deadband_hz -> df - @governor_deadband_hz
        true -> 0.0
      end

    # Droop demand, scaled by the share of this fuel's fleet actually under
    # responsive governor control. Negative df (underfrequency) -> positive dp.
    dp_target = -(df_eff / @f0) / unit.droop * unit.p_rated * unit.duty

    dp_target =
      dp_target
      # Sustained primary response ceiling: rate * nadir window.
      |> max(-unit.capability_mw)
      |> min(unit.capability_mw)
      # Physical limits: cannot exceed headroom, cannot back below zero output.
      |> max(-unit.p_dispatch)
      |> min(unit.headroom)

    # First-order lag: dp approaches dp_target with time constant T_gov
    # dp_new = dp_old + (dp_target - dp_old) * dt / T_gov
    dp_lagged = current_dp + (dp_target - current_dp) * min(dt / unit.t_gov, 1.0)

    # Delivery rate limit: the valves/gates cannot move faster than this,
    # whatever the lag would allow. Symmetric — backing down is rate-limited
    # exactly as ramping up is.
    max_step = unit.rate_mw_per_s * dt

    dp_lagged
    |> max(current_dp - max_step)
    |> min(current_dp + max_step)
  end

  # Tolerance for the arming-delay comparison: `time` values are multiples of
  # a binary-inexact dt, so `0.5 - 0.4 < 0.1` in floats — without the epsilon
  # a stage armed for exactly `delay` seconds would wait one extra step.
  @delay_epsilon 1.0e-9

  # `connected_mw` is the load still connected when the step begins; each
  # tripping stage sheds `shed_frac` of the load remaining after the stages
  # that tripped before it — including earlier stages in this same step
  # (ENE-6: fraction of CURRENTLY-connected load, never of the pre-event
  # total).
  defp update_ufls(ufls_state, freq, time, connected_mw) do
    {new_state, total_new_shed} =
      Enum.zip(@ufls_stages, ufls_state)
      |> Enum.map_reduce(0.0, fn {{threshold, shed_frac, delay}, stage_state}, shed_acc ->
        cond do
          stage_state.tripped ->
            # Already tripped, no new shedding
            {stage_state, shed_acc}

          freq < threshold ->
            case stage_state.armed_at do
              nil ->
                # Arm the stage
                {%{stage_state | armed_at: time}, shed_acc}

              armed_time when time - armed_time >= delay - @delay_epsilon ->
                # Delay elapsed, trip the stage
                shed_mw = max(connected_mw - shed_acc, 0.0) * shed_frac
                {%{stage_state | tripped: true}, shed_acc + shed_mw}

              _armed_time ->
                # Still waiting for delay
                {stage_state, shed_acc}
            end

          true ->
            # Frequency above threshold, reset arming if not tripped
            {%{stage_state | armed_at: nil}, shed_acc}
        end
      end)

    {new_state, total_new_shed}
  end
end
