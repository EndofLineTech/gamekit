// Design-artifact smoke check and screenshot capture. Requires Playwright.
// NODE_PATH="$PWD/.build/wiki-browser/node_modules" node docs/design/library-v1/capture.cjs
const { chromium } = require('playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const fs = require('node:fs/promises');
const assert = require('node:assert/strict');

(async () => {
  const output = path.resolve(process.env.GAMEKIT_DESIGN_OUTPUT || '.build/library-design-v1');
  await fs.mkdir(output, { recursive: true });
  const browser = await chromium.launch({ headless: true,
    ...(process.env.GAMEKIT_DESIGN_BROWSER ? { executablePath: process.env.GAMEKIT_DESIGN_BROWSER } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.goto(pathToFileURL(path.join(__dirname, 'index.html')).href);
    const capture = async name => {
      await page.evaluate(async () => {
        await Promise.all([...document.images].map(img => img.decode()));
        document.querySelector('#page').scrollTop = 0;
        document.querySelector('#toast').textContent = '';
      });
      await page.screenshot({ path: path.join(output, name + '.png'), fullPage: true });
    };
    assert.equal(await page.locator('.game').count(), 8);
    assert.equal(await page.locator('.game .launcher-corner').count(), 8);
    await capture('01-library-grid-dark');
    await page.locator('#theme').click();
    await capture('02-library-grid-light');
    await page.locator('#theme').click();
    await page.locator('[data-game="steam:1"]').click();
    assert.equal(await page.locator('#inspector').isVisible(), true);
    await capture('03-game-inspector');
    await page.locator('#space').selectOption('Use fullscreen Space');
    await page.locator('#list-button').click();
    assert.equal(await page.locator('tbody tr.selected').count(), 1);
    await page.locator('#inspector-button').click();
    await capture('04-library-list');
    await page.locator('#search').fill('satisfactory');
    assert.equal(await page.locator('tbody tr').count(), 2);
    await page.locator('.nav[data-page="Ubisoft"]').click();
    assert.equal(await page.locator('tbody tr').count(), 2);
    await capture('05-launcher-library');
    await page.locator('.nav[data-page="launchers"]').click();
    await capture('06-launcher-management');
    await page.locator('.nav[data-page="settings"]').click();
    await page.locator('[data-settings="Game defaults"]').click();
    assert.equal(await page.locator('.sidebar .settings-tabs').count(), 1);
    assert.equal(await page.locator('#page .settings-tabs').count(), 0);
    await capture('07-game-defaults');
    await page.getByRole('button', { name: 'Back to Launchers' }).click();
    assert.equal(await page.locator('.nav.active').getAttribute('data-page'), 'launchers');
    await page.locator('#icons').click();
    await capture('08-icon-concepts');
    await page.locator('#scenario').selectOption('empty');
    await capture('09-empty-library');
    await page.locator('#scenario').selectOption('error');
    await capture('10-library-error');
    await page.locator('[data-action="retry"]').click();
    assert.equal(await page.locator('.notice.warning').count(), 0);
    await page.locator('#scenario').selectOption('loading');
    assert.equal(await page.locator('.skeleton').count(), 3);
    await page.locator('#scenario').selectOption('offline');
    assert.match(await page.locator('.notice').innerText(), /Offline/);
    await page.locator('#scenario').selectOption('normal');
    await page.locator('#grid-button').click();
    await page.locator('[data-game="steam:1"]').click();
    assert.equal(await page.locator('#space').inputValue(), 'Use fullscreen Space');
    await page.locator('[data-action="favorite"]').click();
    assert.equal(await page.locator('#fav-count').innerText(), '1');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#inspector').isVisible(), false);
    await page.setViewportSize({ width: 900, height: 800 });
    await capture('11-compact-library');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    assert.deepEqual(errors, []);
    console.log('PASS: mockup navigation, selection, search, preferences, favorites, states and no JS errors.');
    console.log('Screenshots: ' + output);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
