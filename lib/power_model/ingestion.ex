defmodule PowerModel.Ingestion do
  @moduledoc """
  Coordinates data ingestion from EIA, HIFLD, and EPA sources.
  """

  alias PowerModel.Ingestion.{
    BusMapper,
    ParameterEstimator,
    LoadEstimator,
    InternationalConnections
  }

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
end
