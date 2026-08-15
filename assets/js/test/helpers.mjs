// Shared test helpers: binary buffer builders matching the data_store.js
// wire layouts, a canvas-free document stub for the icon atlas, and a fake
// maplibre map for the viewport tracker.

// Layout: count u32, then per record u32 id, f32 lon, f32 lat, f32 capacity,
// u8 fuelType, u8 state (18 bytes).
export function buildGeneratorsBuffer(gens) {
  const buf = new ArrayBuffer(4 + gens.length * 18);
  const v = new DataView(buf);
  v.setUint32(0, gens.length, true);
  let o = 4;
  for (const g of gens) {
    v.setUint32(o, g.id, true); o += 4;
    v.setFloat32(o, g.lon ?? -98.5, true); o += 4;
    v.setFloat32(o, g.lat ?? 39.5, true); o += 4;
    v.setFloat32(o, g.capacity ?? 100, true); o += 4;
    v.setUint8(o, g.fuelType ?? 1); o += 1;
    v.setUint8(o, g.state ?? 0); o += 1;
  }
  return buf;
}

// Layout: count u32, then per record u32 id, f32 lon, f32 lat, f32 voltage,
// u8 state (17 bytes).
export function buildSubstationsBuffer(subs) {
  const buf = new ArrayBuffer(4 + subs.length * 17);
  const v = new DataView(buf);
  v.setUint32(0, subs.length, true);
  let o = 4;
  for (const s of subs) {
    v.setUint32(o, s.id, true); o += 4;
    v.setFloat32(o, s.lon ?? -98.5, true); o += 4;
    v.setFloat32(o, s.lat ?? 39.5, true); o += 4;
    v.setFloat32(o, s.voltage ?? 345, true); o += 4;
    v.setUint8(o, s.state ?? 0); o += 1;
  }
  return buf;
}

// Same 17-byte layout as substations, with rated MVA in place of voltage.
export function buildTransformersBuffer(xfmrs) {
  const buf = new ArrayBuffer(4 + xfmrs.length * 17);
  const v = new DataView(buf);
  v.setUint32(0, xfmrs.length, true);
  let o = 4;
  for (const x of xfmrs) {
    v.setUint32(o, x.id, true); o += 4;
    v.setFloat32(o, x.lon ?? -98.5, true); o += 4;
    v.setFloat32(o, x.lat ?? 39.5, true); o += 4;
    v.setFloat32(o, x.ratedMva ?? 300, true); o += 4;
    v.setUint8(o, x.state ?? 0); o += 1;
  }
  return buf;
}

// Layout: count u32, then per record u32 id, f32 kv, f32 rating, u16 points,
// u8 state, then per point f32 lon, f32 lat.
export function buildLinesBuffer(lines) {
  let size = 4;
  for (const l of lines) size += 15 + (l.path?.length ?? 2) * 8;
  const buf = new ArrayBuffer(size);
  const v = new DataView(buf);
  v.setUint32(0, lines.length, true);
  let o = 4;
  for (const l of lines) {
    const path = l.path ?? [[-98.5, 39.5], [-98.0, 39.0]];
    v.setUint32(o, l.id, true); o += 4;
    v.setFloat32(o, l.voltageKv ?? 345, true); o += 4;
    v.setFloat32(o, l.ratingMva ?? 500, true); o += 4;
    v.setUint16(o, path.length, true); o += 2;
    v.setUint8(o, l.state ?? 0); o += 1;
    for (const [lon, lat] of path) {
      v.setFloat32(o, lon, true); o += 4;
      v.setFloat32(o, lat, true); o += 4;
    }
  }
  return buf;
}

// Canvas-free document stub for icon_atlas.buildAtlas: getContext returns a
// proxy whose every method is a no-op and that accepts any property write.
export function stubDocument() {
  if (globalThis.document && globalThis.document.__testStub) return;
  const makeCtx = () =>
    new Proxy(
      {},
      {
        get: (t, p) => {
          if (!(p in t) && typeof p === "string") t[p] = () => {};
          return t[p];
        },
        set: (t, p, val) => {
          t[p] = val;
          return true;
        },
      }
    );
  globalThis.document = {
    __testStub: true,
    createElement: () => ({ width: 0, height: 0, getContext: makeCtx }),
  };
}

// Minimal maplibre-gl Map stand-in for ViewportTracker.
export class FakeMap {
  constructor() {
    this._handlers = {};
    this._zoom = 4.2;
    this._bounds = { west: -125, south: 24, east: -66, north: 49 };
  }
  on(event, fn) {
    (this._handlers[event] ||= []).push(fn);
  }
  off(event, fn) {
    this._handlers[event] = (this._handlers[event] || []).filter((f) => f !== fn);
  }
  emit(event) {
    for (const fn of this._handlers[event] || []) fn();
  }
  setZoom(z) {
    this._zoom = z;
  }
  setBounds(b) {
    this._bounds = { ...this._bounds, ...b };
  }
  getZoom() {
    return this._zoom;
  }
  getBounds() {
    const b = this._bounds;
    return {
      getWest: () => b.west,
      getSouth: () => b.south,
      getEast: () => b.east,
      getNorth: () => b.north,
    };
  }
}

export function tick(ms = 10) {
  return new Promise((r) => setTimeout(r, ms));
}
