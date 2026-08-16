import { PathLayer } from "@deck.gl/layers";
import { COLOR_SCALES, VOLTAGE_COLORS } from "../color_scales";

// Dimmed ghost color for unaffected lines during cascade — dim, not gone:
// the network must stay visible as context around the failure.
const GHOST_RGB = [90, 90, 110];
const GHOST_COLOR = [...GHOST_RGB, 70];

// Review weight for the REROUTED class (state 4).
//
// Rerouted is not damage. It is "flow moved here", and on a real system flow
// moves a very long way: a single Palo Verde unit tripping — engine verdict
// settled/intact, 0 MW shed, 59.80 Hz nadir — repainted 995 of 22,152
// branches as rerouted across the whole West. At full impact weight that
// reads as a catastrophe when what happened was a ride-through. So once the
// run SETTLES, rerouted drops to a tint: still legible as the rerouted
// colour, but clearly subordinate to the classes that mean damage.
//
// Three-step ladder, which is the property to preserve if these numbers are
// ever retuned: ghost (unaffected context) < tint (flow moved) < full
// (stressed / overloaded / tripped).
//
// It stays at FULL weight during the live cascade — watching redistribution
// spread is the whole point of the streaming view.
const REVIEW_TINT_MIX = 0.55;
const REVIEW_TINT_ALPHA = 120;

// Derived from STATE_COLORS rather than hardcoded, so retuning the rerouted
// colour carries the legend swatch and this tint along with it.
function reroutedTintColor() {
  const base = COLOR_SCALES.getStateColor(4);
  return [
    ...base.map((c, i) =>
      Math.round(c + (GHOST_RGB[i] - c) * REVIEW_TINT_MIX)
    ),
    REVIEW_TINT_ALPHA,
  ];
}

// Legend voltage classes used for filtering — derived from VOLTAGE_COLORS so
// the classes the legend paints and the classes the toggle filters can never
// drift apart (115 and 161 kV were missing from a hand-written copy).
const LEGEND_VOLTAGE_CLASSES = Object.keys(VOLTAGE_COLORS)
  .map(Number)
  .sort((a, b) => a - b);

function voltageClassKey(kv) {
  let closest = LEGEND_VOLTAGE_CLASSES[0];
  for (const c of LEGEND_VOLTAGE_CLASSES) {
    if (Math.abs(c - kv) < Math.abs(closest - kv)) closest = c;
  }
  return String(closest);
}

// Memoized zoom/legend filter result. Filtering ~90k paths on every pan
// produced a fresh array each call, defeating deck.gl's data memoization and
// forcing a full GPU re-upload; identical inputs now return the same array.
let _filterCache = { src: null, key: null, out: null };

function filteredLines(dataStore, zoom, hiddenVoltages, stateVersion) {
  const src = dataStore.transmissionLines.lines;
  const band = zoom < 6 ? "z0" : zoom < 8 ? "z1" : "z2";
  const hiddenKey =
    hiddenVoltages && hiddenVoltages.size > 0
      ? [...hiddenVoltages].sort().join(",")
      : "";
  const key = `${band}|${stateVersion}|${hiddenKey}`;
  if (_filterCache.src === src && _filterCache.key === key) {
    return _filterCache.out;
  }

  let lines = src;

  // Zoom decluttering must never hide an active alarm: affected lines
  // (tripped/overloaded/rerouted) render at every zoom level.
  if (zoom < 6) {
    lines = lines.filter((l) => l.state > 0 || l.voltageKv >= 345);
  } else if (zoom < 8) {
    lines = lines.filter((l) => l.state > 0 || l.voltageKv >= 138);
  }

  // Legend toggles hide voltage classes — but never an active alarm
  // (cascade-affected lines stay visible regardless).
  if (hiddenVoltages && hiddenVoltages.size > 0) {
    lines = lines.filter(
      (l) => l.state > 0 || !hiddenVoltages.has(voltageClassKey(l.voltageKv))
    );
  }

  _filterCache = { src, key, out: lines };
  return lines;
}

// `impactView` is the impact picture being on at all (live cascade OR settled
// review); `review` is specifically the settled half of it, and is what
// demotes the rerouted class.
export function createTransmissionLayer(dataStore, viewMode, zoom, onClick, selectedId, impactView, hiddenVoltages, stateVersion, review = false) {
  const lines = filteredLines(dataStore, zoom, hiddenVoltages, stateVersion);

  const layers = [];

  if (impactView) {
    // Split into affected and unaffected for separate rendering. Rerouted is
    // pulled out into its own layer in BOTH states rather than only in
    // review: a line that moved between layers at the settle boundary would
    // leave one and appear in the other, and deck.gl can only interpolate an
    // attribute for data that stays put. Keeping it in one layer is what lets
    // the demotion animate rather than snap.
    const rerouted = lines.filter((d) => d.state === 4);
    const affected = lines.filter((d) => d.state > 0 && d.state !== 4);
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

    // Rerouted — full weight while live, tint once settled. Pushed BEFORE the
    // affected layer so damage always draws over flow redistribution.
    if (rerouted.length > 0) {
      layers.push(
        new PathLayer({
          id: "transmission-rerouted",
          data: rerouted,
          pickable: true,
          widthScale: 1,
          // A clamp, not an accessor, so it steps rather than eases. At these
          // zooms the metre-denominated getWidth is sub-pixel and the clamp is
          // what sets the drawn width, so the width change is a step and the
          // colour is what carries the 600 ms fade.
          widthMinPixels: review ? 1 : 2,
          widthMaxPixels: review ? 2.5 : 7,
          getPath: (d) => d.path,
          getColor: review ? reroutedTintColor() : (d) => getCascadeLineColor(d),
          getWidth: (d) => getCascadeLineWidth(d, zoom),
          onClick,
          updateTriggers: {
            getColor: [stateVersion, review],
            getWidth: [zoom],
          },
          transitions: {
            // Same 600 ms as the vignette's settle transition, so the whole
            // "the event is over, here is what mattered" beat reads as one
            // movement.
            getColor: 600,
          },
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
            getColor: [stateVersion],
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
          getColor: [viewMode, stateVersion],
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
