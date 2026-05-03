// bench-playwright.mjs
// Compare Playwright page load times against AWR's benchmark.
// Run: node bench-playwright.mjs

const urls = [
  { label: "example.com", url: "https://example.com/" },
  { label: "hackernews", url: "https://news.ycombinator.com/" },
  { label: "wikipedia", url: "https://en.wikipedia.org/wiki/Octopus" },
  { label: "mdn", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select" },
];

async function measurePlaywright(browserType, name) {
  const { chromium } = await import('playwright');
  const browser = await chromium.launch();
  const results = {};

  for (const u of urls) {
    const page = await browser.newPage();
    const start = performance.now();
    await page.goto(u.url, { waitUntil: 'domcontentloaded' });
    const domLoaded = performance.now() - start;

    const start2 = performance.now();
    await page.goto(u.url, { waitUntil: 'load' });
    const fullLoad = performance.now() - start2;

    // Get text content (equivalent to AWR's render)
    const start3 = performance.now();
    await page.textContent('body');
    const renderTime = performance.now() - start3;

    results[u.label] = { domLoaded, fullLoad, renderTime };
    await page.close();
  }

  await browser.close();
  return { name, results };
}

async function measureAwr() {
  const { execSync } = await import('child_process');
  const results = {};

  for (const u of urls) {
    const start = performance.now();
    execSync(`./zig-out/bin/awr "${u.url}"`, { timeout: 30000 });
    const elapsed = performance.now() - start;
    results[u.label] = { total: elapsed };
  }

  return { name: "AWR", results };
}

async function main() {
  console.log("=== AWR vs Playwright Page Load Benchmark ===\n");

  // Measure AWR
  console.log("Measuring AWR...");
  const awrResults = await measureAwr();

  // Measure Playwright
  console.log("Measuring Playwright (Chromium)...");
  const pwResults = await measurePlaywright('chromium', 'Playwright');

  // Print comparison table
  console.log("\n┌──────────────┬────────────┬──────────────────────┬──────────────────────┐");
  console.log("│ URL          │ Metric     │ AWR                  │ Playwright (Chromium)│");
  console.log("├──────────────┼────────────┼──────────────────────┼──────────────────────┤");

  for (const u of urls) {
    const awr = awrResults.results[u.label];
    const pw = pwResults.results[u.label];

    console.log(`│ ${u.label.padEnd(12)} │ DOM loaded │                      │ ${pw.domLoaded.toFixed(1).padStart(18)}ms │`);
    console.log(`│              │ Full load  │                      │ ${pw.fullLoad.toFixed(1).padStart(18)}ms │`);
    console.log(`│              │ Render     │                      │ ${pw.renderTime.toFixed(1).padStart(18)}ms │`);
    console.log(`│              │ Total      │ ${awr.total.toFixed(1).padStart(18)}ms │                      │`);
    console.log("├──────────────┼────────────┼──────────────────────┼──────────────────────┤");
  }

  console.log("\nNotes:");
  console.log("- AWR 'Total' = fetch + parse + JS exec + render (all in one)");
  console.log("- Playwright splits into DOMContentLoaded, load, and textContent");
  console.log("- AWR is CLI-first: single process, no browser overhead");
  console.log("- Playwright launches full Chromium browser");
}

main().catch(console.error);
