// Run after build.sh; validates the actual JS → Swift state boundary.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createActivity, createReplies, processStart, publish } from "../core.mjs";
const binary = process.env.PI_PANEL_BINARY || fileURLToPath(new URL("../.build/Pi Sessions.app/Contents/MacOS/PiSessions", import.meta.url));
const directory = mkdtempSync(join(tmpdir(), "pi-native-wire-"));
try {
  const activity = createActivity();
  const replies = createReplies();
  replies.message({ role: "assistant", content: [{ type: "thinking", thinking: "private" },
    { type: "text", text: "**Ready**: http://localhost:3000/review" }] });
  const base = { version: 1, pid: process.pid, processStart: processStart(process.pid), runtimeId: randomUUID(),
    sessionId: randomUUID(), cwd: "/tmp/project", changedAt: Date.now(), task: "Check compatibility", tty: "", tmux: null,
    sessionFile: "/tmp/session.jsonl", ...replies.snapshot() };
  const roundTrip = () => {
    const state = { ...base, ...activity.snapshot() };
    publish(state, directory);
    return JSON.parse(execFileSync(binary, ["--validate-state", join(directory, `${process.pid}.json`)], { encoding: "utf8" }));
  };
  activity.event("agent_start");
  activity.event("ui_prompt_start", { title: "Approve?" });
  const attention = roundTrip();
  assert.equal(attention.attention.id, activity.snapshot().attention.id);
  assert.equal(attention.lastReply, "Ready: http://localhost:3000/review");
  assert.deepEqual(attention.links, ["http://localhost:3000/review"]);
  activity.event("ui_prompt_end");
  activity.event("agent_before_settle", { outcome: "completed" });
  activity.event("agent_settled");
  const settled = roundTrip();
  assert.equal(settled.lastSettled.id, activity.snapshot().lastSettled.id);
  assert.equal(settled.lastSettled.outcome, "completed");
  assert.equal(settled.sessionFile, base.sessionFile);
  assert.equal(settled.runtimeId, base.runtimeId);
  console.log("JS → Swift wire integration passed");
} finally { rmSync(directory, { recursive: true, force: true }); }
