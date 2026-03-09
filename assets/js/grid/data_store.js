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
  }

  loadGenerators(buffer) {
    const view = new DataView(buffer);
    const count = view.getUint32(0, true);
    let offset = 4;

    const ids = new Uint32Array(count);
    const positions = new Float32Array(count * 2);
    const capacities = new Float32Array(count);
    const fuelTypes = new Uint8Array(count);
    const states = new Uint8Array(count);

    for (let i = 0; i < count; i++) {
      ids[i] = view.getUint32(offset, true); offset += 4;
      positions[i * 2] = view.getFloat32(offset, true); offset += 4;
      positions[i * 2 + 1] = view.getFloat32(offset, true); offset += 4;
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

  applyLineStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    for (const line of this.transmissionLines.lines) {
      const s = stateMap[line.id];
      if (s !== undefined) line.state = s;
    }
  }

  applyGeneratorStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.generators.ids) return;
    for (let i = 0; i < this.generators.count; i++) {
      const s = stateMap[this.generators.ids[i]];
      if (s !== undefined) this.generators.states[i] = s;
    }
  }

  applySubstationStateMap(stateMap) {
    if (!stateMap || Object.keys(stateMap).length === 0) return;
    if (!this.substations.ids) return;
    for (let i = 0; i < this.substations.count; i++) {
      const s = stateMap[this.substations.ids[i]];
      if (s !== undefined) this.substations.states[i] = s;
    }
  }

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
    for (const f of this.waterFacilities.facilities) f.state = STATE_NORMAL;
  }

  resetTransientStates() {
    if (this.generators.states) {
      for (let i = 0; i < this.generators.states.length; i++) {
        const s = this.generators.states[i];
        if (s === 1 || s === 2 || s === 4) this.generators.states[i] = STATE_NORMAL;
      }
    }
    for (const line of this.transmissionLines.lines) {
      if (line.state === 1 || line.state === 2 || line.state === 4) line.state = STATE_NORMAL;
    }
    if (this.substations.states) {
      for (let i = 0; i < this.substations.states.length; i++) {
        const s = this.substations.states[i];
        if (s === 1 || s === 2 || s === 4) this.substations.states[i] = STATE_NORMAL;
      }
    }
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
