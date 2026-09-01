defmodule PowerModel.Ingestion.Epa.CemsTest do
  use ExUnit.Case, async: true

  alias PowerModel.Ingestion.Epa.Cems

  # The model's reference peak hour; the vendored CEMS day covers it.
  @hour ~U[2024-07-15 21:00:00Z]

  test "plant_id canonicalises the ORIS/EIA join key" do
    assert Cems.plant_id("0123") == "123"
    assert Cems.plant_id(123) == "123"
    assert Cems.plant_id(" 55501 ") == "55501"
    assert Cems.plant_id("3470S") == nil
    assert Cems.plant_id(nil) == nil
  end

  test "measured_at reads the vendored day at local standard time" do
    measured = Cems.measured_at(@hour)

    # W A Parish (ORIS 3470) sits in CST, so 21:00Z is its hour 15. The CSV
    # says: gas units WAP1 114 + WAP4 493 (WAP2/WAP3 idle), coal units WAP5-8
    # 404 + 560 + 497 + 645 — verified by hand against the vendored file.
    assert measured["3470"] == %{"natural_gas" => 607.0, "coal" => 2106.0}

    # The whole monitored fleet reports, idle plants included.
    assert map_size(measured) > 1000
  end

  test "an hour outside the vendored day measures nothing" do
    assert Cems.measured_at(~U[2023-01-01 05:00:00Z]) == %{}
  end
end
