defmodule PowerModel.GridNetworkSignatureTest do
  @moduledoc """
  `Grid.network_signature/0` is the stamp that tells a measured artifact
  whether the network it was solved on still exists.

  The property that matters most is the negative one: applying a study must
  NOT invalidate its own stamp. `synthesize_bus_shunts/1` writes
  `buses.bs_mvar`, so a signature over `max(updated_at)` — the obvious
  implementation, and the one `export_signature/0` uses for a different job —
  would go stale the instant the study was used, and a gate that always fires
  is a gate everyone learns to ignore.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.Grid.{Bus, Generator, Interconnection, TransmissionLine}
  alias PowerModel.Repo

  defp seed do
    {:ok, ic} = Repo.insert(%Interconnection{name: "SigTest"})

    {:ok, a} =
      Repo.insert(%Bus{
        base_kv: 138.0,
        bus_type: 1,
        source: "substation",
        source_id: "sig_a_138.0kV",
        interconnection_id: ic.id,
        bs_mvar: 0.0
      })

    {:ok, b} =
      Repo.insert(%Bus{
        base_kv: 138.0,
        bus_type: 1,
        source: "substation",
        source_id: "sig_b_138.0kV",
        interconnection_id: ic.id,
        bs_mvar: 0.0
      })

    {:ok, line} =
      Repo.insert(%TransmissionLine{
        from_bus_id: a.id,
        to_bus_id: b.id,
        voltage_kv: 138.0,
        r_pu: 0.01,
        x_pu: 0.05,
        b_pu: 0.001,
        rating_a_mva: 200.0,
        status: "in_service",
        source: "test"
      })

    %{ic: ic, a: a, b: b, line: line}
  end

  test "a stamp matches itself" do
    seed()
    sig = Grid.network_signature()
    assert Grid.network_signature_drift(stored(sig)) == []
  end

  test "an unstamped artifact is UNKNOWN, not fresh" do
    assert Grid.network_signature_drift(nil) == [:unstamped]
    assert Grid.network_signature_drift(%{}) == [:unstamped]
    assert Grid.network_signature_drift(%{"digest" => %{}}) == [:unstamped]
  end

  test "writing bs_mvar — the study's own output — does NOT invalidate the stamp" do
    %{a: a} = seed()
    sig = Grid.network_signature()

    {:ok, _} = a |> Ecto.Changeset.change(%{bs_mvar: -75.0}) |> Repo.update()

    assert Grid.network_signature_drift(stored(sig)) == [],
           "applying a reactive study must not invalidate the stamp it was derived under"
  end

  test "a voltage restamp DOES invalidate it — the 2026-08-19 failure" do
    %{a: a} = seed()
    sig = Grid.network_signature()

    {:ok, _} =
      a |> Ecto.Changeset.change(%{base_kv: 69.0, source_id: "sig_a_69.0kV"}) |> Repo.update()

    drift = Grid.network_signature_drift(stored(sig))
    assert "buses: contents changed" in drift
  end

  test "an impedance change invalidates it — the case that would have been silent" do
    %{line: line} = seed()
    sig = Grid.network_signature()

    {:ok, _} = line |> Ecto.Changeset.change(%{x_pu: 0.42}) |> Repo.update()

    drift = Grid.network_signature_drift(stored(sig))

    assert "transmission_lines: contents changed" in drift,
           "bank keys survive an impedance change, so nothing else would have caught this"
  end

  test "adding a row shows up as a count difference, named" do
    %{ic: ic} = seed()
    sig = Grid.network_signature()

    {:ok, _} =
      Repo.insert(%Bus{
        base_kv: 138.0,
        bus_type: 1,
        source: "substation",
        source_id: "sig_c_138.0kV",
        interconnection_id: ic.id
      })

    drift = Grid.network_signature_drift(stored(sig))
    assert Enum.any?(drift, &String.starts_with?(&1, "buses: "))
  end

  test "a NULL moving between adjacent columns changes the digest" do
    # `concat_ws` OMITS null arguments rather than emitting an empty field, so
    # a bare `col::text` list hashes ('100', NULL, '-50') and ('100', '-50',
    # NULL) identically. Verified in psql 2026-08-23, and not hypothetical —
    # 27 in-service lines carry a null in these columns today. The digest
    # coalesces for exactly this reason; `q_max_mvar` and `q_min_mvar` are
    # adjacent in the generator column list and both nullable, which is the
    # collision in its smallest form.
    %{a: a} = seed()

    {:ok, gen} =
      Repo.insert(%Generator{
        bus_id: a.id,
        generator_id: "sigtest-1",
        fuel_type: "natural_gas",
        p_max_mw: 100.0,
        q_max_mvar: nil,
        q_min_mvar: -50.0,
        status: "in_service"
      })

    sig = Grid.network_signature()

    # Swap the value and the NULL between the two columns: same multiset of
    # non-null fields, different row.
    {:ok, _} =
      gen
      |> Ecto.Changeset.change(%{q_max_mvar: -50.0, q_min_mvar: nil})
      |> Repo.update()

    drift = Grid.network_signature_drift(stored(sig))

    assert "generators: contents changed" in drift,
           "a value moving between two nullable columns must change the digest"
  end

  defp stored(%{counts: counts, digest: digest}) do
    %{
      "counts" => Map.new(counts, fn {k, v} -> {to_string(k), v} end),
      "digest" => Map.new(digest, fn {k, v} -> {to_string(k), v} end)
    }
  end
end
