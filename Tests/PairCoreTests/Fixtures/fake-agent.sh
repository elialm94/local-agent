#!/usr/bin/env bash
# Stand-in for the Cursor CLI (`agent -p --output-format stream-json ...`).
# Emits the documented NDJSON event shapes and performs a real edit so the
# checkpoint/undo path can be exercised without a Cursor install.
set -euo pipefail

workspace="."
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) workspace="$2"; shift 2 ;;
    --output-format|--model|--resume) shift 2 ;;
    -p|--force|--trust) shift ;;
    *) prompt="$1"; shift ;;
  esac
done

# The target file is taken from the "Source:" line of the compiled prompt.
file=$(printf '%s\n' "$prompt" | sed -n 's/^\([A-Za-z0-9_./-]*\.[a-z]*\):[0-9]*.*/\1/p' | head -n1)
[[ -z "$file" ]] && file="FAKE_AGENT_TOUCHED.txt"

echo '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"'"$workspace"'","session_id":"fake-session-123","model":"fake","permissionMode":"default"}'
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"(prompt omitted)"}]},"session_id":"fake-session-123"}'
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Editing '"$file"'."}]},"session_id":"fake-session-123"}'
echo '{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"'"$file"'"}}},"session_id":"fake-session-123"}'
echo '{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"'"$file"'"},"result":{"success":{"content":"","totalLines":1}}}},"session_id":"fake-session-123"}'
echo '{"type":"tool_call","subtype":"started","call_id":"c2","tool_call":{"writeToolCall":{"args":{"path":"'"$file"'","fileText":"..."}}},"session_id":"fake-session-123"}'
if [[ "${FAKE_AGENT_FAIL:-}" == "1" ]]; then
  echo "simulated agent failure" >&2
  exit 3
fi
mkdir -p "$(dirname "$workspace/$file")"
printf '\n/* fake-agent edit */\n' >> "$workspace/$file"
echo '{"type":"tool_call","subtype":"completed","call_id":"c2","tool_call":{"writeToolCall":{"args":{"path":"'"$file"'","fileText":"..."},"result":{"success":{"path":"'"$file"'","linesCreated":2,"fileSize":40}}}},"session_id":"fake-session-123"}'
echo '{"type":"result","subtype":"success","duration_ms":120,"duration_api_ms":100,"is_error":false,"result":"Made '"$file"' red.","session_id":"fake-session-123","request_id":"r1"}'
