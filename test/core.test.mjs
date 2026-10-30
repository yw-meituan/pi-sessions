import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { archive, createActivity, createReplies, extractLinks, localLink, publish, readSessions, removeOwned } from "../core.mjs";

const state = (overrides = {}) => ({
  version: 1, pid: 1234, processStart: "Thu Oct 29 10:00:00 2026", runtimeId: randomUUID(),
  sessionId: "test-session", cwd: "/tmp/project", status: "idle", activity: "等待输入", changedAt: Date.now(), ...overrides,
});

test("automatic continuation stays busy; overlapping tools cannot hide a prompt", () => {
  const a = createActivity();
  a.event("agent_start");
  a.event("tool_execution_start", { toolCallId: "a", toolName: "bash" });
  a.event("tool_execution_start", { toolCallId: "b", toolName: "read" });
  a.event("ui_prompt_start", { title: "确认操作" });
  assert.equal(a.event("tool_execution_end", { toolCallId: "a" }).status, "attention");
  assert.match(a.event("ui_prompt_end").activity, /read/);
  a.event("tool_execution_end", { toolCallId: "b" });
  assert.equal(a.event("agent_end").status, "busy");
  assert.equal(a.event("agent_before_settle", { outcome: "completed", continue: true }).status, "busy");
  assert.equal(a.event("agent_settled").status, "idle");
  a.event("agent_start");
  assert.equal(a.event("agent_settled", { aborted: true }).activity, "Stopped");
});

test("manual compaction and idle UI prompts return to idle", () => {
  const a = createActivity();
  assert.equal(a.event("session_before_compact").status, "busy");
  assert.equal(a.event("session_compact_failed").status, "idle");
  a.event("ui_prompt_start");
  assert.equal(a.event("ui_prompt_end").status, "idle");
});

