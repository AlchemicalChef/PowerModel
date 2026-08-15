defmodule PowerModel.Ingestion.Census.PopulationTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demographics.CountyPopulation
  alias PowerModel.Ingestion.Census.Population

  @popest Path.expand("../../fixtures/census_popest_sample.csv", __DIR__)
  @gazetteer Path.expand("../../fixtures/census_gazetteer_sample.txt", __DIR__)

  defp ingest!, do: Population.ingest(popest: @popest, gazetteer: @gazetteer)

  test "ingests county rows with centroids, skipping state rows and missing centroids" do
    assert {:ok, 3} = ingest!()
    assert Repo.aggregate(CountyPopulation, :count) == 3

    # State summary row (SUMLEV 040) not ingested
    refute Repo.get_by(CountyPopulation, fips: "04000")
    # County without a gazetteer centroid skipped
    refute Repo.get_by(CountyPopulation, fips: "04999")
  end

  test "uses the latest POPESTIMATE column and joins centroid by FIPS" do
    {:ok, _} = ingest!()

    maricopa = Repo.get_by!(CountyPopulation, fips: "04013")
    assert maricopa.population == 4_673_096
    assert maricopa.name == "Maricopa County"
    assert maricopa.state == "Arizona"

    %Geo.Point{coordinates: {lon, lat}, srid: 4326} = maricopa.coordinates
    assert_in_delta lon, -112.491815, 1.0e-6
    assert_in_delta lat, 33.348359, 1.0e-6
  end

  test "re-ingestion upserts instead of duplicating" do
    {:ok, 3} = ingest!()
    {:ok, 3} = ingest!()

    assert Repo.aggregate(CountyPopulation, :count) == 3
  end

  test "counties absent from the ingested file are deleted (DAT-6)" do
    # A county from a previous vintage (e.g. a pre-2022 Connecticut county
    # that has since been replaced by a planning region).
    Repo.insert!(%CountyPopulation{
      fips: "09001",
      name: "Fairfield County",
      state: "Connecticut",
      population: 957_419,
      coordinates: %Geo.Point{coordinates: {-73.36, 41.27}, srid: 4326}
    })

    {:ok, 3} = ingest!()

    refute Repo.get_by(CountyPopulation, fips: "09001")
    assert Repo.aggregate(CountyPopulation, :count) == 3
  end
end
