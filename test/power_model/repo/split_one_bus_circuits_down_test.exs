defmodule PowerModel.Repo.SplitOneBusCircuitsDownTest do
  @moduledoc """
  REVIEW DAT-27: migration 20260816150000's `down/0` deleted the synthetic
  buses it created while 102 generators — put there afterwards by migration
  150003, whose own `down/0` is `:ok` — still pointed at them, so the rollback
  raised `foreign_key_violation` on `generators_bus_id_fkey` and left the
  database halfway reversed.

  The down is driven through `Ecto.Migration.Runner.run/8` rather than
  `Ecto.Migrator.down/4`. The Migrator wraps the migration in a Task, and a
  Task checks out its OWN connection — so it escapes the sandbox here, and it
  escapes an enclosing `Repo.transaction` on a real database too (that is how
  a rollback of this very migration reached power_model_dev). `Runner.run/8`
  performs the operation in the CALLING process, which is this test's
  sandboxed connection.
  """
  use PowerModel.DataCase, async: false

  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  @moduletag :db

  @version 20_260_816_150_000
  @path "priv/repo/migrations/20260816150000_split_one_bus_circuits.exs"

  defp run_down(module) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      module,
      :forward,
      :down,
      :down,
      log: false
    )
  end

  setup do
    [{module, _}] = Code.compile_file(@path)

    real = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, source: "substation", source_id: "S1"})

    from_bus =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        source: "synthetic",
        source_id: "line_4242_from"
      })

    to_bus =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        source: "synthetic",
        source_id: "line_4242_to"
      })

    split_line =
      Repo.insert!(%TransmissionLine{
        from_bus_id: from_bus.id,
        to_bus_id: to_bus.id,
        voltage_kv: 138.0,
        status: "in_service",
        source: "hifld",
        source_id: "L4242"
      })

    # A line the split never touched: it must come through untouched.
    untouched =
      Repo.insert!(%TransmissionLine{
        from_bus_id: real.id,
        to_bus_id: from_bus.id,
        voltage_kv: 138.0,
        status: "in_service",
        source: "hifld",
        source_id: "L4243"
      })

    %{
      module: module,
      real: real,
      from_bus: from_bus,
      to_bus: to_bus,
      split_line: split_line,
      untouched: untouched
    }
  end

  test "down/0 raises the FK violation once a generator sits on a synthetic bus (pre-fix)",
       %{from_bus: from_bus} do
    # The pre-fix statements, verbatim, to hold the defect in place: unmap the
    # line endpoints, then delete. This is the repro, not the fix.
    Repo.insert!(%Generator{p_max_mw: 250.0, bus_id: from_bus.id, status: "in_service"})

    Repo.query!("""
    UPDATE transmission_lines tl
    SET from_bus_id = CASE WHEN fb.source_id LIKE 'line\\_%' THEN NULL ELSE tl.from_bus_id END,
        to_bus_id   = CASE WHEN tb.source_id LIKE 'line\\_%' THEN NULL ELSE tl.to_bus_id END
    FROM buses fb, buses tb
    WHERE fb.id = tl.from_bus_id AND tb.id = tl.to_bus_id
    """)

    assert_raise Postgrex.Error, ~r/foreign_key_violation|generators_bus_id_fkey/, fn ->
      Repo.query!("DELETE FROM buses WHERE source = 'synthetic' AND source_id LIKE 'line\\_%'")
    end
  end

  test "down/0 unmaps the generators first and completes", %{
    module: module,
    from_bus: from_bus,
    to_bus: to_bus,
    split_line: split_line,
    untouched: untouched,
    real: real
  } do
    gen = Repo.insert!(%Generator{p_max_mw: 250.0, bus_id: from_bus.id, status: "in_service"})

    run_down(module)

    refute Repo.get(Bus, from_bus.id)
    refute Repo.get(Bus, to_bus.id)
    assert Repo.get(Bus, real.id)

    # Unmapped, not deleted: `mix power_model.ingest map_buses` is a fill pass
    # and re-places exactly the NULLs this leaves.
    assert Repo.get(Generator, gen.id).bus_id == nil

    reloaded = Repo.get(TransmissionLine, split_line.id)
    assert reloaded.from_bus_id == nil
    assert reloaded.to_bus_id == nil

    # The half of the untouched line that pointed at a real bus is preserved.
    survivor = Repo.get(TransmissionLine, untouched.id)
    assert survivor.from_bus_id == real.id
    assert survivor.to_bus_id == nil
  end

  test "a line with a synthetic bus on one end and NULL on the other is still unmapped",
       %{module: module, from_bus: from_bus, real: real} do
    # The old two-endpoint join had no row to match the NULL side against and
    # skipped these lines whole, so the DELETE met them as orphans.
    half =
      Repo.insert!(%TransmissionLine{
        from_bus_id: from_bus.id,
        to_bus_id: nil,
        voltage_kv: 138.0,
        status: "in_service",
        source: "hifld",
        source_id: "L4244"
      })

    run_down(module)

    assert Repo.get(TransmissionLine, half.id).from_bus_id == nil
    assert Repo.get(Bus, real.id)
  end

  test "a referent this file cannot null refuses with the map_buses pointer", %{
    module: module,
    from_bus: from_bus
  } do
    # A load carries an allocation `estimate_loads` owns; nulling it here would
    # destroy that silently, so the down declines rather than guess.
    Repo.insert!(%Load{p_mw: 40.0, bus_id: from_bus.id})

    assert_raise RuntimeError, ~r/loads\.bus_id.*map_buses/s, fn ->
      run_down(module)
    end

    # Nothing was half-applied.
    assert Repo.get(Bus, from_bus.id)
  end
end
