defmodule PowerModel.Validation.ReplayTest do
  use PowerModel.DataCase, async: false

  # The scoring tests below are pure: every measurement is a fixture and no
  # query runs. Only the tests tagged :db touch the repository.
  @moduletag :capture_log

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Failure.Cascade

  alias PowerModel.Grid.{
    BalancingAuthority,
    Bus,
    Generator,
    Interconnection,
    Load,
    TransmissionLine
  }

  alias PowerModel.Validation.Replay

  # July -> EIA summer capability season, matching PowerModel.Dispatch.
  @hour ~U[2024-07-15 18:00:00Z]

  # --- fixtures --------------------------------------------------------------

  defp gen(id, opts) do
    Enum.into(opts, %{
      id: id,
      bus_id: Keyword.get(opts, :bus_id, 1),
      fuel_type: "NG",
      prime_mover: "CC",
      p_max_mw: 100.0,
      p_min_mw: 0.0,
      capacity_factor: 0.5,
      status: "in_service"
    })
  end

  defp load(bus_id, p_mw), do: %{bus_id: bus_id, p_mw: p_mw, q_mvar: 0.0, load_type: "estimated"}

  # Two BAs: BA 10 on bus 1, BA 20 on bus 2.
  defp input(overrides) do
    Enum.into(overrides, %{
      hour: @hour,
      generators: [],
      loads: [],
      bus_ba: %{1 => 10, 2 => 20},
      fuel_totals: %{},
      demand: %{},
      interchange: %{},
      ba_codes: %{10 => "ALPHA", 20 => "BETA"}
    })
  end

  defp ba(score, code), do: Enum.find(score.by_ba, &(&1.ba_code == code))

  # ---------------------------------------------------------------------------

  describe "tv_distance/2" do
    test "is zero for identical mixes regardless of scale" do
      assert Replay.tv_distance(%{"coal" => 50.0, "wind" => 50.0}, %{
               "coal" => 5000.0,
               "wind" => 5000.0
             }) == 0.0
    end

    test "is the fraction of generation on the wrong fuel" do
      # Model: half coal, half gas. Actual: all coal. Half the generation
      # would have to move from gas to coal.
      assert Replay.tv_distance(%{"coal" => 50.0, "natural_gas" => 50.0}, %{"coal" => 100.0}) ==
               0.5
    end

    test "is 1.0 for disjoint mixes" do
      assert Replay.tv_distance(%{"solar" => 10.0}, %{"nuclear" => 999.0}) == 1.0
    end

    test "is 1.0 when one side produced nothing and nil when both did" do
      assert Replay.tv_distance(%{}, %{"coal" => 100.0}) == 1.0
      assert Replay.tv_distance(%{"coal" => 0.0}, %{"coal" => 100.0}) == 1.0
      assert Replay.tv_distance(%{}, %{}) == nil
      assert Replay.tv_distance(%{"coal" => 0.0}, %{"coal" => 0.0}) == nil
    end

    test "clamps negative net generation (storage charging) out of the shares" do
      # "other" charging at -40 MW must not become a negative share, nor
      # shrink the denominator below the MW actually generated.
      assert Replay.tv_distance(%{"coal" => 100.0}, %{"coal" => 100.0, "other" => -40.0}) == 0.0
    end

    test "worked example: a third of generation on the wrong fuel" do
      model = %{"coal" => 100.0, "natural_gas" => 200.0}
      actual = %{"coal" => 200.0, "natural_gas" => 100.0}

      # shares 1/3 vs 2/3 and 2/3 vs 1/3 -> 0.5 * (1/3 + 1/3)
      assert_in_delta Replay.tv_distance(model, actual), 1 / 3, 1.0e-12
    end
  end

  describe "score_hour/2 fuel mix" do
    test "a dispatch that reproduces the measurement scores zero everywhere" do
      score =
        Replay.score_hour(
          input(
            generators: [
              gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 100.0, capacity_factor: 0.9),
              gen(2, bus_id: 1, fuel_type: "NG", p_max_mw: 100.0),
              gen(3, bus_id: 2, fuel_type: "NUC", p_max_mw: 100.0)
            ],
            loads: [load(1, 80.0), load(2, 60.0)],
            fuel_totals: %{
              10 => %{"coal" => 100.0, "natural_gas" => 0.0},
              20 => %{"nuclear" => 50.0}
            },
            demand: %{10 => 80.0, 20 => 60.0},
            interchange: %{10 => 20.0, 20 => -10.0}
          )
        )

      assert score.dispatch_source == :eia_fuel
      assert ba(score, "ALPHA").fuel_mix_tv == 0.0
      assert ba(score, "BETA").fuel_mix_tv == 0.0
      assert score.totals.tv_load_weighted == 0.0

      # Absolute measured MW minus served load reproduces reported interchange.
      assert ba(score, "ALPHA").implied_interchange_mw == 20.0
      assert ba(score, "ALPHA").interchange_error_mw == 0.0
      assert ba(score, "BETA").interchange_error_mw == 0.0
      assert score.totals.interchange_mae_mw == 0.0
    end

    test "load-weighted TV weights each BA by its demand, not its count" do
      score =
        Replay.score_hour(
          input(
            generators: [
              # BA 10 is large and right; BA 20 is small and completely wrong.
              gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 1000.0),
              gen(2, bus_id: 2, fuel_type: "NG", p_max_mw: 10.0)
            ],
            loads: [load(1, 900.0), load(2, 10.0)],
            fuel_totals: %{10 => %{"coal" => 1000.0}, 20 => %{"solar" => 10.0}},
            demand: %{10 => 900.0, 20 => 10.0}
          )
        )

      assert ba(score, "ALPHA").fuel_mix_tv == 0.0
      assert ba(score, "BETA").fuel_mix_tv == 1.0

      # Unweighted mean says the model is half wrong; weighted by demand it
      # is 10/910 wrong, which is the honest national number.
      assert score.totals.tv_mean == 0.5
      assert_in_delta score.totals.tv_load_weighted, 10 / 910, 1.0e-12
    end

    test "model MW on a fuel EIA-930 never reports is penalised as unclassified" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "import", p_max_mw: 100.0)],
            loads: [load(1, 100.0)],
            fuel_totals: %{10 => %{"coal" => 0.0}},
            demand: %{10 => 100.0}
          )
        )

      # The import pseudo-generator carries the island's whole residual, and
      # none of it is generation EIA measured.
      assert ba(score, "ALPHA").model_fuel_mw["unclassified"] > 0.0
      assert ba(score, "ALPHA").fuel_mix_tv == 1.0
    end
  end

  describe "score_hour/2 balance and conservation" do
    test "interchange error is implied minus reported" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 100.0)],
            loads: [load(1, 60.0)],
            fuel_totals: %{10 => %{"coal" => 100.0}},
            demand: %{10 => 60.0},
            # The model implies +40 MW of exports; EIA reported +25.
            interchange: %{10 => 25.0}
          )
        )

      assert ba(score, "ALPHA").implied_interchange_mw == 40.0
      assert ba(score, "ALPHA").interchange_error_mw == 15.0
      assert score.totals.interchange_mae_mw == 15.0
      assert score.totals.interchange_bias_mw == 15.0
    end

    test "the interchange error decomposes exactly into placement gap and EIA's own residual" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 100.0)],
            loads: [load(1, 60.0)],
            # 400 MW measured, 100 MW of coal fleet: 300 MW cannot be placed.
            fuel_totals: %{10 => %{"coal" => 400.0}},
            demand: %{10 => 60.0},
            # EIA's own trio misses by 40 MW: 400 - 60 - 300.
            interchange: %{10 => 300.0}
          )
        )

      row = ba(score, "ALPHA")
      assert row.generation_error_mw == -300.0
      assert row.eia_identity_residual_mw == 40.0
      assert row.served_load_error_mw == 0.0
      assert row.interchange_error_mw == -260.0

      # The decomposition is an identity, not an approximation.
      assert row.interchange_error_mw ==
               row.generation_error_mw + row.eia_identity_residual_mw - row.served_load_error_mw

      t = score.totals

      assert_in_delta t.interchange_bias_mw,
                      t.interchange_from_placement_mw + t.interchange_from_eia_residual_mw -
                        t.interchange_from_load_error_mw,
                      1.0e-9
    end

    test "the two coverage universes are reported side by side" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 100.0)],
            loads: [load(1, 500.0)],
            fuel_totals: %{10 => %{"coal" => 400.0}},
            demand: %{10 => 500.0},
            # The snapshot holds 3 of this BA's 30 geolocated buses, yet its
            # loads carry all 500 MW of demand.
            ba_bus_coverage: %{10 => %{snapshot_buses: 3, geolocated_buses: 30, coverage: 0.1}}
          )
        )

      row = ba(score, "ALPHA")
      assert row.bus_coverage == 0.1
      assert row.snapshot_buses == 3
      assert row.generation_coverage == 0.25
      assert row.dispatch_to_load == 0.2
      assert score.totals.bus_coverage_load_weighted == 0.1
      assert score.totals.generation_coverage == 0.25

      # The conservation residual is that asymmetry, not lost dispatch: all
      # 500 MW of load, only the 100 MW of coal the fleet could hold.
      assert score.totals.conservation_residual_mw == -400.0
    end

    test "served-load error and scale factor compare against the pre-scaling baseline" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT")],
            loads: [load(1, 80.0)],
            baseline_loads: [load(1, 160.0)],
            fuel_totals: %{10 => %{"coal" => 80.0}},
            demand: %{10 => 80.0}
          )
        )

      assert ba(score, "ALPHA").served_load_mw == 80.0
      assert ba(score, "ALPHA").baseline_load_mw == 160.0
      assert ba(score, "ALPHA").load_scale_factor == 0.5
      assert ba(score, "ALPHA").served_load_error_mw == 0.0
      assert score.totals.bas_load_unscaled == 0
    end

    test "a BA left on the synthetic baseline shows up as served-load error" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT")],
            # Scaling never ran for this BA: load is twice its real demand.
            loads: [load(1, 160.0)],
            fuel_totals: %{10 => %{"coal" => 80.0}},
            demand: %{10 => 80.0}
          )
        )

      assert ba(score, "ALPHA").served_load_error_mw == 80.0
      assert ba(score, "ALPHA").served_load_error_pct == 1.0
      assert score.totals.bas_load_unscaled == 1
    end

    test "conservation residual is per island" do
      islands = [MapSet.new([1]), MapSet.new([2])]

      score =
        Replay.score_hour(
          input(
            generators: [
              gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 100.0),
              gen(2, bus_id: 2, fuel_type: "NUC", p_max_mw: 100.0)
            ],
            loads: [load(1, 60.0), load(2, 100.0)],
            islands: islands,
            fuel_totals: %{10 => %{"coal" => 100.0}, 20 => %{"nuclear" => 40.0}},
            demand: %{10 => 60.0, 20 => 100.0}
          )
        )

      # Island 1 generates 100 against 60 of load, island 2 only 40 against
      # 100: +40 and -60 net to -20 but sum to 100 in absolute terms.
      assert score.islands.count == 2
      assert score.islands.residual_mw == -20.0
      assert score.islands.abs_residual_mw == 100.0
      assert score.totals.conservation_residual_mw == -20.0
    end
  end

  describe "score_hour/2 unplaced measured MW (REVIEW ENE-15)" do
    test "measured MW with no unit of that fuel is unmatched, per fuel" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "NG", p_max_mw: 100.0)],
            loads: [load(1, 100.0)],
            # The BA reports 900 MW of nuclear; the model owns no nuclear unit.
            fuel_totals: %{10 => %{"natural_gas" => 100.0, "nuclear" => 900.0}},
            demand: %{10 => 100.0}
          )
        )

      assert score.gap_by_fuel["nuclear"].unmatched_mw == 900.0
      assert score.gap_by_fuel["nuclear"].unserved_mw == 0.0
      assert score.totals.unplaced_nuclear_mw == 900.0
      assert score.totals.unmatched_mw == 900.0
    end

    test "measured MW beyond the fleet's capability is unserved, per fuel" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 2, fuel_type: "NUC", p_max_mw: 100.0)],
            loads: [load(2, 500.0)],
            fuel_totals: %{20 => %{"nuclear" => 500.0}},
            demand: %{20 => 500.0}
          )
        )

      # One 100 MW unit cannot absorb 500 MW of measured nuclear.
      assert score.gap_by_fuel["nuclear"].unserved_mw == 400.0
      assert score.totals.unplaced_nuclear_mw == 400.0
      assert score.totals.unplaced_mw == 400.0
    end

    test "the legacy dispatch has no coverage, so the gap is not reported" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "NG")],
            loads: [load(1, 50.0)],
            fuel_totals: %{10 => %{"nuclear" => 900.0}},
            demand: %{10 => 50.0}
          ),
          mode: :legacy
        )

      assert score.dispatch_source == :proportional
      assert score.gap_by_fuel == nil
      assert score.totals.unplaced_mw == nil
    end
  end

  describe "score_hour/2 scope" do
    test "reporting BAs with no bus in the snapshot are listed, never scored" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT")],
            loads: [load(1, 100.0)],
            fuel_totals: %{
              10 => %{"coal" => 100.0},
              # BA 99 owns no bus in bus_ba.
              99 => %{"hydro" => 700.0}
            },
            demand: %{10 => 100.0, 99 => 700.0},
            ba_codes: %{10 => "ALPHA", 99 => "OUTSIDE"}
          )
        )

      assert Enum.map(score.by_ba, & &1.ba_code) == ["ALPHA"]
      assert [%{ba_code: "OUTSIDE", actual_generation_mw: 700.0}] = score.unmodeled_bas
      assert score.totals.bas_scored == 1
      assert score.totals.bas_reporting == 2
    end

    test "a modeled BA with no generators scores 1.0 rather than disappearing" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT")],
            loads: [load(1, 100.0), load(2, 50.0)],
            fuel_totals: %{10 => %{"coal" => 100.0}, 20 => %{"hydro" => 50.0}},
            demand: %{10 => 100.0, 20 => 50.0}
          )
        )

      assert ba(score, "BETA").fuel_mix_tv == 1.0
      assert ba(score, "BETA").model_generation_mw == 0.0
      assert ba(score, "BETA").actual_generation_mw == 50.0
    end
  end

  describe "dispatch parity with the simulator" do
    setup do
      buses = [
        %{id: 1, bus_type: 3, base_kv: 345.0, balancing_authority_id: 10},
        %{id: 2, bus_type: 1, base_kv: 345.0, balancing_authority_id: 20}
      ]

      snapshot = %{
        buses: buses,
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            r_pu: 0.01,
            x_pu: 0.1,
            b_pu: 0.0,
            rating_a_mva: 500.0,
            status: "in_service"
          }
        ],
        transformers: [],
        generators: [
          gen(1, bus_id: 1, fuel_type: "BIT", p_max_mw: 200.0, capacity_factor: 0.8),
          gen(2, bus_id: 2, fuel_type: "NG", p_max_mw: 300.0, capacity_factor: 0.3)
        ],
        loads: [load(1, 120.0), load(2, 80.0)]
      }

      {:ok, snapshot: snapshot}
    end

    test "the measured dispatch is the one Cascade.init/3 would run", %{snapshot: snapshot} do
      fuel_totals = %{10 => %{"coal" => 150.0}, 20 => %{"natural_gas" => 60.0}}

      state = Cascade.init(snapshot, 100.0, hour: @hour, fuel_totals: fuel_totals)

      {dispatch, source, _coverage} =
        Replay.dispatch_for(%{
          hour: @hour,
          generators: snapshot.generators,
          loads: snapshot.loads,
          bus_ba: %{1 => 10, 2 => 20},
          islands: [MapSet.new([1, 2])],
          fuel_totals: fuel_totals
        })

      assert source == :eia_fuel
      assert state.dispatch_source == :eia_fuel
      assert dispatch == state.dispatch
    end

    test "legacy_dispatch/3 is the rule Cascade falls back to", %{snapshot: snapshot} do
      # No hour -> Cascade uses its private balance_dispatch_per_island.
      state = Cascade.init(snapshot, 100.0, [])

      dispatch =
        Replay.legacy_dispatch(snapshot.generators, snapshot.loads, [MapSet.new([1, 2])])

      assert state.dispatch_source == :proportional
      assert dispatch == state.dispatch

      # 200 MW of load against 500 MW of capacity: everyone at 40%.
      assert dispatch[1] == 80.0
      assert dispatch[2] == 120.0
    end
  end

  describe "presentation" do
    test "presentable/1 makes a score JSON-safe and stable" do
      score =
        Replay.score_hour(
          input(
            generators: [gen(1, bus_id: 1, fuel_type: "BIT")],
            loads: [load(1, 100.0)],
            fuel_totals: %{10 => %{"coal" => 100.0}},
            demand: %{10 => 100.0}
          )
        )

      json = score |> Replay.presentable() |> Jason.encode!()
      decoded = Jason.decode!(json)

      assert decoded["hour"] == DateTime.to_iso8601(@hour)
      assert decoded["mode"] == "measured"
      assert decoded["dispatch_source"] == "eia_fuel"
      assert [%{"ba_code" => "ALPHA"} = alpha] = decoded["by_ba"]
      assert alpha["fuel_mix_tv"] == 0.0

      # Encoding is a pure function of the score: two passes are byte-identical.
      assert json == score |> Replay.presentable() |> Jason.encode!()
    end

    test "presentable/1 rounds floats so unrelated runs do not diff" do
      assert Replay.presentable(%{tv: 0.1234567891}) == %{"tv" => 0.123457}
    end

    test "summary_lines/1 emits greppable key=value pairs per mode" do
      report = %{
        schema_version: 1,
        comparison: nil,
        modes: [
          %{
            mode: :measured,
            summary: %{
              hours: 3,
              bas_scored: 54,
              tv_load_weighted: 0.1054,
              tv_generation_weighted: 0.109,
              tv_mean: 0.3167,
              interchange_mae_mw: 1412.5,
              served_load_mape: 0.0,
              conservation_residual_mw: -60_382.6,
              unplaced_mw: 57_360.6,
              unplaced_nuclear_mw: 24_178.6
            }
          }
        ]
      }

      assert [line] = Replay.summary_lines(report)
      assert line =~ "REPLAY schema=1 mode=measured"
      assert line =~ "hours=3"
      assert line =~ "tv_load_weighted=0.1054"
      assert line =~ "unplaced_nuclear_mw=24178.6000"
    end

    test "summary_lines/1 adds a delta line when the legacy dispatch ran" do
      summary = fn tv ->
        %{
          hours: 2,
          bas_scored: 5,
          tv_load_weighted: tv,
          tv_generation_weighted: tv,
          tv_mean: tv,
          interchange_mae_mw: 0.0,
          served_load_mape: 0.0,
          conservation_residual_mw: 0.0,
          unplaced_mw: 0.0,
          unplaced_nuclear_mw: 0.0
        }
      end

      report = %{
        schema_version: 1,
        modes: [
          %{mode: :measured, summary: summary.(0.10)},
          %{mode: :legacy, summary: summary.(0.30)}
        ],
        comparison: %{tv_load_weighted: %{measured: 0.10, legacy: 0.30, delta: -0.20}}
      }

      assert [_measured, _legacy, delta] = Replay.summary_lines(report)
      assert delta =~ "mode=delta"
      assert delta =~ "tv_load_weighted=-0.2000"
    end
  end

  # ---------------------------------------------------------------------------
  # Database-backed: hour selection and one end-to-end replay
  # ---------------------------------------------------------------------------

  describe "hour selection" do
    @describetag :db

    test "takes the most recent COMPLETE hours and skips the boundary hour" do
      # Three BAs report two full hours; only one reports the third, which is
      # the partial hour a bulk EIA file ends on (REVIEW ENE-13).
      for code <- ~w(AAA BBB CCC), hour <- [~U[2024-07-15 16:00:00Z], ~U[2024-07-15 17:00:00Z]] do
        insert_fuel(code, hour, "coal", 100.0)
      end

      insert_fuel("AAA", ~U[2024-07-15 18:00:00Z], "coal", 100.0)

      assert [%{hour: ~U[2024-07-15 17:00:00Z], reporting_bas: 3, complete?: true}] =
               Replay.hours(hours: 1)

      assert Replay.hours(hours: 5) |> Enum.map(& &1.hour) == [
               ~U[2024-07-15 16:00:00Z],
               ~U[2024-07-15 17:00:00Z]
             ]
    end

    test "a from/to window replays incomplete hours too, flagged" do
      for code <- ~w(AAA BBB CCC), hour <- [~U[2024-07-15 16:00:00Z], ~U[2024-07-15 17:00:00Z]] do
        insert_fuel(code, hour, "coal", 100.0)
      end

      insert_fuel("AAA", ~U[2024-07-15 18:00:00Z], "coal", 100.0)

      hours = Replay.hours(from: ~U[2024-07-15 17:00:00Z], to: ~U[2024-07-15 18:00:00Z])

      assert Enum.map(hours, & &1.hour) == [
               ~U[2024-07-15 17:00:00Z],
               ~U[2024-07-15 18:00:00Z]
             ]

      assert Enum.map(hours, & &1.complete?) == [true, false]
    end
  end

  describe "run/1 end to end" do
    @describetag :db

    test "an un-ingested database yields an empty report rather than an error" do
      report = Replay.run(hours: 3)

      assert report.hours == []
      assert report.window == nil
      assert [%{summary: %{hours: 0}}] = report.modes
      assert Jason.decode!(Mix.Tasks.PowerModel.Validate.encode_json(report))["hours"] == []
    end

    test "replays a real hour through the snapshot and scores it" do
      hour = ~U[2024-07-15 17:00:00Z]
      seed_grid(hour)

      report = Replay.run(hours: 1, legacy: true)

      assert report.schema_version == Replay.schema_version()
      assert report.hours == [hour]
      assert report.scope.buses == 2
      assert [measured, legacy] = report.modes
      assert measured.mode == :measured
      assert legacy.mode == :legacy

      summary = measured.summary
      assert summary.hours == 1
      assert summary.dispatch_sources == %{eia_fuel: 1}

      # The whole point of the harness: a finite, comparable number.
      assert is_float(summary.tv_load_weighted)
      assert summary.tv_load_weighted >= 0.0 and summary.tv_load_weighted <= 1.0
      assert is_float(legacy.summary.tv_load_weighted)

      assert report.comparison.tv_load_weighted.delta ==
               summary.tv_load_weighted - legacy.summary.tv_load_weighted

      # Loads were scaled to the hour, so served load matches EIA demand.
      assert_in_delta summary.served_load_mae_mw, 0.0, 1.0e-6

      json = Mix.Tasks.PowerModel.Validate.encode_json(report)
      assert Jason.decode!(json)["modes"] |> length() == 2
      assert json == Mix.Tasks.PowerModel.Validate.encode_json(report)

      assert [measured_line, _legacy_line, _delta] = Replay.summary_lines(report)
      assert measured_line =~ "mode=measured hours=1"
    end
  end

  # --- database fixtures -----------------------------------------------------

  defp insert_fuel(code, hour, fuel, mw) do
    Repo.insert!(%BAFuelHour{
      ba_code: code,
      timestamp_utc: hour,
      fuel: fuel,
      net_generation_mw: mw
    })
  end

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  # A two-bus, one-line interconnection with one coal and one gas unit, one
  # BA, and one hour of matching EIA-930 demand and per-fuel generation.
  defp seed_grid(hour) do
    ic = Repo.insert!(%Interconnection{name: "TestIC"})
    ba = Repo.insert!(%BalancingAuthority{code: "AAA", name: "Alpha"})

    from_bus = insert_bus(ic, ba, -96.0, 32.0)
    to_bus = insert_bus(ic, ba, -96.5, 32.5)

    Repo.insert!(%TransmissionLine{
      from_bus_id: from_bus.id,
      to_bus_id: to_bus.id,
      voltage_kv: 345.0,
      length_km: 50.0,
      r_pu: 0.01,
      x_pu: 0.1,
      b_pu: 0.0,
      rating_a_mva: 900.0,
      status: "in_service",
      source: "test",
      source_id: "line-1"
    })

    insert_generator(from_bus, "BIT", 400.0, 0.8)
    insert_generator(to_bus, "NG", 400.0, 0.4)

    Repo.insert!(%Load{bus_id: from_bus.id, p_mw: 300.0, q_mvar: 60.0, status: "in_service"})
    Repo.insert!(%Load{bus_id: to_bus.id, p_mw: 100.0, q_mvar: 20.0, status: "in_service"})

    Repo.insert!(%BADemandHour{
      balancing_authority_id: ba.id,
      timestamp_utc: hour,
      demand_mw: 500.0,
      net_generation_mw: 550.0,
      total_interchange_mw: 50.0
    })

    insert_fuel("AAA", hour, "coal", 350.0)
    insert_fuel("AAA", hour, "natural_gas", 200.0)
  end

  defp insert_bus(ic, ba, lon, lat) do
    Repo.insert!(%Bus{
      bus_type: 1,
      base_kv: 345.0,
      coordinates: point(lon, lat),
      interconnection_id: ic.id,
      balancing_authority_id: ba.id,
      source: "substation",
      source_id: "bus-#{System.unique_integer([:positive])}"
    })
  end

  defp insert_generator(bus, fuel_type, p_max_mw, capacity_factor) do
    Repo.insert!(%Generator{
      bus_id: bus.id,
      fuel_type: fuel_type,
      prime_mover: "ST",
      p_max_mw: p_max_mw,
      p_min_mw: 0.0,
      capacity_factor: capacity_factor,
      status: "in_service"
    })
  end
end
