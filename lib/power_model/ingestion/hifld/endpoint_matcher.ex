defmodule PowerModel.Ingestion.HIFLD.EndpointMatcher do
  @moduledoc """
  Resolve a transmission-line endpoint to the substation it terminates at,
  using HIFLD's own `SUB_1`/`SUB_2` names as the primary key (ROADMAP item 12).

  The names have been stored on `transmission_lines` since the R3 backfill and
  used by nothing: every endpoint was resolved by snapping to whatever bus
  happened to be nearest at a compatible voltage, which is why 45.9% of
  endpoints ended up beyond snap range of their own substation (REVIEW LIN-1).
  A name match is far stronger evidence than proximity — measured on the two
  pinned snapshots, 86% of the 189,238 endpoints carry a name that resolves to
  a substation, with a median offset of 0-15 m.

  Names are still only evidence, so a match is accepted only when the named
  substation is within `max_km` of the endpoint; beyond that the caller falls
  back to the geometric tiers. Where several substations share a name (15,161
  endpoints — "MIDWAY" alone names 15 yards), the NEAREST one wins, which is
  the disambiguation LIN-1 asks for.

  See `PowerModel.Ingestion.HIFLD.Names` for which names count as identities.
  """

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.Names

  # A named substation further than this from an endpoint is not that
  # endpoint's substation, whatever the name says. Generous because the name
  # is strong evidence and HIFLD endpoint coordinates are approximate — 65% of
  # the line geometry is flagged INFERRED by HIFLD itself. Measured on the
  # pinned snapshots, 25 km keeps 95% of name matches and cuts the tail that
  # runs to 900+ km.
  @name_match_radius_km 25.0

  @doc "Distance beyond which a name match is rejected. See `resolve/4`."
  def name_match_radius_km, do: @name_match_radius_km

  @doc """
  Build the normalized-name index over every substation with coordinates:
  `%{normalized_name => [{substation_id, lon, lat}]}`.

  Substations whose own name is non-identifying are left out — they can never
  be a match target, and "DEAD HEAD" alone would otherwise offer 46 of them.
  """
  def build_index do
    from(s in Substation, select: {s.id, s.name, s.coordinates})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, name, coords}, acc ->
      with normalized when not is_nil(normalized) <- Names.normalize(name),
           true <- Names.identifying?(normalized),
           %Geo.Point{coordinates: {lon, lat}} <- coords do
        Map.update(acc, normalized, [{id, lon, lat}], &[{id, lon, lat} | &1])
      else
        _ -> acc
      end
    end)
  end

  @doc """
  Resolve one endpoint against the index.

  Returns `{:ok, substation_id, distance_km}` when `name` identifies a
  substation within `max_km` of `{lon, lat}`, otherwise:

    * `:no_name` — the name is missing or a bare sentinel ("NOT AVAILABLE",
      "DEAD HEAD", …), so it identifies nothing;
    * `:no_match` — a real name with no substation of that name (the
      snapshots are different vintages: 8,758 endpoints name a yard the 2021
      substation layer does not have);
    * `{:too_far, substation_id, distance_km}` — the name matched but the
      nearest same-name substation is beyond `max_km`, which is evidence the
      name is being reused rather than the geometry being wrong.
  """
  def resolve(index, name, {lon, lat}, max_km) do
    case Names.normalize(name) do
      nil ->
        :no_name

      normalized ->
        if Names.identifying?(normalized) do
          resolve_normalized(index, normalized, lon, lat, max_km)
        else
          :no_name
        end
    end
  end

  def resolve(_index, _name, _point, _max_km), do: :no_name

  defp resolve_normalized(index, normalized, lon, lat, max_km) do
    case Map.get(index, normalized) do
      nil ->
        :no_match

      candidates ->
        {id, distance} =
          candidates
          |> Enum.map(fn {id, clon, clat} -> {id, haversine_km(lat, lon, clat, clon)} end)
          |> Enum.min_by(&elem(&1, 1))

        if distance <= max_km do
          {:ok, id, distance}
        else
          {:too_far, id, distance}
        end
    end
  end

  @doc "Great-circle distance in km."
  def haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    lat1_r = lat1 * :math.pi() / 180.0
    lat2_r = lat2 * :math.pi() / 180.0

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_r) * :math.cos(lat2_r) * :math.sin(dlon / 2) * :math.sin(dlon / 2)

    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end
end
