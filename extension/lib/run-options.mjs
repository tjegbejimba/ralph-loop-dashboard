// Run options module — validates and returns run configuration with safe defaults

// Known valid model names (from parent issue #7 and Copilot CLI docs)
const VALID_MODELS = new Set([
  "claude-sonnet-4.5",
  "claude-sonnet-4.6",
  "claude-opus-4.5",
  "claude-opus-4.6",
  "claude-opus-4.7",
  "claude-haiku-4.5",
  "gpt-5.2",
  "gpt-5.3-codex",
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.5",
  "gpt-4.1",
]);

const DEFAULT_RUN_MODE = "one-pass";
const DEFAULT_PARALLELISM = 1;
const DEFAULT_MODEL = "claude-sonnet-4.5";
const MIN_PARALLELISM = 1;
const MAX_PARALLELISM = 10;

/**
 * Get run options with defaults from user config
 * 
 * @param {Object} options
 * @param {Object} [options.userConfig] - User config with defaults
 * @returns {Object} Run options
 * @returns {string} .runMode - "one-pass" or "until-empty"
 * @returns {number} .parallelism - Number of parallel workers
 * @returns {string} .model - Model name
 */
export function getRunOptions({ userConfig } = {}) {
  const config = userConfig || {};
  
  return {
    runMode: DEFAULT_RUN_MODE, // User config doesn't store run mode
    parallelism: config.defaultParallelism ?? DEFAULT_PARALLELISM,
    model: config.defaultModel ?? DEFAULT_MODEL,
  };
}

/**
 * Validate run mode
 * 
 * @param {string} mode - Run mode to validate
 * @returns {Object} Validation result
 * @returns {boolean} .valid - Whether the mode is valid
 * @returns {string} [.error] - Error message if invalid
 */
export function validateRunMode(mode) {
  if (mode !== "one-pass" && mode !== "until-empty") {
    return {
      valid: false,
      error: "Run mode must be 'one-pass' or 'until-empty'",
    };
  }
  
  return { valid: true };
}

/**
 * Validate parallelism
 * 
 * @param {number} parallelism - Parallelism value to validate
 * @returns {Object} Validation result
 * @returns {boolean} .valid - Whether the value is valid
 * @returns {string} [.error] - Error message if invalid
 */
export function validateParallelism(parallelism) {
  if (!Number.isInteger(parallelism) || parallelism < MIN_PARALLELISM) {
    return {
      valid: false,
      error: `Parallelism must be at least ${MIN_PARALLELISM}`,
    };
  }
  
  if (parallelism > MAX_PARALLELISM) {
    return {
      valid: false,
      error: `Parallelism must be at most ${MAX_PARALLELISM}`,
    };
  }
  
  return { valid: true };
}

/**
 * Validate model name
 * 
 * @param {string} model - Model name to validate
 * @returns {Object} Validation result
 * @returns {boolean} .valid - Whether the model is valid
 * @returns {string} [.error] - Error message if invalid
 */
export function validateModel(model) {
  if (!model || model.trim() === "") {
    return {
      valid: false,
      error: "Model cannot be empty",
    };
  }
  
  if (!VALID_MODELS.has(model)) {
    return {
      valid: false,
      error: `Unknown model '${model}'. Valid models: ${Array.from(VALID_MODELS).join(", ")}`,
    };
  }
  
  return { valid: true };
}
