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
logs=$(jq -nc --arg f "$filler" '{name: "pod-0", logs: ([range(5)] | map("line \(.) \($f)") | join("\n"))} | tojson')
check "TOON not smaller: no output" "" "$(event mcp__srv__logs "[{\"type\":\"text\",\"text\":$logs}]" | run)"
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

# Oversized results: Claude Code saves them to <session>/tool-results/*.txt and passes the hook a message naming the file
proj=$(mktemp -d "${TMPDIR:-/tmp}/spill-test.XXXXXX")
trap 'rm -rf "$proj"' EXIT
mkdir -p "$proj/sess/tool-results" "$proj/other/tool-results"
jq -r '.' <<<"$big" > "$proj/sess/tool-results/mcp-srv-list-1.txt"
printf 'x%.0s' {1..600} > "$proj/sess/tool-results/mcp-srv-list-2.txt"
jq -r '.' <<<"$big" > "$proj/other/tool-results/mcp-srv-list-3.txt"
spill_msg() { printf 'Error: result (999 characters across 9 lines) exceeds maximum allowed tokens. Output has been saved to %s.\nFormat: Plain text\n- You MUST read the content from the file at %s in sequential chunks.\n' "$1" "$1"; }
# spill <file>: PostToolUse event for a spilled result in session "sess"
spill() { jq -nc --arg m "$(spill_msg "$1")" --arg tp "$proj/sess.jsonl" \
  '{hook_event_name: "PostToolUse", tool_name: "mcp__srv__list", transcript_path: $tp, tool_response: $m}'; }

out=$(spill "$proj/sess/tool-results/mcp-srv-list-1.txt" | run)
msg=$(jq -r '.hookSpecificOutput.updatedToolOutput' <<<"$out")
check "spill: TOON file written" "[30]{id,name,role}:" "$(sed -n 1p "$proj/sess/tool-results/mcp-srv-list-1.toon" 2>/dev/null)"
check "spill: message points at TOON file" "2" "$(jq -rn --arg m "$msg" '[$m | match("mcp-srv-list-1\\.toon"; "g")] | length')"
check "spill: label names original JSON" "true" "$(head -1 <<<"$msg" | jq -R --arg p "$LABEL_PREFIX" --arg j "$proj/sess/tool-results/mcp-srv-list-1.txt" 'startswith($p) and contains($j)')"
check "spill: TOON decodes to original" "true" "$(toon --decode "$proj/sess/tool-results/mcp-srv-list-1.toon" | jq --argjson o "$(jq -r . <<<"$big")" '. == $o')"
check "spill: non-JSON file: no output" "" "$(spill "$proj/sess/tool-results/mcp-srv-list-2.txt" | run)"
check "spill: file outside session: no output" "" "$(spill "$proj/other/tool-results/mcp-srv-list-3.txt" | run)"
check "spill: path traversal: no output" "" "$(spill "$proj/sess/tool-results/../../other/tool-results/mcp-srv-list-3.txt" | run)"
check "spill: outside file left alone" "false" "$([[ -e $proj/other/tool-results/mcp-srv-list-3.toon ]] && echo true || echo false)"
check "spill: missing file: no output" "" "$(spill "$proj/sess/tool-results/missing.txt" | run)"
check "spill: excluded tool: no output" "" "$(spill "$proj/sess/tool-results/mcp-srv-list-1.txt" | CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS='mcp__srv__.*' run)"

# Temp dirs cleaned up
check "no temp dirs left" "0" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mcp-toon.*' 2>/dev/null | wc -l | tr -d ' ')"

echo "pass=$pass fail=$fail"
(( fail == 0 ))
