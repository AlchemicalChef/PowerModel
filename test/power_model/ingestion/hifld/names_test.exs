defmodule PowerModel.Ingestion.HIFLD.NamesTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.HIFLD.Names

  describe "normalize/1" do
    test "upcases, trims, and collapses internal whitespace" do
      assert Names.normalize("  midway  junction ") == "MIDWAY JUNCTION"
      assert Names.normalize("Dead  Head") == "DEAD HEAD"
    end

    test "blank and non-binary inputs have no name" do
      assert Names.normalize("") == nil
      assert Names.normalize("   ") == nil
      assert Names.normalize(nil) == nil
      assert Names.normalize(42) == nil
    end
  end

  describe "identifying?/1 — bare sentinels are excluded" do
    test "the placeholder names identify nothing" do
      refute Names.identifying?("NOT AVAILABLE")
      refute Names.identifying?(" not available ")
      refute Names.identifying?("NONE")
      refute Names.identifying?("N/A")
      refute Names.identifying?("UNKNOWN")
      refute Names.identifying?("TAP")
      refute Names.identifying?("RISER")
      refute Names.identifying?("DEAD HEAD")
      refute Names.identifying?("DEADHEAD")
      refute Names.identifying?("DEAD END")
      refute Names.identifying?(nil)
      refute Names.identifying?("")
    end

    test "every DEAD-prefixed variant is excluded, suffix or not" do
      # "DEAD END176040" appears on line endpoints but names no substation:
      # only 3 of the 28 such endpoints resolve, so the whole family is out.
      refute Names.identifying?("DEAD END176040")
      refute Names.identifying?("DEADEND176040")
      refute Names.identifying?("DEAD HEAD 12")
    end
  end

  describe "identifying?/1 — HIFLD's suffixed ids are real keys" do
    test "UNKNOWN<id> and TAP<id> identify one yard each" do
      # Measured across the two pinned snapshots: 37,625 distinct UNKNOWN* and
      # 20,567 distinct TAP* names, of which exactly one is carried by more
      # than one substation. Excluding them would throw away 113,443 of the
      # 189,238 endpoint identities.
      assert Names.identifying?("UNKNOWN107655")
      assert Names.identifying?("TAP176040")
    end

    test "ordinary substation names identify" do
      assert Names.identifying?("MIDWAY")
      assert Names.identifying?("KEYSTONE")
      assert Names.identifying?("WESTAP")
    end
  end
end
