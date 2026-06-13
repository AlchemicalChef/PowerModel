import { H3HexagonLayer } from "@deck.gl/geo-layers";
import * as h3 from "h3-js";

// Coarser cells when zoomed out (fewer, larger hexagons on screen), finer as
// you zoom in. Aggregation is memoized per resolution in the DataStore.
function resolutionForZoom(zoom) {
  if (zoom < 4.5) return 3;
  if (zoom < 6) return 4;
  if (zoom < 7.5) return 5;
  return 6;
}

// Magma-ish stops (dark purple -> magenta -> orange -> pale yellow). Low
// demand fades into the dark basemap; metros glow hot. Distinct from the
// green/red used for line loading and failures.
const RAMP = [
  [12, 8, 38],
  [90, 20, 110],
  [182, 54, 121],
  [240, 110, 70],
  [252, 200, 120],
];

function rampColor(t) {
  const x = Math.max(0, Math.min(1, t)) * (RAMP.length - 1);
  const i = Math.floor(x);
  const f = x - i;
  if (i >= RAMP.length - 1) return RAMP[RAMP.length - 1];
  const a = RAMP[i];
  const b = RAMP[i + 1];
  return [
    Math.round(a[0] + (b[0] - a[0]) * f),
    Math.round(a[1] + (b[1] - a[1]) * f),
    Math.round(a[2] + (b[2] - a[2]) * f),
  ];
}

export function createDemandDensityLayer(dataStore, zoom, hidden, stateVersion) {
  if (hidden) return [];

  const res = resolutionForZoom(zoom);
  const data = dataStore.getDemandHexagons(res, h3);
  if (!data || data.length === 0) return [];

  // Log scale: demand per cell spans ~1 MW (rural) to tens of GW (metros).
  let lo = Infinity;
  let hi = -Infinity;
  for (const d of data) {
    const v = Math.log10(d.mw + 1);
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  const span = hi - lo || 1;

  return [
    new H3HexagonLayer({
      id: "demand-density",
      data,
      pickable: true,
      filled: true,
      stroked: false,
      extruded: false,
      highPrecision: "auto",
      getHexagon: (d) => d.hex,
      getFillColor: (d) => {
        const t = (Math.log10(d.mw + 1) - lo) / span;
        return [...rampColor(t), 165];
      },
      opacity: 0.55,
      updateTriggers: {
        getFillColor: [res, stateVersion],
      },
    }),
  ];
}
