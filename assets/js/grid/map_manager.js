import maplibregl from "maplibre-gl";
import { MapboxOverlay } from "@deck.gl/mapbox";
import { DataStore } from "./data_store";
import { createGeneratorsLayer } from "./layers/generators_layer";
import { createTransmissionLayer } from "./layers/transmission_layer";
import { createSubstationsLayer } from "./layers/substations_layer";
import { createWaterFacilitiesLayer } from "./layers/water_facilities_layer";
import { createCriticalFacilitiesLayer } from "./layers/critical_facilities_layer";
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
    this.onComponentClick = null;
    this.onViewportChange = null;
    this.onCascadeActiveChange = null;
    this.selectedComponent = null;
    this.hiddenLayers = new Set();
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
    const [genData, transData, subData, waterData, ciData] = await Promise.all([
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
      fetch("/grid_data/critical_facilities.json").then((r) =>
        r.ok ? r.json() : null
      ),
    ]);

    if (genData) this.dataStore.loadGenerators(genData);
    if (transData) this.dataStore.loadTransmissionLines(transData);
    if (subData) this.dataStore.loadSubstations(subData);
    if (waterData) this.dataStore.loadWaterFacilities(waterData);
    if (ciData) this.dataStore.loadCriticalFacilities(ciData);

    this._updateLayers();
  }

  setSelectedComponent(type, id) {
    this.selectedComponent = type && id != null ? { type, id: Number(id) } : null;
    this._updateLayers();
  }

  flyToComponent(type, id) {
    if (!this.map) return;
    const numId = Number(id);
    let lon = null, lat = null;

    if (type === "generator") {
      const g = this.dataStore.generators;
      for (let i = 0; i < g.count; i++) {
        if (g.ids[i] === numId) {
          lon = g.positions[i * 2];
          lat = g.positions[i * 2 + 1];
          break;
        }
      }
    } else if (type === "substation") {
      const s = this.dataStore.substations;
      for (let i = 0; i < s.count; i++) {
        if (s.ids[i] === numId) {
          lon = s.positions[i * 2];
          lat = s.positions[i * 2 + 1];
          break;
        }
      }
    } else if (type === "transmission_line") {
      const lines = this.dataStore.transmissionLines.lines;
      const line = lines.find(l => l.id === numId);
      if (line && line.path && line.path.length > 0) {
        const mid = Math.floor(line.path.length / 2);
        lon = line.path[mid][0];
        lat = line.path[mid][1];
      }
    } else if (type === "water_facility") {
      const wf = this.dataStore.waterFacilities;
      if (wf.facilities) {
        const facility = wf.facilities.find(f => f.id === numId);
        if (facility && facility.position) {
          lon = facility.position[0];
          lat = facility.position[1];
        }
      }
    } else if (type === "critical_facility") {
      const cf = this.dataStore.criticalFacilities;
      if (cf.facilities) {
        const facility = cf.facilities.find(f => f.id === numId);
        if (facility && facility.position) {
          lon = facility.position[0];
          lat = facility.position[1];
        }
      }
    }

    if (lon != null && lat != null) {
      this.map.flyTo({ center: [lon, lat], zoom: Math.max(this.map.getZoom(), 8), duration: 1500 });
    }
  }

  _updateLayers() {
    if (!this.deckOverlay) return;

    const zoom = this.map ? this.map.getZoom() : 4;
    const selectedId = this.selectedComponent ? this.selectedComponent.id : null;
    const selectedType = this.selectedComponent ? this.selectedComponent.type : null;
    const layers = [];

    const ca = this.cascadeActive;

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
        }, selectedType === "transmission_line" ? selectedId : null, ca)
      );
    }

    if (this.dataStore.generators.count > 0 && this.isLayerVisible("generators")) {
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
        }, selectedType === "generator" ? selectedId : null, ca)
      );
    }

    if (this.dataStore.substations.count > 0 && (zoom >= 8 || ca) && this.isLayerVisible("substations")) {
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

    const wfVisible = {
      1: this.isLayerVisible("wf_desal"),
      2: this.isLayerVisible("wf_waste"),
      3: this.isLayerVisible("wf_treat"),
      4: this.isLayerVisible("wf_pump"),
      5: this.isLayerVisible("wf_reservoir"),
    };
    const anyWFVisible = Object.values(wfVisible).some(v => v);

    if (this.dataStore.waterFacilities.count > 0 && anyWFVisible) {
      layers.push(
        createWaterFacilitiesLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("water_facility", obj.id, {
              capacity: obj.capacityMgd,
              powerMw: obj.powerMw,
              facilityType: obj.facilityType,
              busId: obj.busId,
              state: obj.state,
            });
          }
        }, selectedType === "water_facility" ? selectedId : null, ca, wfVisible)
      );
    }

    const ciVisible = {
      1: this.isLayerVisible("ci_hospital"),
      2: this.isLayerVisible("ci_fire"),
      3: this.isLayerVisible("ci_police"),
      4: this.isLayerVisible("ci_ems"),
    };
    const anyCIVisible = Object.values(ciVisible).some(v => v);

    if (this.dataStore.criticalFacilities.count > 0 && anyCIVisible) {
      layers.push(
        createCriticalFacilitiesLayer(this.dataStore, this.viewMode, zoom, (info) => {
          if (info.object && this.onComponentClick) {
            const obj = info.object;
            this.onComponentClick("critical_facility", obj.id, {
              category: obj.category,
              facilityType: obj.facilityType,
              beds: obj.beds,
              trauma: obj.trauma,
              powerMw: obj.powerMw,
              busId: obj.busId,
              state: obj.state,
            });
          }
        }, selectedType === "critical_facility" ? selectedId : null, ca, ciVisible)
      );
    }

    this.deckOverlay.setProps({ layers: layers.flat() });
  }

  applyDCResults(data) {
    const lineStateMap = {};

    if (data.overloaded_line_ids) {
      for (const id of data.overloaded_line_ids) lineStateMap[id] = 2;
    }
    if (data.stressed_line_ids) {
      for (const id of data.stressed_line_ids) lineStateMap[id] = 1;
    }
    if (data.rerouted_line_ids) {
      for (const id of data.rerouted_line_ids) lineStateMap[id] = 4;
    }

    this.dataStore.applyLineStateMap(lineStateMap);
    this._updateLayers();
  }

  applyACResults(data) {
    if (data.voltage_violation_substation_ids) {
      const subMap = {};
      for (const id of data.voltage_violation_substation_ids) subMap[id] = 1;
      this.dataStore.applySubstationStateMap(subMap);
    }
    this._updateLayers();
  }

  applyCascadeStep(data) {
    this.cascadeHistory.push(data);

    if (!this.cascadeActive) {
      this.cascadeActive = true;
      if (this.onCascadeActiveChange) this.onCascadeActiveChange(true);
    }

    this._applyCascadeData(data);
    this._updateLayers();
  }

  _applyCascadeData(data, cumulative = false) {
    if (!cumulative) {
      this.dataStore.resetTransientStates();
    }

    const lineMap = {};
    if (data.tripped_line_ids) {
      for (const id of data.tripped_line_ids) lineMap[id] = 3;
    }
    if (data.overloaded_line_ids) {
      for (const id of data.overloaded_line_ids) lineMap[id] = 2;
    }
    if (data.rerouted_line_ids) {
      for (const id of data.rerouted_line_ids) lineMap[id] = 4;
    }
    if (data.stressed_line_ids) {
      for (const id of data.stressed_line_ids) lineMap[id] = 1;
    }
    this.dataStore.applyLineStateMap(lineMap);

    const genMap = {};
    if (data.tripped_generator_ids) {
      for (const id of data.tripped_generator_ids) genMap[id] = 3;
    }
    this.dataStore.applyGeneratorStateMap(genMap);

    if (data.shed_ids) {
      const loadMap = {};
      for (const id of data.shed_ids) loadMap[id] = 5;
      this.dataStore.applyGeneratorStateMap(loadMap);
    }

    if (data.water_facility_ids && data.water_facility_ids.length > 0) {
      this.dataStore.applyWaterFacilityState(data.water_facility_ids, 3);
    }

    if (data.critical_facility_ids && data.critical_facility_ids.length > 0) {
      this.dataStore.applyCriticalFacilityState(data.critical_facility_ids, 3);
    }
  }

  resetToBaseline() {
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

  toggleLayer(layerId) {
    if (this.hiddenLayers.has(layerId)) {
      this.hiddenLayers.delete(layerId);
    } else {
      this.hiddenLayers.add(layerId);
    }
    this._updateLayers();
  }

  isLayerVisible(layerId) {
    return !this.hiddenLayers.has(layerId);
  }

  showCascadeStep(step) {
    this.dataStore.resetAllStates();
    const shouldBeActive = step > 0 && this.cascadeHistory.length > 0;
    if (shouldBeActive !== this.cascadeActive) {
      this.cascadeActive = shouldBeActive;
      if (this.onCascadeActiveChange) this.onCascadeActiveChange(shouldBeActive);
    }
    for (let i = 0; i < step && i < this.cascadeHistory.length; i++) {
      const isLast = (i === step - 1);
      this._applyCascadeData(this.cascadeHistory[i], !isLast);
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
