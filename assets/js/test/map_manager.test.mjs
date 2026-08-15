import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildGeneratorsBuffer,
  buildSubstationsBuffer,
  buildTransformersBuffer,
  buildLinesBuffer,
  stubDocument,
  tick,
} from "./helpers.mjs";

stubDocument();

const { MapManager } = await import("../grid/map_manager.js");
const { DataStore } = await import("../grid/data_store.js");

// Manager without a DOM/WebGL: skip the constructor (which builds a real
// maplibre map) and initialize the state fields it would have set, stubbing
// _updateLayers. Everything under test here is pure state logic.
function bareManager() {
  const m = Object.create(MapManager.prototype);
  m.dataStore = new DataStore();
  m.viewMode = "voltage_level";
  m.cascadeHistory = [];
  m.cascadeActive = false;
  m.showWaterFacilities = false;
  m.showDatacenters = false;
  m.showDemandDensity = false;
  m.stateVersion = 0;
  m.categoryFilters = {
    voltage: new Set(),
    fuel: new Set(),
    water: new Set(),
    datacenter: new Set(),
    equipment: new Set(),
  };
  m.onComponentClick = null;
  m.onViewportChange = null;
  m.onCascadeActiveChange = null;
  m.selectedComponent = null;
  m.map = null;
  m.deckOverlay = null;
  m.viewportTracker = null;
  m._waterLoadPromise = null;
  m._errorBanner = null;
  m._updateLayerCalls = 0;
  m._updateLayers = () => {
    m._updateLayerCalls++;
  };
  return m;
}

function loadedManager() {
  const m = bareManager();
  m.dataStore.loadGenerators(buildGeneratorsBuffer([{ id: 10 }, { id: 11 }]));
  m.dataStore.loadSubstations(buildSubstationsBuffer([{ id: 20 }]));
  m.dataStore.loadTransformers(buildTransformersBuffer([{ id: 30 }]));
  m.dataStore.loadTransmissionLines(buildLinesBuffer([{ id: 1 }, { id: 2 }, { id: 3 }]));
  return m;
}

function lineById(m, id) {
  return m.dataStore.transmissionLines.lines.find((l) => l.id === id);
}

// UI-C1 / contract #2: "cascade_done" leaves cascade mode but KEEPS the
// final classification marks.
test("endCascade clears cascade mode, keeps marks, bumps stateVersion", () => {
  const m = loadedManager();
  const activeChanges = [];
  m.onCascadeActiveChange = (a) => activeChanges.push(a);

  m.applyCascadeStep({ step: 1, tripped_line_ids: [1], tripped_generator_ids: [10] });
  assert.equal(m.cascadeActive, true);
  assert.deepEqual(activeChanges, [true]);

  const versionBefore = m.stateVersion;
  m.endCascade(false);

  assert.equal(m.cascadeActive, false, "cascade mode must end");
  assert.deepEqual(activeChanges, [true, false]);
  assert.ok(m.stateVersion > versionBefore, "accessors must re-evaluate");
  assert.equal(lineById(m, 1).state, 3, "tripped line mark retained");
  assert.equal(m.dataStore.getGeneratorData()[0].state, 3, "tripped generator retained");
  assert.ok(m.cascadeHistory.length > 0, "timeline history retained for scrubbing");
});

// UI-H3 / contract #4: scrubbing indexes cascadeHistory by ARRAY POSITION.
// Server step numbers reset at each manual trip, so two frames can share
// step: 1 — replay by position must distinguish them, and the final frame
// must replay the settled (__finalClassification) view.
test("showCascadeStep replays by array position with repeated server step numbers", () => {
  const m = loadedManager();

  // Cascade A: two frames
  m.applyCascadeStep({ step: 1, tripped_line_ids: [1] });
  m.applyCascadeStep({ step: 2, tripped_line_ids: [2] });
  // Settled classification arrives -> attached to the last frame (position 1)
  m.applyDCResults({ stressed_line_ids: [3], line_loading: { 3: 62 } });
  // Cascade B after a new manual trip: server step counter reset to 1
  m.applyCascadeStep({ step: 1, tripped_generator_ids: [10] });

  assert.equal(m.cascadeHistory.length, 3);
  assert.equal(m.cascadeHistory[0].step, m.cascadeHistory[2].step, "step numbers repeat across cascades");

  // Position 0: only cascade A's first frame
  m.showCascadeStep(0);
  assert.equal(lineById(m, 1).state, 3);
  assert.equal(lineById(m, 2).state, 0, "later frames must not leak into position 0");
  assert.equal(m.dataStore.getGeneratorData()[0].state, 0, "cascade B's frame must not be applied");

  // Position 1: cascade A complete, including the settled classification
  m.showCascadeStep(1);
  assert.equal(lineById(m, 1).state, 3);
  assert.equal(lineById(m, 2).state, 3);
  assert.equal(lineById(m, 3).state, 1, "__finalClassification replayed (stressed)");
  assert.equal(lineById(m, 3).loadingPct, 62, "__finalClassification replays line_loading");

  // Position 2 (last): cascade B's generator trip on top
  m.showCascadeStep(2);
  assert.equal(m.dataStore.getGeneratorData()[0].state, 3);
  assert.equal(lineById(m, 3).state, 1, "settled classification still present at the end");
});

// UI-H2 / contract #3: dc_update line_loading consumption.
test("applyDCResults consumes line_loading, absent ids default to lowest band", () => {
  const m = loadedManager();
  m.applyDCResults({ line_loading: { 1: 85 } });
  assert.equal(lineById(m, 1).loadingPct, 85);
  assert.equal(lineById(m, 2).loadingPct, 0);

  // Older servers omit the field entirely -> no-op, no crash
  m.applyDCResults({});
  assert.equal(lineById(m, 1).loadingPct, 85, "absent field leaves loading untouched");
});

