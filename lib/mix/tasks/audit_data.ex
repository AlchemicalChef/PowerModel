defmodule Mix.Tasks.PowerModel.AuditData do
  @moduledoc "Comprehensive data quality audit across all tables."
  use Mix.Task
  import Ecto.Query
  alias PowerModel.Repo

  @shortdoc "Run comprehensive data quality audit"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts(String.duplicate("=", 70))
    IO.puts("COMPREHENSIVE DATA AUDIT — #{Date.utc_today()}")
    IO.puts(String.duplicate("=", 70))

    audit_generators()
    audit_transmission_lines()
    audit_substations()
    audit_buses()
    audit_loads()
    audit_transformers()
    audit_water_facilities()
    audit_eia_hourly()
    audit_cross_references()
    audit_geographic_consistency()
  end

  defp audit_generators do
    alias PowerModel.Grid.Generator
    IO.puts("\n#{section("GENERATORS")}")

    total = Repo.aggregate(Generator, :count)
    in_service = Repo.one(from g in Generator, where: g.status == "in_service", select: count())
    IO.puts("  Total: #{total} (#{in_service} in service)")

    null_cap = Repo.one(from g in Generator, where: is_nil(g.p_max_mw), select: count())
    zero_cap = Repo.one(from g in Generator, where: g.p_max_mw <= 0.0, select: count())
    tiny_cap = Repo.one(from g in Generator, where: g.p_max_mw > 0.0 and g.p_max_mw < 0.1, select: count())
    huge_cap = Repo.all(from g in Generator, where: g.p_max_mw > 4000.0, select: {g.id, g.p_max_mw, g.fuel_type, g.eia_plant_id}, order_by: [desc: g.p_max_mw], limit: 10)
    IO.puts("  Null capacity: #{null_cap}")
    IO.puts("  Zero/negative capacity: #{zero_cap}")
    IO.puts("  Tiny capacity (<0.1 MW): #{tiny_cap}")
    IO.puts("  Units > 4 GW: #{length(huge_cap)}")
    for {id, cap, fuel, eia} <- huge_cap, do: IO.puts("    gen##{id} #{Float.round(cap, 1)}MW fuel=#{fuel} eia=#{eia}")

    no_bus = Repo.one(from g in Generator, where: is_nil(g.bus_id), select: count())
    no_coords = Repo.one(from g in Generator, where: is_nil(g.coordinates), select: count())
    no_eia = Repo.one(from g in Generator, where: is_nil(g.eia_plant_id) or g.eia_plant_id == "", select: count())
    IO.puts("  Missing bus_id: #{no_bus}")
    IO.puts("  Missing coordinates: #{no_coords}")
    IO.puts("  Missing EIA plant ID: #{no_eia}")

    fuels = Repo.all(from g in Generator, where: g.status == "in_service",
      group_by: g.fuel_type,
      select: {g.fuel_type, count(), sum(g.p_max_mw)},
      order_by: [desc: sum(g.p_max_mw)])
    IO.puts("  Fuel type breakdown (in-service):")
    for {fuel, cnt, mw} <- fuels do
      IO.puts("    #{String.pad_trailing(fuel || "NULL", 12)} #{String.pad_leading("#{cnt}", 6)} units  #{String.pad_leading(Float.round(mw / 1000, 1) |> to_string(), 8)} GW")
    end

    total_cap = Repo.one(from g in Generator, where: g.status == "in_service", select: sum(g.p_max_mw))
    IO.puts("  Total in-service capacity: #{Float.round(total_cap / 1000, 1)} GW")
    IO.puts("  EIA reality check: ~1,300 GW nameplate → #{if abs(total_cap / 1000 - 1300) < 200, do: "✓ REASONABLE", else: "⚠ DIVERGENT"}")

    dupes = Repo.all(from g in Generator,
      where: not is_nil(g.eia_plant_id) and g.eia_plant_id != "",
      group_by: g.eia_plant_id,
      having: count() > 10,
      select: {g.eia_plant_id, count()},
      order_by: [desc: count()],
      limit: 5)
    if length(dupes) > 0 do
      IO.puts("  Plants with >10 units (multi-unit):")
      for {eia_id, cnt} <- dupes, do: IO.puts("    EIA #{eia_id}: #{cnt} units")
    end
  end

  defp audit_transmission_lines do
    alias PowerModel.Grid.TransmissionLine
    IO.puts("\n#{section("TRANSMISSION LINES")}")

    total = Repo.aggregate(TransmissionLine, :count)
    in_service = Repo.one(from t in TransmissionLine, where: t.status == "in_service", select: count())
    IO.puts("  Total: #{total} (#{in_service} in service)")

    null_from = Repo.one(from t in TransmissionLine, where: is_nil(t.from_bus_id), select: count())
    null_to = Repo.one(from t in TransmissionLine, where: is_nil(t.to_bus_id), select: count())
    self_loop = Repo.one(from t in TransmissionLine,
      where: not is_nil(t.from_bus_id) and t.from_bus_id == t.to_bus_id,
      select: count())
    IO.puts("  Null from_bus_id: #{null_from}")
    IO.puts("  Null to_bus_id: #{null_to}")
    IO.puts("  Self-loops (from=to): #{self_loop}")

    null_r = Repo.one(from t in TransmissionLine, where: is_nil(t.r_pu) or t.r_pu == 0.0, select: count())
    null_x = Repo.one(from t in TransmissionLine, where: is_nil(t.x_pu) or t.x_pu == 0.0, select: count())
    neg_r = Repo.one(from t in TransmissionLine, where: t.r_pu < 0.0, select: count())
    neg_x = Repo.one(from t in TransmissionLine, where: t.x_pu < 0.0, select: count())
    huge_x = Repo.one(from t in TransmissionLine, where: t.x_pu > 10.0, select: count())
    IO.puts("  Zero/null R: #{null_r}")
    IO.puts("  Zero/null X: #{null_x}")
    IO.puts("  Negative R: #{neg_r}")
    IO.puts("  Negative X: #{neg_x}")
    IO.puts("  Unreasonably large X (>10 pu): #{huge_x}")

    null_rating = Repo.one(from t in TransmissionLine, where: is_nil(t.rating_a_mva), select: count())
    zero_rating = Repo.one(from t in TransmissionLine, where: t.rating_a_mva <= 0.0, select: count())
    IO.puts("  Null rating: #{null_rating}")
    IO.puts("  Zero/negative rating: #{zero_rating}")

    voltages = Repo.all(from t in TransmissionLine, where: t.status == "in_service",
      group_by: fragment("CASE WHEN voltage_kv >= 345 THEN '345+' WHEN voltage_kv >= 230 THEN '230-344' WHEN voltage_kv >= 115 THEN '115-229' WHEN voltage_kv >= 69 THEN '69-114' ELSE '<69' END"),
      select: {fragment("CASE WHEN voltage_kv >= 345 THEN '345+' WHEN voltage_kv >= 230 THEN '230-344' WHEN voltage_kv >= 115 THEN '115-229' WHEN voltage_kv >= 69 THEN '69-114' ELSE '<69' END"), count()},
      order_by: [desc: count()])
    IO.puts("  Voltage class distribution:")
    for {v_class, cnt} <- voltages, do: IO.puts("    #{String.pad_trailing(v_class, 10)} #{cnt}")

    null_geom = Repo.one(from t in TransmissionLine, where: is_nil(t.geometry), select: count())
    IO.puts("  Missing geometry: #{null_geom}")

    null_len = Repo.one(from t in TransmissionLine, where: is_nil(t.length_km), select: count())
    zero_len = Repo.one(from t in TransmissionLine, where: t.length_km <= 0.0, select: count())
    huge_len = Repo.one(from t in TransmissionLine, where: t.length_km > 500.0, select: count())
    IO.puts("  Null length: #{null_len}")
    IO.puts("  Zero length: #{zero_len}")
    IO.puts("  Very long (>500km): #{huge_len}")
  end

  defp audit_substations do
    alias PowerModel.Grid.Substation
    IO.puts("\n#{section("SUBSTATIONS")}")

    total = Repo.aggregate(Substation, :count)
    IO.puts("  Total: #{total}")

    rutgers = Repo.one(from s in Substation, where: like(s.hifld_id, "rutgers_%"), select: count())
    derived = total - rutgers
    IO.puts("  Derived from HIFLD lines: #{derived}")
    IO.puts("  From Rutgers mirror: #{rutgers}")

    null_coords = Repo.one(from s in Substation, where: is_nil(s.coordinates), select: count())
    null_voltage = Repo.one(from s in Substation, where: is_nil(s.max_voltage_kv), select: count())
    null_name = Repo.one(from s in Substation, where: is_nil(s.name) or s.name == "", select: count())
    unknown_name = Repo.one(from s in Substation, where: like(s.name, "UNKNOWN%"), select: count())
    IO.puts("  Missing coordinates: #{null_coords}")
    IO.puts("  Missing voltage: #{null_voltage}")
    IO.puts("  Missing/empty name: #{null_name}")
    IO.puts("  Name starts with UNKNOWN: #{unknown_name}")

    dupe_names = Repo.one(from s in Substation,
      group_by: s.name,
      having: count() > 5,
      select: count())
    IO.puts("  Names appearing >5 times: #{dupe_names || 0}")
  end

  defp audit_buses do
    alias PowerModel.Grid.Bus
    IO.puts("\n#{section("BUSES")}")

    total = Repo.aggregate(Bus, :count)
    IO.puts("  Total: #{total}")

    sources = Repo.all(from b in Bus, group_by: b.source, select: {b.source, count()}, order_by: [desc: count()])
    IO.puts("  By source:")
    for {src, cnt} <- sources, do: IO.puts("    #{String.pad_trailing(src || "NULL", 20)} #{cnt}")

    intercos = Repo.all(from b in Bus, group_by: b.interconnection_id, select: {b.interconnection_id, count()}, order_by: b.interconnection_id)
    IO.puts("  By interconnection:")
    for {ic, cnt} <- intercos, do: IO.puts("    IC #{ic || "NULL"}: #{cnt}")

    orphan_count = Repo.one(from b in Bus,
      left_join: g in PowerModel.Grid.Generator, on: g.bus_id == b.id,
      left_join: l in PowerModel.Grid.Load, on: l.bus_id == b.id,
      where: is_nil(g.id) and is_nil(l.id),
      select: count(b.id, :distinct))
    IO.puts("  Buses with no generator or load: #{orphan_count}")

    types = Repo.all(from b in Bus, group_by: b.bus_type, select: {b.bus_type, count()}, order_by: b.bus_type)
    IO.puts("  By type: #{inspect(types)}")
  end

  defp audit_loads do
    alias PowerModel.Grid.Load
    IO.puts("\n#{section("LOADS")}")

    total = Repo.aggregate(Load, :count)
    total_mw = Repo.one(from l in Load, select: sum(l.p_mw))
    IO.puts("  Total: #{total}")
    IO.puts("  Total load: #{Float.round(total_mw / 1000, 1)} GW")

    no_bus = Repo.one(from l in Load, where: is_nil(l.bus_id), select: count())
    IO.puts("  Missing bus_id: #{no_bus}")

    neg = Repo.one(from l in Load, where: l.p_mw < 0.0, select: count())
    IO.puts("  Negative load: #{neg}")

    zero = Repo.one(from l in Load, where: l.p_mw == 0.0, select: count())
    IO.puts("  Zero load: #{zero}")

    huge = Repo.all(from l in Load, where: l.p_mw > 2000.0, select: {l.id, l.p_mw, l.bus_id}, limit: 10)
    IO.puts("  Single loads > 2 GW: #{length(huge)}")
    for {id, mw, bus} <- huge, do: IO.puts("    load##{id} #{Float.round(mw, 1)}MW bus##{bus}")

    IO.puts("  EIA US peak demand: ~750 GW → #{if total_mw / 1000 > 300 and total_mw / 1000 < 1500, do: "✓ REASONABLE", else: "⚠ CHECK"}")
  end

  defp audit_transformers do
    alias PowerModel.Grid.Transformer
    IO.puts("\n#{section("TRANSFORMERS")}")

    total = Repo.aggregate(Transformer, :count)
    IO.puts("  Total: #{total}")

    null_from = Repo.one(from t in Transformer, where: is_nil(t.from_bus_id), select: count())
    null_to = Repo.one(from t in Transformer, where: is_nil(t.to_bus_id), select: count())
    null_rating = Repo.one(from t in Transformer, where: is_nil(t.rated_mva), select: count())
    zero_rating = Repo.one(from t in Transformer, where: t.rated_mva <= 0.0, select: count())
    IO.puts("  Null from_bus: #{null_from}, Null to_bus: #{null_to}")
    IO.puts("  Null rating: #{null_rating}, Zero rating: #{zero_rating}")
  end

  defp audit_water_facilities do
    alias PowerModel.Grid.WaterFacility
    IO.puts("\n#{section("WATER FACILITIES")}")

    total = Repo.aggregate(WaterFacility, :count)
    IO.puts("  Total: #{total}")

    mapped = Repo.one(from w in WaterFacility, where: not is_nil(w.bus_id), select: count())
    IO.puts("  Mapped to grid bus: #{mapped}")

    no_coords = Repo.one(from w in WaterFacility, where: is_nil(w.coordinates), select: count())
    IO.puts("  Missing coordinates: #{no_coords}")
  end

  defp audit_eia_hourly do
    alias PowerModel.Grid.{HourlyLoadProfile, HourlyGenerationMix}
    IO.puts("\n#{section("EIA HOURLY DATA")}")

    load_count = Repo.aggregate(HourlyLoadProfile, :count)
    mix_count = Repo.aggregate(HourlyGenerationMix, :count)
    IO.puts("  Load profiles: #{load_count}")
    IO.puts("  Generation mix: #{mix_count}")

    if load_count > 0 do
      null_demand = Repo.one(from h in HourlyLoadProfile, where: is_nil(h.demand_mw), select: count())
      IO.puts("  Null demand values: #{null_demand}")

      neg_demand = Repo.one(from h in HourlyLoadProfile, where: h.demand_mw < 0.0, select: count())
      IO.puts("  Negative demand: #{neg_demand}")

      pjm_stats = Repo.one(from h in HourlyLoadProfile,
        where: h.ba_code == "PJM" and not is_nil(h.demand_mw),
        select: {min(h.demand_mw), max(h.demand_mw), avg(h.demand_mw)})
      if pjm_stats do
        {pmin, pmax, pavg} = pjm_stats
        IO.puts("  PJM demand range: #{round(pmin)}-#{round(pmax)} MW (avg #{round(pavg)})")
        IO.puts("    Reality: PJM peak ~150 GW, trough ~60 GW → #{if pmax < 200_000 and pmin > 30_000, do: "✓ REASONABLE", else: "⚠ CHECK"}")
      end

      erco_stats = Repo.one(from h in HourlyLoadProfile,
        where: h.ba_code == "ERCO" and not is_nil(h.demand_mw),
        select: {min(h.demand_mw), max(h.demand_mw), avg(h.demand_mw)})
      if erco_stats do
        {emin, emax, eavg} = erco_stats
        IO.puts("  ERCOT demand range: #{round(emin)}-#{round(emax)} MW (avg #{round(eavg)})")
        IO.puts("    Reality: ERCOT peak ~85 GW → #{if emax < 120_000 and emin > 15_000, do: "✓ REASONABLE", else: "⚠ CHECK"}")
      end

      us48_stats = Repo.one(from h in HourlyLoadProfile,
        where: h.ba_code == "US48" and not is_nil(h.demand_mw),
        select: {min(h.demand_mw), max(h.demand_mw), avg(h.demand_mw)})
      if us48_stats do
        {umin, umax, uavg} = us48_stats
        IO.puts("  US48 demand range: #{round(umin)}-#{round(umax)} MW (avg #{round(uavg)})")
        IO.puts("    Reality: US peak ~750 GW → #{if umax < 900_000 and umin > 200_000, do: "✓ REASONABLE", else: "⚠ CHECK"}")
      end
    end
  end

  defp audit_cross_references do
    IO.puts("\n#{section("CROSS-REFERENCE INTEGRITY")}")

    ghost_gen_bus = Repo.one(from g in PowerModel.Grid.Generator,
      left_join: b in PowerModel.Grid.Bus, on: g.bus_id == b.id,
      where: not is_nil(g.bus_id) and is_nil(b.id),
      select: count())
    IO.puts("  Generators → non-existent bus: #{ghost_gen_bus}")

    ghost_line_from = Repo.one(from t in PowerModel.Grid.TransmissionLine,
      left_join: b in PowerModel.Grid.Bus, on: t.from_bus_id == b.id,
      where: not is_nil(t.from_bus_id) and is_nil(b.id),
      select: count())
    ghost_line_to = Repo.one(from t in PowerModel.Grid.TransmissionLine,
      left_join: b in PowerModel.Grid.Bus, on: t.to_bus_id == b.id,
      where: not is_nil(t.to_bus_id) and is_nil(b.id),
      select: count())
    IO.puts("  Lines → non-existent from_bus: #{ghost_line_from}")
    IO.puts("  Lines → non-existent to_bus: #{ghost_line_to}")

    ghost_load = Repo.one(from l in PowerModel.Grid.Load,
      left_join: b in PowerModel.Grid.Bus, on: l.bus_id == b.id,
      where: not is_nil(l.bus_id) and is_nil(b.id),
      select: count())
    IO.puts("  Loads → non-existent bus: #{ghost_load}")

    ghost_xfmr = Repo.one(from t in PowerModel.Grid.Transformer,
      left_join: b1 in PowerModel.Grid.Bus, on: t.from_bus_id == b1.id,
      left_join: b2 in PowerModel.Grid.Bus, on: t.to_bus_id == b2.id,
      where: (not is_nil(t.from_bus_id) and is_nil(b1.id)) or (not is_nil(t.to_bus_id) and is_nil(b2.id)),
      select: count())
    IO.puts("  Transformers → non-existent bus: #{ghost_xfmr}")

    gen_mw = Repo.one(from g in PowerModel.Grid.Generator, where: g.status == "in_service", select: sum(g.p_max_mw))
    load_mw = Repo.one(from l in PowerModel.Grid.Load, select: sum(l.p_mw))
    ratio = gen_mw / load_mw
    IO.puts("  Gen/Load ratio: #{Float.round(ratio, 2)} (#{Float.round(gen_mw/1000, 1)} GW / #{Float.round(load_mw/1000, 1)} GW)")
    IO.puts("    Typical reserve margin: 1.15-1.40 → #{if ratio > 1.0 and ratio < 2.0, do: "✓ REASONABLE", else: "⚠ CHECK"}")
  end

  defp audit_geographic_consistency do
    IO.puts("\n#{section("GEOGRAPHIC CONSISTENCY")}")

    ercot_gens = Repo.all(from g in PowerModel.Grid.Generator,
      join: b in PowerModel.Grid.Bus, on: g.bus_id == b.id,
      where: b.interconnection_id == 3 and not is_nil(g.coordinates),
      select: g.coordinates,
      limit: 1000)

    outside_texas = Enum.count(ercot_gens, fn coords ->
      case coords do
        %Geo.Point{coordinates: {lon, lat}} ->
          lat < 25.0 or lat > 37.0 or lon < -107.0 or lon > -93.0
        _ -> false
      end
    end)
    IO.puts("  ERCOT generators outside Texas bounds: #{outside_texas}/#{length(ercot_gens)}")

    west_gens = Repo.all(from g in PowerModel.Grid.Generator,
      join: b in PowerModel.Grid.Bus, on: g.bus_id == b.id,
      where: b.interconnection_id == 2 and not is_nil(g.coordinates),
      select: g.coordinates,
      limit: 2000)

    east_of_divide = Enum.count(west_gens, fn coords ->
      case coords do
        %Geo.Point{coordinates: {lon, _lat}} -> lon > -100.0
        _ -> false
      end
    end)
    IO.puts("  Western IC generators east of -100° lon: #{east_of_divide}/#{length(west_gens)}")
  end

  defp section(title), do: "## #{title}"
end
