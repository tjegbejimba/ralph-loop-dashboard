// Tests for run-options module — validates and returns run configuration

import { test } from "node:test";
import assert from "node:assert/strict";
import { getRunOptions, validateRunMode, validateParallelism, validateModel } from "../extension/lib/run-options.mjs";

test("getRunOptions returns safe defaults when no user config provided", () => {
  const result = getRunOptions({});
  
  assert.equal(result.runMode, "one-pass");
  assert.equal(result.parallelism, 1);
  assert.equal(result.model, "claude-sonnet-4.5");
});

test("getRunOptions uses defaults from user config when available", () => {
  const userConfig = {
    defaultModel: "gpt-5.4",
    defaultParallelism: 3,
  };
  
  const result = getRunOptions({ userConfig });
  
  assert.equal(result.runMode, "one-pass"); // No run mode in user config
  assert.equal(result.parallelism, 3);
  assert.equal(result.model, "gpt-5.4");
});

test("validateRunMode accepts 'one-pass'", () => {
  const result = validateRunMode("one-pass");
  
  assert.equal(result.valid, true);
  assert.equal(result.error, undefined);
});

test("validateRunMode accepts 'until-empty'", () => {
  const result = validateRunMode("until-empty");
  
  assert.equal(result.valid, true);
  assert.equal(result.error, undefined);
});

test("validateRunMode rejects invalid mode", () => {
  const result = validateRunMode("invalid-mode");
  
  assert.equal(result.valid, false);
  assert.match(result.error, /must be 'one-pass' or 'until-empty'/);
});

test("validateParallelism accepts positive integers", () => {
  const result = validateParallelism(3);
  
  assert.equal(result.valid, true);
  assert.equal(result.error, undefined);
});

test("validateParallelism rejects zero", () => {
  const result = validateParallelism(0);
  
  assert.equal(result.valid, false);
  assert.match(result.error, /must be at least 1/);
});

test("validateParallelism rejects negative numbers", () => {
  const result = validateParallelism(-1);
  
  assert.equal(result.valid, false);
  assert.match(result.error, /must be at least 1/);
});

test("validateParallelism enforces maximum bound", () => {
  const result = validateParallelism(11);
  
  assert.equal(result.valid, false);
  assert.match(result.error, /must be at most 10/);
});

test("validateModel accepts known model names", () => {
  const models = ["claude-sonnet-4.5", "gpt-5.4", "claude-opus-4.7", "gpt-5.5"];
  
  for (const model of models) {
    const result = validateModel(model);
    assert.equal(result.valid, true, `${model} should be valid`);
    assert.equal(result.error, undefined);
  }
});

test("validateModel rejects empty string", () => {
  const result = validateModel("");
  
  assert.equal(result.valid, false);
  assert.match(result.error, /cannot be empty/);
});

test("validateModel rejects unknown model", () => {
  const result = validateModel("foobar-model");
  
  assert.equal(result.valid, false);
  assert.match(result.error, /unknown model/i);
});
