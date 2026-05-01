// Parsing helpers for the Copilot CLI's end-of-iteration token summary.
// Pure functions, no I/O — separate file so they can be unit-tested without
// pulling in the rest of main.mjs (which has session-connect side effects).
//
// Example summary line emitted by `copilot -p`:
//   Tokens    ↑ 8.9m • ↓ 59.5k • 8.6m (cached)
//   Tokens    ↑ 13.6m • ↓ 80.7k • 13.0m (cached) • 2.5k (reasoning)

// Parse Copilot CLI's compact token unit: "8.9m" → 8_900_000, "59.5k" → 59_500,
// "934" → 934. Returns null on garbage input. Case-insensitive on the suffix.
export function parseTokenUnit(s) {
  if (typeof s !== "string") return null;
  const m = s.trim().match(/^([\d.,]+)\s*([kmb]?)$/i);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ""));
  if (!Number.isFinite(n)) return null;
  const mult = { "": 1, k: 1e3, m: 1e6, b: 1e9 }[m[2].toLowerCase()];
  return Math.round(n * mult);
}

// Parse Copilot CLI's end-of-run token summary out of a log body. Returns
// { input, output, cached, reasoning, total } or null when the summary line
// hasn't been written yet (the iteration is still in flight, or the log is
// otherwise unparseable).
export function detectTokens(logBody) {
  if (!logBody) return null;
  const lines = logBody.split("\n");
  // Walk backwards — if a log somehow contains multiple summaries (rare),
  // the most recent one wins.
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!/^Tokens\s/.test(line)) continue;
    const inMatch = line.match(/↑\s*([\d.,]+\s*[kmb]?)/i);
    const outMatch = line.match(/↓\s*([\d.,]+\s*[kmb]?)/i);
    if (!inMatch || !outMatch) continue;
    const cachedMatch = line.match(/•\s*([\d.,]+\s*[kmb]?)\s*\(cached\)/i);
    const reasonMatch = line.match(/•\s*([\d.,]+\s*[kmb]?)\s*\(reasoning\)/i);
    const input = parseTokenUnit(inMatch[1]);
    const output = parseTokenUnit(outMatch[1]);
    if (input == null || output == null) continue;
    const cached = cachedMatch ? parseTokenUnit(cachedMatch[1]) : null;
    const reasoning = reasonMatch ? parseTokenUnit(reasonMatch[1]) : null;
    return { input, output, cached, reasoning, total: input + output };
  }
  return null;
}
