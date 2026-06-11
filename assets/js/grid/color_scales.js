// State colors: impact-type visual encoding during failures
// 0 = normal, 1 = stressed (voltage), 2 = overloaded (thermal),
// 3 = tripped/dead, 4 = rerouted (flow change), 5 = shed (load lost),
// 6 = islanded (disconnected from main grid)
export const STATE_COLORS = {
  0: [46, 204, 113],    // green - normal
  1: [245, 166, 35],    // yellow - stressed voltage
  2: [231, 76, 60],     // red - thermal overload
  3: [255, 50, 30],     // bright red - tripped/dead (must read on a dark basemap)
  4: [255, 140, 0],     // dark orange - rerouted flow
  5: [155, 89, 182],    // purple - load shed
  6: [52, 73, 94],      // dark blue-gray - islanded
};

// Voltage level colors
export const VOLTAGE_COLORS = {
  69:  [100, 149, 237],   // cornflower blue
  115: [70, 130, 180],    // steel blue
  138: [64, 224, 208],    // turquoise
  161: [0, 206, 209],     // dark turquoise
  230: [50, 205, 50],     // lime green
  345: [255, 165, 0],     // orange
  500: [255, 69, 0],      // red-orange
  765: [220, 20, 60],     // crimson
};

// Fuel type colors
export const FUEL_COLORS = {
  0:  [150, 150, 150],  // unknown - gray
  1:  [65, 131, 215],   // natural gas - blue
  2:  [100, 100, 100],  // sub coal - dark gray
  3:  [80, 80, 80],     // bit coal - darker gray
  4:  [155, 89, 182],   // nuclear - purple
  5:  [52, 152, 219],   // hydro - water blue
  6:  [46, 204, 113],   // wind - green
  7:  [241, 196, 15],   // solar - yellow
  8:  [127, 140, 141],  // DFO - slate
  9:  [113, 128, 131],  // RFO - darker slate
  10: [139, 90, 43],    // wood - brown
  11: [230, 126, 34],   // geothermal - orange
  12: [0, 255, 255],     // import - cyan
};

export const COLOR_SCALES = {
  getStateColor(state) {
    return STATE_COLORS[state] || STATE_COLORS[0];
  },

  getVoltageColor(kv) {
    // Find closest voltage class
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
    if (pct < 50) return [46, 204, 113];      // green
    if (pct < 75) return [241, 196, 15];       // yellow
    if (pct < 90) return [230, 126, 34];       // orange
    if (pct < 100) return [231, 76, 60];       // red
    return [192, 57, 43];                       // dark red
  },

  // Interpolate between two colors
  lerp(c1, c2, t) {
    return [
      Math.round(c1[0] + (c2[0] - c1[0]) * t),
      Math.round(c1[1] + (c2[1] - c1[1]) * t),
      Math.round(c1[2] + (c2[2] - c1[2]) * t),
    ];
  },
};
