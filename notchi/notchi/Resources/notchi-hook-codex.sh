#!/bin/bash
# Notchi Hook for Codex CLI - forwards Codex events to Notchi app via Unix socket

SOCKET_PATH="/tmp/notchi.sock"

# Exit silently if socket doesn't exist (app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Preserve stdin payload (if any) before using a heredoc for Python source.
# When stdin is a TTY, avoid blocking on `cat`.
if [ -t 0 ]; then
  NOTCHI_STDIN_PAYLOAD=""
else
  NOTCHI_STDIN_PAYLOAD="$(cat)"
fi

/usr/bin/env NOTCHI_STDIN_PAYLOAD="$NOTCHI_STDIN_PAYLOAD" \
/usr/bin/python3 - "$SOCKET_PATH" "$@" <<'PY'
import hashlib
import json
import os
import socket
import sys

SOCKET_PATH = sys.argv[1]
raw_arg_payload = sys.argv[2] if len(sys.argv) > 2 else None
raw_stdin_payload = os.environ.get("NOTCHI_STDIN_PAYLOAD", "")


def send_event(event: dict) -> None:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(event).encode())
        sock.close()
    except Exception:
        pass


def parse_input_payload() -> dict:
    if raw_arg_payload:
        try:
            payload = json.loads(raw_arg_payload)
            if isinstance(payload, dict):
                return payload
        except Exception:
            pass

    if raw_stdin_payload:
        try:
            payload = json.loads(raw_stdin_payload)
            if isinstance(payload, dict):
                return payload
        except Exception:
            pass

    try:
        payload = json.load(sys.stdin)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass

    return {}


input_data = parse_input_payload()


def extract_text(value) -> str:
    if isinstance(value, str):
        return value.strip()

    if isinstance(value, dict):
        for key in ("text", "content", "value", "message", "prompt", "user_prompt", "userPrompt", "user-prompt", "input"):
            text = extract_text(value.get(key))
            if text:
                return text
        return ""

    if isinstance(value, list):
        parts = []
        for item in value:
            text = extract_text(item)
            if text:
                parts.append(text)
        return "\n".join(parts).strip()

    return ""


def extract_from_map(payload: dict, keys) -> str:
    if not isinstance(payload, dict):
        return ""
    for key in keys:
        text = extract_text(payload.get(key))
        if text:
            return text
    return ""


def latest_codex_session_id() -> str:
    root = os.path.expanduser("~/.codex/sessions")
    best_name = ""
    best_mtime = -1.0

    if not os.path.isdir(root):
        return ""

    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if not filename.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, filename)
            try:
                modified = os.path.getmtime(path)
            except OSError:
                continue
            if modified > best_mtime:
                best_mtime = modified
                best_name = os.path.splitext(filename)[0]

    return best_name


def extract_session_id(payload: dict) -> str:
    direct_keys = (
        "session_id",
        "sessionId",
        "session-id",
        "thread-id",
        "thread_id",
        "threadId",
        "conversation_id",
        "conversationId",
        "conversation-id",
        "invocation_id",
        "invocationId",
        "id",
    )

    nested_keys = (
        "session",
        "thread",
        "conversation",
        "payload",
        "meta",
        "metadata",
    )

    for key in direct_keys:
        value = payload.get(key)
        if isinstance(value, dict):
            nested = extract_from_map(value, direct_keys)
            if nested:
                return nested
            continue
        text = extract_text(value)
        if text:
            return text

    for key in nested_keys:
        nested = extract_from_map(payload.get(key), direct_keys)
        if nested:
            return nested

    for key in ("session_path", "sessionPath", "transcript_path", "transcriptPath"):
        path_value = extract_text(payload.get(key))
        if not path_value:
            continue
        basename = os.path.basename(path_value)
        if basename.endswith(".jsonl"):
            basename = basename[:-6]
        elif basename.endswith(".json"):
            basename = basename[:-5]
        if basename:
            return basename

    return latest_codex_session_id()


def extract_user_prompt(payload: dict, hook_payload: dict) -> str:
    for value in (
        payload.get("user-prompt"),
        payload.get("user_prompt"),
        payload.get("userPrompt"),
        payload.get("prompt"),
        hook_payload.get("user-prompt"),
        hook_payload.get("user_prompt"),
        hook_payload.get("userPrompt"),
        hook_payload.get("prompt"),
    ):
        text = extract_text(value)
        if text:
            return text

    input_messages = (
        payload.get("input-messages")
        or payload.get("input_messages")
        or payload.get("inputMessages")
        or hook_payload.get("input_messages")
        or hook_payload.get("inputMessages")
        or []
    )
    if isinstance(input_messages, list):
        for message in reversed(input_messages):
            if not isinstance(message, dict):
                continue

            role = str(message.get("role", "")).lower()
            if role and role != "user":
                continue

            content = (
                message.get("content")
                or message.get("input")
                or message.get("text")
                or message.get("message")
            )
            text = extract_text(content)
            if text:
                return text

    return ""

