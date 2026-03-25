import { MapManager } from "../grid/map_manager";

const GridMapHook = {
  mounted() {
    this.mapManager = new MapManager(this.el);

    this.mapManager.loadInitialData();

    this.handleEvent("dc_results", (data) => {
      this.mapManager.applyDCResults(data);
    });

    this.handleEvent("ac_results", (data) => {
      this.mapManager.applyACResults(data);
    });

    this.handleEvent("cascade_step", (data) => {
      this.mapManager.applyCascadeStep(data);
    });

    this.handleEvent("reset_grid", () => {
      this.mapManager.resetToBaseline();
    });

    this.handleEvent("view_mode_changed", (data) => {
      this.mapManager.setViewMode(data.mode);
    });

    this.handleEvent("show_cascade_step", (data) => {
      this.mapManager.showCascadeStep(data.step);
    });

    this.handleEvent("update_lod", (data) => {
      this.mapManager.updateLOD(data.zoom, data.bounds);
    });

    this.handleEvent("deselect_highlight", () => {
      this.mapManager.setSelectedComponent(null, null);
    });

    this.handleEvent("highlight_component", (data) => {
      this.mapManager.setSelectedComponent(data.type, data.id);
    });

    this.handleEvent("fly_to_component", (data) => {
      this.mapManager.flyToComponent(data.type, data.id);
    });

    this.handleEvent("lookup_error", (data) => {
      const input = document.querySelector(".lookup-input");
      if (!input) return;
      input.classList.add("lookup-error");
      input.placeholder = data.msg;
      input.value = "";
      setTimeout(() => {
        input.classList.remove("lookup-error");
        input.placeholder = "ID #";
      }, 2000);
    });

    this.mapManager.onCascadeActiveChange = (active) => {
      const gridContainer = this.el.closest(".grid-container") || this.el.parentElement;
      if (gridContainer) {
        gridContainer.classList.toggle("cascade-active", active);
      }
    };

    window.__toggleLayer = (el) => {
      const layer = el.dataset.layer;
      if (!layer) return;
      el.classList.toggle("active");
      this.mapManager.toggleLayer(layer);
    };

    this.mapManager.onComponentClick = (type, id, details) => {
      this.mapManager.setSelectedComponent(type, id);
      this.pushEvent("select_component", { type, id: String(id), ...details });
    };

    this.mapManager.onViewportChange = (zoom, bounds) => {
      this.pushEvent("viewport_changed", { zoom, bounds });
    };
  },

  destroyed() {
    window.__toggleLayer = null;
    if (this.mapManager) {
      this.mapManager.destroy();
    }
  },
};

export default GridMapHook;
