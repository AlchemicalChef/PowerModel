import maplibregl from "maplibre-gl";
import { MapboxOverlay } from "@deck.gl/mapbox";
import { DataStore } from "./data_store";
import { createGeneratorsLayer } from "./layers/generators_layer";
import { createTransmissionLayer } from "./layers/transmission_layer";
import { createSubstationsLayer } from "./layers/substations_layer";
import { createWaterFacilitiesLayer } from "./layers/water_facilities_layer";
import { createDatacentersLayer } from "./layers/datacenters_layer";
import { createTransformersLayer } from "./layers/transformers_layer";
import { createDemandDensityLayer } from "./layers/demand_density_layer";
import { createVoltageOverlayLayer } from "./layers/voltage_overlay_layer";
import { COLOR_SCALES } from "./color_scales";
import { ViewportTracker } from "./viewport_tracker";

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
    // UI-M21: whether the SERVER has said this cascade is over ("cascade_done").
    // Cascade mode is a fact the server reports, and it used to be re-derived
    // from `cascadeHistory.length` inside showCascadeStep — so reviewing a
    // finished cascade re-armed cascade mode (vignette, ghosting, forced
    // layers) with no exit but Reset, because no second cascade_done was ever
    // coming.
    this.cascadeEnded = false;
    // Whether the impact view is currently on, so onImpactViewChange fires on
    // transitions rather than on every repaint.
    this._impactViewOn = false;
    this.showWaterFacilities = false;
    this.showDatacenters = false;
    this.showDemandDensity = false;
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
    // Separate from onCascadeActiveChange: "a cascade is RUNNING" and "the
    // impact of a cascade is on the map" are different facts, and only the
    // first should drive live affordances (the pulsing alarm bar).
    this.onImpactViewChange = null;
    this.selectedComponent = null; // { type, id }
    this.map = null;
    this.deckOverlay = null;
    this.viewportTracker = null;
    this._waterLoadPromise = null;
    this._errorBanner = null;

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

    // Basemap/tile failures must be visible, not a silent blank page.
    this.map.on("error", (e) => {
      console.error("GridMap: basemap error", e && e.error);
      this._showMapError(
        "Basemap failed to load. Grid overlays may still work; check your network connection."
      );
    });

    // Zoom LOD and label culling are computed client-side from the viewport
    // (no server round trip); the server is still informed so it can adapt
    // payloads, but it must not echo back — a server-triggered rebuild made
    // every debounced pan rebuild ~90k line paths TWICE (UIW-8). The tracker
    // debounces and filters insignificant moves.
    this.viewportTracker = new ViewportTracker(this.map, (zoom, bounds) =>
      this._onViewportMove(zoom, bounds)
    );
  }

  // One debounced viewport move: rebuild locally, then tell the server. The
  // rebuild count per notification is exactly one and must stay there.
  _onViewportMove(zoom, bounds) {
    this._updateLayers();
    if (this.onViewportChange) this.onViewportChange(zoom, bounds);
  }

  // One-time, dismissable error banner inside the map container
  _showMapError(message) {
    if (this._errorBanner || !this.container) return;
    const banner = document.createElement("div");
    banner.className = "map-error-banner";
    banner.setAttribute("role", "alert");
    const text = document.createElement("span");
    text.textContent = message;
    const dismiss = document.createElement("button");
    dismiss.className = "map-error-dismiss";
    dismiss.type = "button";
    dismiss.setAttribute("aria-label", "Dismiss");
    dismiss.textContent = "×";
    // Keep this._errorBanner set after dismissal so repeated tile errors
    // don't re-spawn the banner every pan.
    dismiss.addEventListener("click", () => banner.remove());
    banner.appendChild(text);
    banner.appendChild(dismiss);
    this.container.appendChild(banner);
    this._errorBanner = banner;
  }

  async loadInitialData() {
    // Water facilities (17.7 MB JSON, default-off layer) are NOT fetched
    // here — see _ensureWaterFacilitiesLoaded (lazy, on first toggle or
    // first cascade impact).
    const [genData, transData, subData, dcData, xfmrData, loadData] = await Promise.all([
      fetch("/grid_data/generators.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/transmission.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/substations.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/datacenters.json").then((r) =>
        r.ok ? r.json() : null
      ),
      fetch("/grid_data/transformers.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
      fetch("/grid_data/bus_loads.bin").then((r) =>
        r.ok ? r.arrayBuffer() : null
      ),
    ]);

    if (genData) this.dataStore.loadGenerators(genData);
    if (transData) this.dataStore.loadTransmissionLines(transData);
    if (subData) this.dataStore.loadSubstations(subData);
    if (dcData) this.dataStore.loadDatacenters(dcData);
    if (xfmrData) this.dataStore.loadTransformers(xfmrData);
    if (loadData) this.dataStore.loadBusLoads(loadData);

    this._updateLayers();
  }

  // Lazy-fetch the water facilities JSON once, on first need. The promise is
  // cached only on success: a transient network failure must not permanently
  // disable the layer for the session, so failures clear the cache and the
  // next toggle/cascade impact retries the fetch.
  _ensureWaterFacilitiesLoaded() {
    if (this._waterLoadPromise) return this._waterLoadPromise;
    this._waterLoadPromise = fetch("/grid_data/water_facilities.json")
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((json) => {
        this.dataStore.loadWaterFacilities(json);
        this._updateLayers();
      })
      .catch((err) => {
        this._waterLoadPromise = null;
        console.error(
          "GridMap: water facilities load failed (will retry on next toggle)",
          err
        );
      });
    return this._waterLoadPromise;
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

    // Current viewport (plain object) for client-side label culling
    let viewBounds = null;
    if (this.map) {
      const b = this.map.getBounds();
      viewBounds = {
        west: b.getWest(),
        south: b.getSouth(),
        east: b.getEast(),
        north: b.getNorth(),
      };
    }

    // Every layer's emphasis decision reads the IMPACT view, not liveness:
    // ghosting, ghost-shrink, forced-visible impacted infrastructure. A
    // settled cascade is still a cascade to look at.
    const ca = this._impactView();
    // The settled half of the impact view. The rerouted class is demoted to a
    // tint here: flow redistribution is informational, and at collapse scale
    // it is the overwhelming majority of what gets repainted, so at full
    // weight a ride-through reads as a catastrophe.
    const review = ca && !this.cascadeActive;

    // Demand-density hexbin overlay (drawn first = beneath the network) so
    // the line/generator geometry stays legible on top of it.
    layers.push(
      ...createDemandDensityLayer(
        this.dataStore,
        zoom,
        !this.showDemandDensity,
        this.stateVersion
      )
    );

    // Voltage-depth hexbins and shed-bus marks, also beneath the network and
    // above the demand hexbins: the two rarely coexist (demand density is a
    // baseline view, voltage depth only exists during/after a cascade) and
    // when they do, the failure surface is the one to read.
    layers.push(
      ...createVoltageOverlayLayer(this.dataStore, zoom, this.stateVersion)
    );

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
        this.categoryFilters.voltage, this.stateVersion, review)
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
        }, selectedType === "substation" ? selectedId : null, ca,
        this.stateVersion)
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
          stateVersion: this.stateVersion,
          bounds: viewBounds })
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
    this._applyDCClassification(data);

    // A settled classification arriving while cascade frames exist is the
    // authoritative post-cascade view: attach it to the last frame so
    // scrubbing to the end of the timeline reproduces the settled view
    // (frames are replayed by ARRAY POSITION — see showCascadeStep).
    if (this.cascadeHistory.length > 0) {
      this.cascadeHistory[this.cascadeHistory.length - 1].__finalClassification =
        data;
    }

    this._updateLayers();
  }

  _applyDCClassification(data) {
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

    // Per-line loading percentages for the "Loading %" view mode
    // (contract #3; the field is optional — older servers omit it).
    if (data.line_loading) {
      this.dataStore.applyLineLoading(data.line_loading);
    }

    // The end-of-cascade voltage overlay (UIW-2/UIW-4) rides on the same
    // payload as the DC lists. Consuming it HERE rather than in
    // applyACResults is what makes scrubbing agree with the live view: this
    // payload is also stored as __finalClassification on the last cascade
    // frame, so showCascadeStep replays the overlay through the same path.
    if (data.ac_overlay) {
      this.dataStore.applyVoltageOverlay(data.ac_overlay);
    }
  }

  applyACResults(data) {
    // The AC channel carries partial, per-island voltages plus the DC
    // classification lists ridden along unchanged (an overlay without them
    // would blank the map the dc_update just painted, because the DC painter
    // clears every flow state before applying what it is given).
    //
    // It replaced a substation-level voltage-violation channel that no server
    // ever produced. Bus ids are NOT substation ids — independently allocated
    // integer spaces — so nothing bus-level may be routed back through
    // applySubstationStateMap.
    this.applyDCResults(data);
  }

  // The single writer of `cascadeActive`, so the callback fires exactly on
  // transitions and every entry point agrees on what "in cascade mode" means.
  _setCascadeActive(next) {
    if (next === this.cascadeActive) return;
    this.cascadeActive = next;
    if (this.onCascadeActiveChange) this.onCascadeActiveChange(next);
  }

  // Is the impact picture on? — unaffected components ghosted, affected ones
  // emphasised with glow and boosted width, impacted water/datacenters/
  // substations forced visible.
  //
  // This is what makes a cascade legible, and it used to be tied to
  // `cascadeActive` alone: the moment the run settled, the ghost layer was
  // replaced by the ordinary full-brightness network and the impact was
  // erased at exactly the moment the operator wanted to study it. The trip
  // marks were never lost — a tripped line still paints red through the final
  // classification — but at 1px with no glow, among ~99k fully-lit lines,
  // "still painted" and "invisible" are the same thing.
  //
  // So the view outlives the run: it stays until Reset Grid or the next trip.
  // `cascadeHistory.length` is the guard for a cascade_done that carries no
  // impact at all (a failed server start pushes one), which would otherwise
  // ghost the entire network with nothing to look at.
  _impactView() {
    // Boolean(), not the bare `||` chain: `undefined && x` is `undefined`, and
    // this value is compared with === against the last one and handed to
    // classList.toggle, both of which need a real boolean.
    return Boolean(
      this.cascadeActive || (this.cascadeEnded && this.cascadeHistory.length > 0)
    );
  }

  // Fires onImpactViewChange on transitions only. Called after every mutation
  // of the two flags it is computed from.
  _syncImpactView() {
    const on = this._impactView();
    if (on === this._impactViewOn) return;
    this._impactViewOn = on;
    if (this.onImpactViewChange) this.onImpactViewChange(on);
  }

  applyCascadeStep(data) {
    this.stateVersion++;
    this.cascadeHistory.push(data);

    // A frame is a live cascade by definition: a new one after a finished run
    // re-arms cascade mode. The previous run's review view gives way to this
    // one's live view without ever passing through full brightness.
    this.cascadeEnded = false;
    this._setCascadeActive(true);
    this._syncImpactView();

    // The cascade forces the water layer visible for impacted facilities;
    // fetch the (lazy) dataset the first time an impact actually appears.
    // States arriving before the fetch resolves are buffered in the store.
    if (data.water_facility_ids && data.water_facility_ids.length > 0) {
      this._ensureWaterFacilitiesLoaded();
    }

    this._applyCascadeData(data);
    this._updateLayers();
  }

  // Cascade finished (server "cascade_done", contract #2): leave the LIVE
  // state — the pulsing alarm bar, the timeline's progress affordance — and
  // enter review. The impact picture stays exactly as it was: ghosted
  // context, emphasised failures, and the final classification on top of
  // them. Reset Grid or the next trip is what clears it.
  endCascade(_stable) {
    this.cascadeEnded = true;
    this._setCascadeActive(false);
    this._syncImpactView();
    this.stateVersion++;
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

    // Bus-level failure surface (UIW-2). Both keys are omitted entirely when
    // the step has nothing to say — an absent key means NO INFORMATION, not
    // "no violations", so the previous overlay stands rather than being
    // cleared. A step's bus_voltage is the violating set only; the full
    // magnitude map arrives once per cascade on the AC channel.
    if (data.bus_voltage) {
      this.dataStore.applyBusVoltage(data.bus_voltage);
    }
    if (data.shed_bus_ids) {
      this.dataStore.applyShedBusIds(data.shed_bus_ids);
    }
  }

  resetToBaseline() {
    this.stateVersion++;
    this.dataStore.resetAllStates();
    this.dataStore.resetLineLoading();
    this.cascadeHistory = [];
    // Nothing to review and nothing running: the next frame starts a cascade
    // from scratch rather than reviving the one that was just cleared. This
    // is the one exit from the review view that returns the map to full
    // brightness.
    this.cascadeEnded = false;
    this._setCascadeActive(false);
    this._syncImpactView();

    this._updateLayers();
  }

  setViewMode(mode) {
    this.viewMode = mode;
    this._updateLayers();
  }

  setWaterFacilitiesVisible(visible) {
    this.showWaterFacilities = !!visible;
    if (this.showWaterFacilities) {
      // Lazy 17.7 MB fetch on first toggle; _updateLayers re-runs on load
      this._ensureWaterFacilitiesLoaded();
    }
    this._updateLayers();
  }

  setDatacentersVisible(visible) {
    this.showDatacenters = !!visible;
    this._updateLayers();
  }

  setDemandDensityVisible(visible) {
    this.showDemandDensity = !!visible;
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

  // Replay a finished cascade up to `position`. Returns false when the scrub
  // was refused (see below), true when the map was rewound.
  showCascadeStep(position) {
    // UI-M19: a RUNNING cascade may not be rewound. The replay below resets
    // every component state and re-applies frames 0..position; the frames
    // after `position` are skipped, and the live frames that arrive next are
    // applied on top of that truncated map. Their trip marks are then gone for
    // the rest of the session — the settled dc_update repaints flow classes
    // but never STATE_TRIPPED, which only cascade frames carry. Scrubbing a
    // timeline that is still being appended to is also of no use to the
    // viewer: the next frame snaps the map forward again within a second. The
    // timeline's buttons are disabled while `active` for the same reason.
    if (this.cascadeActive) return false;

    // Reset and replay THROUGH the clicked frame (inclusive), indexing
    // cascadeHistory by ARRAY POSITION (contract #4). Server step numbers
    // reset at every manual trip and can repeat across cascades in one
    // session, so they are never used as indexes here. A frame carrying the
    // settled post-cascade classification (__finalClassification, attached
    // by applyDCResults) replays that classification too, so scrubbing to
    // the last frame agrees with the settled view.
    this.stateVersion++;
    this.dataStore.resetAllStates();
    // UI-M21: restore the server-reported flag rather than deriving activity
    // from the history length. A finished cascade stays finished however far
    // back the viewer scrubs; a negative position (nothing replayed) leaves
    // cascade mode the same way it always did.
    this._setCascadeActive(
      !this.cascadeEnded && position >= 0 && this.cascadeHistory.length > 0
    );
    // Reviewing a step keeps the review view: the ghosting is what makes the
    // replayed frame readable, and it is the same view the scrub was started
    // from.
    this._syncImpactView();
    for (let i = 0; i <= position && i < this.cascadeHistory.length; i++) {
      const frame = this.cascadeHistory[i];
      this._applyCascadeData(frame);
      if (frame.__finalClassification) {
        this._applyDCClassification(frame.__finalClassification);
      }
    }
    this._updateLayers();
    return true;
  }

  destroy() {
    if (this.viewportTracker) {
      this.viewportTracker.destroy();
      this.viewportTracker = null;
    }
    if (this._errorBanner) {
      this._errorBanner.remove();
      this._errorBanner = null;
    }
    if (this.map) {
      this.map.remove();
    }
  }
}
