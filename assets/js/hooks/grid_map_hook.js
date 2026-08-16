import { MapManager } from "../grid/map_manager";

const GridMapHook = {
  mounted() {
    // A map/WebGL failure must never take down LiveView interactivity --
    // panels, toggles, and metrics still work without the map canvas.
    try {
      this.mapManager = new MapManager(this.el);
    } catch (err) {
      console.error("GridMap: map initialization failed; UI continues without map", err);
      this.mapManager = null;
    }

    if (!this.mapManager) {
      // Recursive black hole: every property read yields another callable
      // black hole, so arbitrarily deep accesses (manager.dataStore.x.count)
      // and chained calls all no-op instead of throwing.
      const blackhole = new Proxy(function () {}, {
        get: (_t, prop) => (prop === Symbol.toPrimitive ? () => 0 : blackhole),
        apply: () => blackhole,
      });
      this.mapManager = blackhole;
    }

    // Debug/automation handle (read access to the manager for tooling)
    window.__gridMapManager = this.mapManager;

    // Load initial grid data; a failed fetch must not become an unhandled
    // rejection that silently leaves the map empty with no trace.
    Promise.resolve(this.mapManager.loadInitialData()).catch((err) =>
      console.error("GridMap: initial grid data load failed", err)
    );

    // Wire server -> JS events
    this.handleEvent("dc_results", (data) => {
      this.mapManager.applyDCResults(data);
    });

    this.handleEvent("ac_results", (data) => {
      this.mapManager.applyACResults(data);
    });

    this.handleEvent("cascade_step", (data) => {
      this.mapManager.applyCascadeStep(data);
    });

    // Cascade finished (contract #2): leave the LIVE state but stay in the
    // impact view, so the failure picture survives for the operator to read.
    this.handleEvent("cascade_done", (data) => {
      this.mapManager.endCascade(data && data.stable);
    });

    this.handleEvent("reset_grid", () => {
      this.mapManager.resetToBaseline();
    });

    this.handleEvent("view_mode_changed", (data) => {
      this.mapManager.setViewMode(data.mode);
    });

    this.handleEvent("set_water_visibility", (data) => {
      this.mapManager.setWaterFacilitiesVisible(data.visible);
    });

    this.handleEvent("set_datacenter_visibility", (data) => {
      this.mapManager.setDatacentersVisible(data.visible);
    });

    this.handleEvent("set_demand_density_visibility", (data) => {
      this.mapManager.setDemandDensityVisible(data.visible);
    });

    this.handleEvent("set_category_filters", (data) => {
      this.mapManager.setCategoryFilters(data);
    });

    this.handleEvent("show_cascade_step", (data) => {
      this.mapManager.showCascadeStep(data.step);
    });

    this.handleEvent("deselect_highlight", () => {
      this.mapManager.setSelectedComponent(null, null);
    });

    // Two classes, because they answer different questions. `cascade-active`
    // is LIVENESS -- it drives the pulsing alarm bar, and a bar that kept
    // pulsing over a settled result would claim the grid is still failing.
    // `cascade-impact` is "there is a failure picture on this map", which
    // outlives the run and carries the vignette.
    const container = () =>
      this.el.closest(".grid-container") || this.el.parentElement;

    this.mapManager.onCascadeActiveChange = (active) => {
      const el = container();
      if (el) el.classList.toggle("cascade-active", active);
    };

    this.mapManager.onImpactViewChange = (on) => {
      const el = container();
      if (el) el.classList.toggle("cascade-impact", on);
    };

    // Wire JS -> server events
    this.mapManager.onComponentClick = (type, id, details) => {
      this.mapManager.setSelectedComponent(type, id);
      this.pushEvent("select_component", { type, id: String(id), ...details });
    };

    this.mapManager.onViewportChange = (zoom, bounds) => {
      this.pushEvent("viewport_changed", { zoom, bounds });
    };
  },

  destroyed() {
    if (this.mapManager) {
      this.mapManager.destroy();
    }
    // Drop the debug handle so a destroyed manager (and its WebGL context,
    // data store, and map) can be garbage collected after navigation.
    if (window.__gridMapManager === this.mapManager) {
      window.__gridMapManager = null;
    }
    this.mapManager = null;
  },
};

export default GridMapHook;
