import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
// A new module path bypasses the pre-upgrade .mjs cache in already-running Pi processes.
import { archive, createActivity, createReplies, processStart, publish, removeOwned, run, text } from "./state.mjs";

interface SessionState {
  version: number;
  pid: number;
  processStart: string;
  runtimeId: string;
  sessionId: string;
  sessionFile?: string;
  lastReply?: string;
  links?: string[];
  lastSettled?: { id: string; at: number; outcome: "completed" | "error" | "aborted" };
  attention?: { id: string; at: number; title: string } | null;
  runStartedAt?: number;
  exitedAt?: number;
  cwd: string;
  changedAt: number;
  task: string;
  status: string;
  activity: string;
  tty: string;
  tmux: { socket: string; pane: string } | null;
}

function latestTask(ctx: ExtensionContext): string {
  const entry = ctx.sessionManager.getBranch().findLast((entry) =>
    entry.type === "message" && entry.message.role === "user");
  if (entry?.type !== "message" || entry.message.role !== "user") return "";
  const content = entry.message.content;
  return text(typeof content === "string" ? content : content
    .filter((part) => part.type === "text").map((part) => part.text).join(" "), 100);
}

function terminalLocation() {
  let tty = "";
  try {
    const value = run("/bin/ps", ["-p", String(process.pid), "-o", "tty="]);
    if (value !== "??" && value !== "?") tty = value.startsWith("/") ? value : `/dev/${value}`;
  } catch {}
  const socket = process.env.TMUX?.replace(/,\d+,\d+$/, "");
  let pane = process.env.TMUX_PANE;
  if (socket && !pane && tty) {
    try {
      const rows = run("tmux", ["-S", socket, "list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}"]).split("\n");
      pane = rows.map((line: string) => line.split("\t")).find((row: string[]) => row[1] === tty)?.[0];
    } catch {}
  }
  return { tty, tmux: socket && pane && /^%\d+$/.test(pane) ? { socket, pane } : null };
}

export default function (pi: ExtensionAPI) {
  let state: SessionState | undefined;
  let activity = createActivity();
  let replies = createReplies();
  let warned = false;

  const warn = (ctx: ExtensionContext, error: unknown) => {
    if (warned) return;
    warned = true;
    try { ctx.ui.notify(`Session panel: ${String(error)}`, "warning"); } catch {}
  };
  const save = (ctx: ExtensionContext) => {
    if (!state) return;
    try {
      const next = activity.snapshot();
      if (next.status !== state.status || next.activity !== state.activity) state.changedAt = Date.now();
      Object.assign(state, next, replies.snapshot(), {
        sessionFile: ctx.sessionManager.getSessionFile(),
        name: text(ctx.sessionManager.getSessionName(), 100),
        model: text(ctx.model?.id, 100),
      });
      publish(state);
    } catch (error) { warn(ctx, error); }
  };

  pi.on("session_start", (_event, ctx) => {
    if (state) removeOwned(state.pid, state.runtimeId);
    state = undefined;
    // Remote and non-interactive runs do not have a local terminal to focus.
    if (process.platform !== "darwin" || ctx.mode !== "tui" || process.env.SSH_CONNECTION) return;
    activity = createActivity();
    replies = createReplies();
    warned = false;
    try {
      for (const entry of ctx.sessionManager.getBranch()) {
        if (entry.type === "message") replies.message(entry.message);
      }
      state = {
        version: 1, pid: process.pid, processStart: processStart(process.pid), runtimeId: randomUUID(),
        sessionId: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, changedAt: Date.now(),
        task: latestTask(ctx), ...terminalLocation(), ...activity.snapshot(),
      };
      if (!ctx.isIdle()) activity.event("agent_start");
      save(ctx);
    } catch (error) {
      state = undefined;
      warn(ctx, error);
    }
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (!state) return;
    if (event.messageType === "user") state.task = text(event.prompt, 100);
    activity.event(event.type, event);
    save(ctx);
  });
  pi.on("agent_start", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("agent_before_settle", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("agent_settled", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("tool_execution_start", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("tool_execution_end", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("ui_prompt_start", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("ui_prompt_end", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("session_before_compact", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("session_compact", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("session_compact_failed", (event, ctx) => { activity.event(event.type, event); save(ctx); });
  pi.on("message_end", (event, ctx) => {
    if (!state || event.message.role !== "assistant") return;
    try { replies.message(event.message); save(ctx); } catch (error) { warn(ctx, error); }
  });
  pi.on("session_info_changed", (_event, ctx) => save(ctx));
  pi.on("model_select", (_event, ctx) => save(ctx));
  pi.on("session_shutdown", (event, ctx) => {
    if (!state) return;
    try {
      if (event.reason === "quit") archive(state);
    } catch (error) { warn(ctx, error); }
    finally {
      removeOwned(state.pid, state.runtimeId);
      state = undefined;
    }
  });
}
