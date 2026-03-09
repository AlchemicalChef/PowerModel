export const STATE_COLORS = {
  0: [46, 204, 113],
  1: [245, 166, 35],
  2: [231, 76, 60],
  3: [40, 40, 40],
  4: [255, 140, 0],
  5: [155, 89, 182],
  6: [52, 73, 94],
};

export const VOLTAGE_COLORS = {
  69:  [100, 149, 237],
  115: [70, 130, 180],
  138: [64, 224, 208],
  161: [0, 206, 209],
  230: [50, 205, 50],
  345: [255, 165, 0],
  500: [255, 69, 0],
  765: [220, 20, 60],
};

export const FUEL_COLORS = {
  0:  [150, 150, 150],
  1:  [65, 131, 215],
  2:  [100, 100, 100],
  3:  [80, 80, 80],
  4:  [155, 89, 182],
  5:  [52, 152, 219],
  6:  [46, 204, 113],
  7:  [241, 196, 15],
  8:  [127, 140, 141],
  9:  [113, 128, 131],
  10: [139, 90, 43],
  11: [230, 126, 34],
  12: [0, 255, 255],
};

export const COLOR_SCALES = {
  getStateColor(state) {
    return STATE_COLORS[state] || STATE_COLORS[0];
  },

  getVoltageColor(kv) {
    const classes = Object.keys(VOLTAGE_COLORS).map(Number).sort((a, b) => a - b);
    let closest = classes[0];
    for (const c of classes) {
      if (Math.abs(c - kv) < Math.abs(closest - kv)) closest = c;
    }
    return VOLTAGE_COLORS[closest] || [150, 150, 150];
  },

  getFuelColor(fuelCode) {
    return FUEL_COLORS[fuelCode] || FUEL_COLORS[0];
  },

  getLoadingColor(pct) {
    if (pct < 50) return [46, 204, 113];
    if (pct < 75) return [241, 196, 15];
    if (pct < 90) return [230, 126, 34];
    if (pct < 100) return [231, 76, 60];
    return [192, 57, 43];
  },

  lerp(c1, c2, t) {
    return [
      Math.round(c1[0] + (c2[0] - c1[0]) * t),
      Math.round(c1[1] + (c2[1] - c1[1]) * t),
      Math.round(c1[2] + (c2[2] - c1[2]) * t),
    ];
  },
};
