defmodule PowerModel.Ingestion.HIFLD.API do
  @moduledoc """
  Paginated fetcher for HIFLD ArcGIS REST API Feature Services.
  """

  @base_url "https://services1.arcgis.com/Hp6G80Pky0om7QvQ/arcgis/rest/services"
  @page_size 2000

  @doc """
  Stream all features from a HIFLD feature service, paginating automatically.
  Returns a Stream of feature maps with `attributes` and `geometry` keys.
  """
  def stream_features(service_name, opts \\ []) do
    layer = Keyword.get(opts, :layer, 0)
    fields = Keyword.get(opts, :fields, "*")
    where = Keyword.get(opts, :where, "1=1")

    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        offset ->
          case fetch_page(service_name, layer, fields, where, offset) do
            {:ok, features, exceeded_limit} ->
              next = if exceeded_limit, do: offset + @page_size, else: :done
              {features, next}

            {:error, reason} ->
              IO.puts("API error at offset #{offset}: #{inspect(reason)}")
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Get total feature count for a service.
  """
  def count(service_name, opts \\ []) do
    layer = Keyword.get(opts, :layer, 0)
    where = Keyword.get(opts, :where, "1=1")

    url = "#{@base_url}/#{service_name}/FeatureServer/#{layer}/query"

    case Req.get(url, params: [where: where, returnCountOnly: "true", f: "json"]) do
      {:ok, %{status: 200, body: %{"count" => count}}} -> {:ok, count}
      {:ok, resp} -> {:error, resp.body}
      {:error, err} -> {:error, err}
    end
  end

  defp fetch_page(service_name, layer, fields, where, offset) do
    url = "#{@base_url}/#{service_name}/FeatureServer/#{layer}/query"

    params = [
      where: where,
      outFields: fields,
      f: "json",
      resultRecordCount: @page_size,
      resultOffset: offset,
      returnGeometry: "true",
      outSR: "4326"
    ]

    case Req.get(url, params: params, receive_timeout: 60_000, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if body["error"] do
          {:error, body["error"]}
        else
          features = body["features"] || []
          exceeded = body["exceededTransferLimit"] == true
          {:ok, features, exceeded}
        end

      {:ok, resp} ->
        {:error, "HTTP #{resp.status}"}

      {:error, err} ->
        {:error, err}
    end
  end
end
