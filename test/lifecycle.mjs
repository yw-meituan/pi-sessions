// PI_PACKAGE_DIR points at the installed Pi package; no user sessions/settings are loaded.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

assert.ok(process.env.PI_PACKAGE_DIR, "Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(join(process.env.PI_PACKAGE_DIR, "package.json"));
const { createJiti } = require("jiti");
const home = mkdtempSync(join(tmpdir(), "pi-panel-lifecycle-"));
const originalEnv = { HOME: process.env.HOME, SSH_CONNECTION: process.env.SSH_CONNECTION };
const platform = Object.getOwnPropertyDescriptor(process, "platform");
process.env.HOME = home;
delete process.env.SSH_CONNECTION;
// Exercise macOS-only producer behavior even when the test host is not macOS.
Object.defineProperty(process, "platform", { value: "darwin" });

try {
  const jiti = createJiti(import.meta.url, { fsCache: false });
  const extension = await jiti.import("../index.ts", { default: true });
  const root = join(home, "Library", "Application Support", "PiSessionPanel");
  const dir = join(root, "sessions");
  const exited = join(root, "exited");
  const file = join(dir, `${process.pid}.json`);
  const handlers = new Map();
  const warnings = [];
  let sessionId = "first-session";
  let idle = true;
  const message = (role, content) => ({ type: "message", message: { role, content } });
  let branch = [
    message("user", "Previous task http://localhost:9991/"),
    message("toolResult", [{ type: "text", text: "Secret tool http://localhost:9992/" }]),
    message("assistant", [
      { type: "thinking", thinking: "Secret thinking http://localhost:9993/" },
      { type: "text", text: "**Previous reply** http://localhost:3000/" },
    ]),
    message("assistant", [{ type: "toolCall", name: "bash", arguments: { command: "secret" } }]),
  ];
  const ctx = {
    mode: "tui", cwd: "/tmp/example", isIdle: () => idle, model: { id: "test-model" },
    sessionManager: {
      getSessionId: () => sessionId, getSessionName: () => "My session",
      getSessionFile: () => join(home, `${sessionId}.jsonl`), getBranch: () => branch,
    },
    ui: { notify: (message) => { warnings.push(message); throw new Error("UI failure"); } },
  };
  const fire = async (type, event = {}) => {
    const handler = handlers.get(type);
    if (handler) await handler({ type, ...event }, ctx);
  };
  const read = () => JSON.parse(readFileSync(file, "utf8"));
  const archives = () => existsSync(exited) ? readdirSync(exited) : [];
  const load = () => {
    handlers.clear();
    extension({ on: (name, handler) => handlers.set(name, handler) });
  };
  load();
  assert.ok(!existsSync(root), "factory must not create resources");
  await fire("session_start", { reason: "startup" });
  assert.equal(read().version, 1);
  assert.equal(read().status, "idle");
  assert.equal(read().task, "Previous task http://localhost:9991/");
  assert.equal(read().sessionFile, join(home, `${sessionId}.jsonl`));
  assert.equal(read().lastReply, "Previous reply http://localhost:3000/");
  assert.deepEqual(read().links, ["http://localhost:3000/"]);
  assert.equal(read().lastSettled, undefined, "hydration cannot replay a completion notification");
  assert.equal(read().attention, null, "hydration cannot replay an attention notification");
  assert.equal(read().runStartedAt, undefined);

  await fire("before_agent_start", { messageType: "user", prompt: "Build the panel" });
  await fire("agent_start");
  assert.equal(read().task, "Build the panel");
  assert.ok(Number.isFinite(read().runStartedAt));
  const started = read().runStartedAt;
  const outer = { kind: "custom", title: "Choose" };
  const inner = { kind: "confirm", title: "Allow?" };
  await fire("ui_prompt_start", outer);
  const attention = read().attention;
  assert.equal(read().status, "attention");
  await fire("ui_prompt_start", inner);
  assert.notEqual(read().attention.id, attention.id);
  await fire("ui_prompt_end", inner);
  assert.deepEqual(read().attention, attention);
  await fire("ui_prompt_end", outer);
  assert.equal(read().attention, null);
  await fire("agent_end");
  await fire("agent_before_settle", { outcome: "error", continue: true });
  assert.equal(read().lastSettled, undefined);
  await fire("agent_start");
  assert.equal(read().runStartedAt, started);
  assert.equal(read().status, "busy");
  await fire("message_end", { message: { role: "assistant", content: [
    { type: "text", text: "Ready http://[::1]:5173/" }, { type: "thinking", thinking: "Secret http://localhost:7777/" },
  ] } });
  await fire("message_end", { message: { role: "toolResult", content: [{ type: "text", text: "Output http://localhost:6666/" }] } });
  assert.equal(read().lastReply, "Ready http://[::1]:5173/");
  assert.deepEqual(read().links, ["http://localhost:3000/", "http://[::1]:5173/"]);
  await fire("agent_before_settle", { outcome: "completed" });
  await fire("agent_settled", { aborted: false });
  assert.equal(read().status, "idle");
  const completed = read().lastSettled;
  assert.equal(completed.outcome, "completed");
  await fire("before_agent_start", { messageType: "custom" });
  assert.deepEqual(read().lastSettled, completed);
  assert.equal(read().task, "Build the panel");
  await fire("agent_before_settle", { outcome: "error" });
  await fire("agent_settled", { aborted: false });
  assert.equal(read().lastSettled.outcome, "error");
  assert.notEqual(read().lastSettled.id, completed.id);
  await fire("agent_start");
  await fire("agent_settled", { aborted: true });
  assert.equal(read().lastSettled.outcome, "aborted");

  for (const reason of ["reload", "new", "resume", "fork"]) {
    const oldRuntime = read().runtimeId;
    await fire("session_shutdown", { reason });
    assert.ok(!existsSync(file));
    assert.deepEqual(archives(), [], `${reason} must not archive`);
    if (reason !== "reload") sessionId = `${reason}-session`;
    load();
    assert.ok(!existsSync(file), "replacement factory must not publish");
    await fire("session_start", { reason });
    assert.equal(read().sessionId, sessionId);
    assert.notEqual(read().runtimeId, oldRuntime);
    assert.equal(read().sessionFile, join(home, `${sessionId}.jsonl`));
    assert.equal(read().lastSettled, undefined);
    assert.equal(read().attention, null);
    assert.equal(read().lastReply, "Previous reply http://localhost:3000/");
    assert.deepEqual(read().links, ["http://localhost:3000/"], "only active branch links hydrate");
    assert.equal(readdirSync(dir).length, 1);
  }
  branch = [];
  idle = false;
  await fire("session_start", { reason: "new" });
  assert.equal(read().status, "busy");
  assert.equal(read().lastSettled, undefined);
  assert.equal(read().lastReply, undefined);
  assert.deepEqual(read().links, []);
  assert.equal(read().attention, null);
  assert.equal(read().task, "");
  await fire("agent_before_settle", { outcome: "completed" });
  await fire("agent_settled", { aborted: false });
  const finalState = read();
  const beforeQuit = Date.now();
  await fire("session_shutdown", { reason: "quit" });
  assert.ok(!existsSync(file));
  assert.deepEqual(archives(), [`${finalState.runtimeId}.json`]);
  const archivePath = join(exited, `${finalState.runtimeId}.json`);
  const archived = JSON.parse(readFileSync(archivePath, "utf8"));
  const { exitedAt, ...snapshot } = archived;
  assert.deepEqual(snapshot, finalState);
  assert.ok(exitedAt >= beforeQuit);
  assert.equal(statSync(archivePath).mode & 0o777, 0o600);
  assert.equal(statSync(exited).mode & 0o777, 0o700);
  await fire("session_shutdown", { reason: "quit" });
  assert.deepEqual(archives(), [`${finalState.runtimeId}.json`], "shutdown is idempotent");
  assert.deepEqual(warnings, []);

  for (const mode of ["rpc", "json", "print"]) {
    ctx.mode = mode;
    await fire("session_start");
    await fire("agent_start");
    await fire("agent_settled");
    await fire("session_shutdown", { reason: "quit" });
    assert.ok(!existsSync(file), `${mode} must not publish`);
    assert.equal(archives().length, 1);
  }
  ctx.mode = "tui";
  process.env.SSH_CONNECTION = "test";
  await fire("session_start");
  assert.ok(!existsSync(file), "remote sessions must not appear");
  delete process.env.SSH_CONNECTION;
  Object.defineProperty(process, "platform", { value: "linux" });
  await fire("session_start");
  assert.ok(!existsSync(file), "non-macOS sessions must not appear");
  Object.defineProperty(process, "platform", { value: "darwin" });

  // Both disk and notification failures remain isolated from the agent lifecycle.
  rmSync(dir, { recursive: true });
  writeFileSync(dir, "not a directory");
  await fire("session_start");
  await fire("agent_start");
  await fire("agent_settled");
  assert.equal(warnings.length, 1, "only one warning per runtime");
  await fire("session_shutdown", { reason: "reload" });
  rmSync(dir);
  mkdirSync(dir);
  await fire("session_start");
  rmSync(exited, { recursive: true });
  writeFileSync(exited, "not a directory");
  await fire("session_shutdown", { reason: "quit" });
  assert.ok(!existsSync(file), "failed archive still removes the owned live file");
  assert.equal(warnings.length, 2);
  console.log("Lifecycle integration passed (isolated HOME, installed Pi jiti)");
} finally {
  Object.defineProperty(process, "platform", platform);
  for (const [key, value] of Object.entries(originalEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  rmSync(home, { recursive: true, force: true });
}
