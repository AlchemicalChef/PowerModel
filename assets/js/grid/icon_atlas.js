const ICON_SIZE = 64;
const COLS = 5;
const ROWS = 3;

let _cached = null;

export function getIconAtlas() {
  if (!_cached) _cached = buildAtlas();
  return _cached;
}

export function generatorIconName(fuelCode) {
  switch (fuelCode) {
    case 1: return "gen_gas";
    case 2: case 3: return "gen_coal";
    case 4: return "gen_nuclear";
    case 5: return "gen_hydro";
    case 6: return "gen_wind";
    case 7: return "gen_solar";
    default: return "gen_other";
  }
}

export function waterIconName(facilityType) {
  switch (facilityType) {
    case 1: return "water_desal";
    case 2: return "water_waste";
    case 3: return "water_treat";
    case 4: return "water_pump";
    case 5: return "water_reservoir";
    default: return "water_treat";
  }
}

function buildAtlas() {
  const canvas = document.createElement("canvas");
  canvas.width = COLS * ICON_SIZE;
  canvas.height = ROWS * ICON_SIZE;
  const ctx = canvas.getContext("2d");

  const s = ICON_SIZE * 0.38;

  drawFlame(ctx, cell(0, 0), s);
  drawFactory(ctx, cell(1, 0), s);
  drawAtom(ctx, cell(2, 0), s);
  drawDam(ctx, cell(3, 0), s);
  drawTurbine(ctx, cell(4, 0), s);
  drawSun(ctx, cell(0, 1), s);
  drawBolt(ctx, cell(1, 1), s);
  drawDiamond(ctx, cell(2, 1), s);
  drawDrop(ctx, cell(3, 1), s);
  drawRecycle(ctx, cell(4, 1), s);
  drawFlask(ctx, cell(0, 2), s);
  drawChevrons(ctx, cell(1, 2), s);
  drawWaves(ctx, cell(2, 2), s);

  const mapping = {};
  const names = [
    ["gen_gas", "gen_coal", "gen_nuclear", "gen_hydro", "gen_wind"],
    ["gen_solar", "gen_other", "substation", "water_desal", "water_waste"],
    ["water_treat", "water_pump", "water_reservoir"],
  ];
  for (let r = 0; r < names.length; r++) {
    for (let c = 0; c < names[r].length; c++) {
      mapping[names[r][c]] = {
        x: c * ICON_SIZE,
        y: r * ICON_SIZE,
        width: ICON_SIZE,
        height: ICON_SIZE,
        mask: true,
      };
    }
  }

  return { atlas: canvas, mapping };
}

function cell(col, row) {
  return { cx: col * ICON_SIZE + ICON_SIZE / 2, cy: row * ICON_SIZE + ICON_SIZE / 2 };
}

function drawFlame(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.moveTo(cx, cy - s);
  ctx.bezierCurveTo(cx + s * 0.15, cy - s * 0.5, cx + s * 0.6, cy - s * 0.1, cx + s * 0.45, cy + s * 0.4);
  ctx.bezierCurveTo(cx + s * 0.35, cy + s * 0.75, cx + s * 0.12, cy + s, cx, cy + s * 0.7);
  ctx.bezierCurveTo(cx - s * 0.12, cy + s, cx - s * 0.35, cy + s * 0.75, cx - s * 0.45, cy + s * 0.4);
  ctx.bezierCurveTo(cx - s * 0.6, cy - s * 0.1, cx - s * 0.15, cy - s * 0.5, cx, cy - s);
  ctx.fill();
  ctx.globalCompositeOperation = "destination-out";
  ctx.beginPath();
  ctx.moveTo(cx, cy + s * 0.7);
  ctx.quadraticCurveTo(cx + s * 0.15, cy + s * 0.2, cx + s * 0.08, cy + s * 0.05);
  ctx.quadraticCurveTo(cx, cy + s * 0.3, cx - s * 0.08, cy + s * 0.05);
  ctx.quadraticCurveTo(cx - s * 0.15, cy + s * 0.2, cx, cy + s * 0.7);
  ctx.fill();
  ctx.globalCompositeOperation = "source-over";
}

