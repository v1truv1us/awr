// bench-compare.mjs
// Compare AWR vs Playwright page load times.

const urls = [
  { label: "example.com", url: "https://example.com/" },
  { label: "hackernews", url: "https://news.ycombinator.com/" },
  { label: "wikipedia", url: "https://en.wikipedia.org/wiki/Octopus" },
  { label: "mdn", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select" },
];

const awrTimes = {
  "example.com": 502,
  "hackernews": 875,
  "wikipedia": 920,
  "mdn": 932,
};

async function measurePlaywright() {
  const { chromium } = await import('playwright');
  const browser = await chromium.launch();
  const results = {};

  for (const u of urls) {
    const page = await browser.newPage();

    // DOMContentLoaded
    const start1 = performance.now();
    await page.goto(u.url, { waitUntil: 'domcontentloaded' });
    const domLoaded = performance.now() - start1;

    // Full load
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
  return results;
}

async function main() {
  console.log("=== AWR vs Playwright Page Load Benchmark ===\n");
  console.log("Measuring Playwright (Chromium)...");

  const pwResults = await measurePlaywright();

  console.log("\n┌──────────────┬────────────┬───────────┬──────────────────────┐");
  console.log("│ URL          │ Metric     │ AWR (ms)  │ Playwright (ms)      │");
  console.log("├──────────────┼────────────┼───────────┼──────────────────────┤");

  for (const u of urls) {
    const awr = awrTimes[u.label];
    const pw = pwResults[u.label];

    console.log(`│ ${u.label.padEnd(12)} │ DOM loaded │           │ ${pw.domLoaded.toFixed(0).padStart(18)} │`);
    console.log(`│              │ Full load  │           │ ${pw.fullLoad.toFixed(0).padStart(18)} │`);
    console.log(`│              │ Text       │           │ ${pw.renderTime.toFixed(0).padStart(18)} │`);
    console.log(`│              │ Total      │ ${awr.toString().padStart(9)} │                      │`);
    console.log("├──────────────┼────────────┼───────────┼──────────────────────┤");
  }

  console.log("\nNotes:");
  console.log("- AWR 'Total' = fetch + parse + JS exec + render (single process)");
  console.log("- Playwright measures DOMContentLoaded, load, and textContent separately");
  console.log("- AWR is CLI-first: no browser overhead, single process");
  console.log("- Playwright launches full Chromium browser");
}

main().catch(console.error);
