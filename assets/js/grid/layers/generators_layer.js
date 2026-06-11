import { IconLayer, ScatterplotLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas, generatorIconName } from "../icon_atlas";

// Dim but still visible: the grid must remain legible context during a cascade
const GHOST_COLOR = [110, 110, 130, 80];

// Fuel code -> legend key (must match the legend entries)
const FUEL_LEGEND_KEY = {
  1: "gas", 2: "coal", 3: "coal", 4: "nuclear", 5: "hydro",
  6: "wind", 7: "solar", 11: "geothermal", 12: "import",
};

function fuelKey(code) {
  return FUEL_LEGEND_KEY[code] || "other";
}

export function createGeneratorsLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, hiddenFuels, stateVersion) {
  let data = dataStore.getGeneratorData();

  // Legend toggles hide fuel types — cascade-affected units stay visible.
  if (hiddenFuels && hiddenFuels.size > 0) {
    data = data.filter((d) => d.state > 0 || !hiddenFuels.has(fuelKey(d.fuelType)));
  }

  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "generators",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: (d) => generatorIconName(d.fuelType),
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? Math.max(8, Math.sqrt(d.capacity) * 0.6 + 4)
        : Math.max(14, Math.sqrt(d.capacity) * 1.2 + 8),
      sizeScale: zoom < 6 ? 0.8 : 1,
      sizeMinPixels: cascadeActive ? 4 : (zoom < 6 ? 8 : 10),
      sizeMaxPixels: cascadeActive ? 24 : 36,
      getColor: (d) => cascadeActive
        ? getCascadeGenColor(d)
        : getGeneratorColor(d, viewMode),
      onClick,
      updateTriggers: {
        getColor: [viewMode, stateVersion, cascadeActive],
        getSize: [cascadeActive, zoom],
        getIcon: [viewMode],
      },
      transitions: {
        getColor: 500,
        getSize: 400,
      },
    }),
  ];

  // Glow rings on affected generators during cascade — tripped units
  // especially: the injected failure must be unmissable.
  if (cascadeActive) {
    const affected = data.filter((d) => d.state > 0);
    if (affected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "generators-cascade-glow",
          data: affected,
          pickable: false,
          opacity: 0.35,
          stroked: false,
          filled: true,
          radiusMinPixels: 8,
          radiusMaxPixels: 30,
          getPosition: (d) => d.position,
          getRadius: (d) => Math.sqrt(d.capacity) * 80 + 400,
          getFillColor: (d) => [...COLOR_SCALES.getStateColor(d.state), 50],
          updateTriggers: {
            getFillColor: [stateVersion],
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
          id: "generators-selection-ring",
          data: selected,
          pickable: false,
          opacity: 1,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusScale: zoom < 6 ? 3 : 1,
          radiusMinPixels: zoom < 6 ? 6 : 5,
          radiusMaxPixels: 28,
          getPosition: (d) => d.position,
          getRadius: (d) => Math.sqrt(d.capacity) * 50 + 200,
          getLineColor: [255, 255, 255, 220],
        })
      );
    }
  }

  return layers;
}

function getCascadeGenColor(d) {
  if (d.state === 0) return GHOST_COLOR;
  const base = COLOR_SCALES.getStateColor(d.state);
  // Boost brightness for affected generators
  return [
    Math.min(255, base[0] + 30),
    Math.min(255, base[1] + 30),
    Math.min(255, base[2] + 30),
    250,
  ];
}

function getGeneratorColor(d, viewMode) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];

  switch (viewMode) {
    case "fuel_type":
      return [...COLOR_SCALES.getFuelColor(d.fuelType), 220];
    case "failure_state":
      return [...COLOR_SCALES.getStateColor(d.state), 220];
    case "loading":
    case "voltage_level":
    default:
      return [...COLOR_SCALES.getFuelColor(d.fuelType), 200];
  }
}
