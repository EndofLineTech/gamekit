// Regenerate the native macOS asset catalog from the approved editable SVG.
// NODE_PATH="$PWD/.build/wiki-browser/node_modules" node tools/generate_app_icon.cjs
const { chromium } = require('playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const fs = require('node:fs/promises');

(async () => {
  const root = path.resolve(__dirname, '..');
  const source = path.join(root, 'docs/design/library-v1/icon-case.svg');
  const target = path.join(root, 'App/Assets.xcassets/AppIcon.appiconset');
  const browser = await chromium.launch({ headless: true,
    ...(process.env.GAMEKIT_DESIGN_BROWSER ? { executablePath: process.env.GAMEKIT_DESIGN_BROWSER } : {}) });
  try {
    const page = await browser.newPage({ deviceScaleFactor: 1 });
    for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
      await page.setViewportSize({ width: size, height: size });
      await page.goto(pathToFileURL(source).href);
      await page.locator('svg').evaluate(svg => {
        svg.style.width = '100vw';
        svg.style.height = '100vh';
      });
      await page.screenshot({ path: path.join(target, `icon-${size}.png`), omitBackground: true });
    }
  } finally {
    await browser.close();
  }
  console.log(`Generated seven macOS icon sizes from ${source}`);
})().catch(error => { console.error(error); process.exitCode = 1; });
