defmodule PowerModel.Reference do
  @moduledoc """
  Structural statistics from published reference network models, so a census
  can answer "is this number normal?" instead of guessing.

  ## Why this exists

  Every census in this repo measures OUR network and reports an absolute
  number. Absolute numbers cannot be read without a yardstick. Measured
  2026-08-22: 12.4% of Eastern's load sits on a bus at 230 kV or above, and
  32.5% of it sits five or more hops from the nearest such bus. Neither figure
  means anything on its own — the only way to learn whether they were
  pathological was to build a 189 GW relocation experiment, which cost an hour
  and returned "inconclusive". `case_ACTIVSg2000` answers both in a lookup:
  0% of its load sits on EHV (all of it is at 115 and 161 kV), and 32% of it
  sits five or more hops out. So the depth was ORDINARY and the voltage
  placement was not, which is the opposite of what the experiment was built to
  test.

  That is the whole purpose here: turn "design an experiment" into "read a
  number", for the class of question where a reference model already knows.

  ## What this is NOT

  Not a source of truth about the real grid, and not a target to tune toward.
  A reference case is one modeller's choices about what to represent, and
  differences between it and us are often CONVENTION rather than defect —
  `case_ACTIVSg2000` models every machine at its 13.8 kV terminal with an
  explicit step-up branch, while this codebase places generators directly on
  the substation bus. Read a divergence as a question, never as a verdict.

  ## Sources and their limits

  Both shipped cases are the ones already vendored for solver validation:

    * `case_ACTIVSg2000` — 2,000 buses, 67.1 GW, synthetic but built by the
      Texas A&M group expressly to reproduce the STATISTICAL properties of a
      real interconnection, which is the property this module needs. Levels
      are 115/161/230/500 kV: it can say nothing about 345 or 765 kV.
    * `case118` — the IEEE 118-bus case, 4.2 GW, levels 138/161/345 kV. Small
      enough that its distributions are noisy; it is here because it covers
      the 345 kV level ACTIVSg2000 lacks.

  Neither is 60,000 buses, and neither is the Eastern Interconnection. The
  honest use is order-of-magnitude and presence/absence — "reference places no
  load at all below 115 kV" is a strong signal; "reference median x_pu at
  115 kV is 0.0385 against our 0.0103" is a prompt to ask why, not a defect.

  ## Regenerating

      mix grid.reference_stats

  Unlike `priv/reactive_planning/reactive_support_banks.json` (REVIEW DAT-31),
  this artifact ships WITH its producer, so it can be regenerated on demand
  and re-derived when a case is added.
  """

  @artifact "structural_stats.json"

  @doc """
  The whole corpus as a map, or `nil` when the artifact is absent.

  Absent is a supported state: a checkout without the file still runs every
  census, just without the reference column.

  Reads and parses the file on EVERY call — measured 0.072 ms, so the census's
  ~9,600 `poi_floor_kv/1` calls cost about 0.6 s of a multi-minute run, which
  is not worth a cache with invalidation to match. A genuinely hot loop should
  hoist the call rather than expect memoisation here.
  """
  @spec stats() :: map() | nil
  def stats do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} -> map
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Absolute path to the artifact, wherever the app was built."
  @spec path() :: Path.t()
  def path do
    :power_model |> :code.priv_dir() |> Path.join("reference") |> Path.join(@artifact)
  end

  @doc """
  Minimum point-of-interconnection voltage, in kV, that any reference case
  uses for a plant of this size.

  This is the MOST PERMISSIVE reading of the reference — the lowest POI ever
  observed at that size, not the median — so a bus that fails it is one no
  reference case would produce even at its most generous. `case_ACTIVSg2000`
  interconnects the median 200-400 MW plant at 500 kV; the floor below says
  161 kV, because exactly one plant in that band sits that low.

  Returns `nil` when the corpus is absent, which callers must treat as
  "no opinion" rather than "passes".

      iex> is_nil(PowerModel.Reference.poi_floor_kv(300)) or PowerModel.Reference.poi_floor_kv(300) > 0
      true
  """
  @spec poi_floor_kv(number()) :: float() | nil
  def poi_floor_kv(plant_mw) when is_number(plant_mw) do
    with %{"derived" => %{"generator_poi_floor_kv" => bands}} <- stats() do
      bands
      |> Enum.filter(fn [above_mw, _kv] -> plant_mw > above_mw end)
      |> Enum.map(fn [_above_mw, kv] -> kv end)
      |> case do
        [] -> nil
        kvs -> Enum.max(kvs)
      end
    else
      _ -> nil
    end
  end

  @doc """
  A named metric for one reference case, or `nil`.

      PowerModel.Reference.metric("load_mw_share_by_bus_kv", "case_ACTIVSg2000")
  """
  @spec metric(String.t(), String.t()) :: any()
  def metric(name, case_name) do
    with %{"metrics" => metrics} <- stats(),
         %{^name => by_case} <- metrics,
         %{^case_name => value} <- by_case do
      value
    else
      _ -> nil
    end
  end

  @doc "Case names present in the corpus, or `[]`."
  @spec cases() :: [String.t()]
  def cases do
    case stats() do
      %{"sources" => sources} when is_list(sources) -> Enum.map(sources, & &1["case"])
      _ -> []
    end
  end
end
