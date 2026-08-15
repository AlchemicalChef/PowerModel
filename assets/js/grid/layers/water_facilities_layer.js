import { IconLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas, waterIconName } from "../icon_atlas";

const WATER_COLORS = {
  1: [0, 191, 255],     // desalination - bright blue
  2: [139, 90, 43],     // wastewater - brown
  3: [0, 200, 150],     // treatment - teal
  4: [147, 51, 234],    // pump_station - purple
  5: [0, 100, 180],     // reservoir - deep blue
  6: [100, 160, 200],   // pipeline - steel blue
  0: [120, 120, 140],   // unknown
};

const GHOST_COLOR = [110, 110, 130, 80];

// Facility type code -> legend key (must match the legend entries)
const WATER_LEGEND_KEY = {
  1: "desalination", 2: "wastewater", 3: "treatment",
  4: "pump_station", 5: "reservoir", 6: "pipeline",
};

// TextLayer over ~95k facilities froze the GPU: labels render only for
// facilities inside the current viewport, hard-capped.
const LABEL_CAP = 250;

export function cullLabels(data, bounds, cap) {
  if (!bounds) return data.slice(0, cap);
  const out = [];
  for (const d of data) {
    const lon = d.position[0];
    const lat = d.position[1];
    if (
      lon >= bounds.west &&
      lon <= bounds.east &&
      lat >= bounds.south &&
      lat <= bounds.north
    ) {
      out.push(d);
      if (out.length >= cap) break;
    }
  }
  return out;
}

export function createWaterFacilitiesLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, opts = {}) {
  let data = dataStore.getWaterFacilityData();
  if (opts.affectedOnly) {
    data = data.filter((d) => d.state > 0);
  }
  if (opts.hiddenTypes && opts.hiddenTypes.size > 0) {
    data = data.filter(
      (d) => d.state > 0 || !opts.hiddenTypes.has(WATER_LEGEND_KEY[d.facilityType])
    );
  }
  if (!data || data.length === 0) return [];

  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "water-facilities",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: (d) => waterIconName(d.facilityType),
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? getWaterSize(d) * 0.6
        : getWaterSize(d),
      sizeMinPixels: cascadeActive ? 6 : 12,
      sizeMaxPixels: cascadeActive ? 28 : 40,
      getColor: (d) => cascadeActive
        ? getCascadeWaterColor(d)
        : getWaterColor(d),
      onClick,
      updateTriggers: {
        getColor: [viewMode, opts.stateVersion, cascadeActive],
        // getSize reads d.state (ghost shrink): stateVersion must retrigger
        // it — with all filters off, the data array identity is stable.
        getSize: [cascadeActive, opts.stateVersion],
      },
      transitions: {
        getColor: 500,
        getSize: 400,
      },
    }),
  ];

  // Labels — only for affected facilities during cascade, or at high zoom
  // normally; always culled to the current viewport and capped (a national
  // dataset or national blackout would otherwise label ~95k points).
  const labelCandidates = cascadeActive
    ? data.filter((d) => d.state > 0)
    : (zoom >= 10 ? data : []);
  const labelData =
    labelCandidates.length > 0
      ? cullLabels(labelCandidates, opts.bounds, LABEL_CAP)
      : labelCandidates;

  if (labelData.length > 0) {
    layers.push(
      new TextLayer({
        id: "water-facilities-labels",
        data: labelData,
        pickable: false,
        getPosition: (d) => d.position,
        getText: (d) => cascadeActive && d.state > 0
          ? `${d.name} [NO POWER]`
          : d.name,
        getSize: cascadeActive && labelData[0]?.state > 0 ? 12 : 11,
        getColor: (d) => cascadeActive && d.state > 0
          ? [255, 80, 60, 240]
          : [220, 220, 230, 200],
        getAngle: 0,
        getTextAnchor: "start",
        getAlignmentBaseline: "center",
        getPixelOffset: [16, 0],
        fontFamily: "-apple-system, BlinkMacSystemFont, Inter, sans-serif",
        fontWeight: cascadeActive ? 700 : 500,
        outlineWidth: cascadeActive ? 3 : 2,
        outlineColor: cascadeActive ? [20, 0, 0, 220] : [10, 10, 20, 200],
        updateTriggers: {
          getText: [zoom, cascadeActive],
          getColor: [cascadeActive],
        },
      })
    );
  }

  // Danger pulse ring on affected water facilities
  if (cascadeActive) {
    const affected = data.filter((d) => d.state > 0);
    if (affected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "water-facilities-danger-pulse",
          data: affected,
          pickable: false,
          opacity: 0.5,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusMinPixels: 14,
          radiusMaxPixels: 40,
          getPosition: (d) => d.position,
          getRadius: 600,
          getLineColor: (d) => d.state === 3
            ? [255, 50, 30, 140]
            : [...COLOR_SCALES.getStateColor(d.state), 120],
          updateTriggers: {
            getLineColor: [opts.stateVersion],
          },
        })
      );
    }
  }

  // Selection ring
  if (selectedId != null) {
    const selected = data.filter((d) => d.id === selectedId);
    if (selected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "water-facilities-selection-ring",
          data: selected,
          pickable: false,
          opacity: 1,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusMinPixels: 10,
          radiusMaxPixels: 32,
          getPosition: (d) => d.position,
          getRadius: 500,
          getLineColor: [255, 255, 255, 220],
        })
      );
    }
  }

  return layers;
}

function getCascadeWaterColor(d) {
  if (d.state === 0) return GHOST_COLOR;
  if (d.state === 3) return [255, 50, 30, 250]; // power loss = bright red, not dark
  const base = COLOR_SCALES.getStateColor(d.state);
  return [
    Math.min(255, base[0] + 30),
    Math.min(255, base[1] + 30),
    Math.min(255, base[2] + 30),
    250,
  ];
}

function getWaterColor(d) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];
  return [...(WATER_COLORS[d.facilityType] || WATER_COLORS[0]), 230];
}

function getWaterSize(d) {
  if (d.facilityType === 5) {
    return Math.sqrt(d.storageAcreFeet || 1000) * 0.5 + 14;
  }
  const cap = d.capacityMgd || 1;
  return Math.sqrt(cap) * 4 + 14;
}
