// Unit tests for the Copilot CLI token-summary parser.
// Run via `node --test test/tokens.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseTokenUnit, detectTokens } from "../extension/lib/tokens.mjs";

test("parseTokenUnit — plain integer", () => {
  assert.equal(parseTokenUnit("934"), 934);
  assert.equal(parseTokenUnit("0"), 0);
});

test("parseTokenUnit — 'k' suffix scales by 1e3", () => {
  assert.equal(parseTokenUnit("59.5k"), 59_500);
  assert.equal(parseTokenUnit("3.9k"), 3_900);
  assert.equal(parseTokenUnit("503.3k"), 503_300);
});

test("parseTokenUnit — 'm' suffix scales by 1e6", () => {
  assert.equal(parseTokenUnit("8.9m"), 8_900_000);
  assert.equal(parseTokenUnit("13.6m"), 13_600_000);
});

test("parseTokenUnit — case insensitive on suffix", () => {
  assert.equal(parseTokenUnit("1.3M"), 1_300_000);
  assert.equal(parseTokenUnit("4.5K"), 4_500);
});

test("parseTokenUnit — comma-separated thousands", () => {
  assert.equal(parseTokenUnit("1,234"), 1_234);
});

test("parseTokenUnit — rejects garbage", () => {
  assert.equal(parseTokenUnit(""), null);
  assert.equal(parseTokenUnit("abc"), null);
  assert.equal(parseTokenUnit(null), null);
  assert.equal(parseTokenUnit(undefined), null);
});

test("detectTokens — returns null when log has no summary", () => {
  assert.equal(detectTokens(""), null);
  assert.equal(detectTokens("nothing relevant\nat all\n"), null);
  assert.equal(detectTokens(null), null);
});

test("detectTokens — parses canonical 3-field summary", () => {
  const log = `
some prior log line
Tokens    ↑ 8.9m • ↓ 59.5k • 8.6m (cached)
`;
  const r = detectTokens(log);
  assert.deepEqual(r, {
    input: 8_900_000,
    output: 59_500,
    cached: 8_600_000,
    reasoning: null,
    total: 8_959_500,
  });
});

test("detectTokens — parses 4-field summary with reasoning", () => {
  const log = `Tokens    ↑ 13.6m • ↓ 80.7k • 13.0m (cached) • 2.5k (reasoning)`;
  const r = detectTokens(log);
  assert.deepEqual(r, {
    input: 13_600_000,
    output: 80_700,
    cached: 13_000_000,
    reasoning: 2_500,
    total: 13_680_700,
  });
});

test("detectTokens — handles small (raw integer) reasoning value", () => {
  const log = `Tokens    ↑ 13.3m • ↓ 67.7k • 13.0m (cached) • 934 (reasoning)`;
  const r = detectTokens(log);
  assert.equal(r.reasoning, 934);
});

test("detectTokens — uses last summary if multiple exist", () => {
  const log = `
Tokens    ↑ 1.0m • ↓ 5.0k • 900.0k (cached)
mid-log noise
Tokens    ↑ 2.0m • ↓ 10.0k • 1.8m (cached)
`;
  const r = detectTokens(log);
  assert.equal(r.input, 2_000_000);
  assert.equal(r.output, 10_000);
});

test("detectTokens — sub-million input expressed in k", () => {
  const log = `Tokens    ↑ 503.3k • ↓ 3.3k • 398.7k (cached)`;
  const r = detectTokens(log);
  assert.equal(r.input, 503_300);
  assert.equal(r.output, 3_300);
  assert.equal(r.cached, 398_700);
});

test("detectTokens — ignores look-alike lines without arrows", () => {
  const log = `
Tokens used in this run: lots
Tokens   without the arrows shouldn't match
`;
  assert.equal(detectTokens(log), null);
});
