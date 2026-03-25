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

const GHOST_COLOR = [40, 40, 50, 20];

export function createWaterFacilitiesLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, visibleTypes) {
  const allData = dataStore.getWaterFacilityData();
  if (!allData || allData.length === 0) return [];

  const data = visibleTypes
    ? allData.filter((d) => visibleTypes[d.facilityType])
    : allData;
  if (data.length === 0) return [];

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
  if (d.state === 3) return [255, 50, 30, 250];
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
