// Optional real-browser check. See compatibility/README.md for setup.
const assert = require("node:assert/strict");
const path = require("node:path");
const { chromium } = require("playwright");

(async () => {
  const base = (process.env.WIKI_URL || "http://127.0.0.1:8765/").replace(/\/?$/, "/");
  const games = await (await fetch(base + "games.json")).json();
  const reports = await (await fetch(base + "reports.json")).json();
  const browser = await chromium.launch({ executablePath: process.env.WIKI_CHROMIUM || undefined });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(base);
    const visible = () => page.locator("#matrix tbody tr:visible").count();
    assert.equal(await visible(), games.length);
    await page.locator("#status").selectOption("tested");
    assert.equal(await visible(), Object.keys(reports.games).length);
    if (process.env.WIKI_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.WIKI_SCREENSHOTS, "wiki-desktop.png"), fullPage: true });
    await page.locator("#search").fill("553850");
    assert.equal(await visible(), 1);
    await page.reload();
    assert.equal(await page.locator("#search").inputValue(), "553850");
    assert.equal(await visible(), 1);
    await page.locator("#search").fill("not-a-real-game-lookup");
    assert.equal(await visible(), 0);
    assert.equal(await page.locator("#empty").isVisible(), true);
    await page.getByRole("button", { name: "Reset" }).click();
    await page.waitForFunction(total => document.querySelector("#result-count").textContent === `Showing ${total} of ${total} games`, games.length);
    await page.locator("#backend").selectOption("dxvk");
    await page.locator("#status").selectOption("unplayable");
    const failed = Object.values(reports.games).filter(report => report.results.some(result => result.backend === "dxvk" && ["fails", "unplayable"].includes(result.status))).length;
    assert.equal(await visible(), failed);
    assert.equal(await page.locator("#status option").filter({ hasText: /^Unplayable$/ }).count(), 1);
    await page.goto(base + "?backend=dxvk&status=fails");
    assert.equal(await page.locator("#status").inputValue(), "unplayable");
    assert.equal(await visible(), failed);
    await page.locator("#backend").selectOption("any");
    await page.locator("#status").selectOption("caveats");
    const caveated = Object.values(reports.games).filter(report => report.results.some(result => result.status === "caveats")).length;
    assert.equal(await visible(), caveated);
    await page.locator("#status").selectOption("untested");
    assert.equal(await visible(), games.length - Object.keys(reports.games).length);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator("#status").selectOption("all");
    await page.locator("#search").fill("Satisfactory");
    assert.equal(await visible(), 1);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    if (process.env.WIKI_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.WIKI_SCREENSHOTS, "wiki-mobile.png"), fullPage: true });
    await page.locator('tr[data-id="526870"] a').click();
    assert.equal(await page.getByRole("heading", { level: 1 }).textContent(), "Satisfactory");
    assert.equal(await page.getByRole("heading", { name: "Evidence", exact: true }).count(), reports.games["526870"].results.length);
    const untested = games.find(game => !reports.games[String(game.app_id)]);
    await page.goto(base + `games/${untested.app_id}.html`);
    assert.equal(await page.getByRole("heading", { name: "No compatibility report yet" }).count(), 1);
    assert.deepEqual(errors, []);
    const noScript = await browser.newContext({ javaScriptEnabled: false });
    const plain = await noScript.newPage();
    await plain.goto(base);
    assert.equal(await plain.locator("#matrix tbody tr").count(), games.length);
    await plain.locator('tr[data-id="526870"] a').click();
    assert.equal(await plain.getByRole("heading", { level: 1 }).textContent(), "Satisfactory");
    console.log(`Browser checks passed: ${games.length} games, filters, shared URL, mobile, details, and no-JS navigation`);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
