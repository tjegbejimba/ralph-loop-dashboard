// Ralph extension tool tests — validates agent-facing start behavior.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  RALPH_ORCHESTRATE_TOOL_NAME,
  createRalphOrchestrationTool,
  createAutopilotOrchestrationPermissionHook,
  inferSessionMode,
} from "../extension/lib/ralph-tools.mjs";

test("ralph orchestration tool calls the gated orchestrator and returns JSON for the agent", async () => {
  const tool = createRalphOrchestrationTool({
    orchestrateRun: async (args) => ({ ok: true, runId: "run-1", pid: 1234, received: args }),
  });

  assert.equal(tool.name, RALPH_ORCHESTRATE_TOOL_NAME);
  assert.equal(tool.skipPermission, undefined);

  const result = await tool.handler({ issueNumbers: [42], verify: true }, { toolName: tool.name });
  assert.equal(result.resultType, "success");
  const parsed = JSON.parse(result.textResultForLlm);
  assert.deepEqual(parsed.received, { issueNumbers: [42], verify: true });
});

test("ralph orchestration tool reports launch failures as failed tool results", async () => {
  const tool = createRalphOrchestrationTool({
    orchestrateRun: async () => ({ ok: false, error: "Preflight failed." }),
  });

  const result = await tool.handler({ issueNumbers: [42] }, { toolName: tool.name });
  assert.equal(result.resultType, "failure");
  assert.equal(result.error, "Preflight failed.");
  assert.match(result.textResultForLlm, /Preflight failed/);
});

test("autopilot permission hook allows only the Ralph orchestration tool in autopilot mode", () => {
  const hook = createAutopilotOrchestrationPermissionHook({ getMode: () => "autopilot" });

  assert.deepEqual(
    hook({ toolName: RALPH_ORCHESTRATE_TOOL_NAME }),
    {
      permissionDecision: "allow",
      permissionDecisionReason: "Autopilot agents may orchestrate Ralph only when allowAgentLaunch is enabled.",
    },
  );
  assert.equal(hook({ toolName: "ralph_dashboard_eval" }), undefined);
});

test("autopilot permission hook leaves non-autopilot starts on the default permission path", () => {
  const hook = createAutopilotOrchestrationPermissionHook({ getMode: () => "interactive" });

  assert.equal(hook({ toolName: RALPH_ORCHESTRATE_TOOL_NAME }), undefined);
});

test("inferSessionMode tracks mode changes and user-message agent mode", () => {
  assert.equal(inferSessionMode([], "interactive"), "interactive");
  assert.equal(
    inferSessionMode([
      { type: "user.message", data: { agentMode: "plan" } },
      { type: "session.mode_changed", data: { newMode: "autopilot" } },
    ]),
    "autopilot",
  );
  assert.equal(
    inferSessionMode([
      { type: "session.mode_changed", data: { newMode: "interactive" } },
      { type: "user.message", data: { agentMode: "autopilot" } },
    ]),
    "autopilot",
  );
});
