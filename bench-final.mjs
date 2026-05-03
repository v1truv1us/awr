// bench-final.mjs
// Final AWR vs Playwright comparison with averages.

const { execSync } = await import('child_process');
const { chromium } = await import('playwright');

const urls = [
  { label: "example.com", url: "https://example.com/" },
  { label: "hackernews", url: "https://news.ycombinator.com/" },
  { label: "wikipedia", url: "https://en.wikipedia.org/wiki/Octopus" },
  { label: "mdn", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select" },
];

function runAwr(url, runs = 3) {
  const times = [];
  for (let i = 0; i < runs; i++) {
    const start = performance.now();
    execSync(`./zig-out/bin/awr "${url}"`, { timeout: 30000, stdio: 'pipe' });
    times.push(performance.now() - start);
  }
  return {
    min: Math.min(...times),
    max: Math.max(...times),
    avg: times.reduce((a, b) => a + b, 0) / times.length,
  };
}

async function runPlaywright(url, runs = 3) {
  const browser = await chromium.launch();
  const times = { dom: [], load: [], text: [] };

  for (let i = 0; i < runs; i++) {
    const page = await browser.newPage();

    const start1 = performance.now();
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    times.dom.push(performance.now() - start1);

    const start2 = performance.now();
    await page.goto(url, { waitUntil: 'load' });
    times.load.push(performance.now() - start2);

    const start3 = performance.now();
    await page.textContent('body');
    times.text.push(performance.now() - start3);

    await page.close();
  }

  await browser.close();

  return {
    dom: { min: Math.min(...times.dom), max: Math.max(...times.dom), avg: times.dom.reduce((a, b) => a + b, 0) / times.dom.length },
    load: { min: Math.min(...times.load), max: Math.max(...times.load), avg: times.load.reduce((a, b) => a + b, 0) / times.load.length },
    text: { min: Math.min(...times.text), max: Math.max(...times.text), avg: times.text.reduce((a, b) => a + b, 0) / times.text.length },
  };
}

async function main() {
  console.log("=== AWR vs Playwright (Chromium) Page Load Benchmark ===\n");
  console.log("3 runs each, reporting min/avg/max\n");

  for (const u of urls) {
    console.log(`--- ${u.label} ---`);

    console.log("Running AWR...");
    const awr = runAwr(u.url);

    console.log("Running Playwright...");
    const pw = await runPlaywright(u.url);

    console.log(`
AWR:
  Total: ${awr.min.toFixed(0)}ms (min) / ${awr.avg.toFixed(0)}ms (avg) / ${awr.max.toFixed(0)}ms (max)

Playwright (Chromium):
  DOMContentLoaded: ${pw.dom.min.toFixed(0)}ms / ${pw.dom.avg.toFixed(0)}ms / ${pw.dom.max.toFixed(0)}ms
  Full load:        ${pw.load.min.toFixed(0)}ms / ${pw.load.avg.toFixed(0)}ms / ${pw.load.max.toFixed(0)}ms
  textContent:      ${pw.text.min.toFixed(0)}ms / ${pw.text.avg.toFixed(0)}ms / ${pw.text.max.toFixed(0)}ms
  Combined (DOM+text): ${((pw.dom.min + pw.text.min)).toFixed(0)}ms / ${((pw.dom.avg + pw.text.avg)).toFixed(0)}ms / ${((pw.dom.max + pw.text.max)).toFixed(0)}ms
`);
  }

  // Summary table
  console.log("┌──────────────┬───────────┬───────────┬────────────────────────────────────┐");
  console.log("│ URL          │ AWR       │ PW DOM+Tx │ PW Full Load                     │");
  console.log("│              │ (avg ms)  │ (avg ms)  │ (avg ms)                         │");
  console.log("├──────────────┼───────────┼───────────┼────────────────────────────────────┤");

  const results = [];
  for (const u of urls) {
    const awr = runAwr(u.url, 1);
    const pw = await runPlaywright(u.url, 1);
    results.push({ label: u.label, awr: awr.avg, pwDomText: pw.dom.avg + pw.text.avg, pwLoad: pw.load.avg });
  }

  for (const r of results) {
    const ratio = (r.awr / r.pwDomText).toFixed(1);
    console.log(`│ ${r.label.padEnd(12)} │ ${r.awr.toFixed(0).padStart(9)} │ ${r.pwDomText.toFixed(0).padStart(9)} │ ${r.pwLoad.toFixed(0).padStart(34)} │`);
  }

  console.log("└──────────────┴───────────┴───────────┴────────────────────────────────────┘");
  console.log("\nNotes:");
  console.log("- AWR: fetch + parse + JS exec + render (single process, no browser)");
  console.log("- PW DOM+Tx: DOMContentLoaded + textContent (closest to AWR's work)");
  console.log("- PW Full Load: includes all resources, images, etc.");
}

main().catch(console.error);
