import { test } from "node:test";
import assert from "node:assert/strict";
import { ViewportTracker, lodBand, LOD_ZOOM_THRESHOLDS } from "../grid/viewport_tracker.js";
import { FakeMap, tick } from "./helpers.mjs";

function tracked() {
  const map = new FakeMap();
  const calls = [];
  const tracker = new ViewportTracker(map, (zoom, bounds) => calls.push({ zoom, bounds }), 0);
  return { map, calls, tracker };
}

test("lodBand changes exactly at the visibility thresholds", () => {
  for (const t of LOD_ZOOM_THRESHOLDS) {
    assert.notEqual(lodBand(t - 0.01), lodBand(t + 0.01), `band must change across ${t}`);
  }
  assert.equal(lodBand(8.1), lodBand(9.9), "no band change inside 8..10");
});

test("first move always notifies", async () => {
  const { map, calls } = tracked();
  map.emit("moveend");
  await tick();
  assert.equal(calls.length, 1);
});

// UI-M7 regression: a small zoom step that crosses an LOD band boundary
// (7.9 -> 8.05 crosses the zoom-8 substation gate) must NOT be swallowed by
// the significance filter. Under the pre-fix filter (|dz| > 0.5 OR bounds
// moved > 10%) this emitted nothing and substations stayed hidden.
test("small zoom crossing an LOD band boundary notifies", async () => {
  const { map, calls } = tracked();
  map.setZoom(7.9);
  map.emit("zoomend");
  await tick();
  assert.equal(calls.length, 1);

  map.setZoom(8.05); // |dz| = 0.15, bounds unchanged, crosses zoom 8
  map.emit("zoomend");
  await tick();
  assert.equal(calls.length, 2, "band crossing must fire even for tiny zoom deltas");
  assert.equal(calls[1].zoom, 8.05);
});

test("small zoom within one LOD band does not notify", async () => {
  const { map, calls } = tracked();
  map.setZoom(8.1);
  map.emit("zoomend");
  await tick();
  assert.equal(calls.length, 1);

  map.setZoom(8.3); // same band, |dz| = 0.2, bounds unchanged
  map.emit("zoomend");
  await tick();
  assert.equal(calls.length, 1, "insignificant same-band move stays filtered");
});

test("large zoom change notifies", async () => {
  const { map, calls } = tracked();
  map.setZoom(8.1);
  map.emit("zoomend");
  await tick();
  map.setZoom(9.0); // |dz| = 0.9 > 0.5 (same band — magnitude rule fires)
  map.emit("zoomend");
  await tick();
  assert.equal(calls.length, 2);
});

test("pan beyond 10% of the viewport span notifies", async () => {
  const { map, calls } = tracked();
  map.emit("moveend");
  await tick();
  assert.equal(calls.length, 1);

  // Span is 59 degrees of longitude; move west edge by ~12 degrees (>10%)
  map.setBounds({ west: -137, east: -78 });
  map.emit("moveend");
  await tick();
  assert.equal(calls.length, 2);
});
