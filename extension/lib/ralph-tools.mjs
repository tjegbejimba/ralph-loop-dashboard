// Agent-facing Ralph tools and mode-aware permission helpers.

export const RALPH_ORCHESTRATE_TOOL_NAME = "ralph_dashboard_orchestrate";

export function createRalphOrchestrationTool({ orchestrateRun }) {
  if (typeof orchestrateRun !== "function") {
    throw new TypeError("orchestrateRun is required");
  }

  return {
    name: RALPH_ORCHESTRATE_TOOL_NAME,
    description:
      "Orchestrate a gated Ralph run: preflight, create a durable queue run, launch workers, and optionally verify status.json until terminal.",
    parameters: {
      type: "object",
      properties: {
        issueNumbers: {
          type: "array",
          description:
            "Issue numbers to run. Use this for agent-initiated launches when the dashboard queue is not available.",
          items: { type: "integer", minimum: 1 },
        },
        queue: {
          type: "array",
          description:
            "Optional full queue items from the dashboard. If provided, each item must include number and may include title, labels, milestone, and url.",
          items: {
            type: "object",
            properties: {
              number: { type: "integer", minimum: 1 },
              title: { type: "string" },
              url: { type: "string" },
              labels: {
                type: "array",
                items: { type: "string" },
              },
              milestone: {},
            },
            required: ["number"],
          },
        },
        runOptions: {
          type: "object",
          description:
            "Optional run configuration. Missing fields use the user's Ralph dashboard defaults; agent launches default to until-empty.",
          properties: {
            runMode: { type: "string", enum: ["one-pass", "until-empty"] },
            parallelism: { type: "integer", minimum: 1, maximum: 10 },
            model: { type: "string" },
          },
        },
        verify: {
          type: "boolean",
          description: "When true or omitted, poll the run status until all queue items are terminal or timeout.",
        },
        timeoutMinutes: {
          type: "number",
          minimum: 0,
          description: "Maximum minutes to wait for verification. Defaults to the orchestration timeout.",
        },
      },
    },
    handler: async (args = {}) => {
      try {
        const result = await orchestrateRun(args);
        const textResultForLlm = JSON.stringify(result);
        if (result.ok) {
          return { resultType: "success", textResultForLlm };
        }
        return {
          resultType: "failure",
          textResultForLlm,
          error: result.error || "Ralph loop start failed.",
        };
      } catch (err) {
        const error = String(err.message || err);
        return {
          resultType: "failure",
          textResultForLlm: JSON.stringify({ ok: false, error }),
          error,
        };
      }
    },
  };
}

function modeFromEvent(event) {
  if (event?.type === "session.mode_changed") {
    return event.data?.newMode || null;
  }
  if (event?.type === "user.message") {
    const mode = event.data?.agentMode;
    return mode === "shell" ? null : mode || null;
  }
  return null;
}

export function inferSessionMode(events = [], fallback = null) {
  let mode = fallback;
  for (const event of events) {
    mode = modeFromEvent(event) || mode;
  }
  return mode;
}

export function createAutopilotOrchestrationPermissionHook({ getMode }) {
  if (typeof getMode !== "function") {
    throw new TypeError("getMode is required");
  }

  return (input) => {
    if (input?.toolName !== RALPH_ORCHESTRATE_TOOL_NAME) return undefined;
    if (getMode() !== "autopilot") return undefined;

    return {
      permissionDecision: "allow",
      permissionDecisionReason: "Autopilot agents may orchestrate Ralph only when allowAgentLaunch is enabled.",
    };
  };
}
