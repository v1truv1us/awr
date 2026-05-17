/**
 * Post-processing for AWR body_text to make it agent-friendly.
 *
 * AWR's textContentForExtract dumps the entire body as flat text with no
 * structure. This module strips boilerplate, restores paragraph breaks,
 * and removes navigation chrome so agents see content, not layout artifacts.
 */

const BOILERPLATE_LINES = [
  /^jump to content/i,
  /^skip to( content| navigation| main)?/i,
  /^toggle( navigation| sidebar| menu)?/i,
  /^navigation menu/i,
  /^main menu/i,
  /^move to sidebar/i,
  /^hide$/i,
  /^appearance( settings)?$/i,
  /^personal tools$/i,
  /^search$/i,
  /^create account$/i,
  /^log in$/i,
  /^sign in$/i,
  /^sign up$/i,
  /^donate$/i,
  /^subscribe$/i,
  /^cookies?/i,
  /^we use cookies/i,
  /^accept( all)?$/i,
  /^reject( all)?$/i,
  /^manage (preferences|settings|choices)$/i,
  /^your (privacy|cookie|ad) (choices|settings|preferences)/i,
  /^show more$/i,
  /^show less$/i,
  /^read more$/i,
  /^loading\.\.\.$/i,
  /^\d+ comments?$/i,
  /^reply$/i,
  /^share$/i,
  /^report$/i,
  /^save$/i,
  /^follow$/i,
  /^copy( link)?$/i,
];

const BOILERPLATE_BLOCKS = [
  /toggle navigation[\s\S]*?sign in/i,
  /main menu[\s\S]*?hide/i,
  /navigation menu[\s\S]*?(sign in|log in)/i,
  /appearance settings[\s\S]*?(personal tools|create account)/i,
  /we use cookies[\s\S]*?(accept|manage)/i,
];

/**
 * Collapse runs of whitespace into paragraph breaks while preserving
 * intentional single spaces within lines.
 */
function restoreParagraphs(text: string): string {
  const lines = text.split(/\n/);
  const output: string[] = [];
  let inBlank = false;

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.length === 0) {
      if (!inBlank && output.length > 0) {
        output.push("");
        inBlank = true;
      }
      continue;
    }

    output.push(trimmed);
    inBlank = false;
  }

  // Merge short fragments that belong together (< 40 chars, no punctuation)
  const merged: string[] = [];
  for (const line of output) {
    const prev = merged[merged.length - 1];
    if (
      prev !== undefined &&
      prev.length > 0 &&
      prev.length < 60 &&
      !/[.!?]$/.test(prev) &&
      line.length < 60
    ) {
      merged[merged.length - 1] = `${prev} ${line}`;
    } else {
      merged.push(line);
    }
  }

  return merged.join("\n");
}

/**
 * Strip known boilerplate lines.
 */
function stripBoilerplateLines(text: string): string {
  return text
    .split("\n")
    .filter((line) => !BOILERPLATE_LINES.some((pattern) => pattern.test(line.trim())))
    .join("\n");
}

/**
 * Strip known boilerplate blocks (multi-line patterns).
 */
function stripBoilerplateBlocks(text: string): string {
  let result = text;
  for (const block of BOILERPLATE_BLOCKS) {
    result = result.replace(block, " ");
  }
  return result;
}

/**
 * Collapse excessive blank lines to at most one.
 */
function collapseBlankLines(text: string): string {
  return text.replace(/\n{3,}/g, "\n\n").trim();
}

/**
 * Detect if body text is primarily a link list (like HN, Reddit, etc.)
 * and return the cleaned version with line items separated.
 *
 * Handles two cases:
 * 1. Each item on its own line: "1. Title (domain)"
 * 2. All items on a single flat line: "1.Title2.Title3.Title"
 */
function detectLinkList(text: string): string | null {
  // Try splitting flat inline items first (HN-style: "1.Title...2.Title...")
  const inlineItems = splitInlineNumberedItems(text);
  if (inlineItems && inlineItems.length >= 3) {
    return inlineItems.map((item, i) => (i > 0 ? "\n" : "") + item).join("");
  }

  // Fallback: each item on its own line
  const numberedPattern = /^\d+\.\s*\S+/;
  const lines = text.split("\n");
  const itemLines: string[] = [];
  let matchCount = 0;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;

    if (numberedPattern.test(trimmed)) {
      matchCount++;
      if (itemLines.length > 0) {
        itemLines.push("");
      }
      itemLines.push(trimmed);
    } else if (
      matchCount > 0 &&
      /^\d+\s+(points?|comments?|upvotes?)\s/i.test(trimmed)
    ) {
      itemLines.push(`  ${trimmed}`);
    } else if (matchCount > 0 && matchCount < 3) {
      return null;
    }
  }

  if (matchCount >= 3) {
    return itemLines.join("\n");
  }

  return null;
}

/**
 * Split flat text like "1.Title (domain)34 pts2.Title (domain)12 pts"
 * into separate lines.
 */
function splitInlineNumberedItems(text: string): string[] | null {
  // Match numbered items that are jammed together: "1.Title" "2.Title" etc.
  const itemPattern = /(?=\d+\.[A-Za-z(])/g;
  const indices: number[] = [];

  let match: RegExpExecArray | null;
  while ((match = itemPattern.exec(text)) !== null) {
    indices.push(match.index);
    if (indices.length > 100) break; // Safety limit
  }

  if (indices.length < 3) return null;

  // Verify most splits look like real numbered items
  const items = indices.map((start, i) => {
    const end = indices[i + 1];
    return text.slice(start, end).trim();
  });

  const validItems = items.filter((item) => /^\d+\./.test(item));
  if (validItems.length < 3 || validItems.length < items.length * 0.7) {
    return null;
  }

  return validItems;
}

/**
 * Detect and format tabular data (tables with | separators).
 */
function detectTableData(text: string): string | null {
  const lines = text.split("\n").filter((l) => l.trim().length > 0);
  const pipeLines = lines.filter((l) => l.includes("|"));
  if (pipeLines.length < 2) return null;

  // Check if there are enough pipe-delimited lines to be a table
  if (pipeLines.length < lines.length * 0.4) return null;

  return pipeLines.join("\n");
}

/**
 * Main entry point: clean AWR body_text for agent consumption.
 */
export function cleanBodyText(bodyText: string): string {
  if (!bodyText || bodyText.trim().length === 0) {
    return "";
  }

  // First try link list detection on raw text (before stripping)
  const linkList = detectLinkList(bodyText);
  if (linkList) {
    return collapseBlankLines(linkList);
  }

  // Strip boilerplate blocks first, then lines
  let cleaned = stripBoilerplateBlocks(bodyText);
  cleaned = stripBoilerplateLines(cleaned);
  cleaned = restoreParagraphs(cleaned);
  cleaned = collapseBlankLines(cleaned);

  return cleaned;
}

/**
 * Estimate the content-to-chrome ratio.
 * Returns 0-1 where 1 means all content, 0 means all chrome.
 */
export function contentRatio(bodyText: string): number {
  if (!bodyText || bodyText.trim().length === 0) return 0;

  const cleaned = cleanBodyText(bodyText);
  return cleaned.length / bodyText.length;
}
