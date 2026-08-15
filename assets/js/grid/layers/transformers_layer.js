import { IconLayer, ScatterplotLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";
import { getIconAtlas, transformerIconName } from "../icon_atlas";

const NORMAL_COLOR = [186, 154, 90];   // brass — distinct from substations
const GHOST_COLOR = [110, 110, 130, 80];

export function createTransformersLayer(dataStore, viewMode, zoom, onClick, selectedId, cascadeActive, hidden, stateVersion) {
  let data = dataStore.getTransformerData();

  // Visible at closer zooms (like substations) — but affected units render
  // at every zoom and override the legend toggle (active alarms never hide).
  if (hidden || (zoom < 7 && !cascadeActive)) {
    data = data.filter((d) => d.state > 0);
  }
  if (!data || data.length === 0) return [];

  const { atlas, mapping } = getIconAtlas();

  const layers = [
    new IconLayer({
      id: "transformers",
      data,
      pickable: true,
      iconAtlas: atlas,
      iconMapping: mapping,
      getIcon: () => transformerIconName(),
      getPosition: (d) => d.position,
      getSize: (d) => cascadeActive && d.state === 0
        ? getTransformerSize(d) * 0.6
        : getTransformerSize(d),
      sizeMinPixels: cascadeActive ? 5 : 8,
      sizeMaxPixels: cascadeActive ? 22 : 26,
      getColor: (d) => cascadeActive
        ? getCascadeTransformerColor(d)
        : getTransformerColor(d),
      onClick,
      updateTriggers: {
        getColor: [viewMode, stateVersion, cascadeActive],
        // getSize reads d.state (ghost shrink): stateVersion must retrigger
        // it — the memoized data array's identity never changes.
        getSize: [cascadeActive, stateVersion],
      },
      transitions: {
        getColor: 400,
        getSize: 300,
      },
    }),
  ];

  // Danger pulse on affected transformers during cascade
  if (cascadeActive) {
    const affected = data.filter((d) => d.state > 0);
    if (affected.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "transformers-danger-pulse",
          data: affected,
          pickable: false,
          opacity: 0.5,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusMinPixels: 12,
          radiusMaxPixels: 32,
          getPosition: (d) => d.position,
          getRadius: 500,
          getLineColor: (d) => d.state === 3
            ? [255, 50, 30, 140]
            : [...COLOR_SCALES.getStateColor(d.state), 120],
          updateTriggers: {
            getLineColor: [stateVersion],
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
          id: "transformers-selection-ring",
          data: selected,
          pickable: false,
          opacity: 1,
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2,
          lineWidthMaxPixels: 3,
          radiusMinPixels: 9,
          radiusMaxPixels: 26,
          getPosition: (d) => d.position,
          getRadius: 400,
          getLineColor: [255, 255, 255, 220],
        })
      );
    }
  }

  return layers;
}

function getCascadeTransformerColor(d) {
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

function getTransformerColor(d) {
  if (d.state > 0) return [...COLOR_SCALES.getStateColor(d.state), 220];
  return [...NORMAL_COLOR, 210];
}

function getTransformerSize(d) {
  // Sized modestly by rating: 100 MVA ≈ 12px, 1000 MVA ≈ 21px
  return Math.sqrt(d.ratedMva || 50) * 0.55 + 6;
}
