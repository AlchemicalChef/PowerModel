import maplibregl from "maplibre-gl";
import { MapboxOverlay } from "@deck.gl/mapbox";
import { DataStore } from "./data_store";
import { createGeneratorsLayer } from "./layers/generators_layer";
import { createTransmissionLayer } from "./layers/transmission_layer";
import { createSubstationsLayer } from "./layers/substations_layer";
import { createWaterFacilitiesLayer } from "./layers/water_facilities_layer";
import { createDatacentersLayer } from "./layers/datacenters_layer";
import { createTransformersLayer } from "./layers/transformers_layer";
import { COLOR_SCALES } from "./color_scales";

const MAPLIBRE_STYLE =
  "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json";

const INITIAL_VIEW = {
  longitude: -98.5,
  latitude: 39.5,
  zoom: 4.2,
  pitch: 0,
  bearing: 0,
};

export class MapManager {
  constructor(container) {
    this.container = container;
    this.dataStore = new DataStore();
    this.viewMode = "voltage_level";
    this.cascadeHistory = [];
    this.cascadeActive = false;
    this.showWaterFacilities = false;
    this.showDatacenters = false;
    // Monotonic counter bumped on every state mutation; used as the deck.gl
    // updateTrigger so color accessors re-evaluate exactly when needed
    // (Date.now() both defeated caching on idle pans and could collide
    // within one millisecond).
    this.stateVersion = 0;
    // Legend-driven visibility: sets of HIDDEN keys per category
    this.categoryFilters = {
      voltage: new Set(),
      fuel: new Set(),
      water: new Set(),
      datacenter: new Set(),
      equipment: new Set(),
    };
    this.onComponentClick = null;
    this.onViewportChange = null;
    this.onCascadeActiveChange = null;
    this.selectedComponent = null; // { type, id }
    this.map = null;
    this.deckOverlay = null;

    this._initMap();
  }

  _initMap() {
    this.map = new maplibregl.Map({
      container: this.container,
      style: MAPLIBRE_STYLE,
      center: [INITIAL_VIEW.longitude, INITIAL_VIEW.latitude],
      zoom: INITIAL_VIEW.zoom,
      pitch: INITIAL_VIEW.pitch,
      bearing: INITIAL_VIEW.bearing,
      antialias: true,
    });

    this.map.on("load", () => {
      this.deckOverlay = new MapboxOverlay({
        interleaved: false,
        layers: [],
      });
      this.map.addControl(this.deckOverlay);
      this._updateLayers();
    });

    this.map.on("moveend", () => {
      if (this.onViewportChange) {
        const bounds = this.map.getBounds();
        this.onViewportChange(this.map.getZoom(), {
          west: bounds.getWest(),
          south: bounds.getSouth(),
          east: bounds.getEast(),
          north: bounds.getNorth(),
        });
      }
    });
  }

