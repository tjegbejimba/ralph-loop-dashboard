// User config persistence module — loads and saves dashboard defaults outside project repos.

import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// Default config values when file is missing or fields are invalid
const DEFAULTS = {
  defaultRepoRoot: null,
  defaultIssueSearch: null,
  defaultModel: null,
  defaultParallelism: null,
  recentQueries: [],
};

// Allowed config fields (whitelist to prevent secrets)
const ALLOWED_FIELDS = new Set(Object.keys(DEFAULTS));

/**
 * Load user config from ~/.ralph-dashboard/config.json
 * 
 * @param {Object} options
 * @param {string} [options.configDir] - Override config directory (for testing)
 * @returns {Object} Result
 * @returns {Object} .config - User config with defaults filled in
 * @returns {Array<Object>} .warnings - Array of validation warnings
 */
export function loadUserConfig({ configDir } = {}) {
  const warnings = [];
  const dir = configDir || join(homedir(), ".ralph-dashboard");
  const configPath = join(dir, "config.json");
  
  // Return defaults if config file doesn't exist
  if (!existsSync(configPath)) {
    return { config: { ...DEFAULTS }, warnings };
  }
  
  // Try to read and parse config file
  try {
    const content = readFileSync(configPath, "utf8");
    const loaded = JSON.parse(content);
    
    // Validate: only allow known fields (prevent secrets)
    const config = { ...DEFAULTS };
    for (const [key, value] of Object.entries(loaded)) {
      if (ALLOWED_FIELDS.has(key)) {
        config[key] = value;
      } else {
        warnings.push({
          field: key,
          message: `Unknown field '${key}' ignored (only allowed: ${Array.from(ALLOWED_FIELDS).join(", ")})`,
          value,
        });
      }
    }
    
    return { config, warnings };
  } catch (err) {
    // If read/parse fails, return defaults with warning
    warnings.push({
      field: "config.json",
      message: `Failed to load config: ${err.message}`,
      value: null,
    });
    return { config: { ...DEFAULTS }, warnings };
  }
}

/**
 * Save user config to ~/.ralph-dashboard/config.json atomically
 * 
 * @param {Object} config - Config object to save
 * @param {Object} options
 * @param {string} [options.configDir] - Override config directory (for testing)
 * @returns {Object} Result
 * @returns {Array<Object>} .warnings - Array of validation warnings
 */
export function saveUserConfig(config, { configDir } = {}) {
  const warnings = [];
  const dir = configDir || join(homedir(), ".ralph-dashboard");
  const configPath = join(dir, "config.json");
  const tmpPath = configPath + ".tmp";
  
  // Filter config to only allowed fields (prevent secrets)
  const filtered = {};
  for (const [key, value] of Object.entries(config)) {
    if (ALLOWED_FIELDS.has(key)) {
      filtered[key] = value;
    } else {
      warnings.push({
        field: key,
        message: `Unknown field '${key}' not saved (only allowed: ${Array.from(ALLOWED_FIELDS).join(", ")})`,
        value,
      });
    }
  }
  
  try {
    // Create directory if it doesn't exist
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    
    // Atomic write: write to temp file, then rename
    writeFileSync(tmpPath, JSON.stringify(filtered, null, 2) + "\n", "utf8");
    renameSync(tmpPath, configPath);
    
    return { warnings };
  } catch (err) {
    warnings.push({
      field: "config.json",
      message: `Failed to save config: ${err.message}`,
      value: null,
    });
    return { warnings };
  }
}

/**
 * Add a recent query to the config (dedupe, keep last N)
 * 
 * @param {string} query - Query to add
 * @param {Object} options
 * @param {string} [options.configDir] - Override config directory (for testing)
 * @param {number} [options.maxRecent=10] - Max number of recent queries to keep
 * @returns {Object} Result with config and warnings
 */
export function addRecentQuery(query, { configDir, maxRecent = 10 } = {}) {
  const { config, warnings: loadWarnings } = loadUserConfig({ configDir });
  
  // Dedupe: remove existing occurrence of this query (case-sensitive)
  const recentQueries = config.recentQueries.filter(q => q !== query);
  
  // Add to front
  recentQueries.unshift(query);
  
  // Keep only last N
  config.recentQueries = recentQueries.slice(0, maxRecent);
  
  // Save
  const { warnings: saveWarnings } = saveUserConfig(config, { configDir });
  
  return { config, warnings: [...loadWarnings, ...saveWarnings] };
}

/**
 * Get query presets (built-in + recent)
 * 
 * @param {Object} options
 * @param {string} [options.configDir] - Override config directory (for testing)
 * @returns {Object} Result
 * @returns {Array<Object>} .presets - Array of { label, query }
 * @returns {Array<Object>} .warnings - Warnings from loading config
 */
export function getPresets({ configDir } = {}) {
  const { config, warnings } = loadUserConfig({ configDir });
  
  const presets = [];
  
  // Built-in: Slice N preset
  presets.push({
    label: "Slice N (numbered issues)",
    query: "is:open sort:created-asc",
  });
  
  // Recent queries
  for (const query of config.recentQueries) {
    presets.push({
      label: query.length > 50 ? query.slice(0, 47) + "..." : query,
      query,
    });
  }
  
  return { presets, warnings };
}