test("state ownership, corruption, exited processes and reused PIDs", () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-panel-test-"));
  try {
    const s = state();
    publish(s, dir);
    assert.equal(statSync(join(dir, "1234.json")).mode & 0o777, 0o600);
    assert.equal(readSessions(dir, () => s.processStart).length, 1);
    assert.equal(readSessions(dir, () => "another process start").length, 0);
    assert.equal(readSessions(dir, () => { throw new Error("gone"); }).length, 0);
    const replacement = { ...s, runtimeId: randomUUID(), sessionId: "resumed" };
    publish(replacement, dir);
    removeOwned(s.pid, s.runtimeId, dir);
    assert.equal(JSON.parse(readFileSync(join(dir, "1234.json"))).sessionId, "resumed");
    writeFileSync(join(dir, "999.json"), "broken json");
    assert.equal(readSessions(dir, () => s.processStart).length, 1);
    removeOwned(replacement.pid, replacement.runtimeId, dir);
    assert.equal(readSessions(dir, () => s.processStart).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});


test("only final settlement emits a notification identity, including retries and aborts", () => {
  const a = createActivity();
  assert.equal(a.snapshot().lastSettled, undefined);
  assert.equal(a.snapshot().runStartedAt, undefined);
  assert.equal(a.snapshot().attention, null);
  a.event("before_agent_start");
  const started = a.snapshot().runStartedAt;
  a.event("agent_start");
  a.event("agent_end");
  a.event("agent_before_settle", { outcome: "error", continue: true });
  a.event("session_before_compact", { willRetry: true });
  a.event("session_compact", { willRetry: true });
  a.event("agent_start");
  assert.equal(a.snapshot().lastSettled, undefined);
  assert.equal(a.snapshot().runStartedAt, started);
  assert.equal(a.snapshot().status, "busy");
  a.event("agent_before_settle", { outcome: "completed" });
  const completed = a.event("agent_settled", { aborted: false }).lastSettled;
  assert.match(completed.id, /^[a-f\d-]{36}$/);
  assert.equal(completed.outcome, "completed");
  assert.ok(completed.at >= started);
  a.event("before_agent_start");
  assert.deepEqual(a.snapshot().lastSettled, completed, "keep the previous settlement while busy");
  a.event("agent_before_settle", { outcome: "error" });
  assert.deepEqual(a.snapshot().lastSettled, completed);
  const error = a.event("agent_settled").lastSettled;
  assert.equal(error.outcome, "error");
  assert.notEqual(error.id, completed.id);
  assert.equal(a.snapshot().activity, "Failed");
  a.event("agent_start");
  a.event("agent_before_settle", { outcome: "completed" });
  assert.equal(a.event("agent_settled", { aborted: true }).lastSettled.outcome, "aborted");
  a.event("agent_start");
  a.event("agent_before_settle", { outcome: "aborted" });
  assert.equal(a.event("agent_settled").lastSettled.outcome, "aborted");
  a.event("agent_start");
  assert.equal(a.event("agent_settled").lastSettled.outcome, "completed", "new runs reset the pending outcome");
});

test("nested attention restores the outer identity; matching end tolerates overlapping prompts", () => {
  const a = createActivity();
  const outer = { kind: "custom", title: "Choose" };
  const inner = { kind: "confirm", title: "Allow?" };
  const first = a.event("ui_prompt_start", outer).attention;
  assert.equal(first.title, outer.title);
  const second = a.event("ui_prompt_start", inner).attention;
  assert.notEqual(first.id, second.id);
  assert.deepEqual(a.event("ui_prompt_end", inner).attention, first);
  assert.equal(a.event("ui_prompt_end", outer).attention, null);
  const third = a.event("ui_prompt_start", outer).attention;
  assert.notEqual(third.id, first.id, "repeated prompt text gets a new identity");
  const fourth = a.event("ui_prompt_start", inner).attention;
  assert.deepEqual(a.event("ui_prompt_end", outer).attention, fourth);
  assert.deepEqual(a.event("ui_prompt_end", outer).attention, fourth, "unmatched end cannot dismiss another prompt");
  assert.equal(a.event("ui_prompt_end", inner).attention, null);
  assert.equal(a.snapshot().status, "idle");
});

test("local links require an explicit port, strict host and a UI rather than API endpoint", () => {
  const accepted = [
    "http://localhost:3000/", "https://app.localhost:8443/ui?x=1#home", "http://127.0.0.1:8080/",
    "http://127.23.255.0:1000/", "http://[::1]:9000/", "http://dev-box.local:5173/",
    "http://localhost:80/", "https://localhost:443/", "http://localhost:3000/a(b)",
  ];
  for (const url of accepted) assert.equal(localLink(url), url, url);
  const rejected = [
    "https://localhost", "http://localhost/ui", "http://localhost:/", "http://localhost:0/", "http://localhost:65536/",
    "http://localhost:3000oops/", "file://localhost:3000/", "ftp://localhost:3000/",
    "http://user@localhost:3000/", "http://user:secret@localhost:3000/", "http://@localhost:3000/",
    "http://localhost:3000@evil.com/", "http://localhost:3000\\@evil.com/", "http://localhost.evil.com:3000/",
    "http://0.0.0.0:3000/", "http://192.168.1.2:3000/", "http://10.0.0.1:3000/", "http://example.com:3000/",
    "http://[::]:3000/", "http://[::ffff:127.0.0.1]:3000/", "http://127.1:3000/", "http://127.0.00.1:3000/",
    "http://2130706433:3000/", "http://0x7f000001:3000/", "http://127.256.0.1:3000/", "http://127.0.0.1.evil:3000/",
    "http://localho\nst:3000/", "http://localhost:3000/\x00bad", "http://localhost:3000/%0a", "http://localhost:3000/?x=%0D",
    "http://localhost:3000/%zz", "http://localhost:3000/%", "http://localhost:3000/%C0%AF", "http://%6cocalhost:3000/",
    "http://localhost.:3000/", "http://-bad.localhost:3000/", "http://localhost:3000/api", "http://localhost:3000/api/v1",
    "http://localhost:3000/GRAPHQL?query=x", "http://localhost:3000/health", "http://localhost:3000/healthz/live",
    "http://localhost:3000/data.json?x=1", "http://localhost:3000/%61pi/v1", "http://localhost:3000/ui/../api",
    "http://localhost:3000/v1/graphql", "http://localhost:3000/a.JSON", `http://localhost:3000/${"x".repeat(2048)}`,
  ];
  for (const url of rejected) assert.equal(localLink(url), undefined, url);
});

test("assistant-only summaries and links handle markdown, quotes, malformed URLs and bounds", () => {
  const r = createReplies();
  const ignored = "SECRET http://localhost:3001/";
  r.message({ role: "user", content: ignored });
  r.message({ role: "toolResult", content: [{ type: "text", text: ignored }] });
  assert.deepEqual(r.snapshot(), { links: [] });
  const result = r.message({ role: "assistant", content: [
    { type: "thinking", thinking: ignored }, { type: "toolCall", name: "bash", arguments: { command: ignored } },
    { type: "text", text: '**Ready**: [Open](http://localhost:3000/). "http://[::1]:5173/ui"\n' +
      "'https://app.localhost:8443/' `http://127.0.0.1:8080/` “http://dev.local:9000/” " +
      "http://localhost:3000/ http://localhost:3000/\x00bad http://127.1:8080/ http://localhost:3000/api" },
  ] });
  assert.ok(result.lastReply.startsWith("Ready: Open."));
  assert.ok(!result.lastReply.includes("SECRET"));
  assert.equal(result.links.length, 5);
  assert.ok(!result.links.some((link) => link.includes(":3001")));
  assert.deepEqual(extractLinks("(http://localhost:3000/a(b)). [App](http://localhost:3000/ui)."),
    ["http://localhost:3000/a(b)", "http://localhost:3000/ui"]);
  r.message({ role: "assistant", content: [{ type: "thinking", thinking: ignored }] });
  assert.deepEqual(r.snapshot(), result, "tool-only/thinking messages do not erase the latest reply");
  for (let i = 0; i < 20; i++) r.message({ role: "assistant", content: `http://localhost:${4000 + i}/` });
  assert.equal(r.snapshot().links.length, 12);
  assert.equal(new Set(r.snapshot().links).size, 12);
  assert.equal(r.snapshot().links.at(-1), "http://localhost:4019/");
  const long = r.message({ role: "assistant", content: "x".repeat(1500) + " http://localhost:5000/" });
  assert.equal(long.lastReply.length, 1000);
  assert.ok(long.links.includes("http://localhost:5000/"), "links are extracted before summary truncation");
  const unicode = r.message({ role: "assistant", content: "x".repeat(999) + "😀" });
  assert.ok(unicode.lastReply.isWellFormed(), "truncation must not split a surrogate pair");
});

test("archives are private, bounded and prune only owned valid UUID records", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-panel-archive-"));
  const dir = join(root, "sessions");
  const exited = join(root, "exited");
  mkdirSync(exited);
  try {
    const old = [];
    for (let i = 0; i < 102; i++) {
      const record = state({ exitedAt: i });
      const path = join(exited, `${record.runtimeId}.json`);
      writeFileSync(path, JSON.stringify(record));
      old.push(path);
    }
    const unrelated = [join(exited, "notes.json"), join(exited, `${randomUUID()}.json`), join(exited, `${randomUUID()}.json`)];
    writeFileSync(unrelated[0], JSON.stringify(state({ exitedAt: -1 })));
    writeFileSync(unrelated[1], JSON.stringify(state({ exitedAt: -1 })));
    writeFileSync(unrelated[2], "not json");
    const target = join(root, "outside.json");
    const linked = state({ exitedAt: -1 });
    writeFileSync(target, JSON.stringify(linked));
    const symlink = join(exited, `${linked.runtimeId}.json`);
    symlinkSync(target, symlink);
    const s = state({ lastReply: "Done", links: ["http://localhost:3000/"], attention: null });
    archive(s, dir, 1000);
    const path = join(exited, `${s.runtimeId}.json`);
    assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { ...s, exitedAt: 1000 });
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.equal(statSync(exited).mode & 0o777, 0o700);
    assert.equal(old.filter(existsSync).length, 99);
    assert.ok(old.slice(0, 3).every((path) => !existsSync(path)), "oldest records were pruned");
    assert.ok(unrelated.every(existsSync));
    assert.ok(lstatSync(symlink).isSymbolicLink());
    assert.ok(existsSync(target));
    assert.ok(readdirSync(exited).every((name) => name.endsWith(".json")), "no temporary files remain");
    assert.throws(() => archive(state({ runtimeId: "../not-owned" }), dir));
    assert.throws(() => archive(state({ lastReply: "x".repeat(128 * 1024) }), dir), /too large/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("archive directory symlinks are rejected rather than followed", () => {
  const root = mkdtempSync(join(tmpdir(), "pi-panel-symlink-"));
  try {
    mkdirSync(join(root, "outside"));
    symlinkSync(join(root, "outside"), join(root, "exited"));
    assert.throws(() => archive(state(), join(root, "sessions")), /Unsafe panel directory/);
    assert.deepEqual(readdirSync(join(root, "outside")), []);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