  async loadInitialData() {
    const [genData, transData, subData, waterData, dcData, xfmrData] = await Promise.all([
      fetch("/grid_data/generators.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/transmission.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/substations.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/water_facilities.json").then((r) =>
        r.ok ? r.json() : null
      ),
      fetch("/grid_data/datacenters.json").then((r) =>
        r.ok ? r.json() : null
      ),
      fetch("/grid_data/transformers.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
    ]);

    if (genData) this.dataStore.loadGenerators(genData);
    if (transData) this.dataStore.loadTransmissionLines(transData);
    if (subData) this.dataStore.loadSubstations(subData);
    if (waterData) this.dataStore.loadWaterFacilities(waterData);
    if (dcData) this.dataStore.loadDatacenters(dcData);
    if (xfmrData) this.dataStore.loadTransformers(xfmrData);

    this._updateLayers();
  }

  setSelectedComponent(type, id) {
    this.selectedComponent = type && id != null ? { type, id: Number(id) } : null;
    this._updateLayers();
  }

  _updateLayers() {
    if (!this.deckOverlay) return;

    const zoom = this.map ? this.map.getZoom() : 4;
    const selectedId = this.selectedComponent ? this.selectedComponent.id : null;
    const selectedType = this.selectedComponent ? this.selectedComponent.type : null;
    const layers = [];

    const ca = this.cascadeActive;

    // Transmission lines (always visible, filtered by zoom)
    if (this.dataStore.transmissionLines.count > 0) {
      layers.push(
        createTransmissionLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("transmission_line", obj.id, {
              voltageKv: obj.voltageKv,
              ratingMva: obj.ratingMva,
              state: obj.state,
            });
          }
        }, selectedType === "transmission_line" ? selectedId : null, ca,
        this.categoryFilters.voltage, this.stateVersion)
      );
    }

    // Generators
    if (this.dataStore.generators.count > 0) {
      layers.push(
        createGeneratorsLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("generator", obj.id, {
              capacity: obj.capacity,
              fuelType: obj.fuelType,
              state: obj.state,
            });
          }
        }, selectedType === "generator" ? selectedId : null, ca,
        this.categoryFilters.fuel, this.stateVersion)
      );
    }

    // Substations (visible at zoom >= 8, or always during cascade)
    if (this.dataStore.substations.count > 0 && (zoom >= 8 || ca)) {
      layers.push(
        createSubstationsLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("substation", obj.id, {
              voltage: obj.voltage,
              state: obj.state,
            });
          }
        }, selectedType === "substation" ? selectedId : null, ca)
      );
    }

    // Transformers (visible at zoom >= 7; affected units at any zoom)
    if (this.dataStore.transformers.count > 0) {
      layers.push(
        createTransformersLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("transformer", obj.id, {
              ratingMva: obj.ratedMva,
              state: obj.state,
            });
          }
        }, selectedType === "transformer" ? selectedId : null, ca,
        this.categoryFilters.equipment.has("transformer"), this.stateVersion)
      );
    }

    // Water facilities / critical infrastructure: hidden unless toggled on.
    // During a cascade, facilities that lose power are still shown — that is
    // failure impact, not baseline clutter.
    if (this.dataStore.waterFacilities.count > 0 && (this.showWaterFacilities || ca)) {
      layers.push(
        createWaterFacilitiesLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("water_facility", obj.id, {
              capacityMgd: obj.capacityMgd,
              powerMw: obj.powerMw,
              facilityType: obj.facilityType,
              busId: obj.busId,
              state: obj.state,
            });
          }
        }, selectedType === "water_facility" ? selectedId : null, ca,
        { affectedOnly: !this.showWaterFacilities && ca,
          hiddenTypes: this.categoryFilters.water,
          stateVersion: this.stateVersion })
      );
    }

    // Datacenters: hidden unless toggled on; power-loss impacts always shown
    // during a cascade (same convention as water facilities).
    if (this.dataStore.datacenters.count > 0 && (this.showDatacenters || ca)) {
      layers.push(
        createDatacentersLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("datacenter", obj.id, {
              operator: obj.operator,
              powerMw: obj.powerMw,
              facilityType: obj.facilityType,
              busId: obj.busId,
              state: obj.state,
            });
          }
        }, selectedType === "datacenter" ? selectedId : null, ca,
        { affectedOnly: !this.showDatacenters && ca,
          hiddenTypes: this.categoryFilters.datacenter,
          stateVersion: this.stateVersion })
      );
    }

    this.deckOverlay.setProps({ layers: layers.flat() });
  }

  applyDCResults(data) {
    this.stateVersion++;

    // This is the authoritative flow classification for the current topology:
    // clear previous flow states (keeping tripped marks, which the solver
    // cannot see — tripped lines carry no flow) so recovered lines stop
    // showing stale alarms.
    this.dataStore.resetLineFlowStates();
    this.dataStore.resetTransformerFlowStates();

    // Apply least-severe first so a line in multiple lists keeps the most
    // severe color (rerouted < stressed < overloaded).
    const lineStateMap = {};
    if (data.rerouted_line_ids) {
      for (const id of data.rerouted_line_ids) lineStateMap[id] = 4; // orange - rerouted
    }
    if (data.stressed_line_ids) {
      for (const id of data.stressed_line_ids) lineStateMap[id] = 1; // yellow - stressed
    }
    if (data.overloaded_line_ids) {
      for (const id of data.overloaded_line_ids) lineStateMap[id] = 2; // red - overloaded
    }

    this.dataStore.applyLineStateMap(lineStateMap);

    const xfmrStateMap = {};
    if (data.rerouted_transformer_ids) {
      for (const id of data.rerouted_transformer_ids) xfmrStateMap[id] = 4;
    }
    if (data.stressed_transformer_ids) {
      for (const id of data.stressed_transformer_ids) xfmrStateMap[id] = 1;
    }
    if (data.overloaded_transformer_ids) {
      for (const id of data.overloaded_transformer_ids) xfmrStateMap[id] = 2;
    }
    this.dataStore.applyTransformerStateMap(xfmrStateMap);

    this._updateLayers();
  }

  applyACResults(data) {
    // AC refinement carries the same line-classification lists as DC --
    // apply them, plus substation-level voltage violations when present.
    if (data.voltage_violation_substation_ids) {
      const subMap = {};
      for (const id of data.voltage_violation_substation_ids) subMap[id] = 1;
      this.dataStore.applySubstationStateMap(subMap);
    }
    this.applyDCResults(data);
  }

  applyCascadeStep(data) {
    this.stateVersion++;
    this.cascadeHistory.push(data);

    if (!this.cascadeActive) {
      this.cascadeActive = true;
      if (this.onCascadeActiveChange) this.onCascadeActiveChange(true);
    }

    this._applyCascadeData(data);
    this._updateLayers();
  }

  _applyCascadeData(data) {
    // Line-specific state changes, least-severe written first so multi-list
    // ids keep the most severe state (rerouted < stressed < overloaded <
    // tripped).
    const lineMap = {};
    if (data.rerouted_line_ids) {
      for (const id of data.rerouted_line_ids) lineMap[id] = 4;
    }
    if (data.stressed_line_ids) {
      for (const id of data.stressed_line_ids) lineMap[id] = 1;
    }
    if (data.overloaded_line_ids) {
      for (const id of data.overloaded_line_ids) lineMap[id] = 2;
    }
    if (data.tripped_line_ids) {
      for (const id of data.tripped_line_ids) lineMap[id] = 3;
    }
    this.dataStore.applyLineStateMap(lineMap);

    // Transformer-specific state changes (separate id space from lines)
    const xfmrMap = {};
    if (data.rerouted_transformer_ids) {
      for (const id of data.rerouted_transformer_ids) xfmrMap[id] = 4;
    }
    if (data.stressed_transformer_ids) {
      for (const id of data.stressed_transformer_ids) xfmrMap[id] = 1;
    }
    if (data.overloaded_transformer_ids) {
      for (const id of data.overloaded_transformer_ids) xfmrMap[id] = 2;
    }
    if (data.tripped_transformer_ids) {
      for (const id of data.tripped_transformer_ids) xfmrMap[id] = 3;
    }
    this.dataStore.applyTransformerStateMap(xfmrMap);

    // Generator-specific state changes
    const genMap = {};
    if (data.tripped_generator_ids) {
      for (const id of data.tripped_generator_ids) genMap[id] = 3;
    }
    this.dataStore.applyGeneratorStateMap(genMap);

    // Water facility states
    if (data.water_facility_ids && data.water_facility_ids.length > 0) {
      this.dataStore.applyWaterFacilityState(data.water_facility_ids, 3);
    }

    // Datacenter states
    if (data.datacenter_ids && data.datacenter_ids.length > 0) {
      this.dataStore.applyDatacenterState(data.datacenter_ids, 3);
    }
  }

  resetToBaseline() {
    this.stateVersion++;
    this.dataStore.resetAllStates();
    this.cascadeHistory = [];

    if (this.cascadeActive) {
      this.cascadeActive = false;
      if (this.onCascadeActiveChange) this.onCascadeActiveChange(false);
    }

    this._updateLayers();
  }

  setViewMode(mode) {
    this.viewMode = mode;
    this._updateLayers();
  }

  setWaterFacilitiesVisible(visible) {
    this.showWaterFacilities = !!visible;
    this._updateLayers();
  }

  setDatacentersVisible(visible) {
    this.showDatacenters = !!visible;
    this._updateLayers();
  }

  setCategoryFilters(data) {
    this.categoryFilters = {
      voltage: new Set(data.voltage || []),
      fuel: new Set(data.fuel || []),
      water: new Set(data.water || []),
      datacenter: new Set(data.datacenter || []),
      equipment: new Set(data.equipment || []),
    };
    this._updateLayers();
  }

  showCascadeStep(step) {
    // Reset and replay THROUGH the clicked step (inclusive). Step numbers
    // start at 0 (the manual trip), matching cascadeHistory indexes.
    this.stateVersion++;
    this.dataStore.resetAllStates();
    const shouldBeActive = step >= 0 && this.cascadeHistory.length > 0;
    if (shouldBeActive !== this.cascadeActive) {
      this.cascadeActive = shouldBeActive;
      if (this.onCascadeActiveChange) this.onCascadeActiveChange(shouldBeActive);
    }
    for (let i = 0; i <= step && i < this.cascadeHistory.length; i++) {
      this._applyCascadeData(this.cascadeHistory[i]);
    }
    this._updateLayers();
  }

  updateLOD(zoom, bounds) {
    this._updateLayers();
  }

  destroy() {
    if (this.map) {
      this.map.remove();
    }
  }
}
