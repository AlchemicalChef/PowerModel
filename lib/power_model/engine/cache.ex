defmodule PowerModel.Engine.Cache do
  @moduledoc """
  ETS-based cache for LU factors, LODF matrices, and voltage profiles.
  Avoids copying large data through GenServer state.
  """

  @table :power_model_cache

  def init do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
    :ok
  end

  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  def put_lu_factors(interconnection_id, factors) do
    put({:lu_factors, interconnection_id}, factors)
  end

  def get_lu_factors(interconnection_id) do
    get({:lu_factors, interconnection_id})
  end

  def put_voltage_profile(sim_id, profile) do
    put({:voltage_profile, sim_id}, profile)
  end

  def get_voltage_profile(sim_id) do
    get({:voltage_profile, sim_id})
  end

  def put_lodf_matrix(interconnection_id, lodf) do
    put({:lodf, interconnection_id}, lodf)
  end

  def get_lodf_matrix(interconnection_id) do
    get({:lodf, interconnection_id})
  end
end
