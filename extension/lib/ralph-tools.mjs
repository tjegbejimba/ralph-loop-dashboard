// Agent-facing Ralph tools and mode-aware permission helpers.

export const RALPH_START_TOOL_NAME = "ralph_dashboard_start";

export function createRalphStartTool({ startLoop }) {
  if (typeof startLoop !== "function") {
    throw new TypeError("startLoop is required");
  }

  return {
    name: RALPH_START_TOOL_NAME,
    description:
      "Start the Ralph loop after running Ralph preflight. Autopilot agents may use this when given issueNumbers or a queue.",
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
            "Optional run configuration. Missing fields use the user's Ralph dashboard defaults.",
          properties: {
            runMode: { type: "string", enum: ["one-pass", "until-empty"] },
            parallelism: { type: "integer", minimum: 1, maximum: 10 },
            model: { type: "string" },
          },
        },
      },
    },
    handler: async (args = {}) => {
      try {
        const result = await startLoop(args);
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

export function createAutopilotStartPermissionHook({ getMode }) {
  if (typeof getMode !== "function") {
    throw new TypeError("getMode is required");
  }

  return (input) => {
    if (input?.toolName !== RALPH_START_TOOL_NAME) return undefined;
    if (getMode() !== "autopilot") return undefined;

    return {
      permissionDecision: "allow",
      permissionDecisionReason: "Autopilot agents may start Ralph after Ralph preflight passes.",
    };
  };
}
