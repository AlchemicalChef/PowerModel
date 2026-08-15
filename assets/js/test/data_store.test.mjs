import { test } from "node:test";
import assert from "node:assert/strict";
import { DataStore } from "../grid/data_store.js";
import {
  buildGeneratorsBuffer,
  buildSubstationsBuffer,
  buildTransformersBuffer,
  buildLinesBuffer,
} from "./helpers.mjs";

function storeWithAll() {
  const ds = new DataStore();
  ds.loadGenerators(buildGeneratorsBuffer([{ id: 10 }, { id: 11 }]));
  ds.loadSubstations(buildSubstationsBuffer([{ id: 20 }, { id: 21 }]));
  ds.loadTransformers(buildTransformersBuffer([{ id: 30 }, { id: 31 }]));
  ds.loadTransmissionLines(buildLinesBuffer([{ id: 1 }, { id: 2 }, { id: 3 }]));
  return ds;
}

// UI-H4: getData arrays must be memoized — same identity across calls — and
// in-place state mutations must be visible through the cached objects.
// Under the pre-fix behavior each call built a fresh array (identity test
// fails); under a broken sync the cached object would keep the stale state.
test("generator data array identity is stable and state mutations propagate", () => {
  const ds = storeWithAll();
  const a = ds.getGeneratorData();
  const b = ds.getGeneratorData();
  assert.equal(a, b, "getGeneratorData must return the same array identity");

  ds.applyGeneratorStateMap({ 11: 3 });
  const c = ds.getGeneratorData();
  assert.equal(a, c, "mutation must not change the array identity");
  assert.equal(c[1].state, 3, "cached object must see the tripped state");
  assert.equal(c[0].state, 0);
});

test("substation data array identity is stable and state mutations propagate", () => {
  const ds = storeWithAll();
  const a = ds.getSubstationData();
  ds.applySubstationStateMap({ 20: 1 });
  const b = ds.getSubstationData();
  assert.equal(a, b);
  assert.equal(b[0].state, 1);
  assert.equal(b[1].state, 0);
});

test("transformer data array identity is stable and state mutations propagate", () => {
  const ds = storeWithAll();
  const a = ds.getTransformerData();
  ds.applyTransformerStateMap({ 31: 2 });
  const b = ds.getTransformerData();
  assert.equal(a, b);
  assert.equal(b[1].state, 2);

  ds.resetTransformerFlowStates();
  assert.equal(b[1].state, 0, "flow-derived state cleared through cache");
});

test("resetAllStates clears states through the memoized caches", () => {
  const ds = storeWithAll();
  const gens = ds.getGeneratorData();
  const subs = ds.getSubstationData();
  ds.applyGeneratorStateMap({ 10: 3 });
  ds.applySubstationStateMap({ 21: 3 });
  ds.resetAllStates();
  assert.equal(gens[0].state, 0);
  assert.equal(subs[1].state, 0);
});

// UI-H2 / contract #3: line_loading consumption. The server sends only lines
// >= 30% loaded; absent ids are the lowest band (0).
test("applyLineLoading sets pct for present ids and 0 for absent ids", () => {
  const ds = storeWithAll();
  ds.applyLineLoading({ 1: 85.5, 3: 42 });
  const byId = new Map(ds.transmissionLines.lines.map((l) => [l.id, l]));
  assert.equal(byId.get(1).loadingPct, 85.5);
  assert.equal(byId.get(2).loadingPct, 0, "absent id defaults to 0");
  assert.equal(byId.get(3).loadingPct, 42);

  ds.resetLineLoading();
  assert.equal(byId.get(1).loadingPct, 0);
});

// UI-H5: water facilities load lazily; cascade states arriving before the
// 17.7 MB fetch resolves must be buffered and applied on load.
test("water facility states arriving before load are buffered and applied", () => {
  const ds = new DataStore();
  ds.applyWaterFacilityState([5, 6], 3);
  assert.equal(ds.waterFacilities.count, 0);

  ds.loadWaterFacilities({
    facilities: [
      { id: 5, lon: -117, lat: 32, name: "Pump A", capacityMgd: 10, powerMw: 2, facilityType: 4 },
      { id: 7, lon: -117, lat: 33, name: "Plant B", capacityMgd: 20, powerMw: 4, facilityType: 3 },
    ],
  });

  const byId = new Map(ds.getWaterFacilityData().map((f) => [f.id, f]));
  assert.equal(byId.get(5).state, 3, "buffered state applied on load");
  assert.equal(byId.get(7).state, 0, "unbuffered facility stays normal");
  assert.equal(ds._pendingWaterStates.size, 0, "buffer cleared after apply");
});

test("resetAllStates clears buffered pending water states", () => {
  const ds = new DataStore();
  ds.applyWaterFacilityState([5], 3);
  ds.resetAllStates();
  ds.loadWaterFacilities({
    facilities: [{ id: 5, lon: -117, lat: 32, name: "Pump A", capacityMgd: 10, powerMw: 2, facilityType: 4 }],
  });
  assert.equal(ds.getWaterFacilityData()[0].state, 0, "stale buffered state must not survive a reset");
});
