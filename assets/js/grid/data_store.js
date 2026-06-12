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
  }

  getTransformerData() {
    const data = [];
    for (let i = 0; i < this.transformers.count; i++) {
      data.push({
        id: this.transformers.ids[i],
        position: [this.transformers.positions[i * 2], this.transformers.positions[i * 2 + 1]],
        ratedMva: this.transformers.ratings[i],
        state: this.transformers.states[i],
      });
    }
    return data;
  }

  applyTransformerStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.transformers.ids) return;
    for (let i = 0; i < this.transformers.count; i++) {
      const s = stateMap[this.transformers.ids[i]];
      if (s !== undefined) this.transformers.states[i] = s;
    }
  }

  // Clear flow-derived transformer states, preserving tripped marks
  resetTransformerFlowStates() {
    if (!this.transformers.states) return;
    for (let i = 0; i < this.transformers.count; i++) {
      if (this.transformers.states[i] !== STATE_TRIPPED) {
        this.transformers.states[i] = STATE_NORMAL;
      }
    }
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
  }

  // Apply per-ID states to substations only
  applySubstationStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.substations.ids) return;
    for (let i = 0; i < this.substations.count; i++) {
      const s = stateMap[this.substations.ids[i]];
      if (s !== undefined) this.substations.states[i] = s;
    }
  }

  // Update water facility states by ID list
  applyWaterFacilityState(ids, newState) {
    if (!ids || ids.length === 0) return;
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
  }

  getGeneratorData() {
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
    return data;
  }

  getSubstationData() {
    const data = [];
    for (let i = 0; i < this.substations.count; i++) {
      data.push({
        id: this.substations.ids[i],
        position: [this.substations.positions[i * 2], this.substations.positions[i * 2 + 1]],
        voltage: this.substations.voltages[i],
        state: this.substations.states[i],
      });
    }
    return data;
  }
}
