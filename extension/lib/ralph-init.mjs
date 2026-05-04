// Ralph initialization service — prepares a repo with .ralph/ setup.

import { existsSync, mkdirSync, readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RALPH_SOURCE = join(__dirname, "..", "..", "ralph");

/**
 * Initialize Ralph in a target repository.
 * Creates .ralph/ directory structure with scripts, config, and templates.
 * 
 * @param {string} repoRoot - Path to repository root
 * @returns {Object} Initialization result
 * @returns {boolean} .success - Whether initialization succeeded
 * @returns {string[]} .created - List of created files/directories
 * @returns {string[]} .skipped - List of skipped files (already exist)
 * @returns {string} .error - Error message if failed
 */
export function initializeRalph(repoRoot) {
  const ralphDir = join(repoRoot, ".ralph");
  const created = [];
  const skipped = [];
  
  try {
    // Create .ralph/ directory
    if (!existsSync(ralphDir)) {
      mkdirSync(ralphDir, { recursive: true });
      created.push(".ralph");
    }
    
    // Copy RALPH.md template
    const ralphMd = join(ralphDir, "RALPH.md");
    if (existsSync(ralphMd)) {
      skipped.push(".ralph/RALPH.md");
    } else {
      const template = readFileSync(join(RALPH_SOURCE, "RALPH.md.template"), "utf-8");
      writeFileSync(ralphMd, template);
      created.push(".ralph/RALPH.md");
    }
    
    // Create config.json with generic profile
    const configPath = join(ralphDir, "config.json");
    if (existsSync(configPath)) {
      skipped.push(".ralph/config.json");
    } else {
      const config = {
        profile: "generic",
        repo: "{{REPO}}",
        prdReference: "#7"
      };
      writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
      created.push(".ralph/config.json");
    }
    
    // Copy shell scripts
    const scripts = ["ralph.sh", "launch.sh"];
    for (const script of scripts) {
      const dest = join(ralphDir, script);
      if (existsSync(dest)) {
        skipped.push(`.ralph/${script}`);
      } else {
        copyFileSync(join(RALPH_SOURCE, script), dest);
        created.push(`.ralph/${script}`);
      }
    }
    
    // Create lib/ directory and copy state.sh
    const libDir = join(ralphDir, "lib");
    if (!existsSync(libDir)) {
      mkdirSync(libDir);
      created.push(".ralph/lib");
    }
    
    const stateSh = join(libDir, "state.sh");
    if (existsSync(stateSh)) {
      skipped.push(".ralph/lib/state.sh");
    } else {
      copyFileSync(join(RALPH_SOURCE, "lib", "state.sh"), stateSh);
      created.push(".ralph/lib/state.sh");
    }
    
    // Create profiles/ directory and copy default profiles
    const profilesDir = join(ralphDir, "profiles");
    if (!existsSync(profilesDir)) {
      mkdirSync(profilesDir);
      created.push(".ralph/profiles");
    }
    
    const profiles = ["generic.json", "bun.json", "python.json"];
    for (const profile of profiles) {
      const dest = join(profilesDir, profile);
      if (existsSync(dest)) {
        skipped.push(`.ralph/profiles/${profile}`);
      } else {
        copyFileSync(join(RALPH_SOURCE, "profiles", profile), dest);
        created.push(`.ralph/profiles/${profile}`);
      }
    }
    
    // Create .gitignore for runtime artifacts
    const gitignorePath = join(ralphDir, ".gitignore");
    if (existsSync(gitignorePath)) {
      skipped.push(".ralph/.gitignore");
    } else {
      const gitignoreContent = `# Ralph runtime artifacts
logs/
locks/
state/
runs/
`;
      writeFileSync(gitignorePath, gitignoreContent);
      created.push(".ralph/.gitignore");
    }
    
    return {
      success: true,
      created,
      skipped,
    };
  } catch (error) {
    return {
      success: false,
      created,
      skipped,
      error: error.message,
    };
  }
}
