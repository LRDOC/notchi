#!/bin/bash
# Notchi Hook for Gemini CLI - forwards Gemini events to Notchi app via Unix socket

SOCKET_PATH="/tmp/notchi.sock"
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json, socket, sys, hashlib

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

hook_event_payload = input_data.get('hook_event')
if not isinstance(hook_event_payload, dict):
    hook_event_payload = {}

hook_event = (input_data.get('hook_event_name') or
              input_data.get('event_name') or
              input_data.get('event') or
              hook_event_payload.get('event_type') or '')

def extract_text(value):
    if isinstance(value, str):
        return value.strip()

    if isinstance(value, dict):
        for key in ('text', 'content', 'value', 'message', 'prompt', 'user_prompt', 'userPrompt', 'user-prompt', 'input'):
            text = extract_text(value.get(key))
            if text:
                return text
        return ''

    if isinstance(value, list):
        parts = []
        for item in value:
            text = extract_text(item)
            if text:
                parts.append(text)
        return '\n'.join(parts).strip()

    return ''

def extract_prompt(payload, nested):
    for value in (
        payload.get('prompt'),
        payload.get('user_prompt'),
        payload.get('userPrompt'),
        payload.get('user-prompt'),
        payload.get('input'),
        payload.get('content'),
        payload.get('text'),
        nested.get('prompt'),
        nested.get('user_prompt'),
        nested.get('userPrompt'),
        nested.get('user-prompt'),
        nested.get('input'),
        nested.get('content'),
        nested.get('text'),
    ):
        text = extract_text(value)
        if text:
            return text

    messages = (payload.get('messages') or
                payload.get('input_messages') or
                payload.get('inputMessages') or [])
    if isinstance(messages, list):
        for message in reversed(messages):
            if not isinstance(message, dict):
                continue

            role = str(message.get('role', '')).lower()
            if role and role != 'user':
                continue

            text = extract_text(
                message.get('content') or
                message.get('input') or
                message.get('text') or
                message.get('message')
            )
            if text:
                return text

    return ''

event_map = {
    'BeforeTool':   'PreToolUse',
    'beforetool':   'PreToolUse',
    'before_tool':  'PreToolUse',
    'AfterTool':    'PostToolUse',
    'aftertool':    'PostToolUse',
    'after_tool':   'PostToolUse',
    'BeforeAgent':  'UserPromptSubmit',
    'beforeagent':  'UserPromptSubmit',
    'before_agent': 'UserPromptSubmit',
    'BeforeModel':  'UserPromptSubmit',
    'beforemodel':  'UserPromptSubmit',
    'before_model': 'UserPromptSubmit',
    'AfterAgent':   'Stop',
    'afteragent':   'Stop',
    'after_agent':  'Stop',
    'SessionStart': 'SessionStart',
    'session_start': 'SessionStart',
    # Gemini emits SessionEnd at the end of one-shot runs; map it to Stop so
    # the sprite stays visible as idle instead of being removed immediately.
    'SessionEnd':   'Stop',
    'session_end':  'Stop',
    # Gemini may emit PreCompress without follow-up lifecycle events, which can
    # leave the sprite stuck in compacting. Treat it as Stop for stable state.
    'PreCompress':  'Stop',
    'precompress':  'Stop',
    'pre_compress': 'Stop',
}
normalized_event = event_map.get(hook_event, hook_event)

status_map = {
    'UserPromptSubmit': 'processing',
    'PreCompact':       'compacting',
    'SessionStart':     'waiting_for_input',
    'SessionEnd':       'ended',
    'PreToolUse':       'running_tool',
    'PostToolUse':      'processing',
    'PermissionRequest':'waiting_for_input',
    'Stop':             'waiting_for_input',
}

cwd_val = (input_data.get('cwd') or
           input_data.get('working_directory') or
           input_data.get('project_dir') or
           input_data.get('workdir') or '')

session_id = (input_data.get('session_id') or
              input_data.get('session') or
              input_data.get('conversation_id') or '')
if not session_id:
    session_id = input_data.get('invocation_id') or ''
if not session_id:
    session_id = 'gemini-' + hashlib.md5(cwd_val.encode()).hexdigest()[:8]

output = {
    'session_id': session_id,
    'cwd': cwd_val,
    'event': normalized_event,
    'status': status_map.get(normalized_event, 'unknown'),
    'pid': None,
    'tty': None,
    'permission_mode': input_data.get('permission_mode', 'default'),
    'source': 'gemini',
}

if normalized_event in ('UserPromptSubmit', 'SessionStart'):
    prompt = extract_prompt(input_data, hook_event_payload)
    if prompt:
        output['user_prompt'] = prompt

if input_data.get('transcript_path'):
    output['transcript_path'] = input_data['transcript_path']

tool = (input_data.get('tool_name') or
        input_data.get('toolName') or
        input_data.get('tool') or
        hook_event_payload.get('tool_name') or
        hook_event_payload.get('toolName') or '')
if tool:
    output['tool'] = tool

tool_use_id = (input_data.get('tool_use_id') or
               input_data.get('toolUseId') or
               hook_event_payload.get('tool_use_id') or
               hook_event_payload.get('toolUseId') or
               hook_event_payload.get('callId') or
               hook_event_payload.get('call_id'))
if tool_use_id:
    output['tool_use_id'] = tool_use_id

tool_input = (input_data.get('tool_input') or
              input_data.get('toolInput'))
if not tool_input:
    tool_input = (hook_event_payload.get('tool_input') or
                  hook_event_payload.get('toolInput'))
if tool_input:
    output['tool_input'] = tool_input

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
"
