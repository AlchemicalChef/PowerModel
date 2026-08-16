import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildGeneratorsBuffer,
  buildSubstationsBuffer,
  buildTransformersBuffer,
  buildLinesBuffer,
  stubDocument,
  FakeMap,
  tick,
} from "./helpers.mjs";

stubDocument();

const { MapManager } = await import("../grid/map_manager.js");
const { DataStore } = await import("../grid/data_store.js");
const { ViewportTracker } = await import("../grid/viewport_tracker.js");
const { voltageCellColor, createVoltageOverlayLayer } = await import(
  "../grid/layers/voltage_overlay_layer.js"
);
const h3 = await import("h3-js");

// bus_loads.bin v2: "BLD" tag, version u8, count u32, then per record
// bus_id u32, lon f32, lat f32, demand_mw f32. Buses default to distinct
// positions so they land in distinct H3 cells.
function buildBusLoadsBuffer(buses) {
  const buf = new ArrayBuffer(8 + buses.length * 16);
  const v = new DataView(buf);
  v.setUint8(0, 0x42);
  v.setUint8(1, 0x4c);
  v.setUint8(2, 0x44);
  v.setUint8(3, 2);
  v.setUint32(4, buses.length, true);
  let o = 8;
  for (const [i, b] of buses.entries()) {
    v.setUint32(o, b.id, true); o += 4;
    v.setFloat32(o, b.lon ?? -98.5 - i * 2, true); o += 4;
    v.setFloat32(o, b.lat ?? 39.5 + i * 2, true); o += 4;
    v.setFloat32(o, b.mw ?? 100, true); o += 4;
  }
  return buf;
}

// The pre-bus-id layout: bare count u32, then three floats per record.
function buildLegacyBusLoadsBuffer(buses) {
  const buf = new ArrayBuffer(4 + buses.length * 12);
  const v = new DataView(buf);
  v.setUint32(0, buses.length, true);
  let o = 4;
  for (const [i, b] of buses.entries()) {
    v.setFloat32(o, b.lon ?? -98.5 - i * 2, true); o += 4;
    v.setFloat32(o, b.lat ?? 39.5 + i * 2, true); o += 4;
    v.setFloat32(o, b.mw ?? 100, true); o += 4;
  }
  return buf;
}

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
  // Bus ids deliberately collide with the substation id (20) and a line id
  // (1): they are independent integer spaces and nothing may cross over.
  m.dataStore.loadBusLoads(
    buildBusLoadsBuffer([{ id: 1 }, { id: 20 }, { id: 4001 }, { id: 4002 }])
  );
  return m;
}

