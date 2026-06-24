/**
 * Parse structured fields from GitHub issue form body.
 * Returns normalized field values or null if field is missing/empty.
 *
 * @param {string} body - The issue body text
 * @returns {{
 *   priority: string | null,
 *   automationSafety: string | null,
 *   workType: string | null,
 *   parentPrd: number | null
 * }}
 */
export function parseFormFields(body) {
  if (!body || typeof body !== "string") {
    return {
      priority: null,
      automationSafety: null,
      workType: null,
      parentPrd: null,
    };
  }

  return {
    priority: extractPriority(body),
    automationSafety: extractAutomationSafety(body),
    workType: extractWorkType(body),
    parentPrd: extractParentPrd(body),
  };
}

/**
 * Extract and normalize priority field (P0-P3).
 * Matches headings like "### Priority" followed by "P0 - Critical", "P1 - High", etc.
 */
function extractPriority(body) {
  const match = body.match(/###\s+Priority\s+([^\n]+)/i);
  if (!match) return null;

  const value = match[1].trim();
  // Extract P0-P3 from strings like "P1 - High" or "P0 - Critical (stop-the-line)"
  const priorityMatch = value.match(/\b(P[0-3])\b/i);
  return priorityMatch ? priorityMatch[1].toUpperCase() : null;
}

/**
 * Extract and normalize automation safety field.
 * Returns lowercase normalized values: "safe after prep", "needs human judgment", "not safe"
 */
function extractAutomationSafety(body) {
  const match = body.match(/###\s+Automation Safety\s+([^\n]+)/i);
  if (!match) return null;

  const value = match[1].trim().toLowerCase();
  // Normalize to canonical values
  if (value.includes("safe after prep")) return "safe after prep";
  if (value.includes("needs human judgment") || value.includes("human")) return "needs human judgment";
  if (value.includes("not safe")) return "not safe";
  return null;
}

/**
 * Extract and normalize work type field.
 * Returns lowercase normalized values: "standalone work", "part of a prd", "new prd parent"
 */
function extractWorkType(body) {
  const match = body.match(/###\s+Work Type\s+([^\n]+)/i);
  if (!match) return null;

  const value = match[1].trim().toLowerCase();
  // Normalize to canonical values
  if (value.includes("standalone")) return "standalone work";
  if (value.includes("part of") && value.includes("prd")) return "part of a prd";
  if (value.includes("new") && value.includes("prd")) return "new prd parent";
  return null;
}

/**
 * Extract parent PRD number.
 * Returns a number or null if field is missing/empty/"_No response_"
 */
function extractParentPrd(body) {
  const match = body.match(/###\s+Parent PRD Number[^\n]*\n+([^\n]+)/i);
  if (!match) return null;

  const value = match[1].trim();
  // Handle GitHub's "_No response_" placeholder
  if (value === "_No response_" || value === "") return null;

  const num = parseInt(value, 10);
  return isNaN(num) ? null : num;
}
