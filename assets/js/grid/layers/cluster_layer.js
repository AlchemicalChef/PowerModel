import { ScatterplotLayer } from "@deck.gl/layers";
import { COLOR_SCALES } from "../color_scales";

export function createClusterLayer(dataStore, viewMode, zoom) {
  const data = dataStore.getGeneratorData();
  const cellSize = zoom < 4 ? 2.0 : zoom < 5 ? 1.0 : 0.5;
  const clusters = new Map();

  for (const gen of data) {
    const cellX = Math.floor(gen.position[0] / cellSize);
    const cellY = Math.floor(gen.position[1] / cellSize);
    const key = `${cellX},${cellY}`;

    if (!clusters.has(key)) {
      clusters.set(key, {
        position: [0, 0],
        totalCapacity: 0,
        count: 0,
        dominantFuel: new Map(),
      });
    }

    const c = clusters.get(key);
    c.position[0] += gen.position[0];
    c.position[1] += gen.position[1];
    c.totalCapacity += gen.capacity;
    c.count += 1;

    const fuelCount = c.dominantFuel.get(gen.fuelType) || 0;
    c.dominantFuel.set(gen.fuelType, fuelCount + gen.capacity);
  }

  const clusterData = [];
  for (const [, c] of clusters) {
    c.position[0] /= c.count;
    c.position[1] /= c.count;

    let maxFuel = 0;
    let dominantFuelType = 0;
    for (const [fuel, cap] of c.dominantFuel) {
      if (cap > maxFuel) {
        maxFuel = cap;
        dominantFuelType = fuel;
      }
    }

    clusterData.push({
      position: c.position,
      capacity: c.totalCapacity,
      count: c.count,
      fuelType: dominantFuelType,
    });
  }

  return new ScatterplotLayer({
    id: "generator-clusters",
    data: clusterData,
    pickable: false,
    opacity: 0.7,
    stroked: true,
    filled: true,
    radiusMinPixels: 6,
    radiusMaxPixels: 40,
    getPosition: (d) => d.position,
    getRadius: (d) => Math.sqrt(d.capacity) * 100,
    getFillColor: (d) =>
      viewMode === "fuel_type"
        ? [...COLOR_SCALES.getFuelColor(d.fuelType), 150]
        : [78, 205, 196, 130],
    getLineColor: [200, 200, 200, 100],
    lineWidthMinPixels: 1,
  });
}
