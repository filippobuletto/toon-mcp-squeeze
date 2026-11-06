#!/usr/bin/env bash
# Check toon-mcp-squeeze prerequisites and options.
# Usage: doctor.sh [tool_name ...]   each tool name is checked against the include/exclude filters.
# Reads the same CLAUDE_PLUGIN_OPTION_* variables as scripts/mcp-toon.sh.
set -uo pipefail

INCLUDE=${CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS:-mcp__.*}
EXCLUDE=${CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS:-}
MIN_BYTES=${CLAUDE_PLUGIN_OPTION_MIN_BYTES:-500}
TOON=${CLAUDE_PLUGIN_OPTION_TOON_PATH:-toon}
problems=0

ok()   { echo "ok    $*"; }
warn() { echo "warn  $*"; }
bad()  { echo "FAIL  $*"; problems=$((problems + 1)); }

if command -v jq >/dev/null; then ok "jq $(jq --version)"; else bad "jq not found: install it (brew install jq / apt install jq)"; fi

if command -v node >/dev/null; then ok "node $(node --version)"; else warn "node not found: needed to install and run toon"; fi
if command -v npm >/dev/null; then ok "npm $(npm --version)"; else warn "npm not found: needed for npm i -g @toon-format/cli"; fi

if toon_bin=$(command -v "$TOON"); then
  ok "toon $("$TOON" --version 2>/dev/null) at $toon_bin"
  case $toon_bin in
    */.nvm/*|*/.volta/*|*/.asdf/*|*/.local/share/mise/*|*/.fnm/*)
      warn "toon lives under a Node version manager; if Claude Code starts without that PATH, set the toon_path option to $toon_bin" ;;
  esac
else
  bad "toon not found ('$TOON'): run npm i -g @toon-format/cli, or set the toon_path option to its absolute path"
fi

if ! [[ $MIN_BYTES =~ ^[0-9]+$ ]]; then bad "min_bytes '$MIN_BYTES' is not a non-negative integer"; else ok "min_bytes $MIN_BYTES"; fi

regex_ok() { jq -en --arg re "$1" '"" | test("^(" + $re + ")$") | . or true' >/dev/null 2>&1; }
if regex_ok "$INCLUDE"; then ok "include_tools ^($INCLUDE)\$"; else bad "include_tools '$INCLUDE' is not a valid regex"; fi
if [[ -z $EXCLUDE ]]; then ok "exclude_tools (none)"
elif regex_ok "$EXCLUDE"; then ok "exclude_tools ^($EXCLUDE)\$"
else bad "exclude_tools '$EXCLUDE' is not a valid regex"; fi

for tool in "$@"; do
  verdict=$(jq -rn --arg t "$tool" --arg inc "$INCLUDE" --arg exc "$EXCLUDE" '
    if ($t | test("^(" + $inc + ")$")) | not then "skip (not in include_tools)"
    elif $exc != "" and ($t | test("^(" + $exc + ")$")) then "skip (in exclude_tools)"
    else "convert" end' 2>/dev/null) || verdict="unknown (invalid regex)"
  echo "tool  $tool -> $verdict"
done

if (( problems )); then echo "$problems problem(s) found; the hook passes output through unchanged until fixed"; exit 1; fi
echo "all checks passed"
