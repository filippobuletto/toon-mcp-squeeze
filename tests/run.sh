#!/usr/bin/env bash
# Behavior tests for scripts/mcp-toon.sh. Requires jq and toon on PATH.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/mcp-toon.sh"
LABEL_PREFIX='[MCP JSON output re-encoded as TOON'
pass=0 fail=0

check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

big=$(jq -nc '[range(30) | {id: ., name: "user\(.)", role: "admin"}] | tojson')
small='"{\"a\":1}"'
filler=$(printf 'x%.0s' {1..600})

# event <tool_name> <tool_response-json>
event() { jq -nc --arg t "$1" --argjson r "$2" '{hook_event_name: "PostToolUse", tool_name: $t, tool_response: $r}'; }

run() { bash "$HOOK"; }

# Converts large JSON in content blocks, leaves small JSON and non-text blocks alone
out=$(event mcp__srv__list "[{\"type\":\"text\",\"text\":$big},{\"type\":\"text\",\"text\":$small},{\"type\":\"image\",\"data\":\"x\"}]" | run)
check "block: large JSON gets label" "true" "$(jq --arg p "$LABEL_PREFIX" '.hookSpecificOutput.updatedToolOutput[0].text | startswith($p)' <<<"$out")"
check "block: large JSON becomes tabular TOON" "[30]{id,name,role}:" "$(jq -r '.hookSpecificOutput.updatedToolOutput[0].text' <<<"$out" | sed -n 2p)"
check "block: small JSON untouched" '{"a":1}' "$(jq -r '.hookSpecificOutput.updatedToolOutput[1].text' <<<"$out")"
check "block: image untouched" '{"type":"image","data":"x"}' "$(jq -c '.hookSpecificOutput.updatedToolOutput[2]' <<<"$out")"
check "block: hook event name" "PostToolUse" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")"

# Plain string response
out=$(event mcp__srv__list "$big" | run)
check "string: large JSON becomes TOON" "[30]{id,name,role}:" "$(jq -r '.hookSpecificOutput.updatedToolOutput' <<<"$out" | sed -n 2p)"

# Pass-through cases produce no output
check "small JSON only: no output" "" "$(event mcp__srv__list "[{\"type\":\"text\",\"text\":$small}]" | run)"
check "non-JSON text: no output" "" "$(event mcp__srv__list "[{\"type\":\"text\",\"text\":\"$filler\"}]" | run)"
check "toon missing: no output" "" "$(event mcp__srv__list "$big" | CLAUDE_PLUGIN_OPTION_TOON_PATH=/nonexistent/toon run)"

# Threshold option
check "min_bytes raised: no output" "" "$(event mcp__srv__list "$big" | CLAUDE_PLUGIN_OPTION_MIN_BYTES=100000 run)"

# Tool filters: include and exclude are full-name regexes
check "include miss: no output" "" "$(event mcp__other__list "$big" | CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='mcp__srv__.*' run)"
out=$(event mcp__srv__list "$big" | CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='mcp__srv__.*' run)
check "include hit: converted" "[30]{id,name,role}:" "$(jq -r '.hookSpecificOutput.updatedToolOutput' <<<"$out" | sed -n 2p)"
check "include is anchored: no output" "" "$(event mcp__srv__list_all "$big" | CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='mcp__srv__list' run)"
check "exclude hit: no output" "" "$(event mcp__srv__get_file "$big" | CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS='mcp__srv__get_.*' run)"
check "invalid regex: no output" "" "$(event mcp__srv__list "$big" | CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='(' run)"

# Temp dirs cleaned up
check "no temp dirs left" "0" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mcp-toon.*' 2>/dev/null | wc -l | tr -d ' ')"

echo "pass=$pass fail=$fail"
(( fail == 0 ))