function drawFactory(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.fillRect(cx - s * 0.7, cy + s * 0.05, s * 1.4, s * 0.9);
  ctx.fillRect(cx - s * 0.25, cy - s * 0.7, s * 0.25, s * 0.8);
  ctx.fillRect(cx + s * 0.15, cy - s * 0.35, s * 0.2, s * 0.45);
  ctx.beginPath();
  ctx.arc(cx - s * 0.12, cy - s * 0.85, s * 0.14, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(cx + s * 0.05, cy - s * 0.95, s * 0.1, 0, Math.PI * 2);
  ctx.fill();
}

function drawAtom(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  const r = s * 0.32;
  const d = s * 0.42;
  for (let i = 0; i < 3; i++) {
    const a = (i * Math.PI * 2) / 3 - Math.PI / 2;
    ctx.beginPath();
    ctx.arc(cx + Math.cos(a) * d, cy + Math.sin(a) * d, r, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.beginPath();
  ctx.arc(cx, cy, s * 0.14, 0, Math.PI * 2);
  ctx.fill();
}

function drawDam(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.8, cy - s * 0.5);
  ctx.lineTo(cx - s * 0.5, cy + s * 0.6);
  ctx.lineTo(cx + s * 0.5, cy + s * 0.6);
  ctx.lineTo(cx + s * 0.8, cy - s * 0.5);
  ctx.closePath();
  ctx.fill();
  ctx.beginPath();
  for (let i = 0; i < 3; i++) {
    const wx = cx - s * 0.6 + i * s * 0.4;
    const wy = cy - s * 0.65;
    ctx.moveTo(wx, wy);
    ctx.quadraticCurveTo(wx + s * 0.1, wy - s * 0.12, wx + s * 0.2, wy);
    ctx.quadraticCurveTo(wx + s * 0.3, wy + s * 0.12, wx + s * 0.4, wy);
  }
  ctx.strokeStyle = "white";
  ctx.lineWidth = 2.5;
  ctx.stroke();
}

function drawTurbine(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.arc(cx, cy, s * 0.12, 0, Math.PI * 2);
  ctx.fill();
  for (let i = 0; i < 3; i++) {
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate((i * Math.PI * 2) / 3 - Math.PI / 2);
    ctx.beginPath();
    ctx.ellipse(0, -s * 0.5, s * 0.14, s * 0.45, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }
}

function drawSun(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  const coreR = s * 0.35;
  ctx.beginPath();
  ctx.arc(cx, cy, coreR, 0, Math.PI * 2);
  ctx.fill();
  const rayLen = s * 0.3;
  const rayW = s * 0.12;
  for (let i = 0; i < 8; i++) {
    const a = (i * Math.PI) / 4;
    const rx = cx + Math.cos(a) * (coreR + rayLen * 0.3);
    const ry = cy + Math.sin(a) * (coreR + rayLen * 0.3);
    ctx.save();
    ctx.translate(rx, ry);
    ctx.rotate(a);
    ctx.fillRect(-rayW / 2, -rayLen / 2, rayW, rayLen);
    ctx.restore();
  }
}

function drawBolt(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.moveTo(cx + s * 0.1, cy - s);
  ctx.lineTo(cx - s * 0.35, cy + s * 0.05);
  ctx.lineTo(cx + s * 0.05, cy + s * 0.05);
  ctx.lineTo(cx - s * 0.1, cy + s);
  ctx.lineTo(cx + s * 0.35, cy - s * 0.05);
  ctx.lineTo(cx - s * 0.05, cy - s * 0.05);
  ctx.closePath();
  ctx.fill();
}

function drawDiamond(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.moveTo(cx, cy - s * 0.85);
  ctx.lineTo(cx + s * 0.65, cy);
  ctx.lineTo(cx, cy + s * 0.85);
  ctx.lineTo(cx - s * 0.65, cy);
  ctx.closePath();
  ctx.fill();
  ctx.globalCompositeOperation = "destination-out";
  ctx.strokeStyle = "white";
  ctx.lineWidth = 3;
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.3, cy);
  ctx.lineTo(cx + s * 0.3, cy);
  ctx.stroke();
  ctx.globalCompositeOperation = "source-over";
}

function drawDrop(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.beginPath();
  ctx.moveTo(cx, cy - s * 0.9);
  ctx.bezierCurveTo(cx + s * 0.1, cy - s * 0.5, cx + s * 0.55, cy + s * 0.1, cx + s * 0.45, cy + s * 0.45);
  ctx.bezierCurveTo(cx + s * 0.35, cy + s * 0.9, cx + s * 0.1, cy + s, cx, cy + s);
  ctx.bezierCurveTo(cx - s * 0.1, cy + s, cx - s * 0.35, cy + s * 0.9, cx - s * 0.45, cy + s * 0.45);
  ctx.bezierCurveTo(cx - s * 0.55, cy + s * 0.1, cx - s * 0.1, cy - s * 0.5, cx, cy - s * 0.9);
  ctx.fill();
}

function drawRecycle(ctx, { cx, cy }, s) {
  ctx.strokeStyle = "white";
  ctx.lineWidth = 3.5;
  ctx.lineCap = "round";
  for (let i = 0; i < 3; i++) {
    const a1 = (i * Math.PI * 2) / 3 - Math.PI / 2;
    const a2 = ((i + 1) * Math.PI * 2) / 3 - Math.PI / 2;
    const r = s * 0.6;
    const x1 = cx + Math.cos(a1) * r;
    const y1 = cy + Math.sin(a1) * r;
    const x2 = cx + Math.cos(a2) * r;
    const y2 = cy + Math.sin(a2) * r;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    const cpx = cx + Math.cos((a1 + a2) / 2) * r * 0.4;
    const cpy = cy + Math.sin((a1 + a2) / 2) * r * 0.4;
    ctx.quadraticCurveTo(cpx, cpy, x2, y2);
    ctx.stroke();
    const aAngle = Math.atan2(y2 - cpy, x2 - cpx);
    ctx.fillStyle = "white";
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - Math.cos(aAngle - 0.5) * s * 0.25, y2 - Math.sin(aAngle - 0.5) * s * 0.25);
    ctx.lineTo(x2 - Math.cos(aAngle + 0.5) * s * 0.25, y2 - Math.sin(aAngle + 0.5) * s * 0.25);
    ctx.closePath();
    ctx.fill();
  }
}

function drawFlask(ctx, { cx, cy }, s) {
  ctx.fillStyle = "white";
  ctx.fillRect(cx - s * 0.15, cy - s * 0.9, s * 0.3, s * 0.55);
  ctx.beginPath();
  ctx.moveTo(cx - s * 0.15, cy - s * 0.35);
  ctx.lineTo(cx - s * 0.55, cy + s * 0.85);
  ctx.lineTo(cx + s * 0.55, cy + s * 0.85);
  ctx.lineTo(cx + s * 0.15, cy - s * 0.35);
  ctx.closePath();
  ctx.fill();
  ctx.fillRect(cx - s * 0.25, cy - s * 0.92, s * 0.5, s * 0.08);
  ctx.globalCompositeOperation = "destination-out";
  ctx.fillRect(cx - s * 0.2, cy + s * 0.2, s * 0.4, s * 0.1);
  ctx.fillRect(cx - s * 0.05, cy + s * 0.05, s * 0.1, s * 0.4);
  ctx.globalCompositeOperation = "source-over";
}

function drawChevrons(ctx, { cx, cy }, s) {
  ctx.strokeStyle = "white";
  ctx.lineWidth = 4;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  for (let i = 0; i < 3; i++) {
    const y = cy + s * 0.5 - i * s * 0.55;
    ctx.beginPath();
    ctx.moveTo(cx - s * 0.45, y + s * 0.2);
    ctx.lineTo(cx, y - s * 0.2);
    ctx.lineTo(cx + s * 0.45, y + s * 0.2);
    ctx.stroke();
  }
}

function drawWaves(ctx, { cx, cy }, s) {
  ctx.strokeStyle = "white";
  ctx.lineWidth = 4;
  ctx.lineCap = "round";
  for (let i = 0; i < 3; i++) {
    const y = cy - s * 0.5 + i * s * 0.5;
    ctx.beginPath();
    ctx.moveTo(cx - s * 0.8, y);
    ctx.quadraticCurveTo(cx - s * 0.4, y - s * 0.22, cx, y);
    ctx.quadraticCurveTo(cx + s * 0.4, y + s * 0.22, cx + s * 0.8, y);
    ctx.stroke();
  }
}