// The voltage cells that would actually be painted at the zoom the map opens
// on: aggregated by the store, then filtered by the layer's display band.
function drawable(m) {
  return m.dataStore
    .getVoltageHexagons(3, h3)
    .filter((c) => voltageCellColor(c) !== null);
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

// UIW-2: the bus-level failure surface. Before this, 5,651 of 5,654 trip
// entries in the reference cascade had no way onto the map at all.
test("applyCascadeStep paints voltage hexes and shed marks from the bus channels", () => {
  const m = loadedManager();

  m.applyCascadeStep({
    step: 1,
    bus_voltage: { 4001: 0.82, 4002: 0.93 },
    // 99999 is not in the export: an unplaceable bus is dropped, never drawn
    // at [0, 0].
    shed_bus_ids: [4001, 99999],
  });

  assert.equal(drawable(m).length, 2, "both sagging buses produce a drawable cell");
  assert.deepEqual(
    m.dataStore.getShedBusMarks().map((s) => s.id),
    [4001],
    "only shed buses with a known position are marked"
  );

  // Bus ids are not substation ids: bus 20 is untouched by substation 20.
  assert.equal(m.dataStore.getSubstationData()[0].state, 0);
});

// The step channel is violating-buses-only and the key is OMITTED when the
// step has nothing to say — which is also what a step whose voltage layer
// never ran looks like. Absence is no information, so the last known picture
// must survive it rather than being cleared to "healthy".
test("a step without bus_voltage leaves the previous alarm set standing", () => {
  const m = loadedManager();
  m.applyCascadeStep({ step: 1, bus_voltage: { 4001: 0.82 } });
  assert.equal(drawable(m).length, 1);

  m.applyCascadeStep({ step: 2, tripped_line_ids: [2] });
  assert.equal(drawable(m).length, 1, "silent step must not blank the overlay");

  // A step that DOES carry the key is a complete alarm snapshot, so it
  // replaces rather than merges: bus 4001 recovering is expressed by it no
  // longer being named.
  m.applyCascadeStep({ step: 3, bus_voltage: { 4002: 0.88 } });
  const cells = drawable(m);
  assert.equal(cells.length, 1, "recovered bus must not linger at its old reading");
  assert.equal(cells[0].min, 0.88);
});

// The end-of-cascade ac_update carries the FULL magnitude map for the islands
// that converged — the per-cell minimum needs every bus in the cell, not only
// the ones already outside the band.
test("ac_overlay replaces the alarm set and replays when scrubbing", () => {
  const m = loadedManager();
  m.applyCascadeStep({ step: 1, bus_voltage: { 4001: 0.82 } });
  m.applyCascadeStep({ step: 2, bus_voltage: { 4002: 0.93 } });

  const acPayload = {
    partial_ac: true,
    stressed_line_ids: [3],
    ac_overlay: {
      partial: true,
      island_count: 1,
      islands: [
        {
          island_id: 1,
          vm_by_bus: { 1: 1.0, 20: 1.08, 4001: 0.9, 4002: 0.99 },
        },
      ],
    },
  };
  m.applyACResults(acPayload);

  let cells = drawable(m);
  assert.equal(cells.length, 2, "one sagging cell and one Ferranti cell");
  assert.equal(lineById(m, 3).state, 1, "the DC lists still ride along");

  // Scrubbing back: position 0 is the first step's alarm set alone.
  m.showCascadeStep(0);
  cells = drawable(m);
  assert.equal(cells.length, 1);
  assert.equal(cells[0].min, 0.82);

  // Scrubbing to the last frame reproduces the settled AC view, the same way
  // the settled DC classification is reproduced.
  m.showCascadeStep(1);
  assert.equal(drawable(m).length, 2, "settled overlay replayed at the end");
});

test("resetToBaseline clears the voltage overlay and shed marks", () => {
  const m = loadedManager();
  m.applyCascadeStep({ step: 1, bus_voltage: { 4001: 0.82 }, shed_bus_ids: [4001] });
  assert.ok(drawable(m).length > 0);

  m.resetToBaseline();
  assert.equal(m.dataStore.busVoltage.size, 0);
  assert.equal(m.dataStore.getShedBusMarks().length, 0);
  assert.equal(drawable(m).length, 0);
});

// The ramp UI-3's static legend mirrors. Changing a stop here desyncs it.
test("voltage cell colors pin the legend stops and pick the deeper deviation", () => {
  assert.equal(voltageCellColor({ min: 0.96, max: 1.04 }), null, "in-band cells are not drawn");

  // The three named stops, at the exact values the legend names.
  assert.deepEqual(voltageCellColor({ min: 0.95, max: 0.95 }).slice(0, 3), [245, 166, 35]);
  assert.deepEqual(voltageCellColor({ min: 0.85, max: 0.85 }).slice(0, 3), [231, 76, 60]);
  assert.deepEqual(voltageCellColor({ min: 0.7, max: 0.7 }).slice(0, 3), [231, 76, 60], "clamped below 0.85");
  assert.deepEqual(voltageCellColor({ min: 1.0, max: 1.06 }).slice(0, 3), [155, 89, 182]);

  // A cell holding both a deep sag and a shallow rise reads as the sag; a
  // minimum-only rule would have missed the rise entirely in the other case.
  assert.deepEqual(voltageCellColor({ min: 0.85, max: 1.06 }).slice(0, 3), [231, 76, 60]);
  assert.deepEqual(voltageCellColor({ min: 0.95, max: 1.14 }).slice(0, 3), [155, 89, 182]);

  // Alpha deepens with the deviation.
  assert.ok(
    voltageCellColor({ min: 0.86, max: 0.86 })[3] > voltageCellColor({ min: 0.94, max: 0.94 })[3]
  );
});

test("the overlay builds a hex layer and a shed layer, and nothing when idle", () => {
  const m = loadedManager();
  assert.deepEqual(
    createVoltageOverlayLayer(m.dataStore, 4.2, m.stateVersion),
    [],
    "no layers before a cascade has said anything"
  );

  m.applyCascadeStep({ step: 1, bus_voltage: { 4001: 0.82 }, shed_bus_ids: [4001] });
  const layers = createVoltageOverlayLayer(m.dataStore, 4.2, m.stateVersion);

  assert.deepEqual(layers.map((l) => l.id), ["voltage-overlay", "voltage-overlay-shed"]);
  assert.equal(layers[0].props.data.length, 1);
  assert.equal(layers[1].props.data.length, 1);
  // Purple: STATE_SHED (5), the legend row nothing used to paint.
  assert.deepEqual(layers[1].props.getFillColor.slice(0, 3), [155, 89, 182]);
});

// A stale export must degrade to demand-only rather than placing buses at
// coordinates read out of misaligned bytes.
test("a pre-bus-id bus_loads export leaves bus-level channels unplaceable", () => {
  const m = bareManager();
  const realWarn = console.warn;
  let warned = 0;
  console.warn = () => {
    warned++;
  };
  try {
    m.dataStore.loadBusLoads(buildLegacyBusLoadsBuffer([{ id: 4001 }, { id: 4002 }]));
  } finally {
    console.warn = realWarn;
  }

  assert.equal(m.dataStore.busLoads.count, 2, "demand points still parse");
  assert.equal(m.dataStore.busLoads.demands[0], 100);
  assert.equal(warned, 1, "the stale export is surfaced, not silent");

  m.applyCascadeStep({ step: 1, bus_voltage: { 4001: 0.8 }, shed_bus_ids: [4001] });
  assert.equal(drawable(m).length, 0, "no position to join to");
  assert.equal(m.dataStore.getShedBusMarks().length, 0);
});

// UIW-8: the server used to echo 'update_lod' back after every debounced
// viewport move, rebuilding ~90k line paths a second time.
test("a viewport move rebuilds layers exactly once", async () => {
  const m = loadedManager();
  const map = new FakeMap();
  const notifications = [];
  m.onViewportChange = (zoom, bounds) => notifications.push({ zoom, bounds });

  const tracker = new ViewportTracker(map, (z, b) => m._onViewportMove(z, b), 5);
  try {
    const before = m._updateLayerCalls;
    map.setZoom(9);
    map.emit("zoomend");
    await tick(40);

    assert.equal(notifications.length, 1, "the server is still informed");
    assert.equal(m._updateLayerCalls - before, 1, "exactly one rebuild per notification");
    assert.equal(
      typeof m.updateLOD,
      "undefined",
      "the echo sink is gone; a server round trip cannot trigger a second rebuild"
    );
  } finally {
    tracker.destroy();
  }
});
