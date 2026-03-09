import { IconLayer, ScatterplotLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas } from "../icon_atlas";

const GHOST_COLOR = [40, 40, 50, 16];

export function createSubstationsLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive) {
  const data = dataStore.getSubstationData();
  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "substations",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: () => "substation",
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? 6
        : Math.max(10, d.voltage * 0.04 + 8),
      sizeMinPixels: cascadeActive ? 3 : 8,
      sizeMaxPixels: cascadeActive ? 12 : 20,
      getColor: (d) => cascadeActive
        ? getCascadeSubColor(d)
        : getSubstationColor(d, viewMode),
      onClick,
      updateTriggers: {
        getColor: [viewMode, dataStore.substations.states, cascadeActive],
        getSize: [cascadeActive],
      },
      transitions: {
        getColor: 500,
        getSize: 400,
      },
    }),
  ];

  if (selectedId != null) {
    const selected = data.filter((d) => d.id === selectedId);
    if (selected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "substations-selection-ring",
          data: selected,
          pickable: false,
          opacity: 1,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusMinPixels: 5,
          radiusMaxPixels: 16,
          getPosition: (d) => d.position,
          getRadius: (d) => Math.max(200, d.voltage * 3) + 200,
          getLineColor: [255, 255, 255, 220],
        })
      );
    }
  }

  return layers;
}

function getCascadeSubColor(d) {
  if (d.state === 0) return GHOST_COLOR;
  const base = COLOR_SCALES.getStateColor(d.state);
  return [
    Math.min(255, base[0] + 30),
    Math.min(255, base[1] + 30),
    Math.min(255, base[2] + 30),
    240,
  ];
}

function getSubstationColor(d, viewMode) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];

  switch (viewMode) {
    case "voltage_level":
      return [...COLOR_SCALES.getVoltageColor(d.voltage), 200];
    case "failure_state":
      return [...COLOR_SCALES.getStateColor(d.state), 200];
    default:
      return [140, 140, 160, 180];
  }
}
