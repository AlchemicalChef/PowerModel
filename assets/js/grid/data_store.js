// States: 0=normal, 1=stressed, 2=overloaded, 3=tripped, 4=rerouted, 5=shed, 6=islanded
const STATE_NORMAL = 0;
const STATE_STRESSED = 1;
const STATE_OVERLOADED = 2;
const STATE_TRIPPED = 3;
const STATE_REROUTED = 4;
const STATE_SHED = 5;
const STATE_ISLANDED = 6;

export class DataStore {
  constructor() {
    this.generators = { count: 0, ids: null, positions: null, capacities: null, fuelTypes: null, states: null };
    this.transmissionLines = { count: 0, lines: [] };
    this.substations = { count: 0, ids: null, positions: null, voltages: null, states: null };
    this.waterFacilities = { count: 0, facilities: [] };
    this.datacenters = { count: 0, datacenters: [] };
    this.transformers = { count: 0, ids: null, positions: null, ratings: null, states: null };
    this.busLoads = {
      count: 0,
      ids: null,
      positions: null,
      demands: null,
      indexByBusId: new Map(),
    };
    // Bus-level cascade products, joined to positions through busLoads.
    this.busVoltage = new Map(); // bus id -> vm_pu
    this.shedBusIds = new Set();
    this._demandHexCache = {}; // resolution -> [{ hex, mw }]
    this._voltageHexCache = {}; // resolution -> [{ hex, min, max }]
    this._shedMarkCache = null;
    // Memoized getData() arrays: built once per load, mutated in place on
    // state changes so deck.gl's data identity stays stable and re-uploads
    // only happen when updateTriggers (stateVersion) say so.
    this._generatorData = null;
    this._substationData = null;
    this._transformerData = null;
    // Water facilities load lazily (17.7 MB JSON): cascade state changes
    // arriving before the data buffer here and are applied on load.
    this._pendingWaterStates = new Map();
  }

  loadGenerators(buffer) {
    const view = new DataView(buffer);
    const count = view.getUint32(0, true);
    let offset = 4;

    const ids = new Uint32Array(count);
    const positions = new Float32Array(count * 2); // [lon, lat, lon, lat, ...]
    const capacities = new Float32Array(count);
    const fuelTypes = new Uint8Array(count);
    const states = new Uint8Array(count);

    for (let i = 0; i < count; i++) {
      ids[i] = view.getUint32(offset, true); offset += 4;
      positions[i * 2] = view.getFloat32(offset, true); offset += 4;     // lon
      positions[i * 2 + 1] = view.getFloat32(offset, true); offset += 4; // lat
      capacities[i] = view.getFloat32(offset, true); offset += 4;
      fuelTypes[i] = view.getUint8(offset); offset += 1;
      states[i] = view.getUint8(offset); offset += 1;
    }

    this.generators = { count, ids, positions, capacities, fuelTypes, states };
    this._generatorData = null;
  }

  loadTransmissionLines(buffer) {
    const view = new DataView(buffer);
    const count = view.getUint32(0, true);
    let offset = 4;

    const lines = [];

    for (let i = 0; i < count; i++) {
      const id = view.getUint32(offset, true); offset += 4;
      const voltageKv = view.getFloat32(offset, true); offset += 4;
      const ratingMva = view.getFloat32(offset, true); offset += 4;
      const numPoints = view.getUint16(offset, true); offset += 2;
      const state = view.getUint8(offset); offset += 1;

      const path = [];
      for (let j = 0; j < numPoints; j++) {
        const lon = view.getFloat32(offset, true); offset += 4;
        const lat = view.getFloat32(offset, true); offset += 4;
        path.push([lon, lat]);
      }

      lines.push({ id, voltageKv, ratingMva, numPoints, state, path });
    }

    this.transmissionLines = { count, lines };
  }

