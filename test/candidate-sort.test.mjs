// Regression tests for the candidate-sort jq pipeline in ralph/ralph.sh.
//
// The pipeline maps each open issue to a sort key `n` so candidates are
// processed slice-number-ascending. Historically it used:
//
//   . + {n: (.title | capture(env.TITLE_NUM_RE).x | tonumber)}
//
// which silently dropped the entire candidate list whenever any single issue's
// title didn't match TITLE_NUM_RE — `capture(...)` would error, `set -e+pipefail`
// in the caller would propagate the failure, and jq returned nothing. The
// worker then printed `no eligible issue (remaining=N)` forever even though
// the issues passed the title regex.
//
// The fixed pipeline uses try-style operators and falls back to the issue's
// GitHub number when title-based ordering is unavailable.

import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const PIPELINE = `
[ .[]
  | select(.title | test(env.TITLE_REGEX))
  | . + {n: ((.title | capture(env.TITLE_NUM_RE)? | .x? | tonumber?) // .number)} ]
| sort_by(.n)
| .[] | .number
`;

function runCandidateSort({ issues, titleRegex = ".", titleNumRe = "(?<x>[0-9]+)" }) {
  const r = spawnSync(
    "jq",
    ["-r", PIPELINE],
    {
      input: JSON.stringify(issues),
      env: {
        ...process.env,
        TITLE_REGEX: titleRegex,
        TITLE_NUM_RE: titleNumRe,
      },
      encoding: "utf8",
    },
  );
  return {
    status: r.status,
    stderr: r.stderr,
    numbers: r.stdout.trim() === "" ? [] : r.stdout.trim().split("\n").map(Number),
  };
}

test("candidate jq sorts by captured slice number when titles have digits", () => {
  const r = runCandidateSort({
    issues: [
      { number: 100, title: "Slice 5: foo", body: "" },
      { number: 101, title: "Slice 1: bar", body: "" },
      { number: 102, title: "Slice 3: baz", body: "" },
    ],
    titleNumRe: "Slice (?<x>[0-9]+):",
  });
  assert.equal(r.status, 0, r.stderr);
  // Sort by captured slice number 1, 3, 5 → issues 101, 102, 100.
  assert.deepEqual(r.numbers, [101, 102, 100]);
});

test("candidate jq falls back to issue number when title has no digits", () => {
  const r = runCandidateSort({
    issues: [
      { number: 200, title: "Health alert routing by failure shape", body: "" },
      { number: 201, title: "Settings page (admin)", body: "" },
    ],
    titleNumRe: "(?<x>[0-9]+)",
  });
  assert.equal(r.status, 0, r.stderr);
  // Title "Settings page (admin)" has no digits, "Health alert..." has none.
  // Both fall back to .number, sort ascending: 200, 201.
  assert.deepEqual(r.numbers, [200, 201]);
});

test("candidate jq does NOT drop the whole list when one issue's title lacks digits", () => {
  // The bug: previously this returned [] because the no-digit issue made jq
  // error out, killing the whole pipeline.
  const r = runCandidateSort({
    issues: [
      { number: 50, title: "Slice 7: thing", body: "" },
      { number: 51, title: "no digits at all", body: "" },
      { number: 52, title: "Slice 2: other", body: "" },
    ],
    titleNumRe: "Slice (?<x>[0-9]+):",
  });
  assert.equal(r.status, 0, r.stderr);
  // Issues 50→7, 52→2, 51→fallback to its number 51. Sorted: 2, 7, 51 → 52, 50, 51.
  assert.deepEqual(r.numbers, [52, 50, 51]);
});

test("candidate jq applies title regex filter before sorting", () => {
  const r = runCandidateSort({
    issues: [
      { number: 1, title: "Slice 1: keep", body: "" },
      { number: 2, title: "Other: drop", body: "" },
      { number: 3, title: "Slice 2: keep", body: "" },
    ],
    titleRegex: "^Slice ",
    titleNumRe: "Slice (?<x>[0-9]+):",
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.numbers, [1, 3]);
});

test("candidate jq returns empty array when no issues match title regex", () => {
  const r = runCandidateSort({
    issues: [{ number: 9, title: "Other thing", body: "" }],
    titleRegex: "^Slice ",
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.numbers, []);
});
