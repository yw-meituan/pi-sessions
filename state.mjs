import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { chmodSync, closeSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const stateDir = join(homedir(), "Library", "Application Support", "PiSessionPanel", "sessions");
export const run = (file, args, timeout = 4000) => execFileSync(file, args, {
  encoding: "utf8", timeout, maxBuffer: 1024 * 1024,
  env: { ...process.env, LC_ALL: "C" }, stdio: ["ignore", "pipe", "pipe"],
}).trim();
export const processStart = (pid) => run("/bin/ps", ["-p", String(pid), "-o", "lstart="]);
export const text = (value, max = 90) => {
  const source = String(value ?? "").replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
  const spaces = /[\s\x00-\x1f\x7f-\x9f|]+/g;
  let result;
  if (Number.isSafeInteger(max) && max >= 0 && source.length > max) {
    result = "";
    let offset = 0, match;
    while (result.length < max && (match = spaces.exec(source))) {
      result += source.slice(offset, Math.min(match.index, offset + max - result.length));
      if (result.length === max) break;
      // A separator is trailing only if its entire run reaches the input end.
      if (result.length && spaces.lastIndex < source.length) result += " ";
      offset = spaces.lastIndex;
    }
    if (result.length < max) result += source.slice(offset, offset + max - result.length);
  } else {
    result = source.replace(spaces, " ").trim().slice(0, max);
  }
  return result.replace(/[\ud800-\udbff]$/, "");
};

const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;

function privateDirectory(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = lstatSync(dir);
  if (!stat.isDirectory() || stat.uid !== process.getuid()) throw new Error("Unsafe panel directory");
  chmodSync(dir, 0o700);
}

function atomicWrite(state, path) {
  const temp = `${path}.${randomUUID()}.tmp`;
  const fd = openSync(temp, "wx", 0o600);
  try {
    try { writeFileSync(fd, JSON.stringify(state)); } finally { closeSync(fd); }
    renameSync(temp, path);
  } finally {
    try { unlinkSync(temp); } catch {}
  }
}

export function publish(state, dir = stateDir) {
  privateDirectory(dir);
  atomicWrite(state, join(dir, `${state.pid}.json`));
}

export function archive(state, dir = stateDir, at = Date.now()) {
  if (!validState(state) || !Number.isFinite(at)) throw new Error("Invalid panel archive");
  const snapshot = { ...state, exitedAt: at };
  if (Buffer.byteLength(JSON.stringify(snapshot)) > 128 * 1024) throw new Error("Panel archive too large");
  const exitedDir = join(dir, "..", "exited");
  privateDirectory(exitedDir);
  atomicWrite(snapshot, join(exitedDir, `${state.runtimeId}.json`));
  const records = [];
  for (const name of readdirSync(exitedDir)) {
    if (!name.endsWith(".json") || !uuidPattern.test(name.slice(0, -5))) continue;
    const path = join(exitedDir, name);
    try {
      const stat = lstatSync(path);
      if (!stat.isFile() || stat.uid !== process.getuid() || stat.size > 128 * 1024) continue;
      const record = JSON.parse(readFileSync(path, "utf8"));
      if (!validState(record) || name !== `${record.runtimeId}.json` || !Number.isFinite(record.exitedAt)) continue;
      records.push({ path, at: record.exitedAt, ino: stat.ino, dev: stat.dev });
    } catch {}
  }
  records.sort((a, b) => b.at - a.at || a.path.localeCompare(b.path));
  for (const record of records.slice(100)) {
    try {
      const stat = lstatSync(record.path);
      if (stat.isFile() && stat.uid === process.getuid() && stat.ino === record.ino && stat.dev === record.dev) {
        unlinkSync(record.path);
      }
    } catch {}
  }
}

export function removeOwned(pid, runtimeId, dir = stateDir) {
  const path = join(dir, `${pid}.json`);
  try {
    if (JSON.parse(readFileSync(path, "utf8")).runtimeId === runtimeId) unlinkSync(path);
  } catch {}
}

export function validState(s) {
  return s?.version === 1 && Number.isSafeInteger(s.pid) && s.pid > 0 &&
    typeof s.processStart === "string" && s.processStart.length > 0 &&
    typeof s.runtimeId === "string" && uuidPattern.test(s.runtimeId) &&
    typeof s.sessionId === "string" && typeof s.cwd === "string" &&
    ["busy", "idle", "attention"].includes(s.status) && Number.isFinite(s.changedAt);
}

export function readSessions(dir = stateDir, getStart = processStart) {
  let names;
  try { names = readdirSync(dir); } catch { return []; }
  const sessions = [];
  for (const name of names) {
    if (!/^\d+\.json$/.test(name)) continue;
    try {
      const s = JSON.parse(readFileSync(join(dir, name), "utf8"));
      if (!validState(s) || name !== `${s.pid}.json`) continue;
      if (getStart(s.pid) !== s.processStart) continue;
      sessions.push(s);
    } catch { /* A dead process or a partially removed file is not a live session. */ }
  }
  return sessions;
}

export function createActivity() {
  let busy = false;
  let outcome = "Ready for input";
  let pendingOutcome = "completed";
  let compacting = false;
  let lastSettled;
  let runStartedAt;
  const tools = new Map();
  const prompts = [];
  return {
    event(type, event = {}) {
      switch (type) {
        case "before_agent_start": case "agent_start":
          if (!busy) { runStartedAt = Date.now(); pendingOutcome = "completed"; }
          busy = true; outcome = "Running";
          break;
        case "tool_execution_start": tools.set(event.toolCallId, text(event.toolName, 40)); break;
        case "tool_execution_end": tools.delete(event.toolCallId); break;
        case "ui_prompt_start":
          prompts.push({ kind: event.kind, title: event.title,
            attention: { id: randomUUID(), at: Date.now(), title: text(event.title || "Awaiting confirmation") } });
          break;
        case "ui_prompt_end": {
          // Pi supplies kind/title, not a prompt ID. Match the newest corresponding prompt.
          const index = prompts.findLastIndex((prompt) =>
            (event.kind === undefined || prompt.kind === event.kind) &&
            (event.title === undefined || prompt.title === event.title));
          if (index >= 0) prompts.splice(index, 1);
          break;
        }
        case "session_before_compact": compacting = true; break;
        case "session_compact": case "session_compact_failed": compacting = false; break;
        case "agent_before_settle":
          pendingOutcome = ["completed", "error", "aborted"].includes(event.outcome) ? event.outcome : "completed";
          break;
        case "agent_settled":
          busy = false; compacting = false; tools.clear(); prompts.length = 0;
          lastSettled = { id: randomUUID(), at: Date.now(), outcome: event.aborted ? "aborted" : pendingOutcome };
          outcome = { completed: "Completed", error: "Failed", aborted: "Stopped" }[lastSettled.outcome];
          break;
      }
      return this.snapshot();
    },
    snapshot() {
      const attention = prompts.at(-1)?.attention ?? null;
      const common = { attention, ...(lastSettled && { lastSettled }), ...(runStartedAt !== undefined && { runStartedAt }) };
      if (attention) return { ...common, status: "attention", activity: attention.title };
      if (compacting) return { ...common, status: "busy", activity: "Compacting context" };
      if (tools.size) return { ...common, status: "busy", activity: text(`Running ${[...tools.values()].join(", ")}`, 200) };
      return { ...common, status: busy ? "busy" : "idle", activity: busy ? "Running" : outcome };
    },
  };
}

export function localLink(candidate) {
  if (typeof candidate !== "string" || candidate.length > 2048 ||
      /[\s\x00-\x1f\x7f-\x9f\\<>"'`]/u.test(candidate) ||
      /%(?![\da-f]{2})|%(?:0[\da-f]|1[\da-f]|7f)/i.test(candidate)) return;
  // Validate the original authority: URL would silently repair backslashes and unusual IPv4 forms.
  const match = /^(https?):\/\/(\[::1\]|[^/:?#]+):(\d{1,5})(?=[/?#]|$)/i.exec(candidate);
  if (!match) return;
  const [, scheme, rawHost, rawPort] = match;
  const host = rawHost.toLowerCase();
  const port = Number(rawPort);
  if (port < 1 || port > 65535) return;
  const labels = host.split(".");
  const dns = host.length <= 253 && labels.every((label) => /^[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?$/.test(label));
  const loopback = labels.length === 4 && labels[0] === "127" &&
    labels.every((label) => /^(?:0|[1-9]\d{0,2})$/.test(label) && Number(label) <= 255);
  if (!(host === "[::1]" || loopback || (dns &&
      (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local"))))) return;
  try {
    const url = new URL(candidate);
    if (url.username || url.password || url.hostname !== host) return;
    const path = decodeURIComponent(url.pathname);
    if (/[\x00-\x1f\x7f-\x9f\\]/u.test(path) ||
        /(?:^|\/)(?:api|graphql|healthz?)(?:[/.;]|$)|\.json(?:[;/]|$)/i.test(path)) return;
    // Preserve an explicitly supplied default port, which URL.href drops.
    return `${scheme.toLowerCase()}://${host}:${port}${url.pathname}${url.search}${url.hash}`;
  } catch { return; }
}

export function extractLinks(value) {
  const links = new Set();
  for (const match of value.matchAll(/https?:\/\/[^\s<>"'`“”‘’]+/gi)) {
    let candidate = match[0].replace(/\*{1,3}$/, "").replace(/[.,;:!?]+$/, "");
    // Markdown/prose closing delimiters are not part of the URL; balanced path parentheses are.
    let end = candidate.length, excess;
    while (end > 0) {
      const close = candidate[end - 1], kind = ")]}".indexOf(close);
      if (kind < 0) break;
      if (!excess) {
        excess = [0, 0, 0];
        for (let i = 0; i < candidate.length; i++) {
          switch (candidate.charCodeAt(i)) {
            case 40: excess[0]--; break;
            case 41: excess[0]++; break;
            case 91: excess[1]--; break;
            case 93: excess[1]++; break;
            case 123: excess[2]--; break;
            case 125: excess[2]++; break;
          }
        }
      }
      const extra = excess[kind];
      if (extra <= 0) break;
      excess[kind] = extra - 1;
      end--;
      while (end > 0 && ".,;:!?".includes(candidate[end - 1])) end--;
    }
    candidate = candidate.slice(0, end);
    const link = localLink(candidate);
    if (link) {
      links.delete(link);
      links.add(link);
      if (links.size > 12) links.delete(links.values().next().value);
    }
  }
  return [...links];
}

export function createReplies() {
  let lastReply;
  let links = [];
  return {
    message(message) {
      if (message?.role !== "assistant") return this.snapshot();
      const content = message.content;
      const value = typeof content === "string" ? content : Array.isArray(content) ? content
        .filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("\n") : "";
      if (value.trim()) {
        lastReply = text(value
          .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
          .replace(/!?\[([^\]]*)\]\([^\n]*?\)/g, "$1")
          .replace(/^\s*(?:```[^\n]*|~~~[^\n]*|#{1,6}\s+|>\s?)/gm, "")
          .replace(/[*_`~]+/g, ""), 1000);
        const found = extractLinks(value);
        links = [...new Set([...links.filter((link) => !found.includes(link)), ...found])].slice(-12);
      }
      return this.snapshot();
    },
    snapshot() { return { ...(lastReply !== undefined && { lastReply }), links: [...links] }; },
  };
}
