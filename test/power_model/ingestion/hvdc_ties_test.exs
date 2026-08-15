defmodule PowerModel.Ingestion.HvdcTiesTest do
  @moduledoc """
  ROADMAP item 13: the curated HVDC table, its dedupe against the existing
  international ties, and the idempotency of its upsert.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, DcTie, Interconnection}
  alias PowerModel.Ingestion.HvdcTies

  describe "the curated table itself" do
    test "every entry is complete and internally consistent" do
      for tie <- HvdcTies.ties() do
        assert is_binary(tie.name) and tie.name != ""
        assert {lon, lat} = tie.receiving_coords
        assert lon < 0 and lat > 0, "#{tie.name}: coordinates are not in North America"
        assert tie.receiving_interconnection in ~w(Eastern Western ERCOT)
        assert tie.sending_interconnection in ~w(Eastern Western ERCOT)

        assert tie.schedule_mw > 0,
               "#{tie.name}: schedules are positive by construction — the receiving " <>
                 "terminal is from_bus, and positive means injection there"

        assert tie.schedule_mw <= tie.rating_mva,
               "#{tie.name}: nominal schedule exceeds converter capacity"
      end
    end

    test "names are unique" do
      names = Enum.map(HvdcTies.ties(), & &1.name)

      assert length(Enum.uniq(names)) == length(names)
    end

    test "the ERCOT North tie and the Oklaunion tie are one entry, not two" do
      # ERCOT's "North" DC tie IS the Oklaunion converter. Listing both names
      # as separate ties would double-count 220 MW of transfer capability.
      oklaunion = Enum.filter(HvdcTies.ties(), &String.contains?(&1.name, "Oklaunion"))
      north = Enum.filter(HvdcTies.ties(), &String.contains?(&1.name, "North"))

      assert length(oklaunion) == 1
      assert oklaunion == north
    end

    test "the US-Mexico back-to-back ties are absent (InternationalConnections owns them)" do
      names = HvdcTies.ties() |> Enum.map(&String.downcase(&1.name)) |> Enum.join(" ")

      for mexico_tie <- ~w(eagle laredo railroad mcallen sharyland) do
        refute String.contains?(names, mexico_tie),
               "#{mexico_tie} is already an international tie; listing it here double-counts it"
      end
    end

    test "each ERCOT tie crosses into the Eastern interconnection" do
      ercot = Enum.filter(HvdcTies.ties(), &(&1.receiving_interconnection == "ERCOT"))

      assert length(ercot) == 2

      for tie <- ercot do
        assert tie.sending_interconnection == "Eastern",
               "#{tie.name}: ERCOT connects to other systems only through DC"
      end
    end
  end

  describe "ingestion" do
    setup do
      ics =
        Map.new(~w(Eastern Western ERCOT), fn name ->
          {name, Repo.insert!(%Interconnection{name: name}).id}
        end)

      %{ics: ics}
    end

    defp put_bus(ic_id, {lon, lat}, base_kv) do
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: base_kv,
        source: "substation",
        source_id: "test-#{System.unique_integer([:positive])}",
        interconnection_id: ic_id,
        coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326}
      })
    end

    test "a tie whose converters both resolve is created with both endpoints", %{ics: ics} do
      celilo = put_bus(ics["Western"], {-120.97, 45.62}, 500.0)
      sylmar = put_bus(ics["Western"], {-118.48, 34.31}, 500.0)

      {:ok, result} = HvdcTies.run()

      assert result.created >= 1

      pdci = Repo.get_by!(DcTie, source: "hvdc", source_id: "pacific_dc_intertie_celilo_sylmar")

      # from_bus is the RECEIVING terminal, and the schedule is the injection
      # there — positive means power arriving at Sylmar.
      assert pdci.from_bus_id == sylmar.id
      assert pdci.to_bus_id == celilo.id
      assert pdci.schedule_mw > 0
      assert pdci.status == "in_service"
    end

    test "a tie with no bus near its receiving converter is skipped, not half-created" do
      {:ok, result} = HvdcTies.run()

      assert Repo.aggregate(DcTie, :count) == 0
      assert length(result.unresolved) == length(HvdcTies.ties())
    end

    test "a tie whose far converter is unresolvable still gets its near-end injection", %{
      ics: ics
    } do
      # Only the Long Island end of Cross Sound exists in this network.
      shoreham = put_bus(ics["Eastern"], {-72.88, 40.96}, 138.0)

      {:ok, _} = HvdcTies.run()

      cross_sound =
        Repo.get_by!(DcTie, source: "hvdc", source_id: "cross_sound_cable_new_haven_shoreham")

      assert cross_sound.from_bus_id == shoreham.id
      assert cross_sound.to_bus_id == nil
    end

    test "a back-to-back tie resolves each end in its OWN interconnection", %{ics: ics} do
      # Both Oklaunion converters sit at one site. Restricting each terminal's
      # search to its own interconnection is what stops both ends landing on
      # the same bus, which would make the tie a no-op.
      ercot_bus = put_bus(ics["ERCOT"], {-99.13, 34.11}, 345.0)
      eastern_bus = put_bus(ics["Eastern"], {-99.14, 34.12}, 345.0)

      {:ok, _} = HvdcTies.run()

      north = Repo.get_by!(DcTie, source: "hvdc", source_id: "ercot_north_dc_tie_oklaunion")

      assert north.from_bus_id == ercot_bus.id
      assert north.to_bus_id == eastern_bus.id
      refute north.from_bus_id == north.to_bus_id
    end

    test "at one site the highest voltage level wins the tie-break", %{ics: ics} do
      # Both buses are adequate for the PDCI and sit at the same coordinate,
      # so distance cannot separate them and voltage decides — the case
      # ROADMAP item 11 makes routine by giving a substation one bus per level.
      _mid = put_bus(ics["Western"], {-118.48, 34.31}, 345.0)
      ehv = put_bus(ics["Western"], {-118.48, 34.31}, 500.0)

      {:ok, _} = HvdcTies.run()

      pdci = Repo.get_by!(DcTie, source: "hvdc", source_id: "pacific_dc_intertie_celilo_sylmar")

      assert pdci.from_bus_id == ehv.id
    end

    test "a converter never lands on a bus too small to carry its schedule", %{ics: ics} do
      # The only bus at Sylmar is 138 kV. Hanging a 3,220 MVA converter on it
      # would produce flows describing the snap rather than the grid, so the
      # tie is reported unresolved instead.
      put_bus(ics["Western"], {-118.48, 34.31}, 138.0)

      {:ok, result} = HvdcTies.run()

      assert "Pacific DC Intertie (Celilo–Sylmar)" in result.unresolved
      assert Repo.aggregate(DcTie, :count) == 0
    end

    test "a smaller tie is allowed onto the same 138 kV bus", %{ics: ics} do
      # Duffy Avenue really is a 138 kV terminal: the floor scales with the
      # converter, it is not a blanket EHV requirement.
      duffy = put_bus(ics["Eastern"], {-73.52, 40.74}, 138.0)

      {:ok, _} = HvdcTies.run()

      neptune =
        Repo.get_by!(DcTie, source: "hvdc", source_id: "neptune_rts_sayreville_duffy_avenue")

      assert neptune.from_bus_id == duffy.id
    end

    test "a bad-voltage bus above any real transmission class is never chosen", %{ics: ics} do
      # REVIEW LIN-12: Western carries bogus 765 kV+ rows. They must not
      # attract converters just for being the highest number nearby.
      _bogus = put_bus(ics["Western"], {-118.48, 34.31}, 1000.0)
      real = put_bus(ics["Western"], {-118.49, 34.32}, 500.0)

      {:ok, _} = HvdcTies.run()

      pdci = Repo.get_by!(DcTie, source: "hvdc", source_id: "pacific_dc_intertie_celilo_sylmar")

      assert pdci.from_bus_id == real.id
    end

    test "terminal_kv_floor/1 scales with converter size" do
      assert HvdcTies.terminal_kv_floor(3220.0) == 345.0
      assert HvdcTies.terminal_kv_floor(1000.0) == 230.0
      assert HvdcTies.terminal_kv_floor(660.0) == 138.0
      assert HvdcTies.terminal_kv_floor(36.0) == 69.0

      floors = Enum.map([3220.0, 1000.0, 660.0, 36.0], &HvdcTies.terminal_kv_floor/1)
      assert floors == Enum.sort(floors, :desc)
    end

    test "rerunning updates in place instead of inserting duplicates", %{ics: ics} do
      put_bus(ics["Western"], {-120.97, 45.62}, 500.0)
      put_bus(ics["Western"], {-118.48, 34.31}, 500.0)

      {:ok, first} = HvdcTies.run()
      count_after_first = Repo.aggregate(DcTie, :count)

      {:ok, second} = HvdcTies.run()

      assert Repo.aggregate(DcTie, :count) == count_after_first
      assert second.created == 0
      assert second.updated == first.created
    end

    test "a newly resolvable converter is picked up on the next run", %{ics: ics} do
      put_bus(ics["Western"], {-118.48, 34.31}, 500.0)

      {:ok, _} = HvdcTies.run()
      pdci = Repo.get_by!(DcTie, source: "hvdc", source_id: "pacific_dc_intertie_celilo_sylmar")
      assert pdci.to_bus_id == nil

      # The Celilo end appears in a later ingest; the upsert adopts it.
      celilo = put_bus(ics["Western"], {-120.97, 45.62}, 500.0)
      {:ok, _} = HvdcTies.run()

      assert Repo.get!(DcTie, pdci.id).to_bus_id == celilo.id
    end
  end
end
