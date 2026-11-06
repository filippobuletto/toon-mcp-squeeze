#!/usr/bin/env bash
# PostToolUse hook: re-encode JSON text in MCP tool output as TOON to save tokens.
# Any failure exits 0 with no output, so Claude gets the original result.
#
# Options (plugin userConfig, exported by Claude Code as env vars):
#   CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS  regex, full tool name must match (default: mcp__.*)
#   CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS  regex, full tool name match skips conversion (default: none)
#   CLAUDE_PLUGIN_OPTION_MIN_BYTES      skip text blocks smaller than this (default: 500)
#   CLAUDE_PLUGIN_OPTION_TOON_PATH      toon executable (default: toon on PATH)
set -uo pipefail

INCLUDE=${CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS:-mcp__.*}
EXCLUDE=${CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS:-}
MIN_BYTES=${CLAUDE_PLUGIN_OPTION_MIN_BYTES:-500}
TOON=${CLAUDE_PLUGIN_OPTION_TOON_PATH:-toon}
LABEL='[MCP JSON output re-encoded as TOON; decode with `toon --decode` if JSON needed]'

command -v "$TOON" >/dev/null || exit 0
work=$(mktemp -d "${TMPDIR:-/tmp}/mcp-toon.XXXXXX") || exit 0
trap 'rm -rf "$work"' EXIT

# Payloads stay in files, never shell variables; toon streams file input to file output.
cat > "$work/event.json"

# Regexes are anchored to the whole tool name; an invalid regex makes jq fail, which skips conversion.
jq -e --arg inc "$INCLUDE" --arg exc "$EXCLUDE" '
  .tool_name as $t
  | ($t | test("^(" + $inc + ")$")) and ($exc == "" or ($t | test("^(" + $exc + ")$") | not))
' "$work/event.json" >/dev/null 2>&1 || exit 0

jq -c '.tool_response' "$work/event.json" > "$work/resp.json" || exit 0

# encode <json-text-file> <toon-file>: fails if too small, not an object/array, not encodable,
# or not smaller than the original once the label line is added
encode() {
  local size
  size=$(wc -c < "$1")
  (( size >= MIN_BYTES )) || return 1
  jq -e 'type == "object" or type == "array"' "$1" >/dev/null 2>&1 || return 1
  "$TOON" --encode "$1" -o "$2" >/dev/null 2>&1 || return 1
  (( ${#LABEL} + 1 + $(wc -c < "$2") < size ))
}

# Oversized results reach the hook as a message naming the file Claude Code saved them to.
# spill: encode that file to a sibling .toon and point the message at it. Only files under
# this session's tool-results directory are read.
spill() {
  local src dir dst
  src=$(jq -r '.tool_response | capture("Output has been saved to (?<p>/[^\n]*?\\.txt)\\.\n").p // empty' "$work/event.json")
  dir=$(jq -r '.transcript_path // "" | rtrimstr(".jsonl")' "$work/event.json")
  [[ -n $src && -n $dir && $src == "$dir"/tool-results/* && $src != */../* && -f $src && ! -L $src ]] || return 1
  dst=${src%.txt}.toon
  encode "$src" "$work/spill.toon" && mv "$work/spill.toon" "$dst" || return 1
  jq --arg s "$src" --arg d "$dst" --arg l "${LABEL%]}; original JSON at $src]" \
    '$l + "\n" + (split($s) | join($d))' "$work/resp.json" > "$work/next.json" &&
    mv "$work/next.json" "$work/resp.json"
}

changed=0
case $(jq -r 'type' "$work/resp.json") in
  string)
    jq -j '.' "$work/resp.json" > "$work/s.json"
    if encode "$work/s.json" "$work/s.toon"; then
      jq -n --arg l "$LABEL" --rawfile t "$work/s.toon" '$l + "\n" + $t' > "$work/resp.json" || exit 0
      changed=1
    elif spill; then
      changed=1
    fi ;;
  array)
    for i in $(jq -r 'to_entries[] | select(.value.type == "text") | .key' "$work/resp.json"); do
      jq -j ".[$i].text" "$work/resp.json" > "$work/$i.json"
      encode "$work/$i.json" "$work/$i.toon" || continue
      jq --arg l "$LABEL" --rawfile t "$work/$i.toon" ".[$i].text = \$l + \"\n\" + \$t" \
        "$work/resp.json" > "$work/next.json" || exit 0
      mv "$work/next.json" "$work/resp.json"
      changed=1
    done ;;
esac

(( changed )) || exit 0
jq -n --slurpfile o "$work/resp.json" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $o[0]}}'
