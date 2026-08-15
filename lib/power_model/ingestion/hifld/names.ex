defmodule PowerModel.Ingestion.HIFLD.Names do
  @moduledoc """
  Substation-name normalization and the endpoint-key rule that decides which
  HIFLD `SUB_1`/`SUB_2` values identify one specific yard.

  ## Why the bare tokens and the suffixed ones are different

  HIFLD does not leave an unnamed yard blank: it writes the substation's own
  record id into the name, so the last public substation layer holds 37,625
  distinct `UNKNOWN<id>` names and 20,567 distinct `TAP<id>` names — and,
  measured across the two pinned snapshots, exactly ONE of those ~58,000 names
  is carried by more than one substation. They are per-yard keys, not
  placeholders, and matching on them resolves 113,443 of the 189,238 line
  endpoints in the 94,619-line snapshot (median offset from the named yard:
  15 m for `UNKNOWN*`, 0 m for `TAP*`).

  The BARE tokens are the placeholders. `"NOT AVAILABLE"` sits on 17,559
  endpoints and matches no substation at all; `"DEAD HEAD"` names 46 different
  substations. Merging on those fuses unrelated endpoints (REVIEW LIN-1), so
  they are excluded and their endpoints fall through to the geometric snap.

  This is a different question from
  `PowerModel.Ingestion.HIFLD.Substations.sentinel_name?/1`, which governs the
  API-DERIVED path: there substations are invented BY grouping endpoint names
  with no substation table to check against, so `UNKNOWN*`/`TAP*` must not
  merge either. Here there is a real substation record to match, and its id is
  in the name.
  """

  # Names that carry no identity even though they are non-empty. Matched after
  # normalization (upcased, whitespace collapsed).
  @bare_sentinels [
    "NOT AVAILABLE",
    "NOT APPLICABLE",
    "NONE",
    "N/A",
    "NA",
    "NULL",
    "UNKNOWN",
    "TAP",
    "RISER",
    "SUBSTATION",
    "DEAD END",
    "DEAD HEAD",
    "DEADEND",
    "DEADHEAD"
  ]

  @doc """
  Upcase, trim, and collapse internal whitespace. Returns nil for nil or a
  blank string, so callers can pattern-match on "no usable name".
  """
  def normalize(nil), do: nil

  def normalize(name) when is_binary(name) do
    case name |> String.upcase() |> String.split() |> Enum.join(" ") do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize(_), do: nil

  @doc """
  True when a HIFLD substation name identifies one specific yard and may be
  used as an endpoint key. See the moduledoc for the measurement behind the
  bare-vs-suffixed distinction.

  Accepts raw or already-normalized names.
  """
  def identifying?(name) do
    case normalize(name) do
      nil -> false
      normalized -> not sentinel?(normalized)
    end
  end

  defp sentinel?(normalized) do
    normalized in @bare_sentinels or
      String.starts_with?(normalized, "DEAD ") or
      String.starts_with?(normalized, "DEADEND") or
      String.starts_with?(normalized, "DEADHEAD")
  end

  @doc "The bare, non-identifying names, for documentation and tests."
  def bare_sentinels, do: @bare_sentinels
end