test("applyDCResults clears flow states but preserves tripped marks", () => {
  const m = loadedManager();
  m.applyCascadeStep({ step: 1, tripped_line_ids: [1] });
  m.applyDCResults({ stressed_line_ids: [2] });
  assert.equal(lineById(m, 1).state, 3, "tripped mark survives re-classification");
  assert.equal(lineById(m, 2).state, 1);

  m.applyDCResults({});
  assert.equal(lineById(m, 2).state, 0, "stale stressed mark cleared by next classification");
});

// UI-H5 (verifier minor): a failed water fetch must NOT be cached — the next
// toggle retries. Under the rejected version the first failure permanently
// disabled the layer for the session.
test("failed water facilities fetch is retried on the next toggle", async () => {
  const m = bareManager();
  let calls = 0;
  const realFetch = globalThis.fetch;
  // The two failures below are the point of the test; the code under test warns
  // on each. Swallow those so a passing run doesn't print stack traces that
  // read like real failures. Warnings are counted, not just discarded.
  const realError = console.error;
  let logged = 0;
  console.error = () => {
    logged++;
  };
  try {
    // 1st: network failure
    globalThis.fetch = () => {
      calls++;
      return Promise.reject(new Error("network down"));
    };
    m.setWaterFacilitiesVisible(true);
    await tick();
    assert.equal(calls, 1);
    assert.equal(m._waterLoadPromise, null, "failure must clear the cached promise");

    // 2nd: HTTP error
    globalThis.fetch = () => {
      calls++;
      return Promise.resolve({ ok: false, status: 503 });
    };
    m.setWaterFacilitiesVisible(true);
    await tick();
    assert.equal(calls, 2, "toggle after failure must refetch");
    assert.equal(m._waterLoadPromise, null, "HTTP error must clear the cached promise");

    // 3rd: success — cached from now on
    globalThis.fetch = () => {
      calls++;
      return Promise.resolve({
        ok: true,
        json: async () => ({
          facilities: [
            { id: 5, lon: -117, lat: 32, name: "Pump A", capacityMgd: 10, powerMw: 2, facilityType: 4 },
          ],
        }),
      });
    };
    m.setWaterFacilitiesVisible(true);
    await tick();
    assert.equal(calls, 3);
    assert.equal(m.dataStore.waterFacilities.count, 1, "data loaded after retry");
    assert.notEqual(m._waterLoadPromise, null, "success is cached");

    m.setWaterFacilitiesVisible(true);
    await tick();
    assert.equal(calls, 3, "no refetch after a successful load");
    assert.equal(logged, 2, "each failure is surfaced to the console exactly once");
  } finally {
    globalThis.fetch = realFetch;
    console.error = realError;
  }
});

// Lazy water fetch + pending-state buffering end to end: a cascade impact
// triggers the fetch, and states arriving before it resolves are applied
// once the data lands.
test("cascade water impacts trigger the lazy fetch and buffered states apply on load", async () => {
  const m = loadedManager();
  let resolveFetch;
  const realFetch = globalThis.fetch;
  try {
    globalThis.fetch = () =>
      new Promise((res) => {
        resolveFetch = res;
      });

    m.applyCascadeStep({ step: 1, water_facility_ids: [5] });
    assert.ok(m._waterLoadPromise, "impact must start the lazy fetch");
    assert.equal(m.dataStore.waterFacilities.count, 0, "data not there yet");

    resolveFetch({
      ok: true,
      json: async () => ({
        facilities: [
          { id: 5, lon: -117, lat: 32, name: "Pump A", capacityMgd: 10, powerMw: 2, facilityType: 4 },
          { id: 7, lon: -117, lat: 33, name: "Plant B", capacityMgd: 20, powerMw: 4, facilityType: 3 },
        ],
      }),
    });
    await m._waterLoadPromise;

    const byId = new Map(m.dataStore.getWaterFacilityData().map((f) => [f.id, f]));
    assert.equal(byId.get(5).state, 3, "buffered impact applied after the lazy load");
    assert.equal(byId.get(7).state, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("state-mutating entry points bump stateVersion monotonically", () => {
  const m = loadedManager();
  const seen = [m.stateVersion];
  m.applyCascadeStep({ step: 1, tripped_line_ids: [1] });
  seen.push(m.stateVersion);
  m.applyDCResults({});
  seen.push(m.stateVersion);
  m.showCascadeStep(0);
  seen.push(m.stateVersion);
  m.endCascade(true);
  seen.push(m.stateVersion);
  m.resetToBaseline();
  seen.push(m.stateVersion);
  for (let i = 1; i < seen.length; i++) {
    assert.ok(seen[i] > seen[i - 1], `stateVersion must increase (step ${i})`);
  }
});

test("resetToBaseline clears history, states, loading, and cascade mode", () => {
  const m = loadedManager();
  const activeChanges = [];
  m.onCascadeActiveChange = (a) => activeChanges.push(a);
  m.applyCascadeStep({ step: 1, tripped_line_ids: [1] });
  m.applyDCResults({ line_loading: { 2: 55 } });

  m.resetToBaseline();
  assert.equal(m.cascadeActive, false);
  assert.deepEqual(activeChanges, [true, false]);
  assert.equal(m.cascadeHistory.length, 0);
  assert.equal(lineById(m, 1).state, 0);
  assert.equal(lineById(m, 2).loadingPct, 0);
});