  loadSubstations(buffer) {
    const view = new DataView(buffer);
    const count = view.getUint32(0, true);
    let offset = 4;

    const ids = new Uint32Array(count);
    const positions = new Float32Array(count * 2);
    const voltages = new Float32Array(count);
    const states = new Uint8Array(count);

    for (let i = 0; i < count; i++) {
      ids[i] = view.getUint32(offset, true); offset += 4;
      positions[i * 2] = view.getFloat32(offset, true); offset += 4;
      positions[i * 2 + 1] = view.getFloat32(offset, true); offset += 4;
      voltages[i] = view.getFloat32(offset, true); offset += 4;
      states[i] = view.getUint8(offset); offset += 1;
    }

    this.substations = { count, ids, positions, voltages, states };
    this._substationData = null;
  }

  loadTransformers(buffer) {
    const view = new DataView(buffer);
    const count = view.getUint32(0, true);
    let offset = 4;

    const ids = new Uint32Array(count);
    const positions = new Float32Array(count * 2);
    const ratings = new Float32Array(count);
    const states = new Uint8Array(count);

    for (let i = 0; i < count; i++) {
      ids[i] = view.getUint32(offset, true); offset += 4;
      positions[i * 2] = view.getFloat32(offset, true); offset += 4;
      positions[i * 2 + 1] = view.getFloat32(offset, true); offset += 4;
      ratings[i] = view.getFloat32(offset, true); offset += 4;
      states[i] = view.getUint8(offset); offset += 1;
    }

    this.transformers = { count, ids, positions, ratings, states };
    this._transformerData = null;
  }

  getTransformerData() {
    if (this._transformerData) return this._transformerData;
    const data = [];
    for (let i = 0; i < this.transformers.count; i++) {
      data.push({
        id: this.transformers.ids[i],
        position: [this.transformers.positions[i * 2], this.transformers.positions[i * 2 + 1]],
        ratedMva: this.transformers.ratings[i],
        state: this.transformers.states[i],
      });
    }
    this._transformerData = data;
    return data;
  }

  // Mirror the typed-array states into a memoized object array (objects are
  // what deck.gl accessors read; the arrays keep a stable identity).
  _syncCachedStates(cache, states) {
    if (!cache || !states) return;
    for (let i = 0; i < cache.length; i++) cache[i].state = states[i];
  }

  applyTransformerStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.transformers.ids) return;
    for (let i = 0; i < this.transformers.count; i++) {
      const s = stateMap[this.transformers.ids[i]];
      if (s !== undefined) this.transformers.states[i] = s;
    }
    this._syncCachedStates(this._transformerData, this.transformers.states);
  }

  // Clear flow-derived transformer states, preserving tripped marks
  resetTransformerFlowStates() {
    if (!this.transformers.states) return;
    for (let i = 0; i < this.transformers.count; i++) {
      if (this.transformers.states[i] !== STATE_TRIPPED) {
        this.transformers.states[i] = STATE_NORMAL;
      }
    }
    this._syncCachedStates(this._transformerData, this.transformers.states);
  }

  // Per-bus points for the H3 overlays (demand density, voltage depth).
  //
  //   v2: "BLD" tag, version u8, count u32, then per record bus_id u32,
  //       lon f32, lat f32, demand_mw f32
  //   v1: count u32, then per record lon f32, lat f32, demand_mw f32
  //
  // v1 files carry no bus id, so a stale export degrades to demand-only: the
  // demand hexbins still render and every bus-level channel (bus_voltage,
  // ac_overlay) finds no position and paints nothing. That is deliberate —
  // reading v1 bytes at v2 offsets would place buses at garbage coordinates.
  loadBusLoads(buffer) {
    const view = new DataView(buffer);
    const v2 =
      buffer.byteLength >= 4 &&
      view.getUint8(0) === 0x42 && // B
      view.getUint8(1) === 0x4c && // L
      view.getUint8(2) === 0x44 && // D
      view.getUint8(3) === 2;

    let offset = v2 ? 4 : 0;
    const count = view.getUint32(offset, true); offset += 4;

    const ids = v2 ? new Uint32Array(count) : null;
    const positions = new Float32Array(count * 2);
    const demands = new Float32Array(count);
    const indexByBusId = new Map();

    for (let i = 0; i < count; i++) {
      if (v2) {
        const busId = view.getUint32(offset, true); offset += 4;
        ids[i] = busId;
        indexByBusId.set(busId, i);
      }
      positions[i * 2] = view.getFloat32(offset, true); offset += 4;
      positions[i * 2 + 1] = view.getFloat32(offset, true); offset += 4;
      demands[i] = view.getFloat32(offset, true); offset += 4;
    }

    if (!v2) {
      console.warn(
        "GridMap: bus_loads.bin is the pre-bus-id layout; bus-level overlays " +
          "(voltage, shed) cannot be placed until the export is regenerated"
      );
    }

    this.busLoads = { count, ids, positions, demands, indexByBusId };
    this._demandHexCache = {};
    this._voltageHexCache = {};
    this._shedMarkCache = null;
  }

  // [lon, lat] of a bus, or null when the bus is not in the export (buses with
  // no in-service load, and every bus at all under a v1 export).
  positionForBus(busId) {
    const i = this.busLoads.indexByBusId.get(Number(busId));
    if (i === undefined) return null;
    return [this.busLoads.positions[i * 2], this.busLoads.positions[i * 2 + 1]];
  }

  // Per-bus voltage magnitudes (pu) for the voltage-depth overlay.
  //
  // Each incoming message REPLACES the map rather than merging into it: a
  // step's `bus_voltage` is the complete alarm set across every island the
  // cascade has AC coverage for, and a cascade's `ac_overlay` is the complete
  // magnitude map for those same islands. Merging would strand a bus at a
  // reading it has since recovered from, because neither channel ever says
  // "this bus is back in band" — it just stops naming it.
  //
  // A payload that omits the key entirely is silent, not empty: the caller
  // does not reach here, and the previous set stands (a step whose voltage
  // layer never ran must not read as "no violations").
  applyBusVoltage(vmByBus) {
    if (!vmByBus) return;
    this.busVoltage = new Map(
      Object.entries(vmByBus).map(([busId, vm]) => [Number(busId), Number(vm)])
    );
    this._voltageHexCache = {};
  }

  // The end-of-cascade `ac_overlay`: FULL magnitude maps for the islands whose
  // AC solve converged. A per-cell minimum needs every bus in the cell, not
  // only the ones already outside the band, which is why this channel is worth
  // its extra bytes over the per-step alarm set.
  applyVoltageOverlay(overlay) {
    if (!overlay || !Array.isArray(overlay.islands)) return;
    const next = new Map();
    for (const island of overlay.islands) {
      for (const [busId, vm] of Object.entries(island.vm_by_bus || {})) {
        next.set(Number(busId), Number(vm));
      }
    }
    this.busVoltage = next;
    this._voltageHexCache = {};
  }

  // Buses that lost load to UFLS/UVLS/blackout. Cumulative across steps, like
  // the trip marks: shedding is not undone within a cascade, and no channel
  // reports restoration.
  applyShedBusIds(ids) {
    if (!ids || ids.length === 0) return;
    for (const id of ids) this.shedBusIds.add(Number(id));
    this._shedMarkCache = null;
  }

  resetVoltageOverlay() {
    this.busVoltage = new Map();
    this.shedBusIds = new Set();
    this._voltageHexCache = {};
    this._shedMarkCache = null;
  }

  // Aggregate known per-bus voltages into H3 cells: {hex, min, max}. Memoized
  // per resolution like the demand hexbins, invalidated whenever the voltage
  // set changes.
  //
  // Both extremes are kept because they are different failure modes at
  // opposite ends of the band — a sagging cell is described by its worst
  // undervoltage and a Ferranti-rising cell by its worst overvoltage, and a
  // minimum alone cannot see the second one.
  getVoltageHexagons(res, h3) {
    if (this._voltageHexCache[res]) return this._voltageHexCache[res];
    if (this.busVoltage.size === 0) return [];

    const cells = new Map();
    for (const [busId, vm] of this.busVoltage) {
      const pos = this.positionForBus(busId);
      if (!pos) continue;
      const hex = h3.latLngToCell(pos[1], pos[0], res);
      const cell = cells.get(hex);
      if (cell) {
        if (vm < cell.min) cell.min = vm;
        if (vm > cell.max) cell.max = vm;
      } else {
        cells.set(hex, { hex, min: vm, max: vm });
      }
    }

    const out = [...cells.values()];
    this._voltageHexCache[res] = out;
    return out;
  }

  // Positioned shed marks; buses missing from the export are dropped rather
  // than drawn at [0, 0] in the Gulf of Guinea. Memoized so panning keeps a
  // stable data identity for deck.gl.
  getShedBusMarks() {
    if (this._shedMarkCache) return this._shedMarkCache;
    const marks = [];
    for (const busId of this.shedBusIds) {
      const position = this.positionForBus(busId);
      if (position) marks.push({ id: busId, position });
    }
    this._shedMarkCache = marks;
    return marks;
  }

  // Aggregate per-bus demand into H3 cells at the given resolution. Memoized
  // per resolution so panning at one zoom doesn't re-bin 77k points.
  getDemandHexagons(res, h3) {
    if (this._demandHexCache[res]) return this._demandHexCache[res];
    if (!this.busLoads.count) return [];

    const sums = new Map();
    const { positions, demands, count } = this.busLoads;
    for (let i = 0; i < count; i++) {
      const lon = positions[i * 2];
      const lat = positions[i * 2 + 1];
      const mw = demands[i];
      if (!(mw > 0)) continue;
      const hex = h3.latLngToCell(lat, lon, res);
      sums.set(hex, (sums.get(hex) || 0) + mw);
    }

    const out = [];
    for (const [hex, mw] of sums) out.push({ hex, mw });
    this._demandHexCache[res] = out;
    return out;
  }

  loadWaterFacilities(json) {
    const facilities = json.facilities.map((f) => ({
      id: f.id,
      position: [f.lon, f.lat],
      name: f.name,
      capacityMgd: f.capacityMgd,
      powerMw: f.powerMw,
      storageAcreFeet: f.storageAcreFeet,
      facilityType: f.facilityType,
      busId: f.busId || null,
      state: f.state || 0,
    }));

    this.waterFacilities = { count: facilities.length, facilities };

    // Apply cascade impacts that arrived while the lazy fetch was in flight
    if (this._pendingWaterStates.size > 0) {
      for (const f of facilities) {
        const s = this._pendingWaterStates.get(f.id);
        if (s !== undefined) f.state = s;
      }
      this._pendingWaterStates.clear();
    }
  }

  getWaterFacilityData() {
    return this.waterFacilities.facilities;
  }

  loadDatacenters(json) {
    const datacenters = json.datacenters.map((d) => ({
      id: d.id,
      position: [d.lon, d.lat],
      name: d.name,
      operator: d.operator,
      powerMw: d.powerMw,
      facilityType: d.facilityType,
      busId: d.busId || null,
      state: d.state || 0,
    }));

    this.datacenters = { count: datacenters.length, datacenters };
  }

  getDatacenterData() {
    return this.datacenters.datacenters;
  }

  // Update datacenter states by ID list
  applyDatacenterState(ids, newState) {
    if (!ids || ids.length === 0) return;
    const idSet = new Set(ids);
    for (const d of this.datacenters.datacenters) {
      if (idSet.has(d.id)) d.state = newState;
    }
  }

  // Clear flow-derived line states (stressed/overloaded/rerouted) while
  // preserving tripped marks — used before an authoritative re-classification.
  resetLineFlowStates() {
    for (const line of this.transmissionLines.lines) {
      if (line.state !== STATE_TRIPPED) line.state = STATE_NORMAL;
    }
  }

  // Per-line loading percentage from the solver ("line_loading" on dc_update
  // payloads, contract #3). The server only sends lines loaded >= 30%; any id
  // absent from the map is in the lowest band (0%).
  applyLineLoading(loadingMap) {
    if (!loadingMap) return;
    for (const line of this.transmissionLines.lines) {
      const pct = loadingMap[line.id];
      line.loadingPct = pct !== undefined ? Number(pct) : 0;
    }
  }

  resetLineLoading() {
    for (const line of this.transmissionLines.lines) {
      line.loadingPct = 0;
    }
  }

  // Apply per-ID states to transmission lines only
  applyLineStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    for (const line of this.transmissionLines.lines) {
      const s = stateMap[line.id];
      if (s !== undefined) line.state = s;
    }
  }

  // Apply per-ID states to generators only
  applyGeneratorStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.generators.ids) return;
    for (let i = 0; i < this.generators.count; i++) {
      const s = stateMap[this.generators.ids[i]];
      if (s !== undefined) this.generators.states[i] = s;
    }
    this._syncCachedStates(this._generatorData, this.generators.states);
  }

  // Apply per-ID states to substations only
  applySubstationStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.substations.ids) return;
    for (let i = 0; i < this.substations.count; i++) {
      const s = stateMap[this.substations.ids[i]];
      if (s !== undefined) this.substations.states[i] = s;
    }
    this._syncCachedStates(this._substationData, this.substations.states);
  }

  // Update water facility states by ID list. Facilities load lazily; states
  // arriving before the data are buffered and applied on load.
  applyWaterFacilityState(ids, newState) {
    if (!ids || ids.length === 0) return;
    if (this.waterFacilities.count === 0) {
      for (const id of ids) this._pendingWaterStates.set(id, newState);
      return;
    }
    const idSet = new Set(ids);
    for (const f of this.waterFacilities.facilities) {
      if (idSet.has(f.id)) f.state = newState;
    }
  }

  resetAllStates() {
    if (this.generators.states) this.generators.states.fill(STATE_NORMAL);
    for (const line of this.transmissionLines.lines) line.state = STATE_NORMAL;
    if (this.substations.states) this.substations.states.fill(STATE_NORMAL);
    if (this.transformers.states) this.transformers.states.fill(STATE_NORMAL);
    for (const f of this.waterFacilities.facilities) f.state = STATE_NORMAL;
    for (const d of this.datacenters.datacenters) d.state = STATE_NORMAL;
    this._pendingWaterStates.clear();
    // Both callers (resetToBaseline, and showCascadeStep before it replays)
    // want the voltage overlay to start from nothing.
    this.resetVoltageOverlay();
    this._syncCachedStates(this._generatorData, this.generators.states);
    this._syncCachedStates(this._substationData, this.substations.states);
    this._syncCachedStates(this._transformerData, this.transformers.states);
  }

  getGeneratorData() {
    if (this._generatorData) return this._generatorData;
    const data = [];
    for (let i = 0; i < this.generators.count; i++) {
      data.push({
        id: this.generators.ids[i],
        position: [this.generators.positions[i * 2], this.generators.positions[i * 2 + 1]],
        capacity: this.generators.capacities[i],
        fuelType: this.generators.fuelTypes[i],
        state: this.generators.states[i],
      });
    }
    this._generatorData = data;
    return data;
  }

  getSubstationData() {
    if (this._substationData) return this._substationData;
    const data = [];
    for (let i = 0; i < this.substations.count; i++) {
      data.push({
        id: this.substations.ids[i],
        position: [this.substations.positions[i * 2], this.substations.positions[i * 2 + 1]],
        voltage: this.substations.voltages[i],
        state: this.substations.states[i],
      });
    }
    this._substationData = data;
    return data;
  }
}
