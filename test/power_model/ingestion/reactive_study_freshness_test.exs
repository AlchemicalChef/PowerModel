defmodule PowerModel.Ingestion.ReactiveStudyFreshnessTest do
  @moduledoc """
  The hard gate for REVIEW DAT-30/DAT-31: a measured study applied to a
  network it was not measured on.

  The split between warn and fail is the point of these tests.
  `ParameterEstimator` only warns, because a hard stop inside the ingest
  pipeline would be worse than slightly-stale banks; the failure belongs in
  validation, where CI reads it and nothing is half-written. And "unstamped"
  must never be treated as "fresh" — the 2026-08-19 study was unstamped, and
  reading that as passing is exactly how it reached a network it did not
  describe.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid
  alias PowerModel.Grid.{Bus, Interconnection}
  alias PowerModel.Ingestion.Validation
  alias PowerModel.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "reactive_study_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # A study is only stale RELATIVE TO a network, so the gate skips a database
    # with no buses. These tests are about the comparison, so they need one.
    {:ok, ic} = Repo.insert(%Interconnection{name: "StudyFreshness"})

    {:ok, _bus} =
      Repo.insert(%Bus{
        base_kv: 138.0,
        bus_type: 1,
        source: "substation",
        source_id: "fresh_1_138.0kV",
        interconnection_id: ic.id
      })

    {:ok, dir: dir}
  end

  defp write(dir, study) do
    path = Path.join(dir, "study.json")
    File.write!(path, Jason.encode!(study))
    path
  end

  defp current_stamp do
    sig = Grid.network_signature()

    %{
      "counts" => Map.new(sig.counts, fn {k, v} -> {to_string(k), v} end),
      "digest" => Map.new(sig.digest, fn {k, v} -> {to_string(k), v} end)
    }
  end

  test "a study stamped with the current network passes", %{dir: dir} do
    path = write(dir, %{"banks" => [], "measured_on" => "2026-08-22", "inputs" => current_stamp()})

    {_tag, report} = Validation.reactive_study_freshness(study_path: path)

    assert report.status == :ok
    assert report.failures == []
    assert report.warnings == []
  end

  test "a drifted study FAILS and names the fix", %{dir: dir} do
    stamp = current_stamp()
    drifted = put_in(stamp, ["digest", "buses"], "0000000000000000")
    path = write(dir, %{"banks" => [], "measured_on" => "2026-08-19", "inputs" => drifted})

    {_tag, report} = Validation.reactive_study_freshness(study_path: path)

    assert report.status == :error
    assert [failure] = report.failures
    assert failure =~ "mix power_model.reactive_study"
    assert failure =~ "DIFFERENT network"
  end

  test "an UNSTAMPED study warns rather than passing silently", %{dir: dir} do
    path = write(dir, %{"banks" => [], "measured_on" => "2026-08-19"})

    {_tag, report} = Validation.reactive_study_freshness(study_path: path)

    assert report.status == :warn
    assert report.failures == [], "unstamped is unknown, not stale — it must not fail the run"
    assert [warning] = report.warnings
    assert warning =~ "cannot be checked"
  end

  test "an un-ingested database SKIPS rather than failing", %{dir: dir} do
    # Without this the gate fails on every fresh checkout and every CI run
    # against an empty database — the exact false-alarm the digest was chosen
    # to avoid.
    Repo.delete_all(Bus)
    path = write(dir, %{"banks" => [], "measured_on" => "2026-08-19", "inputs" => %{"digest" => %{"buses" => "stale"}}})

    {_tag, report} = Validation.reactive_study_freshness(study_path: path)

    assert report.status == :skipped
    assert report.failures == []
  end

  test "an absent study warns, because a checkout without it still ingests", %{dir: dir} do
    {_tag, report} = Validation.reactive_study_freshness(study_path: Path.join(dir, "nope.json"))

    assert report.status == :warn
    assert report.failures == []
    assert hd(report.warnings) =~ "No reactive support study"
  end

  test "a corrupt study warns rather than crashing the whole validation run", %{dir: dir} do
    path = Path.join(dir, "bad.json")
    File.write!(path, "{not json")

    {_tag, report} = Validation.reactive_study_freshness(study_path: path)

    assert report.status == :warn
    assert hd(report.warnings) =~ "not valid JSON"
  end

  # Deliberately NOT "the shipped study matches this database": the test
  # database is empty, so it never can. What CI can check is that the artifact
  # carries a stamp at all — the property whose absence let the 2026-08-19
  # study travel to a network it did not describe.
  test "the shipped study carries an inputs signature" do
    path = PowerModel.Ingestion.ParameterEstimator.generator_support_study_path()

    if File.exists?(path) do
      study = path |> File.read!() |> Jason.decode!()

      assert is_map(study["inputs"]),
             "priv/reactive_planning/reactive_support_banks.json has no `inputs` block — " <>
               "re-derive it with `mix power_model.reactive_study`"

      assert is_map(study["inputs"]["digest"]) and study["inputs"]["digest"] != %{},
             "the study's `inputs` carries no content digest, so drift cannot be detected"

      assert study["generated_by"] == "mix power_model.reactive_study",
             "the study must record its producer (REVIEW DAT-31)"
    end
  end
end
