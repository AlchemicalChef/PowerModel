import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildGeneratorsBuffer,
  buildSubstationsBuffer,
  buildTransformersBuffer,
  stubDocument,
} from "./helpers.mjs";

// The icon atlas draws onto a canvas at first layer construction.
stubDocument();

const { DataStore } = await import("../grid/data_store.js");
const { createGeneratorsLayer } = await import("../grid/layers/generators_layer.js");
const { createSubstationsLayer } = await import("../grid/layers/substations_layer.js");
const { createTransformersLayer } = await import("../grid/layers/transformers_layer.js");
const { createWaterFacilitiesLayer, cullLabels } = await import(
  "../grid/layers/water_facilities_layer.js"
);
const { createDatacentersLayer } = await import("../grid/layers/datacenters_layer.js");

const noop = () => {};

function store() {
  const ds = new DataStore();
  ds.loadGenerators(buildGeneratorsBuffer([{ id: 10, capacity: 500 }, { id: 11, capacity: 50 }]));
  ds.loadSubstations(buildSubstationsBuffer([{ id: 20 }, { id: 21 }]));
  ds.loadTransformers(buildTransformersBuffer([{ id: 30 }, { id: 31 }]));
  return ds;
}

function waterStore(facilities) {
  const ds = new DataStore();
  ds.loadWaterFacilities({ facilities });
  return ds;
}

// UI-H4 regression (verifier finding): with memoized data arrays, deck.gl
// re-evaluates accessors only when an updateTrigger changes. getSize reads
// d.state (tripped/ghost units shrink), so stateVersion MUST appear in the
// getSize triggers of every state-dependent layer — under the rejected
// version the triggers were only [cascadeActive(, zoom)] and a unit tripped
// at step N > 1 kept its ghost size.

test("generators layer getSize updateTriggers change with stateVersion", () => {
  const ds = store();
  const l1 = createGeneratorsLayer(ds, "fuel_type", 7, noop, null, true, new Set(), 1)[0];
  const l2 = createGeneratorsLayer(ds, "fuel_type", 7, noop, null, true, new Set(), 2)[0];
  assert.notDeepEqual(
    l1.props.updateTriggers.getSize,
    l2.props.updateTriggers.getSize,
    "getSize must re-trigger when stateVersion changes"
  );
  assert.notDeepEqual(l1.props.updateTriggers.getColor, l2.props.updateTriggers.getColor);
});

test("substations layer getSize updateTriggers change with stateVersion", () => {
  const ds = store();
  const l1 = createSubstationsLayer(ds, "voltage_level", 9, noop, null, true, 1)[0];
  const l2 = createSubstationsLayer(ds, "voltage_level", 9, noop, null, true, 2)[0];
  assert.notDeepEqual(l1.props.updateTriggers.getSize, l2.props.updateTriggers.getSize);
});

test("transformers layer getSize updateTriggers change with stateVersion", () => {
  const ds = store();
  const l1 = createTransformersLayer(ds, "voltage_level", 8, noop, null, true, false, 1)[0];
  const l2 = createTransformersLayer(ds, "voltage_level", 8, noop, null, true, false, 2)[0];
  assert.notDeepEqual(l1.props.updateTriggers.getSize, l2.props.updateTriggers.getSize);
});

test("datacenters layer getSize updateTriggers change with stateVersion", () => {
  const ds = new DataStore();
  ds.loadDatacenters({
    datacenters: [
      { id: 40, lon: -112, lat: 33, name: "DC1", operator: "Op", powerMw: 50, facilityType: 1 },
    ],
  });
  const l1 = createDatacentersLayer(ds, "voltage_level", 9, noop, null, true, { stateVersion: 1 })[0];
  const l2 = createDatacentersLayer(ds, "voltage_level", 9, noop, null, true, { stateVersion: 2 })[0];
  assert.notDeepEqual(l1.props.updateTriggers.getSize, l2.props.updateTriggers.getSize);
});

test("water facilities layer getSize updateTriggers change with stateVersion", () => {
  const ds = waterStore([
    { id: 5, lon: -117, lat: 32, name: "Pump A", capacityMgd: 10, powerMw: 2, facilityType: 4 },
  ]);
  const opts1 = { stateVersion: 1 };
  const opts2 = { stateVersion: 2 };
  const l1 = createWaterFacilitiesLayer(ds, "voltage_level", 9, noop, null, true, opts1)[0];
  const l2 = createWaterFacilitiesLayer(ds, "voltage_level", 9, noop, null, true, opts2)[0];
  assert.notDeepEqual(l1.props.updateTriggers.getSize, l2.props.updateTriggers.getSize);
});

// UI-H4 memoization: two consecutive layer builds over an unchanged store
// must hand deck.gl the SAME data array identity (a fresh array per call
// forced a full GPU re-upload on every pan — the pre-fix behavior).
test("generator layer data identity is stable across rebuilds", () => {
  const ds = store();
  const l1 = createGeneratorsLayer(ds, "fuel_type", 7, noop, null, false, new Set(), 1)[0];
  const l2 = createGeneratorsLayer(ds, "fuel_type", 7, noop, null, false, new Set(), 1)[0];
  assert.equal(l1.props.data, l2.props.data, "unfiltered rebuilds must reuse the memoized array");
});

test("substation layer data identity is stable across rebuilds", () => {
  const ds = store();
  const l1 = createSubstationsLayer(ds, "voltage_level", 9, noop, null, false, 1)[0];
  const l2 = createSubstationsLayer(ds, "voltage_level", 9, noop, null, false, 1)[0];
  assert.equal(l1.props.data, l2.props.data);
});

// UI-H5: label culling — labels render only inside the viewport, capped.
test("cullLabels filters to bounds and enforces the cap", () => {
  const data = [];
  for (let i = 0; i < 20; i++) {
    // 10 inside the bounds (lon -110..-101), 10 far outside
    data.push({ id: i, position: [i < 10 ? -110 + i : 40 + i, 35] });
  }
  const bounds = { west: -120, east: -100, south: 30, north: 40 };

  const culled = cullLabels(data, bounds, 250);
  assert.equal(culled.length, 10);
  assert.ok(culled.every((d) => d.position[0] <= bounds.east && d.position[0] >= bounds.west));

  const capped = cullLabels(data, bounds, 4);
  assert.equal(capped.length, 4, "cap applies after bounds filtering");

  const noBounds = cullLabels(data, null, 7);
  assert.equal(noBounds.length, 7, "without bounds the hard cap still applies");
});

test("water labels layer culls to the current viewport", () => {
  const facilities = [];
  for (let i = 0; i < 6; i++) {
    facilities.push({
      id: i,
      lon: i < 3 ? -117 : 0, // 3 in-view (San Diego-ish), 3 at Null Island
      lat: i < 3 ? 32.7 : 0,
      name: `F${i}`,
      capacityMgd: 5,
      powerMw: 1,
      facilityType: 3,
    });
  }
  const ds = waterStore(facilities);
  const layers = createWaterFacilitiesLayer(ds, "voltage_level", 11, noop, null, false, {
    stateVersion: 1,
    bounds: { west: -118, east: -116, south: 32, north: 34 },
  });
  const labels = layers.find((l) => l.props.id === "water-facilities-labels");
  assert.ok(labels, "labels layer renders at zoom >= 10");
  assert.equal(labels.props.data.length, 3, "labels restricted to in-bounds facilities");
});
