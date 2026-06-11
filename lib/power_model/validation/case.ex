defmodule PowerModel.Validation.Case do
  @moduledoc """
  Deterministic validation cases used to replay cascading-failure scenarios.

  Each case defines:

  - a synthetic grid snapshot
  - an action script (line/generator trips, or plain cascade run)
  - expected metrics for scoring model behavior
  """

  @enforce_keys [:id, :description, :snapshot, :actions, :expected]
  defstruct [
    :id,
    :description,
    :snapshot,
    :actions,
    :expected,
    base_mva: 100.0,
    cascade_opts: [],
    tags: []
  ]

  @type metric_expectation :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          snapshot: map(),
          actions: [term()],
          expected: %{optional(atom()) => metric_expectation() | term()},
          base_mva: float(),
          cascade_opts: keyword(),
          tags: [atom()]
        }

  @doc """
  Returns the built-in Week 0 fixture cases.
  """
  @spec fixtures() :: [t()]
  def fixtures do
    [
      line_trip_island_blackout_case(),
      generator_trip_ufls_case(),
      harmonics_post_stabilization_case(),
      transient_screening_line_trip_case(),
      voltage_small_signal_post_stabilization_case()
    ]
  end

  @doc """
  Returns all fixture case IDs.
  """
  @spec ids() :: [String.t()]
  def ids do
    fixtures() |> Enum.map(& &1.id)
  end

  @doc """
  Fetch a fixture case by ID.
  """
  @spec fetch(String.t() | atom()) :: {:ok, t()} | :error
  def fetch(id) when is_atom(id), do: fetch(Atom.to_string(id))

  def fetch(id) when is_binary(id) do
    fixtures()
    |> Enum.find(fn fixture -> fixture.id == id end)
    |> case do
      nil -> :error
      fixture -> {:ok, fixture}
    end
  end

  @doc """
  Fetch a fixture case by ID or raise.
  """
  @spec fetch!(String.t() | atom()) :: t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, fixture} ->
        fixture

      :error ->
        raise ArgumentError,
              "unknown validation case #{inspect(id)}. Available IDs: #{Enum.join(ids(), ", ")}"
    end
  end

  defp line_trip_island_blackout_case do
    %__MODULE__{
      id: "line_trip_island_blackout",
      description:
        "Trip the source corridor and verify full downstream island blackout accounting.",
      tags: [:cascade, :islanding, :blackout],
      snapshot: %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [line(1, 1, 2), line(2, 2, 3)],
        transformers: [],
        generators: [generator(1, 1, p_max_mw: 200.0, fuel_type: "NG", cost: 20.0)],
        loads: [load(1, 2, 60.0), load(2, 3, 40.0)]
      },
      actions: [{:trip_line, 1}],
      expected: %{
        stable: %{target: true, comparator: :eq, weight: 1.0},
        cascade_steps: %{target: 1, comparator: :eq, weight: 1.0},
        line_trip_count: %{target: 1, comparator: :eq, weight: 1.0},
        island_blackout_event_count: %{target: 2, comparator: :eq, weight: 2.0},
        blackout_load_mw: %{target: 100.0, tolerance: 1.0e-6, comparator: :approx, weight: 2.0}
      }
    }
  end

  defp generator_trip_ufls_case do
    %__MODULE__{
      id: "generator_trip_ufls_response",
      description:
        "Trip a generator and validate primary response + UFLS behavior under deficit.",
      tags: [:cascade, :frequency, :ufls],
      snapshot: %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 500.0),
          line(2, 2, 3, rating_a_mva: 500.0),
          line(3, 1, 3, rating_a_mva: 500.0)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 60.0, fuel_type: "NG", cost: 20.0),
          generator(2, 2, p_max_mw: 120.0, fuel_type: "NG", cost: 30.0)
        ],
        loads: [load(1, 3, 140.0)]
      },
      actions: [{:trip_generator, 1}],
      expected: %{
        stable: %{target: true, comparator: :eq, weight: 1.0},
        generator_trip_count: %{target: 1, comparator: :eq, weight: 1.0},
        ufls_event_count: %{target: 1, comparator: :eq, weight: 2.0},
        governor_response_event_count: %{target: 1, comparator: :eq, weight: 1.0},
        relay_81_event_count: %{target: 0, comparator: :eq, weight: 1.0},
        ufls_shed_mw: %{target: 20.0, tolerance: 0.05, comparator: :approx, weight: 2.0},
        final_total_load_mw: %{target: 120.0, tolerance: 0.05, comparator: :approx, weight: 1.0},
        min_frequency_hz: %{target: 58.0, tolerance: 0.1, comparator: :lte, weight: 1.0}
      }
    }
  end

  defp harmonics_post_stabilization_case do
    %__MODULE__{
      id: "harmonics_post_stabilization_baseline",
      description: "Run harmonics after stabilization and verify baseline THD/violation outputs.",
      tags: [:harmonics, :post_stabilization],
      snapshot: %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 500.0),
          line(2, 2, 3, rating_a_mva: 500.0),
          line(3, 1, 3, rating_a_mva: 500.0)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 80.0, fuel_type: "SUN", cost: 0.0),
          generator(2, 2, p_max_mw: 120.0, fuel_type: "NG", cost: 20.0)
        ],
        loads: [load(1, 3, 120.0)]
      },
      cascade_opts: [run_harmonics: true],
      actions: [:run_cascade],
      expected: %{
        stable: %{target: true, comparator: :eq, weight: 1.0},
        cascade_steps: %{target: 1, comparator: :eq, weight: 1.0},
        harmonics_result_present: %{target: true, comparator: :eq, weight: 1.0},
        harmonics_violations: %{target: 18, comparator: :eq, weight: 2.0},
        harmonics_worst_thd_pct: %{
          target: 23.05735,
          tolerance: 0.05,
          comparator: :approx,
          weight: 2.0
        }
      }
    }
  end

  defp transient_screening_line_trip_case do
    %__MODULE__{
      id: "transient_screening_line_trip",
      description:
        "Trip a transmission line with transient screening enabled and record stability diagnostics.",
      tags: [:transient, :stability, :cascade],
      snapshot: %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 350.0),
          line(2, 2, 3, rating_a_mva: 350.0),
          line(3, 1, 3, rating_a_mva: 350.0)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 150.0, fuel_type: "NG", cost: 20.0, inertia_h: 4.5),
          generator(2, 2, p_max_mw: 130.0, fuel_type: "NG", cost: 24.0, inertia_h: 4.0)
        ],
        loads: [load(1, 3, 170.0)]
      },
      cascade_opts: [use_transient: true],
      actions: [{:trip_line, 1}],
      expected: %{
        stable: %{target: true, comparator: :eq, weight: 1.0},
        line_trip_count: %{target: 1, comparator: :eq, weight: 1.0},
        transient_checks_run: %{target: 1, comparator: :gte, weight: 2.0},
        transient_screen_event_count: %{target: 1, comparator: :gte, weight: 2.0},
        transient_failed_checks: %{target: 0, comparator: :eq, weight: 2.0}
      }
    }
  end

  defp voltage_small_signal_post_stabilization_case do
    %__MODULE__{
      id: "voltage_small_signal_post_stabilization",
      description:
        "Run CPF and small-signal analyses after stabilization and verify baseline outputs.",
      tags: [:voltage_stability, :small_signal, :post_stabilization],
      snapshot: %{
        buses: [bus(1, bus_type: 3), bus(2), bus(3)],
        lines: [
          line(1, 1, 2, rating_a_mva: 500.0),
          line(2, 2, 3, rating_a_mva: 500.0),
          line(3, 1, 3, rating_a_mva: 500.0)
        ],
        transformers: [],
        generators: [
          generator(1, 1, p_max_mw: 60.0, fuel_type: "NG", cost: 20.0),
          generator(2, 2, p_max_mw: 120.0, fuel_type: "NG", cost: 30.0)
        ],
        loads: [load(1, 3, 140.0)]
      },
      cascade_opts: [run_cpf: true, run_small_signal: true],
      actions: [:run_cascade],
      expected: %{
        stable: %{target: true, comparator: :eq, weight: 1.0},
        cascade_steps: %{target: 1, comparator: :eq, weight: 1.0},
        cpf_result_present: %{target: true, comparator: :eq, weight: 1.0},
        voltage_margin_mw: %{target: 200.0, comparator: :gte, weight: 2.0},
        critical_bus_id: %{target: 1, comparator: :eq, weight: 1.0},
        small_signal_result_present: %{target: true, comparator: :eq, weight: 1.0},
        small_signal_stable: %{target: true, comparator: :eq, weight: 2.0},
        stability_modes_count: %{target: 1, comparator: :gte, weight: 1.0}
      }
    }
  end

  defp bus(id, opts \\ []) do
    %{
      id: id,
      bus_type: Keyword.get(opts, :bus_type, 1),
      base_kv: Keyword.get(opts, :base_kv, 138.0),
      vm_pu: 1.0,
      va_rad: 0.0
    }
  end

  defp line(id, from_bus_id, to_bus_id, opts \\ []) do
    %{
      id: id,
      from_bus_id: from_bus_id,
      to_bus_id: to_bus_id,
      voltage_kv: Keyword.get(opts, :voltage_kv, 138.0),
      r_pu: Keyword.get(opts, :r_pu, 0.01),
      x_pu: Keyword.get(opts, :x_pu, 0.1),
      b_pu: Keyword.get(opts, :b_pu, 0.02),
      rating_a_mva: Keyword.get(opts, :rating_a_mva, 100.0)
    }
  end

  defp generator(id, bus_id, opts) do
    %{
      id: id,
      bus_id: bus_id,
      p_max_mw: Keyword.get(opts, :p_max_mw, 100.0),
      p_min_mw: Keyword.get(opts, :p_min_mw, 0.0),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      q_max_mvar: Keyword.get(opts, :q_max_mvar, 50.0),
      q_min_mvar: Keyword.get(opts, :q_min_mvar, -50.0),
      fuel_type: Keyword.get(opts, :fuel_type, "NG"),
      status: "in_service",
      marginal_cost_per_mwh: Keyword.get(opts, :cost, 35.0),
      inertia_h: Keyword.get(opts, :inertia_h, 3.5),
      droop_pct: Keyword.get(opts, :droop_pct, 4.0),
      gov_time_constant_s: Keyword.get(opts, :gov_time_constant_s, 1.5)
    }
  end

  defp load(id, bus_id, p_mw, opts \\ []) do
    %{
      id: id,
      bus_id: bus_id,
      p_mw: p_mw,
      q_mvar: Keyword.get(opts, :q_mvar, p_mw * 0.3)
    }
  end
end
