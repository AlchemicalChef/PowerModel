defmodule PowerModel.Solver.Harmonics.Scenario do
  @moduledoc """
  Interactive harmonic scenario manager.

  Provides a high-level API for configuring harmonic sources, running the
  harmonic power flow solver, and comparing results. Designed for "what-if"
  analysis: modify individual generator/device harmonic injection spectra,
  switch converter operating modes, add/remove filters at buses, and see
  how each change affects bus-level THD and IEEE 519 compliance.

  ## Workflow

  1. Create a scenario from a grid snapshot with `create_scenario/2`. This
     auto-detects harmonic sources from IBR generators and large loads.
  2. Add, modify, or remove harmonic devices with `add_device/2`,
     `modify_device/3`, `remove_device/2`.
  3. Add or remove passive harmonic filters at buses with `add_filter/5`,
     `remove_filter/2`.
  4. Run the analysis with `run/2` to get per-bus THD, individual harmonic
     voltages, IEEE 519 compliance, and impedance scans.
  5. Compare two results with `compare/2` to see THD improvement per bus.
  6. Use `what_if/3` for quick exploratory changes without mutating the
     scenario.

  ## Data Structures

  All structs use plain maps for testability. No database dependency.

  ### HarmonicDevice

  Represents a single harmonic-producing device at a bus:

      %HarmonicDevice{
        id: term(),
        bus_id: integer(),
        device_type: :six_pulse | :twelve_pulse | :pwm_inverter |
                     :arc_furnace | :saturated_transformer | :custom,
        p_mw: float(),
        v_pu: float(),
        params: map(),
        filter: filter_spec | nil,
        active: boolean()
      }

  ### HarmonicScenario

  Holds the full scenario configuration:

      %HarmonicScenario{
        devices: [%HarmonicDevice{}],
        filters: %{bus_id => filter_spec},
        max_harmonic: integer(),
        base_mva: float()
      }

  ## Units

  - All powers in MW (p_mw) or MVAr (q_mvar).
  - Voltages in per-unit (v_pu) on the system base.
  - Impedances in per-unit on Sbase = base_mva (default 100 MVA).
  - THD results in percent.
  - Harmonic orders are integer multiples of the fundamental (60 Hz).
  """

  alias PowerModel.Solver.Harmonics.{Solver, Filter}

  # ---------------------------------------------------------------------------
  # Data Structures
  # ---------------------------------------------------------------------------

  defmodule HarmonicDevice do
    @moduledoc """
    A harmonic-producing device attached to a bus.

    ## Fields

    - `id` — unique identifier (any term)
    - `bus_id` — the bus this device is connected to
    - `device_type` — one of `:six_pulse`, `:twelve_pulse`, `:pwm_inverter`,
      `:arc_furnace`, `:saturated_transformer`, `:custom`
    - `p_mw` — device active power rating in MW
    - `v_pu` — terminal voltage in per-unit (default 1.0)
    - `params` — device-specific parameters:
      - For converters (`:six_pulse`, `:twelve_pulse`):
        `:alpha` (decay exponent, default 0.8)
      - For `:pwm_inverter`:
        `:spectrum` (custom `%{h => pct_of_fundamental}`),
        `:switching_freq_hz`
      - For `:arc_furnace`:
        `:phase` (`:melting` or `:refining`)
      - For `:saturated_transformer`:
        `:i_magnetizing_pu`, `:saturation_type` (`:gic` or `:overexcitation`)
      - For `:custom`:
        `:spectrum` (required, `%{h => pct_of_fundamental}`)
    - `filter` — optional filter spec attached directly to this device's bus
    - `active` — whether this device is currently injecting harmonics
    """

    defstruct [
      :id,
      :bus_id,
      :device_type,
      p_mw: 0.0,
      v_pu: 1.0,
      params: %{},
      filter: nil,
      active: true
    ]

    @type t :: %__MODULE__{
            id: term(),
            bus_id: integer(),
            device_type:
              :six_pulse
              | :twelve_pulse
              | :pwm_inverter
              | :arc_furnace
              | :saturated_transformer
              | :custom,
            p_mw: float(),
            v_pu: float(),
            params: map(),
            filter: map() | nil,
            active: boolean()
          }
  end

  defmodule HarmonicScenario do
    @moduledoc """
    Full harmonic analysis scenario configuration.

    ## Fields

    - `devices` — list of `HarmonicDevice` structs
    - `filters` — map of `%{bus_id => filter_spec}` for bus-level filters
    - `max_harmonic` — highest harmonic order to analyze (default 25)
    - `base_mva` — system MVA base (default 100.0)
    """

    defstruct devices: [],
              filters: %{},
              max_harmonic: 25,
              base_mva: 100.0

    @type t :: %__MODULE__{
            devices: [PowerModel.Solver.Harmonics.Scenario.HarmonicDevice.t()],
            filters: map(),
            max_harmonic: pos_integer(),
            base_mva: float()
          }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Initialize a harmonic scenario from a grid snapshot.

  Auto-detects harmonic sources by inspecting generators and loads:

  - **IBR generators** (fuel_type in `["SUN", "WND", "MWH", "BAT"]`) are
    modeled as PWM inverter harmonic sources. Their injection magnitude
    is based on `p_max_mw * capacity_factor`.

  - **Large industrial loads** (p_mw >= threshold, default 50 MW) are
    modeled as potential arc furnace sources. These are created but
    **inactive** by default — the user must explicitly activate them.

  ## Options

  - `:max_harmonic` — highest harmonic order (default 25)
  - `:base_mva` — system MVA base (default 100.0)
  - `:ibr_fuel_types` — list of fuel types to treat as IBR (default
    `["SUN", "WND", "MWH", "BAT"]`)
  - `:arc_furnace_threshold_mw` — minimum load MW to auto-detect as
    potential arc furnace (default 50.0)
  - `:auto_detect` — whether to auto-detect sources (default true)

  ## Returns

  A `%HarmonicScenario{}` struct.
  """
  def create_scenario(snapshot, opts \\ []) do
    max_h = Keyword.get(opts, :max_harmonic, 25)
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    auto_detect = Keyword.get(opts, :auto_detect, true)

    devices =
      if auto_detect do
        detect_ibr_devices(snapshot, opts) ++ detect_arc_furnace_loads(snapshot, opts)
      else
        []
      end

    %HarmonicScenario{
      devices: devices,
      filters: %{},
      max_harmonic: max_h,
      base_mva: base_mva
    }
  end

  @doc """
  Add a harmonic-producing device to the scenario.

  The device must be a `%HarmonicDevice{}` struct or a map with the same
  keys. If a device with the same `:id` already exists, it is replaced.

  ## Examples

      scenario = add_device(scenario, %HarmonicDevice{
        id: :solar_farm_1,
        bus_id: 42,
        device_type: :pwm_inverter,
        p_mw: 200.0,
        params: %{spectrum: %{5 => 8.0, 7 => 5.0}}
      })
  """
  def add_device(%HarmonicScenario{} = scenario, %HarmonicDevice{} = device) do
    # Remove existing device with same id, then append
    devices = Enum.reject(scenario.devices, &(&1.id == device.id))
    %{scenario | devices: devices ++ [device]}
  end

  def add_device(%HarmonicScenario{} = scenario, device) when is_map(device) do
    add_device(scenario, struct(HarmonicDevice, device))
  end

  @doc """
  Remove a device from the scenario by ID.

  Returns the scenario unchanged if the device is not found.
  """
  def remove_device(%HarmonicScenario{} = scenario, device_id) do
    %{scenario | devices: Enum.reject(scenario.devices, &(&1.id == device_id))}
  end

  @doc """
  Modify an existing device's parameters.

  `changes` is a map or keyword list of fields to update on the device.
  Supports changing any `HarmonicDevice` field including nested `:params`.

  ## Common use cases

  - Switch converter topology: `modify_device(s, :conv1, %{device_type: :twelve_pulse})`
  - Change PWM spectrum: `modify_device(s, :inv1, %{params: %{spectrum: %{5 => 8.0}}})`
  - Disable a device: `modify_device(s, :dev1, %{active: false})`
  - Change power rating: `modify_device(s, :dev1, %{p_mw: 300.0})`

  Returns `{:ok, scenario}` if the device was found, `{:error, :not_found}`
  otherwise.
  """
  def modify_device(%HarmonicScenario{} = scenario, device_id, changes)
      when is_map(changes) or is_list(changes) do
    changes_map = if is_list(changes), do: Map.new(changes), else: changes

    case Enum.find_index(scenario.devices, &(&1.id == device_id)) do
      nil ->
        {:error, :not_found}

      idx ->
        device = Enum.at(scenario.devices, idx)

        # Merge params maps if both old and new have :params
        updated_params =
          case Map.get(changes_map, :params) do
            nil -> device.params
            new_params -> Map.merge(device.params || %{}, new_params)
          end

        # Apply all other changes, then set merged params
        updated_device =
          changes_map
          |> Map.delete(:params)
          |> Enum.reduce(device, fn {key, val}, dev ->
            if Map.has_key?(dev, key) do
              Map.put(dev, key, val)
            else
              dev
            end
          end)
          |> Map.put(:params, updated_params)

        devices = List.replace_at(scenario.devices, idx, updated_device)
        {:ok, %{scenario | devices: devices}}
    end
  end

  @doc """
  Add a passive harmonic filter at a bus.

  Designs the filter using the specified topology and stores it in the
  scenario. The filter will be applied to the snapshot when `run/2` is
  called.

  ## Parameters

  - `scenario` — the harmonic scenario
  - `bus_id` — bus where the filter will be installed
  - `filter_type` — `:single_tuned` or `:high_pass`
  - `target_harmonic` — harmonic order to filter (e.g., 5 for 5th)
  - `q_mvar` — reactive power compensation at fundamental (MVAr)

  ## Options

  - `:bus_kv` — bus voltage in kV (default 138.0). Used for impedance
    base in filter design.
  - `:q_factor` — filter quality factor (default 40.0 for single-tuned,
    1.0 for high-pass)
  - `:detune_pct` — percent detuning for single-tuned (default 4.0)

  ## Returns

  Updated scenario with the filter added. If a filter already exists at
  the bus, it is replaced.
  """
  def add_filter(
        %HarmonicScenario{} = scenario,
        bus_id,
        filter_type,
        target_harmonic,
        q_mvar,
        opts \\ []
      ) do
    bus_kv = Keyword.get(opts, :bus_kv, 138.0)

    filter_spec =
      case filter_type do
        :single_tuned ->
          q_factor = Keyword.get(opts, :q_factor, 40.0)
          detune_pct = Keyword.get(opts, :detune_pct, 4.0)

          design =
            Filter.design_single_tuned(target_harmonic, bus_kv, q_mvar,
              q_factor: q_factor,
              detune_pct: detune_pct
            )

          Map.put(design, :filter_type, :single_tuned)

        :high_pass ->
          q_factor = Keyword.get(opts, :q_factor, 1.0)
          design = Filter.design_high_pass(target_harmonic, bus_kv, q_mvar, q_factor: q_factor)
          Map.put(design, :filter_type, :high_pass)
      end

    %{scenario | filters: Map.put(scenario.filters, bus_id, filter_spec)}
  end

  @doc """
  Remove the harmonic filter at a bus.

  Returns the scenario unchanged if no filter exists at the bus.
  """
  def remove_filter(%HarmonicScenario{} = scenario, bus_id) do
    %{scenario | filters: Map.delete(scenario.filters, bus_id)}
  end

  @doc """
  Execute the harmonic analysis for the current scenario configuration.

  Converts all active devices to harmonic source descriptors, applies any
  filters to the snapshot, runs the harmonic solver, and computes THD,
  IEEE 519 compliance, and impedance scans.

  ## Parameters

  - `scenario` — the `%HarmonicScenario{}` to analyze
  - `snapshot` — the grid snapshot map with `:buses`, `:lines`,
    `:transformers`, `:generators` keys

  ## Options

  - `:fundamental_solution` — fundamental power flow solution map with
    `:bus_ids`, `:vm_pu`, `:va_rad`. If not provided, a flat start
    (V=1.0, angle=0.0) is used.
  - `:impedance_scan_buses` — list of bus IDs to run impedance scans on
    (default: buses with harmonic sources)

  ## Returns

      {:ok, %{
        harmonic_voltages: %{h => %{bus_id => {v_mag, v_angle}}},
        thd: %{bus_id => thd_pct},
        ieee_519: [compliance_result],
        impedance_scans: %{bus_id => [{h, z_mag, z_angle}]},
        devices: [%HarmonicDevice{}],
        filters: %{bus_id => filter_spec},
        max_harmonic: integer(),
        worst_bus: {bus_id, thd_pct},
        total_violations: integer()
      }}

  or `{:error, reason}`.
  """
  def run(%HarmonicScenario{} = scenario, snapshot, opts \\ []) do
    fundamental = Keyword.get(opts, :fundamental_solution, nil)
    scan_buses = Keyword.get(opts, :impedance_scan_buses, nil)

    # Build fundamental solution (flat start if not provided)
    fundamental_solution = fundamental || build_flat_start(snapshot)

    # Convert active devices to harmonic source map for the solver
    harmonic_sources = build_harmonic_sources(scenario)

    # Apply filters to snapshot
    filtered_snapshot = apply_filters(snapshot, scenario.filters, scenario.base_mva)

    # Run the harmonic solver
    case Solver.solve(filtered_snapshot, fundamental_solution, harmonic_sources,
           max_harmonic: scenario.max_harmonic,
           base_mva: scenario.base_mva
         ) do
      {:ok, harmonic_voltages} ->
        # Compute THD at each bus
        thd = Solver.compute_thd(harmonic_voltages)

        # Check IEEE 519 compliance
        ieee_519 = Solver.check_ieee_519(harmonic_voltages, filtered_snapshot.buses)

        # Run impedance scans at selected buses
        scan_bus_ids = scan_buses || source_bus_ids(scenario)

        impedance_scans =
          Map.new(scan_bus_ids, fn bus_id ->
            scan =
              Solver.impedance_scan(filtered_snapshot, bus_id,
                freq_range: 1..scenario.max_harmonic,
                base_mva: scenario.base_mva
              )

            {bus_id, scan}
          end)

        # Find worst bus
        worst_bus =
          case Enum.max_by(thd, fn {_id, val} -> val end, fn -> {nil, 0.0} end) do
            {id, val} -> {id, val}
          end

        # Count total violations
        total_violations =
          ieee_519
          |> Enum.flat_map(& &1.violations)
          |> length()

        # Compute individual harmonic distortion at each bus
        individual_hd = compute_individual_hd(harmonic_voltages)

        {:ok,
         %{
           harmonic_voltages: harmonic_voltages,
           thd: thd,
           individual_hd: individual_hd,
           ieee_519: ieee_519,
           impedance_scans: impedance_scans,
           devices: scenario.devices,
           filters: scenario.filters,
           max_harmonic: scenario.max_harmonic,
           worst_bus: worst_bus,
           total_violations: total_violations
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Compare two harmonic analysis results.

  Shows per-bus THD improvement, compliance changes, and worst-case
  changes. Useful for evaluating the effect of adding filters, changing
  converter topology, or adjusting device parameters.

  ## Parameters

  - `result_before` — result map from `run/2` (baseline)
  - `result_after` — result map from `run/2` (modified)

  ## Returns

      %{
        thd_improvement: %{bus_id => delta_thd_pct},
        thd_improvement_pct: %{bus_id => pct_reduction},
        compliance_changes: [%{bus_id, before: bool, after: bool}],
        newly_compliant: [bus_id],
        newly_violated: [bus_id],
        worst_before: {bus_id, thd_pct},
        worst_after: {bus_id, thd_pct},
        average_thd_before: float(),
        average_thd_after: float(),
        total_violations_before: integer(),
        total_violations_after: integer()
      }
  """
  def compare(result_before, result_after) do
    thd_before = result_before.thd
    thd_after = result_after.thd

    all_bus_ids =
      MapSet.union(
        MapSet.new(Map.keys(thd_before)),
        MapSet.new(Map.keys(thd_after))
      )

    # Absolute THD improvement (positive = better)
    thd_improvement =
      Map.new(all_bus_ids, fn bus_id ->
        before_val = Map.get(thd_before, bus_id, 0.0)
        after_val = Map.get(thd_after, bus_id, 0.0)
        {bus_id, before_val - after_val}
      end)

    # Percentage THD reduction (positive = better)
    thd_improvement_pct =
      Map.new(all_bus_ids, fn bus_id ->
        before_val = Map.get(thd_before, bus_id, 0.0)
        after_val = Map.get(thd_after, bus_id, 0.0)

        pct =
          if before_val > 1.0e-6 do
            (before_val - after_val) / before_val * 100.0
          else
            0.0
          end

        {bus_id, pct}
      end)

    # Compliance changes
    compliance_before = build_compliance_map(result_before.ieee_519)
    compliance_after = build_compliance_map(result_after.ieee_519)

    compliance_changes =
      all_bus_ids
      |> Enum.map(fn bus_id ->
        before_compliant = Map.get(compliance_before, bus_id, true)
        after_compliant = Map.get(compliance_after, bus_id, true)
        %{bus_id: bus_id, before: before_compliant, after: after_compliant}
      end)
      |> Enum.filter(fn c -> c.before != c.after end)

    newly_compliant =
      compliance_changes
      |> Enum.filter(fn c -> not c.before and c.after end)
      |> Enum.map(& &1.bus_id)

    newly_violated =
      compliance_changes
      |> Enum.filter(fn c -> c.before and not c.after end)
      |> Enum.map(& &1.bus_id)

    # Averages
    avg_before = safe_average(Map.values(thd_before))
    avg_after = safe_average(Map.values(thd_after))

    %{
      thd_improvement: thd_improvement,
      thd_improvement_pct: thd_improvement_pct,
      compliance_changes: compliance_changes,
      newly_compliant: newly_compliant,
      newly_violated: newly_violated,
      worst_before: result_before.worst_bus,
      worst_after: result_after.worst_bus,
      average_thd_before: avg_before,
      average_thd_after: avg_after,
      total_violations_before: result_before.total_violations,
      total_violations_after: result_after.total_violations
    }
  end

  @doc """
  Run a quick "what if" analysis without mutating the scenario.

  Applies a list of changes to a copy of the scenario, runs the analysis,
  and returns both the modified result and a comparison with the baseline.

  ## Parameters

  - `scenario` — the base scenario
  - `snapshot` — grid snapshot
  - `changes` — list of change tuples:
    - `{:add_device, %HarmonicDevice{}}` — add a device
    - `{:remove_device, device_id}` — remove a device
    - `{:modify_device, device_id, changes_map}` — modify device params
    - `{:add_filter, bus_id, filter_type, target_harmonic, q_mvar}`
    - `{:add_filter, bus_id, filter_type, target_harmonic, q_mvar, opts}`
    - `{:remove_filter, bus_id}`

  ## Options

  - `:fundamental_solution` — passed through to `run/2`
  - `:run_baseline` — if true, also runs the unmodified scenario for
    comparison (default true)

  ## Returns

      {:ok, %{
        baseline: result | nil,
        modified: result,
        comparison: comparison | nil
      }}

  or `{:error, reason}`.
  """
  def what_if(%HarmonicScenario{} = scenario, snapshot, changes, opts \\ []) do
    run_baseline = Keyword.get(opts, :run_baseline, true)
    run_opts = Keyword.take(opts, [:fundamental_solution, :impedance_scan_buses])

    # Apply changes to a copy of the scenario
    modified_scenario = apply_changes(scenario, changes)

    # Run baseline if requested
    baseline_result =
      if run_baseline do
        case run(scenario, snapshot, run_opts) do
          {:ok, result} -> result
          {:error, _} -> nil
        end
      else
        nil
      end

    # Run modified scenario
    case run(modified_scenario, snapshot, run_opts) do
      {:ok, modified_result} ->
        comparison =
          if baseline_result do
            compare(baseline_result, modified_result)
          else
            nil
          end

        {:ok,
         %{
           baseline: baseline_result,
           modified: modified_result,
           comparison: comparison
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all devices in the scenario, optionally filtered.

  ## Options

  - `:bus_id` — filter by bus ID
  - `:device_type` — filter by device type
  - `:active_only` — if true, only return active devices (default false)
  """
  def list_devices(%HarmonicScenario{} = scenario, opts \\ []) do
    bus_id = Keyword.get(opts, :bus_id)
    device_type = Keyword.get(opts, :device_type)
    active_only = Keyword.get(opts, :active_only, false)

    scenario.devices
    |> then(fn devs ->
      if bus_id, do: Enum.filter(devs, &(&1.bus_id == bus_id)), else: devs
    end)
    |> then(fn devs ->
      if device_type, do: Enum.filter(devs, &(&1.device_type == device_type)), else: devs
    end)
    |> then(fn devs ->
      if active_only, do: Enum.filter(devs, & &1.active), else: devs
    end)
  end

  @doc """
  Get a summary of the scenario configuration.

  Returns a map with device counts, filter locations, and source bus IDs.
  """
  def summary(%HarmonicScenario{} = scenario) do
    active_devices = Enum.filter(scenario.devices, & &1.active)
    inactive_devices = Enum.reject(scenario.devices, & &1.active)

    by_type =
      active_devices
      |> Enum.group_by(& &1.device_type)
      |> Map.new(fn {type, devs} -> {type, length(devs)} end)

    total_injection_mw =
      active_devices
      |> Enum.map(& &1.p_mw)
      |> Enum.sum()

    %{
      total_devices: length(scenario.devices),
      active_devices: length(active_devices),
      inactive_devices: length(inactive_devices),
      devices_by_type: by_type,
      total_injection_mw: total_injection_mw,
      filter_count: map_size(scenario.filters),
      filter_bus_ids: Map.keys(scenario.filters),
      source_bus_ids: source_bus_ids(scenario),
      max_harmonic: scenario.max_harmonic,
      base_mva: scenario.base_mva
    }
  end

  # ---------------------------------------------------------------------------
  # Private: Auto-detection of harmonic sources
  # ---------------------------------------------------------------------------

  @ibr_fuel_types_default ["SUN", "WND", "MWH", "BAT"]

  defp detect_ibr_devices(snapshot, opts) do
    ibr_types = Keyword.get(opts, :ibr_fuel_types, @ibr_fuel_types_default)
    generators = Map.get(snapshot, :generators, [])

    generators
    |> Enum.filter(fn gen ->
      fuel = Map.get(gen, :fuel_type, "")
      status = Map.get(gen, :status, "in_service")
      fuel in ibr_types and status == "in_service"
    end)
    |> Enum.map(fn gen ->
      cf = Map.get(gen, :capacity_factor) || 1.0
      p_mw = (Map.get(gen, :p_max_mw) || 0.0) * cf

      %HarmonicDevice{
        id: {:gen, gen.id},
        bus_id: gen.bus_id,
        device_type: :pwm_inverter,
        p_mw: p_mw,
        v_pu: Map.get(gen, :v_set_pu) || 1.0,
        params: %{},
        active: true
      }
    end)
  end

  defp detect_arc_furnace_loads(snapshot, opts) do
    threshold = Keyword.get(opts, :arc_furnace_threshold_mw, 50.0)
    loads = Map.get(snapshot, :loads, [])

    loads
    |> Enum.filter(fn load ->
      (Map.get(load, :p_mw) || 0.0) >= threshold
    end)
    |> Enum.map(fn load ->
      %HarmonicDevice{
        id: {:load, load.id},
        bus_id: load.bus_id,
        device_type: :arc_furnace,
        p_mw: Map.get(load, :p_mw) || 0.0,
        v_pu: 1.0,
        params: %{phase: :melting},
        # inactive by default — user must opt in
        active: false
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: Build harmonic source map from scenario devices
  # ---------------------------------------------------------------------------

  # Converts HarmonicDevice structs into the %{bus_id => [device_spec]}
  # format expected by the harmonic solver.
  defp build_harmonic_sources(%HarmonicScenario{} = scenario) do
    scenario.devices
    |> Enum.filter(& &1.active)
    |> Enum.group_by(& &1.bus_id)
    |> Map.new(fn {bus_id, devices} ->
      specs = Enum.map(devices, &device_to_spec(&1, scenario.base_mva))
      {bus_id, specs}
    end)
  end

  # Convert a HarmonicDevice to the solver's device_spec format
  defp device_to_spec(%HarmonicDevice{} = device, base_mva) do
    case device.device_type do
      :six_pulse ->
        # Fundamental current from power: I = P / V (in pu on system base)
        i_fund = abs(device.p_mw) / base_mva / max(abs(device.v_pu), 0.01)
        opts = build_converter_opts(device)
        %{type: :six_pulse, i_fundamental_pu: i_fund, opts: opts}

      :twelve_pulse ->
        i_fund = abs(device.p_mw) / base_mva / max(abs(device.v_pu), 0.01)
        opts = build_converter_opts(device)
        %{type: :twelve_pulse, i_fundamental_pu: i_fund, opts: opts}

      :pwm_inverter ->
        opts = build_pwm_opts(device, base_mva)
        %{type: :pwm_inverter, p_mw: device.p_mw, v_pu: device.v_pu, opts: opts}

      :arc_furnace ->
        opts = build_arc_furnace_opts(device)
        %{type: :arc_furnace, p_mw: device.p_mw, opts: opts}

      :saturated_transformer ->
        i_mag = Map.get(device.params, :i_magnetizing_pu, 1.0)
        opts = build_saturated_xfmr_opts(device)
        %{type: :saturated_transformer, i_magnetizing_pu: i_mag, opts: opts}

      :custom ->
        # Custom devices use the PWM inverter path with explicit spectrum
        spectrum = Map.get(device.params, :spectrum, %{})
        opts = [spectrum: spectrum, base_mva: base_mva]
        %{type: :pwm_inverter, p_mw: device.p_mw, v_pu: device.v_pu, opts: opts}
    end
  end

  defp build_converter_opts(%HarmonicDevice{} = device) do
    opts = [max_harmonic: 50]
    alpha = Map.get(device.params, :alpha)
    if alpha, do: Keyword.put(opts, :alpha, alpha), else: opts
  end

  defp build_pwm_opts(%HarmonicDevice{} = device, base_mva) do
    opts = [base_mva: base_mva]
    spectrum = Map.get(device.params, :spectrum)
    opts = if spectrum, do: Keyword.put(opts, :spectrum, spectrum), else: opts
    sw_freq = Map.get(device.params, :switching_freq_hz)
    if sw_freq, do: Keyword.put(opts, :switching_freq_hz, sw_freq), else: opts
  end

  defp build_arc_furnace_opts(%HarmonicDevice{} = device) do
    phase = Map.get(device.params, :phase, :melting)
    [phase: phase, max_harmonic: 50]
  end

  defp build_saturated_xfmr_opts(%HarmonicDevice{} = device) do
    sat_type = Map.get(device.params, :saturation_type, :gic)
    [saturation_type: sat_type, max_harmonic: 50]
  end

  # ---------------------------------------------------------------------------
  # Private: Filter application
  # ---------------------------------------------------------------------------

  # Apply all scenario filters to the snapshot. Each filter modifies the
  # bus shunt admittance at its target bus for all harmonic frequencies.
  defp apply_filters(snapshot, filters, _base_mva) when map_size(filters) == 0 do
    snapshot
  end

  defp apply_filters(snapshot, filters, base_mva) do
    Enum.reduce(filters, snapshot, fn {bus_id, filter_spec}, snap ->
      apply_single_filter(snap, bus_id, filter_spec, base_mva)
    end)
  end

  # Apply a single filter to the snapshot by modifying the bus shunt admittance
  # at each harmonic frequency. This mirrors Filter.add_filter_to_snapshot/4
  # but is a public-facing version that works with the scenario system.
  defp apply_single_filter(snapshot, bus_id, filter_spec, base_mva) do
    omega_0 = 2.0 * :math.pi() * 60.0

    x_c_ohm = Map.get(filter_spec, :x_c_ohm, 0.0)
    x_l_ohm = Map.get(filter_spec, :x_l_ohm, 0.0)
    r_ohm = Map.get(filter_spec, :r_ohm, 0.0)

    c_farads = if x_c_ohm > 0.0, do: 1.0 / (omega_0 * x_c_ohm), else: 0.0
    l_henries = x_l_ohm / omega_0

    bus_kv =
      Enum.find_value(snapshot.buses, 138.0, fn bus ->
        if bus.id == bus_id, do: Map.get(bus, :base_kv) || 138.0
      end)

    z_base = bus_kv * bus_kv / base_mva

    max_h = 25

    harmonic_shunts =
      Map.new(1..max_h, fn h ->
        omega_h = omega_0 * h
        x_l_h = omega_h * l_henries
        x_c_h = if c_farads > 0.0, do: 1.0 / (omega_h * c_farads), else: 0.0
        z_im = x_l_h - x_c_h
        z_mag_sq = r_ohm * r_ohm + z_im * z_im

        if z_mag_sq > 1.0e-12 do
          g_ohm = r_ohm / z_mag_sq
          b_ohm = -z_im / z_mag_sq
          {h, {g_ohm * z_base, b_ohm * z_base}}
        else
          {h, {0.0, 0.0}}
        end
      end)

    modified_buses =
      Enum.map(snapshot.buses, fn bus ->
        if bus.id == bus_id do
          # Store per-harmonic filter shunt admittances on the bus.
          # The harmonic Y-bus builder reads :harmonic_filter_shunts and adds
          # the correct frequency-dependent admittance at each harmonic order.
          # We do NOT modify b_shunt_mvar because the harmonic builder already
          # scales it by h (treating it as a simple capacitor bank), and the
          # filter's frequency response is fully captured in harmonic_filter_shunts.
          existing_shunts = Map.get(bus, :harmonic_filter_shunts, %{})
          merged_shunts = merge_shunt_maps(existing_shunts, harmonic_shunts)
          Map.put(bus, :harmonic_filter_shunts, merged_shunts)
        else
          bus
        end
      end)

    filter_data = %{
      bus_id: bus_id,
      r_ohm: r_ohm,
      l_henries: l_henries,
      c_farads: c_farads,
      bus_kv: bus_kv
    }

    snapshot
    |> Map.put(:buses, modified_buses)
    |> Map.put(
      :harmonic_filters,
      [filter_data | Map.get(snapshot, :harmonic_filters, [])]
    )
  end

  # ---------------------------------------------------------------------------
  # Private: What-if change application
  # ---------------------------------------------------------------------------

  defp apply_changes(scenario, changes) do
    Enum.reduce(changes, scenario, fn change, acc ->
      case change do
        {:add_device, device} ->
          add_device(acc, device)

        {:remove_device, device_id} ->
          remove_device(acc, device_id)

        {:modify_device, device_id, changes_map} ->
          case modify_device(acc, device_id, changes_map) do
            {:ok, updated} -> updated
            {:error, _} -> acc
          end

        {:add_filter, bus_id, filter_type, target_h, q_mvar} ->
          add_filter(acc, bus_id, filter_type, target_h, q_mvar)

        {:add_filter, bus_id, filter_type, target_h, q_mvar, opts} ->
          add_filter(acc, bus_id, filter_type, target_h, q_mvar, opts)

        {:remove_filter, bus_id} ->
          remove_filter(acc, bus_id)

        _ ->
          acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: Helper utilities
  # ---------------------------------------------------------------------------

  defp build_flat_start(snapshot) do
    bus_ids = Enum.map(snapshot.buses, & &1.id)
    n = length(bus_ids)

    %{
      bus_ids: bus_ids,
      vm_pu: List.duplicate(1.0, n),
      va_rad: List.duplicate(0.0, n)
    }
  end

  defp source_bus_ids(%HarmonicScenario{} = scenario) do
    scenario.devices
    |> Enum.filter(& &1.active)
    |> Enum.map(& &1.bus_id)
    |> Enum.uniq()
  end

  defp build_compliance_map(ieee_519_results) do
    Map.new(ieee_519_results, fn r -> {r.bus_id, r.compliant} end)
  end

  # Compute individual harmonic distortion for each bus:
  # IHD_h = V_h / V_1 * 100%
  defp compute_individual_hd(harmonic_voltages) do
    fundamental = Map.get(harmonic_voltages, 1, %{})
    higher_harmonics = Map.drop(harmonic_voltages, [1])
    bus_ids = Map.keys(fundamental)

    Map.new(bus_ids, fn bus_id ->
      {v1_mag, _} = Map.get(fundamental, bus_id, {1.0, 0.0})

      hd_map =
        Enum.reduce(higher_harmonics, %{}, fn {h, bus_voltages}, acc ->
          case Map.get(bus_voltages, bus_id) do
            {v_h_mag, _angle} when v1_mag > 1.0e-6 ->
              Map.put(acc, h, v_h_mag / v1_mag * 100.0)

            _ ->
              acc
          end
        end)

      {bus_id, hd_map}
    end)
  end

  defp safe_average([]), do: 0.0

  defp safe_average(values) do
    Enum.sum(values) / length(values)
  end

  # Merge two per-harmonic shunt admittance maps.
  # Each map is %{h => {g_pu, b_pu}}. Values at the same harmonic are summed.
  defp merge_shunt_maps(map_a, map_b) do
    Map.merge(map_a, map_b, fn _h, {ga, ba}, {gb, bb} -> {ga + gb, ba + bb} end)
  end
end
