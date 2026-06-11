import { IconLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas, datacenterIconName } from "../icon_atlas";

const DC_COLORS = {
  1: [80, 200, 255],    // hyperscale - cyan
  2: [180, 140, 255],   // colocation - violet
  3: [255, 120, 200],   // ai_training - magenta
  4: [160, 180, 200],   // enterprise - slate
  5: [255, 190, 80],    // crypto - amber
  0: [120, 120, 140],   // unknown
};

const GHOST_COLOR = [110, 110, 130, 80];

// Facility type code -> legend key (must match the legend entries)
const DC_LEGEND_KEY = {
  1: "hyperscale", 2: "colocation", 3: "ai_training", 4: "enterprise", 5: "crypto",
};

export function createDatacentersLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, opts = {}) {
  let data = dataStore.getDatacenterData();
  if (opts.affectedOnly) {
    data = data.filter((d) => d.state > 0);
  }
  if (opts.hiddenTypes && opts.hiddenTypes.size > 0) {
    data = data.filter(
      (d) => d.state > 0 || !opts.hiddenTypes.has(DC_LEGEND_KEY[d.facilityType])
    );
  }
  if (!data || data.length === 0) return [];

  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "datacenters",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: () => datacenterIconName(),
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? getDatacenterSize(d) * 0.6
        : getDatacenterSize(d),
      sizeMinPixels: cascadeActive ? 6 : 12,
      sizeMaxPixels: cascadeActive ? 28 : 40,
      getColor: (d) => cascadeActive
        ? getCascadeDatacenterColor(d)
        : getDatacenterColor(d),
      onClick,
      updateTriggers: {
        getColor: [viewMode, opts.stateVersion, cascadeActive],
        getSize: [cascadeActive],
      },
      transitions: {
        getColor: 500,
        getSize: 400,
      },
    }),
  ];

  // Labels — affected facilities during cascade, or all at high zoom normally
  const labelData = cascadeActive
    ? data.filter((d) => d.state > 0)
    : (zoom >= 9 ? data : []);

  if (labelData.length > 0) {
    layers.push(
      new TextLayer({
        id: "datacenters-labels",
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

  // Danger pulse ring on affected datacenters
  if (cascadeActive) {
    const affected = data.filter((d) => d.state > 0);
    if (affected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "datacenters-danger-pulse",
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
          id: "datacenters-selection-ring",
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

function getCascadeDatacenterColor(d) {
  if (d.state === 0) return GHOST_COLOR;
  if (d.state === 3) return [255, 50, 30, 250]; // power loss = bright red
  const base = COLOR_SCALES.getStateColor(d.state);
  return [
    Math.min(255, base[0] + 30),
    Math.min(255, base[1] + 30),
    Math.min(255, base[2] + 30),
    250,
  ];
}

function getDatacenterColor(d) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];
  return [...(DC_COLORS[d.facilityType] || DC_COLORS[0]), 230];
}

function getDatacenterSize(d) {
  // Sized by grid draw: 100 MW ≈ 22px, 900 MW ≈ 38px
  return Math.sqrt(d.powerMw || 10) * 0.8 + 14;
}
