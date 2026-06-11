import { PathLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";

// Dimmed ghost color for unaffected lines during cascade — dim, not gone:
// the network must stay visible as context around the failure.
const GHOST_COLOR = [90, 90, 110, 70];

// Legend voltage classes used for filtering (must match the legend entries)
const LEGEND_VOLTAGE_CLASSES = [69, 138, 230, 345, 500, 765];

function voltageClassKey(kv) {
  let closest = LEGEND_VOLTAGE_CLASSES[0];
  for (const c of LEGEND_VOLTAGE_CLASSES) {
    if (Math.abs(c - kv) < Math.abs(closest - kv)) closest = c;
  }
  return String(closest);
}

export function createTransmissionLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, hiddenVoltages) {
  let lines = dataStore.transmissionLines.lines;

  if (zoom < 6) {
    lines = lines.filter((l) => l.voltageKv >= 345);
  } else if (zoom < 8) {
    lines = lines.filter((l) => l.voltageKv >= 138);
  }

  // Legend toggles hide voltage classes — but never an active alarm
  // (cascade-affected lines stay visible regardless).
  if (hiddenVoltages && hiddenVoltages.size > 0) {
    lines = lines.filter(
      (l) => l.state > 0 || !hiddenVoltages.has(voltageClassKey(l.voltageKv))
    );
  }

  const layers = [];

  if (cascadeActive) {
    // Split into affected and unaffected for separate rendering
    const affected = lines.filter((d) => d.state > 0);
    const unaffected = lines.filter((d) => d.state === 0);

    // Ghost layer — unaffected lines rendered nearly invisible
    if (unaffected.length > 0) {
      layers.push(
        new PathLayer({
          id: "transmission-ghost",
          data: unaffected,
          pickable: true,
          widthScale: 1,
          widthMinPixels: 0.5,
          widthMaxPixels: 1.5,
          getPath: (d) => d.path,
          getColor: GHOST_COLOR,
          getWidth: 1,
          onClick,
        })
      );
    }

    // Affected layer — vivid state colors, boosted width
    if (affected.length > 0) {
      layers.push(
        new PathLayer({
          id: "transmission-affected",
          data: affected,
          pickable: true,
          widthScale: 1,
          widthMinPixels: 2,
          widthMaxPixels: 7,
          getPath: (d) => d.path,
          getColor: (d) => getCascadeLineColor(d),
          getWidth: (d) => getCascadeLineWidth(d, zoom),
          onClick,
          updateTriggers: {
            getColor: [Date.now()],
            getWidth: [zoom],
          },
          transitions: {
            getColor: 400,
          },
        })
      );

      // Glow halo behind affected lines
      layers.push(
        new PathLayer({
          id: "transmission-glow",
          data: affected.filter((d) => d.state === 2 || d.state === 3),
          pickable: false,
          widthScale: 1,
          widthMinPixels: 6,
          widthMaxPixels: 16,
          getPath: (d) => d.path,
          getColor: (d) => getGlowColor(d),
          getWidth: (d) => getCascadeLineWidth(d, zoom) * 3,
        })
      );
    }
  } else {
    // Normal rendering
    layers.push(
      new PathLayer({
        id: "transmission-lines",
        data: lines,
        pickable: true,
        widthScale: 1,
        widthMinPixels: zoom < 8 ? 1 : 1.5,
        widthMaxPixels: 4,
        getPath: (d) => d.path,
        getColor: (d) => getLineColor(d, viewMode),
        getWidth: (d) => getLineWidth(d, zoom),
        onClick,
        updateTriggers: {
          getColor: [viewMode, Date.now()],
        },
        transitions: {
          getColor: 600,
        },
      })
    );
  }

  if (selectedId != null) {
    const selected = lines.filter((d) => d.id === selectedId);
    if (selected.length > 0) {
      layers.push(
        new PathLayer({
          id: "transmission-selection-highlight",
          data: selected,
          pickable: false,
          widthScale: 1,
          widthMinPixels: 4,
          widthMaxPixels: 8,
          getPath: (d) => d.path,
          getColor: [255, 255, 255, 180],
          getWidth: (d) => getLineWidth(d, zoom) * 3,
        })
      );
    }
  }

  return layers;
}

function getCascadeLineColor(d) {
  const base = COLOR_SCALES.getStateColor(d.state);
  return [...base, 240];
}

function getCascadeLineWidth(d, zoom) {
  // Tripped and overloaded lines swell; rerouted slightly raised
  if (d.state === 3) return zoom < 6 ? 2 : 3; // tripped = prominent
  if (d.state === 2) return zoom < 6 ? 2 : 3.5; // overloaded = thick danger
  if (d.state === 4) return zoom < 6 ? 1.5 : 2.5; // rerouted
  return zoom < 6 ? 1 : 2;
}

function getGlowColor(d) {
  if (d.state === 3) return [255, 50, 30, 70]; // tripped = strong red glow
  if (d.state === 2) return [231, 76, 60, 40]; // overloaded = red glow
  return [255, 140, 0, 30]; // default warm glow
}

function getLineColor(d, viewMode) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 200];

  switch (viewMode) {
    case "voltage_level":
      return [...COLOR_SCALES.getVoltageColor(d.voltageKv), 180];
    case "loading":
      return [...COLOR_SCALES.getLoadingColor(d.loadingPct || 0), 180];
    case "failure_state":
      return [...COLOR_SCALES.getStateColor(d.state), 200];
    default:
      return [...COLOR_SCALES.getVoltageColor(d.voltageKv), 150];
  }
}

function getLineWidth(d, zoom) {
  const baseWidth = d.voltageKv >= 345 ? 3 : d.voltageKv >= 230 ? 2 : 1;
  return baseWidth * (zoom < 6 ? 0.5 : 1);
}
