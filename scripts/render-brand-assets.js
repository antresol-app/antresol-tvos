// Renders the tvOS brand assets (layered app icon, Top Shelf images, logo mark)
// from the Antresol mark in docs/design-ref/app-icon.svg.
//
// Usage: node scripts/render-brand-assets.js <output-dir>   (needs the `playwright` package)
// Then copy the PNGs into AntresolTV/Resources/Assets.xcassets (file names match the
// imageset contents: AppIcon/{Back,Middle,Front}[@2x].png -> App Icon.imagestack, etc.).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const out = process.argv[2];

const HOUSE = 'M 590.23 186.85 L 789.79 298.71 A 200 200 0 0 1 892.00 473.17 L 892.00 747.00 A 100 100 0 0 1 792.00 847.00 L 232.00 847.00 A 100 100 0 0 1 132.00 747.00 L 132.00 473.17 A 200 200 0 0 1 234.21 298.71 L 433.77 186.85 A 160 160 0 0 1 590.23 186.85 Z';
const PLAY = 'M 467.93 433.79 L 638.23 530.19 A 40 40 0 0 1 638.23 599.81 L 467.93 696.21 A 40 40 0 0 1 408.22 661.40 L 408.22 468.60 A 40 40 0 0 1 467.93 433.79 Z';
const DEFS = `<defs>
<linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1"><stop offset="0" stop-color="#3a1c8c"/><stop offset="1" stop-color="#9b2fc9"/></linearGradient>
<radialGradient id="glow" cx="0.3" cy="0.15" r="0.9"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#14062e" flood-opacity=".36"/></filter>
<filter id="psh" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#1b0a3a" flood-opacity=".32"/></filter>
<linearGradient id="glass" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".34"/><stop offset="1" stop-color="#fff" stop-opacity=".08"/></linearGradient>
</defs>`;

// Mark (house centre 512,516.5; height 661 units) placed at cx,cy with pixel height h.
function mark(cx, cy, h, parts) {
  const s = h / 661;
  const t = `translate(${cx - 512 * s} ${cy - 516.5 * s}) scale(${s})`;
  let g = '';
  if (parts.includes('house')) g += `<g filter="url(#sh)"><path d="${HOUSE}" fill="url(#glass)" stroke="#fff" stroke-opacity=".6" stroke-width="4"/></g>`;
  if (parts.includes('play')) g += `<g filter="url(#psh)"><path d="${PLAY}" fill="#fff"/></g>`;
  return `<g transform="${t}">${g}</g>`;
}

function background(w, h) {
  return `<rect width="${w}" height="${h}" fill="url(#bg)"/><rect width="${w}" height="${h}" fill="url(#glow)"/>`;
}

function svg(w, h, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${DEFS}${body}</svg>`;
}

const jobs = [];
function iconLayers(prefix, w, h, scales) {
  for (const scale of scales) {
    const W = w * scale, H = h * scale;
    const markH = H * 0.62;
    jobs.push([`${prefix}/Back.png@${scale}`, svg(W, H, background(W, H))]);
    jobs.push([`${prefix}/Middle.png@${scale}`, svg(W, H, mark(W / 2, H / 2, markH, ['house']))]);
    jobs.push([`${prefix}/Front.png@${scale}`, svg(W, H, mark(W / 2, H / 2, markH, ['play']))]);
  }
}
iconLayers('AppIcon', 400, 240, [1, 2]);
iconLayers('AppStore', 1280, 768, [1]);

function shelf(name, w, h, scales) {
  for (const scale of scales) {
    const W = w * scale, H = h * scale;
    const markH = H * 0.40;
    const font = H * 0.17;
    const html = `<div style="position:relative;width:${W}px;height:${H}px">${svg(W, H, background(W, H))}
      <div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:${H * 0.05}px">
        <svg width="${markH * 1.5}" height="${markH * 1.5}" viewBox="0 0 ${markH * 1.5} ${markH * 1.5}" style="margin:0 -${markH * 0.1}px">${DEFS}${mark(markH * 0.75, markH * 0.75, markH, ["house", "play"])}</svg>
        <span style="font:700 ${font}px -apple-system, 'Helvetica Neue', 'Inter', 'DejaVu Sans', sans-serif;color:#fff;letter-spacing:-0.02em">Antresol</span>
      </div></div>`;
    jobs.push([`${name}.png@${scale}`, html, true]);
  }
}
shelf('TopShelf', 1920, 720, [1, 2]);
shelf('TopShelfWide', 2320, 720, [1, 2]);

for (const scale of [1, 2]) {
  const S = 160 * scale;
  jobs.push([`LogoMark.png@${scale}`, svg(S, S, mark(S / 2, S / 2, S * 0.82, ['house', 'play']))]);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const [name, content] of jobs) {
    const m = content.match(/width="(\d+(?:\.\d+)?)" height="(\d+(?:\.\d+)?)"/) || content.match(/width:(\d+)px;height:(\d+)px/);
    const w = Math.round(+m[1]), h = Math.round(+m[2]);
    await page.setViewportSize({ width: w, height: h });
    await page.setContent(`<html><body style="margin:0;background:transparent">${content}</body></html>`);
    const [file, scale] = name.split('@');
    const dest = path.join(out, file.replace('.png', scale === '1' ? '.png' : `@${scale}x.png`));
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    await page.screenshot({ path: dest, omitBackground: true, clip: { x: 0, y: 0, width: w, height: h } });
  }
  await browser.close();
})();
