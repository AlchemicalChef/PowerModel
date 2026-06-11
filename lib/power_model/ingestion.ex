defmodule PowerModel.Ingestion do
  @moduledoc """
  Coordinates data ingestion from EIA, HIFLD, and EPA sources.
  """

  alias PowerModel.Ingestion.{BAMapper, BusMapper, ParameterEstimator, LoadEstimator, InternationalConnections}
  alias PowerModel.Ingestion.HIFLD
  alias PowerModel.Ingestion.EIA

  def ingest_substations(path) do
    HIFLD.Substations.ingest(path)
  end

  def derive_substations_from_api do
    HIFLD.Substations.derive_from_api()
  end

  def ingest_transmission_lines(path) do
    HIFLD.TransmissionLines.ingest(path)
  end

  def ingest_transmission_lines_from_api do
    HIFLD.TransmissionLines.ingest_from_api()
  end

  def ingest_generators(path) do
    EIA.Form860.ingest(path)
  end

  def map_buses do
    BusMapper.run()
  end

  def estimate_parameters do
    ParameterEstimator.run()
  end

  def estimate_loads do
    LoadEstimator.run()
  end

  def ingest_international_connections do
    InternationalConnections.run()
  end

  @doc "Populate balancing authorities from eGRID and assign buses to them."
  def map_balancing_authorities(path \\ "data") do
    BAMapper.run(path)
  end

  @doc "Ingest EIA-930 hourly demand per balancing authority from bulk CSVs."
  def ingest_demand(path \\ "data") do
    EIA.Form930.ingest(path)
  end

  @doc "Upsert the curated datacenter campus dataset."
  def ingest_datacenters do
    PowerModel.Ingestion.Datacenters.ingest()
  end
end