event_type = extract_text(input_data.get("type")).lower()
if not event_type:
    event_type = extract_text(input_data.get("event_type")).lower()

# Codex `notify` payload (documented path in current Codex CLI).
if event_type in {"agent-turn-complete", "agent_turn_complete"}:
    cwd_val = (
        input_data.get("cwd")
        or input_data.get("workdir")
        or input_data.get("working_directory")
        or input_data.get("working-directory")
        or ""
    )
    session_id = extract_session_id(input_data)
    if not session_id:
        session_id = "codex-" + hashlib.md5(cwd_val.encode()).hexdigest()[:12]

    base = {
        "session_id": session_id,
        "cwd": cwd_val,
        "pid": None,
        "tty": None,
        "permission_mode": "default",
        "source": "codex",
    }

    transcript_path = (
        input_data.get("transcript_path")
        or input_data.get("transcriptPath")
        or input_data.get("session_path")
        or input_data.get("sessionPath")
        or ""
    )
    if transcript_path:
        base["transcript_path"] = transcript_path

    prompt = extract_user_prompt(input_data, {})

    user_event = dict(base)
    user_event.update(
        {
            "event": "UserPromptSubmit",
            "status": "processing",
        }
    )
    if prompt:
        user_event["user_prompt"] = prompt
    send_event(user_event)

    stop_event = dict(base)
    stop_event.update({"event": "Stop", "status": "waiting_for_input"})
    send_event(stop_event)
    sys.exit(0)

# Backward compatibility with older stdin-based hook payloads.
hook_event_payload = input_data.get("hook_event")
if not isinstance(hook_event_payload, dict):
    hook_event_payload = {}

hook_event = (
    input_data.get("hook_event_name")
    or input_data.get("event_name")
    or input_data.get("event")
    or hook_event_payload.get("event_type")
    or hook_event_payload.get("hook_event_name")
    or ""
)

event_map = {
    "SessionStart": "SessionStart",
    "Stop": "Stop",
    "session_start": "SessionStart",
    "pre_tool_use": "PreToolUse",
    "post_tool_use": "PostToolUse",
    "post_tool_use_failure": "PostToolUse",
    "stop": "Stop",
    "after_tool_use": "PostToolUse",
    "after_agent": "Stop",
}
normalized_event = event_map.get(hook_event, hook_event)

status_map = {
    "UserPromptSubmit": "processing",
    "SessionStart": "waiting_for_input",
    "PreToolUse": "running_tool",
    "PostToolUse": "processing",
    "SessionEnd": "ended",
    "Stop": "waiting_for_input",
}

is_failure = hook_event == "post_tool_use_failure"
if hook_event_payload.get("event_type") == "after_tool_use":
    is_failure = bool(hook_event_payload.get("executed")) and not bool(
        hook_event_payload.get("success", True)
    )

cwd_val = (
    input_data.get("cwd")
    or input_data.get("working_directory")
    or input_data.get("project_dir")
    or input_data.get("workdir")
    or ""
)

session_id = extract_session_id(input_data)
if not session_id:
    session_id = "codex-" + hashlib.md5(cwd_val.encode()).hexdigest()[:12]

output = {
    "session_id": session_id,
    "cwd": cwd_val,
    "event": normalized_event,
    "status": "error" if is_failure else status_map.get(normalized_event, "unknown"),
    "pid": None,
    "tty": None,
    "permission_mode": input_data.get("permission_mode", "default"),
    "source": "codex",
}

session_path = input_data.get("transcript_path") or input_data.get("session_path") or ""
if session_path:
    output["transcript_path"] = session_path

tool = input_data.get("tool_name") or input_data.get("tool") or hook_event_payload.get("tool_name") or ""
if tool:
    output["tool"] = tool

tool_id = (
    input_data.get("tool_use_id")
    or input_data.get("call_id")
    or hook_event_payload.get("call_id")
    or ""
)
if tool_id:
    output["tool_use_id"] = tool_id

tool_input = input_data.get("tool_input")
if not tool_input and isinstance(hook_event_payload, dict):
    tool_input = hook_event_payload.get("tool_input")
if not tool_input and isinstance(hook_event_payload.get("tool_input"), dict):
    tool_input = hook_event_payload["tool_input"].get("params")
if tool_input:
    output["tool_input"] = tool_input

if normalized_event == "UserPromptSubmit":
    prompt = extract_user_prompt(input_data, hook_event_payload)
    if prompt:
        output["user_prompt"] = prompt

send_event(output)
PY
