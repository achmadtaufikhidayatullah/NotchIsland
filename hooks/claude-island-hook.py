#!/usr/bin/env python3
"""Hook Claude Code → NotchIsland.

Dipanggil oleh hook UserPromptSubmit / PreToolUse / Notification / Stop / SessionEnd.
Menulis status per sesi ke ~/Library/Application Support/NotchIsland/claude/<session_id>.json.
Tidak pernah mencetak ke stdout (stdout UserPromptSubmit masuk ke konteks Claude) dan selalu exit 0.
"""
import fcntl
import json
import os
import sys
import time

STATE_DIR = os.path.expanduser("~/Library/Application Support/NotchIsland/claude")


def tool_detail(name, inp):
    """Ringkasan singkat argumen tool untuk ditampilkan di island."""
    if not isinstance(inp, dict):
        return ""
    for key in ("description", "file_path", "path", "pattern", "url", "query", "command"):
        val = inp.get(key)
        if isinstance(val, str) and val:
            if key in ("file_path", "path"):
                val = os.path.basename(val.rstrip("/")) or val
            return val.splitlines()[0][:80]
    return ""


def tool_target(name, inp):
    """Apa persisnya yang akan dilakukan tool — ditampilkan saat Claude minta izin."""
    if not isinstance(inp, dict):
        return ""
    if isinstance(inp.get("command"), str):
        return inp["command"].strip().splitlines()[0][:120] if inp["command"].strip() else ""
    for key in ("file_path", "notebook_path", "path"):
        if isinstance(inp.get(key), str) and inp[key]:
            return os.path.basename(inp[key].rstrip("/")) or inp[key]
    return tool_detail(name, inp)


def apply_plan(state, name, inp):
    """Lacak progress dari task list (TodoWrite di CLI, update_plan di aplikasi desktop)."""
    if not isinstance(inp, dict):
        return
    if name == "TodoWrite" and isinstance(inp.get("todos"), list):
        state["plan"] = [t.get("status", "pending") for t in inp["todos"] if isinstance(t, dict)]
        return
    if not name.endswith("update_plan"):
        return
    plan = state.get("plan") or []
    if isinstance(inp.get("items"), list):
        plan = [i.get("status", "pending") for i in inp["items"] if isinstance(i, dict)]
    else:
        for idx in inp.get("done") or []:
            if isinstance(idx, int) and 1 <= idx <= len(plan):
                plan[idx - 1] = "completed"
        if inp.get("advance"):
            if "in_progress" in plan:
                plan[plan.index("in_progress")] = "completed"
            if "pending" in plan:
                plan[plan.index("pending")] = "in_progress"
        start = inp.get("start")
        if isinstance(start, int) and 1 <= start <= len(plan):
            plan = ["pending" if s == "in_progress" else s for s in plan]
            plan[start - 1] = "in_progress"
    state["plan"] = plan


def main():
    data = json.load(sys.stdin)
    sid = data.get("session_id")
    event = data.get("hook_event_name")
    if not sid or not event:
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"{sid}.json")

    if event == "SessionEnd":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return

    with open(os.path.join(STATE_DIR, ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                state = json.load(f)
        except (FileNotFoundError, ValueError):
            state = {}

        now = time.time()
        cwd = data.get("cwd") or state.get("cwd") or ""
        state.update(session_id=sid, cwd=cwd, project=os.path.basename(cwd.rstrip("/")) or "Claude",
                     transcript_path=data.get("transcript_path") or state.get("transcript_path"),
                     updated_at=now)
        if data.get("session_title"):
            state["title"] = data["session_title"]
        # App tempat Claude berjalan (Claude Desktop, VS Code, Terminal, …) — untuk klik dari notch.
        bundle = os.environ.get("__CFBundleIdentifier")
        if bundle:
            state["app_bundle"] = bundle
        if os.environ.get("TERM_PROGRAM"):
            state["term_program"] = os.environ["TERM_PROGRAM"]

        if event == "UserPromptSubmit":
            state.update(state="working", prompt=(data.get("prompt") or "").strip()[:200],
                         started_at=now, finished_at=None, tool=None, tool_detail="",
                         tool_count=0, plan=[], message="")
        elif event == "PreToolUse":
            name = data.get("tool_name") or ""
            inp = data.get("tool_input")
            state.update(state="working", tool=name.split("__")[-1], tool_detail=tool_detail(name, inp),
                         tool_target=tool_target(name, inp),
                         tool_count=int(state.get("tool_count") or 0) + 1, message="", waiting_kind=None)
            state.setdefault("started_at", now)
            apply_plan(state, name, inp)
        elif event == "PostToolUse":
            # Izin sudah diberikan dan tool selesai → kembali bekerja.
            if state.get("state") == "waiting":
                state.update(state="working", message="", waiting_kind=None)
        elif event == "Notification":
            msg = (data.get("message") or "")[:120]
            kind = data.get("notification_type") or ""
            # permission_prompt = minta izin tool; idle_prompt = menunggu balasan pengguna.
            waiting_kind = "permission" if "permission" in kind or "permission" in msg.lower() else "input"
            state.update(state="waiting", message=msg, waiting_kind=waiting_kind)
        elif event == "Stop":
            state.update(state="done", finished_at=now, tool=None, tool_detail="")

        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
