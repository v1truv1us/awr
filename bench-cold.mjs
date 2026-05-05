// bench-cold.mjs — Honest like-for-like cold benchmark.
//
// bench-final.mjs reuses one Chromium process across 3 iterations, so
// iterations 2-3 hit warm DNS, TCP keep-alive, TLS session tickets,
// and V8 bytecode caches. AWR is cold every run. That asymmetry shows
// up as a 2-3x apparent speedup for Chrome that doesn't exist on a
// like-for-like comparison.
//
// This bench launches a fresh Chromium process per iteration so both
// AWR and Chrome pay the full DNS+TCP+TLS+process-startup cost on
// every run.

import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';

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
    execFileSync('./zig-out/bin/awr', [url], { timeout: 30000, stdio: 'pipe' });
    times.push(performance.now() - start);
  }
  return {
    min: Math.min(...times),
    max: Math.max(...times),
    avg: times.reduce((a, b) => a + b, 0) / times.length,
  };
}

async function runPlaywrightCold(url, runs = 3) {
  const times = { dom: [], text: [] };

  for (let i = 0; i < runs; i++) {
    // Fresh browser process per iteration — no shared DNS/TCP/TLS/V8 cache.
    const browser = await chromium.launch();
    const page = await browser.newPage();

    const start1 = performance.now();
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    const dom = performance.now() - start1;
    times.dom.push(dom);

    const start2 = performance.now();
    await page.textContent('body');
    times.text.push(performance.now() - start2);

    await page.close();
    await browser.close();
  }

  return {
    dom: { min: Math.min(...times.dom), max: Math.max(...times.dom), avg: times.dom.reduce((a, b) => a + b, 0) / times.dom.length },
    text: { min: Math.min(...times.text), max: Math.max(...times.text), avg: times.text.reduce((a, b) => a + b, 0) / times.text.length },
  };
}

async function main() {
  console.log("=== AWR vs Playwright (Chromium) — COLD COMPARISON ===\n");
  console.log("Both run with a fresh process per iteration.");
  console.log("3 runs each, reporting min/avg/max\n");

  const results = [];

  for (const u of urls) {
    console.log(`--- ${u.label} ---`);

    console.log("Running AWR...");
    const awr = runAwr(u.url);

    console.log("Running Playwright (cold per run)...");
    const pw = await runPlaywrightCold(u.url);

    console.log(`
AWR:
  Total: ${awr.min.toFixed(0)}ms (min) / ${awr.avg.toFixed(0)}ms (avg) / ${awr.max.toFixed(0)}ms (max)

Playwright cold:
  DOMContentLoaded: ${pw.dom.min.toFixed(0)}ms / ${pw.dom.avg.toFixed(0)}ms / ${pw.dom.max.toFixed(0)}ms
  textContent:      ${pw.text.min.toFixed(0)}ms / ${pw.text.avg.toFixed(0)}ms / ${pw.text.max.toFixed(0)}ms
  Combined (DOM+text): ${(pw.dom.min + pw.text.min).toFixed(0)}ms / ${(pw.dom.avg + pw.text.avg).toFixed(0)}ms / ${(pw.dom.max + pw.text.max).toFixed(0)}ms
`);

    results.push({
      label: u.label,
      awr: awr.avg,
      pw_combined: pw.dom.avg + pw.text.avg,
    });
  }

  console.log("Summary:");
  console.log("URL          | AWR avg   | PW cold   | AWR/PW");
  console.log("             | (ms)      | DOM+Tx ms | ratio");
  console.log("-------------+-----------+-----------+-------");
  for (const r of results) {
    const ratio = r.awr / r.pw_combined;
    console.log(`${r.label.padEnd(12)} | ${r.awr.toFixed(0).padStart(9)} | ${r.pw_combined.toFixed(0).padStart(9)} | ${ratio.toFixed(2)}x`);
  }
  console.log("\nNote: each iteration pays full process startup + cold network.");
  console.log("bench-final.mjs lets Chrome reuse one process across iterations,");
  console.log("which produces artificially fast Chrome numbers.");
}

main().catch((err) => { console.error(err); process.exit(1); });
