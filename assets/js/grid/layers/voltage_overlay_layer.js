import { H3HexagonLayer } from "@deck.gl/geo-layers";
import { ScatterplotLayer } from "@deck.gl/layers";
import * as h3 from "h3-js";
import { COLOR_SCALES } from "../color_scales";

// Same bands as the demand hexbins so the two bus-point overlays bin
// identically at every zoom (see demand_density_layer.js, the source of
// truth). Coarser cells when zoomed out, finer as you zoom in.
function resolutionForZoom(zoom) {
  if (zoom < 4.5) return 3;
  if (zoom < 6) return 4;
  if (zoom < 7.5) return 5;
  return 6;
}

// The cascade's overlay band (0.9/1.1 pu) is the engine's; these are the
// DISPLAY stops, deliberately opened up to 0.95/1.05 so a cell that is only
// starting to sag is still visible before it crosses the engine's threshold.
// Neither is the protection layer's 0.85/1.15 alarm band — those are relay
// settings, a different question, and the two are not to be reconciled.
const UNDER_EDGE = 0.95; // amber starts here, going down
const UNDER_FLOOR = 0.85; // full red at or below
const OVER_EDGE = 1.05; // violet starts here, going up
const OVER_CEILING = 1.15; // full-depth violet at or above

const AMBER = [245, 166, 35];
const RED = [231, 76, 60];
const VIOLET = [155, 89, 182];

const ALPHA_EDGE = 90;
const ALPHA_DEEP = 210;

function lerpColor(a, b, t) {
  const x = Math.max(0, Math.min(1, t));
  return [
    Math.round(a[0] + (b[0] - a[0]) * x),
    Math.round(a[1] + (b[1] - a[1]) * x),
    Math.round(a[2] + (b[2] - a[2]) * x),
  ];
}

function clamp01(t) {
  return Math.max(0, Math.min(1, t));
}

function alphaForDepth(t) {
  return Math.round(ALPHA_EDGE + (ALPHA_DEEP - ALPHA_EDGE) * clamp01(t));
}

/**
 * The fill for one cell, or null when it is inside the display band in both
 * directions and should not be drawn at all.
 *
 * The band edges are INCLUSIVE, so a cell sitting exactly on one is painted in
 * the stop color the legend names for it rather than being the one value that
 * never appears.
 *
 * A cell holding both a sagging bus and a rising one is painted for whichever
 * deviation is deeper, ties going to the undervoltage: a collapsing pocket is
 * the more urgent read, and Ferranti rise on a lightly-loaded EHV line is
 * routine by comparison. Depth is normalized per direction, so "deeper" means
 * further through its own band, not further in raw pu.
 */
export function voltageCellColor(cell) {
  const sagging = cell.min <= UNDER_EDGE;
  const rising = cell.max >= OVER_EDGE;
  if (!sagging && !rising) return null;

  // -1 for a direction this cell is not in, so it can never win the compare.
  const under = sagging ? clamp01((UNDER_EDGE - cell.min) / (UNDER_EDGE - UNDER_FLOOR)) : -1;
  const over = rising ? clamp01((cell.max - OVER_EDGE) / (OVER_CEILING - OVER_EDGE)) : -1;

  if (under >= over) {
    return [...lerpColor(AMBER, RED, under), alphaForDepth(under)];
  }
  return [...VIOLET, alphaForDepth(over)];
}

// Cells inside the display band in both directions are dropped rather than
// drawn transparent. Keyed on the DataStore's memoized array, whose identity
// changes exactly when the voltage set does — so panning at one zoom keeps
// handing deck.gl the same `data` and re-uploads nothing.
const _drawableCache = new WeakMap();

function drawableCells(cells) {
  const cached = _drawableCache.get(cells);
  if (cached) return cached;
  const drawable = cells.filter((c) => voltageCellColor(c) !== null);
  _drawableCache.set(cells, drawable);
  return drawable;
}

/**
 * Voltage-depth hexbins plus shed-bus marks, from the bus-level channels the
 * cascade emits (`bus_voltage` per step, `ac_overlay` once per cascade).
 *
 * Both are joined to positions through bus_loads.bin, so a bus outside that
 * export — or any bus at all under a pre-bus-id export — silently contributes
 * nothing. There is no toggle: the presence of voltage data IS the condition,
 * because these only exist while a cascade's AC coverage has something to say.
 */
export function createVoltageOverlayLayer(dataStore, zoom, stateVersion) {
  const layers = [];
  const res = resolutionForZoom(zoom);
  const cells = drawableCells(dataStore.getVoltageHexagons(res, h3));

  if (cells.length > 0) {
    layers.push(
      new H3HexagonLayer({
        id: "voltage-overlay",
        data: cells,
        pickable: true,
        filled: true,
        stroked: false,
        extruded: false,
        highPrecision: "auto",
        getHexagon: (d) => d.hex,
        getFillColor: voltageCellColor,
        opacity: 0.6,
        updateTriggers: {
          getFillColor: [res, stateVersion],
        },
      })
    );
  }

  // Buses that lost load. STATE_SHED (5) is in the legend and in
  // COLOR_SCALES; until now nothing ever painted it.
  const shedMarks = dataStore.getShedBusMarks();
  if (shedMarks.length > 0) {
    layers.push(
      new ScatterplotLayer({
        id: "voltage-overlay-shed",
        data: shedMarks,
        pickable: false,
        filled: true,
        stroked: true,
        radiusUnits: "pixels",
        getRadius: 4,
        getPosition: (d) => d.position,
        getFillColor: [...COLOR_SCALES.getStateColor(5), 210],
        getLineColor: [255, 255, 255, 140],
        lineWidthUnits: "pixels",
        getLineWidth: 1,
        updateTriggers: {
          getFillColor: [stateVersion],
        },
      })
    );
  }

  return layers;
}
