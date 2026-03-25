import { IconLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas, criticalFacilityIconName } from "../icon_atlas";

const CI_COLORS = {
  1: [220, 50, 50],    // hospital - red
  2: [255, 140, 0],    // fire - orange
  3: [50, 100, 220],   // police - blue
  4: [50, 200, 50],    // ems - green
  0: [120, 120, 140],  // unknown
};

const GHOST_COLOR = [40, 40, 50, 20];

const CATEGORY_LABELS = {
  1: "Hospital",
  2: "Fire Station",
  3: "Police",
  4: "EMS",
};

export function createCriticalFacilitiesLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, visibleCategories) {
  const allData = dataStore.getCriticalFacilityData();
  if (!allData || allData.length === 0) return [];

  const data = visibleCategories
    ? allData.filter((d) => visibleCategories[d.category])
    : allData;
  if (data.length === 0) return [];

  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "critical-facilities",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: (d) => criticalFacilityIconName(d.category),
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? getCISize(d) * 0.6
        : getCISize(d),
      sizeMinPixels: cascadeActive ? 6 : 10,
      sizeMaxPixels: cascadeActive ? 28 : 36,
      getColor: (d) => cascadeActive
        ? getCascadeCIColor(d)
        : getCIColor(d),
      onClick,
      updateTriggers: {
        getColor: [viewMode, Date.now(), cascadeActive],
        getSize: [cascadeActive],
      },
      transitions: {
        getColor: 500,
        getSize: 400,
      },
    }),
  ];

  const labelData = cascadeActive
    ? data.filter((d) => d.state > 0)
    : (zoom >= 10 ? data : []);

  if (labelData.length > 0) {
    layers.push(
      new TextLayer({
        id: "critical-facilities-labels",
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

  if (cascadeActive) {
    const affected = data.filter((d) => d.state > 0);
    if (affected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "critical-facilities-danger-pulse",
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
            getLineColor: [Date.now()],
          },
        })
      );
    }
  }

  if (selectedId != null) {
    const selected = data.filter((d) => d.id === selectedId);
    if (selected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "critical-facilities-selection-ring",
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

function getCascadeCIColor(d) {
  if (d.state === 0) return GHOST_COLOR;
  if (d.state === 3) return [255, 50, 30, 250];
  const base = COLOR_SCALES.getStateColor(d.state);
  return [
    Math.min(255, base[0] + 30),
    Math.min(255, base[1] + 30),
    Math.min(255, base[2] + 30),
    250,
  ];
}

function getCIColor(d) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];
  return [...(CI_COLORS[d.category] || CI_COLORS[0]), 230];
}

function getCISize(d) {
  // Hospitals sized by bed count, others fixed
  if (d.category === 1 && d.beds) {
    return Math.sqrt(d.beds) * 0.8 + 14;
  }
  return 16;
}
