defmodule PowerModel.Grid.SystemStandard do
  @moduledoc """
  Per-synchronous-area frequency and protection settings, so a 50 Hz network
  cannot silently be run through a 60 Hz protection model.

  ## Why this exists

  Voltage porting is free: everything electrical is per-unit on
  `v_nom^2 / base_mva`, so a 380 kV European line and a 345 kV American one
  differ only in a number the reader already carries. **Frequency porting is
  not.** Measured 2026-08-23: `Solver.Frequency` compiles `@f0 60.0` and a UFLS
  program at `{59.3, 58.9, 58.5, 58.1}` Hz, and a HEALTHY Continental European
  system at 50.0 Hz sits below all four thresholds — so every under-frequency
  stage fires at t = 0 on an undisturbed grid, before any contingency. A
  European cascade run through the US model is not approximately right; it is
  nonsense from the first step.

  The same is true of every protection setpoint that is a standard rather than
  physics: PRC-024's frequency envelope, IEEE 1547's inverter trips, and the
  UVLS program are all North American instruments with European counterparts
  that differ in both threshold and structure.

  ## What this module does and does not do

  It carries the settings and it **refuses the mismatch** (`compatible!/2`).
  It does NOT yet re-parameterise `Solver.Frequency`, which uses `@f0` at
  compile time inside the swing equation and the droop model. So today the
  useful property is a loud stop rather than a correct 50 Hz run — which is the
  right order, because the failure it prevents is silent.

  Porting the frequency layer properly means threading a standard through
  `Solver.Frequency`, `Failure.Protection`, `Failure.LoadShedding`,
  `Controls.AGC` and `Grid.BtmSolar`. That work is scoped in ROADMAP; this
  module is its data and its guard.

  ## Sources, and how firm each is

  The North American numbers are the ones already compiled into this repo and
  are unchanged. The European ones are REPRESENTATIVE rather than a single
  authority, and that distinction matters: ENTSO-E sets the framework while
  national TSOs set their own demand-disconnection schemes, so a real study
  should override `ufls_stages` per country rather than trust the default here.
  Marked `:representative` for exactly that reason.
  """

  @type t :: %{
          key: atom(),
          name: String.t(),
          nominal_hz: float(),
          ufls_stages: [{float(), float(), float()}],
          frequency_ride_through: [{float(), float()}],
          btm_underfrequency_hz: float(),
          confidence: :authoritative | :representative,
          notes: String.t()
        }

  @us %{
    key: :nerc_60hz,
    name: "North America (NERC), 60 Hz",
    nominal_hz: 60.0,
    # {threshold_hz, incremental shed fraction, arming delay s}
    ufls_stages: [
      {59.3, 0.075, 0.1},
      {58.9, 0.075, 0.1},
      {58.5, 0.075, 0.1},
      {58.1, 0.075, 0.1}
    ],
    # PRC-024-3 under-frequency: {floor_hz, cumulative seconds allowed below it}
    frequency_ride_through: [{57.0, 0.0}, {58.0, 30.0}, {59.4, 180.0}],
    # IEEE 1547-2003 legacy must-trip.
    btm_underfrequency_hz: 59.3,
    confidence: :authoritative,
    notes: "The settings already compiled into Solver.Frequency and Failure.Protection."
  }

  @entsoe %{
    key: :entsoe_50hz,
    name: "Continental Europe (ENTSO-E), 50 Hz",
    nominal_hz: 50.0,
    # ENTSO-E's framework puts automatic demand disconnection between 49.0 and
    # 48.0 Hz; the stage list, fractions and count are set nationally, so this
    # is a placeholder shaped like the US one rather than a citable program.
    ufls_stages: [
      {49.0, 0.075, 0.1},
      {48.8, 0.075, 0.1},
      {48.6, 0.075, 0.1},
      {48.4, 0.075, 0.1}
    ],
    # Commission Regulation (EU) 2016/631 (RfG) Continental Europe ranges,
    # expressed in this repo's cumulative-seconds-below form.
    frequency_ride_through: [{47.5, 0.0}, {48.5, 1800.0}, {49.0, 1800.0}],
    # EN 50549 / VDE-AR-N 4105 territory; national settings vary.
    btm_underfrequency_hz: 47.5,
    confidence: :representative,
    notes:
      "ENTSO-E sets the framework and national TSOs set the demand-disconnection " <>
        "scheme, so override ufls_stages per country for any real study."
  }

  @standards %{nerc_60hz: @us, entsoe_50hz: @entsoe}

  @doc "Every known standard, keyed."
  @spec all() :: %{atom() => t()}
  def all, do: @standards

  @doc "Fetch a standard by key. Raises on an unknown key rather than defaulting."
  @spec fetch!(atom()) :: t()
  def fetch!(key) do
    Map.get(@standards, key) ||
      raise ArgumentError,
            "unknown system standard #{inspect(key)}; known: #{inspect(Map.keys(@standards))}"
  end

  @doc "The standard this repo's frequency model is currently compiled for."
  @spec compiled() :: t()
  def compiled, do: @us

  @doc """
  The standard whose nominal frequency matches `hz`, or `nil`.

      iex> PowerModel.Grid.SystemStandard.for_frequency(50.0).key
      :entsoe_50hz
  """
  @spec for_frequency(number()) :: t() | nil
  def for_frequency(hz) when is_number(hz) do
    Enum.find_value(@standards, fn {_k, s} -> if abs(s.nominal_hz - hz) < 0.5, do: s end)
  end

  def for_frequency(_), do: nil

  @doc """
  Raise unless a snapshot's nominal frequency matches the compiled model.

  This is the guard the moduledoc is about. A snapshot with no stated frequency
  is ASSUMED to match — an unstamped network is the existing behaviour and
  breaking it would fail every current test — but one that states 50 Hz is
  refused, loudly, with the reason.
  """
  @spec compatible!(map(), keyword()) :: :ok
  def compatible!(snapshot, opts \\ []) do
    expected = Keyword.get(opts, :standard, compiled())

    case Map.get(snapshot, :nominal_hz) do
      nil ->
        :ok

      hz when is_number(hz) ->
        if abs(hz - expected.nominal_hz) < 0.5 do
          :ok
        else
          other = for_frequency(hz)

          raise ArgumentError, """
          This network runs at #{hz} Hz and the frequency model is compiled for \
          #{expected.nominal_hz} Hz (#{expected.name}).

          Running it anyway is not approximately wrong, it is nonsense: the UFLS \
          program is #{inspect(Enum.map(expected.ufls_stages, &elem(&1, 0)))} Hz, \
          every one of which a healthy #{hz} Hz system already sits below, so all \
          stages fire before any contingency.

          #{if other, do: "The matching standard is #{inspect(other.key)} (#{other.name}), which this repo does not yet thread through Solver.Frequency.", else: "No known standard matches that frequency."}

          Steady-state power flow is unaffected — it is per-unit and frequency \
          enters only through line charging, which the reader already handles. \
          Use the solver directly for load-flow work on this network.
          """
        end
    end
  end
end
