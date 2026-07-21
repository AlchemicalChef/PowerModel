defmodule PowerModel.Ingestion.EIA.Form860Test do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PowerModel.Ingestion.EIA.Form860

  describe "parse_status/1" do
    test "OP / OPERATING map to in_service" do
      assert Form860.parse_status("OP") == "in_service"
      assert Form860.parse_status("OPERATING") == "in_service"
      # tolerant of surrounding whitespace and case
      assert Form860.parse_status(" op ") == "in_service"
    end

    test "SB maps to standby (available, but not counted toward the load baseline)" do
      assert Form860.parse_status("SB") == "standby"
    end

    test "OS (out of service) is not in service" do
      assert Form860.parse_status("OS") == "out_of_service"
      refute Form860.parse_status("OS") == "in_service"
    end

    test "RE maps to retired" do
      assert Form860.parse_status("RE") == "retired"
      refute Form860.parse_status("RE") == "in_service"
    end

    test "planned / proposed / under-construction / cancelled codes are not in service" do
      # These units are not currently generating; counting them would inflate
      # the synthetic load baseline (85% of in-service nameplate).
      for code <- ~w(TS T U V L P OT CN) do
        assert Form860.parse_status(code) == "out_of_service",
               "expected #{code} to be out_of_service"

        refute Form860.parse_status(code) == "in_service"
      end
    end

    test "unknown code defaults to not-in-service and logs a warning with the code" do
      log =
        capture_log(fn ->
          assert Form860.parse_status("ZZ") == "out_of_service"
        end)

      assert log =~ "ZZ"
      assert log =~ "out_of_service"
    end

    test "missing status (nil or blank) defaults to in_service without warning" do
      # The Schedule 3.1 file lists existing units; an absent column or blank
      # cell is assumed operating rather than silently dropped.
      log =
        capture_log(fn ->
          assert Form860.parse_status(nil) == "in_service"
          assert Form860.parse_status("") == "in_service"
          assert Form860.parse_status("   ") == "in_service"
        end)

      refute log =~ "unrecognized"
    end
  end
end
