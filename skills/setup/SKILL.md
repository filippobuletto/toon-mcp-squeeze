---
name: setup
description: Set up and troubleshoot the toon-mcp-squeeze hook, which re-encodes JSON from MCP tools as TOON. Checks prerequisites (jq, node, the toon CLI), installs toon globally, picks which MCP servers and tools to convert, measures savings, and verifies the hook works.
when_to_use: User runs /toon-mcp-squeeze:setup, asks to configure or debug TOON conversion of MCP output, asks which MCP tools the hook applies to, or reports that MCP output isn't being converted.
argument-hint: "[check|tools|measure|verify]"
---

# toon-mcp-squeeze setup

The plugin's `PostToolUse` hook runs `${CLAUDE_PLUGIN_ROOT}/scripts/mcp-toon.sh` after every MCP tool call. For each text block that holds a JSON object or array of at least `min_bytes`, it replaces the text with a one-line label followed by the TOON encoding. Anything else passes through unchanged, and any failure (toon missing, invalid regex) leaves the output untouched.

Current options:

| Option | Value | Meaning |
| :- | :- | :- |
| `include_tools` | `${user_config.include_tools}` | Regex, whole tool name must match. Empty means `mcp__.*` |
| `exclude_tools` | `${user_config.exclude_tools}` | Regex, whole-name matches are skipped. Empty means none |
| `min_bytes` | `${user_config.min_bytes}` | Smaller text blocks are skipped. Empty means 500 |
| `toon_path` | `${user_config.toon_path}` | toon executable. Empty means `toon` on PATH |

With argument `$ARGUMENTS`, run only that step. With no argument, walk through every step in order, reporting after each and asking before anything that installs software or changes settings.

## 1. check: prerequisites

Run the doctor with the current options:

```bash
CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='${user_config.include_tools}' \
CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS='${user_config.exclude_tools}' \
CLAUDE_PLUGIN_OPTION_MIN_BYTES='${user_config.min_bytes}' \
CLAUDE_PLUGIN_OPTION_TOON_PATH='${user_config.toon_path}' \
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

Fix what it reports:

- **jq missing**: suggest `brew install jq` (macOS) or the distro package. Ask before installing.
- **toon missing**: ask, then run `npm i -g @toon-format/cli` and rerun the doctor. If npm is missing, the user needs Node.js first.
- **toon under a Node version manager** (nvm, volta, asdf, mise, fnm): Claude Code may start from a launcher without that PATH, and the hook then silently does nothing. Recommend setting `toon_path` to the absolute path the doctor printed.

## 2. tools: choose what to convert

1. List configured servers with `claude mcp list`. Also list the `mcp__<server>__<tool>` names available in this session. Plugin servers are named `mcp__plugin_<plugin>_<server>__<tool>`.
2. Sort candidates:
   - **Good fits**: tools returning lists of similar records, such as list, search and query tools (issues, pods, rows, events). TOON writes these as tables, often saving 30-60%.
   - **Poor fits**: tools whose output Claude copies back verbatim (file contents, manifests, configs to edit and re-apply), deeply nested or irregular JSON, and small responses.
3. Propose an `include_tools` regex for the good fits, e.g. `mcp__github__(list|search)_.*|mcp__kubernetes__.*`, and an `exclude_tools` regex for poor fits within those servers, e.g. `mcp__github__get_file_contents`. Both are anchored to the whole name, so `mcp__github` alone matches nothing.
4. Check the proposal by passing tool names to the doctor along with the proposed values:

```bash
CLAUDE_PLUGIN_OPTION_INCLUDE_TOOLS='<proposed include>' \
CLAUDE_PLUGIN_OPTION_EXCLUDE_TOOLS='<proposed exclude>' \
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" mcp__server__tool_a mcp__server__tool_b
```

## 3. measure: estimate savings

For a candidate tool, save a representative JSON result to a file under the system temp directory and run `toon --stats <file>`. Report the JSON and TOON token estimates. Under about 15% savings, the tool isn't worth converting; suggest excluding it.

## 4. Apply the options

Options live in the plugin's configuration, not in the script. Tell the user to change them in `/config` (the toon-mcp-squeeze rows) or through `/plugin`. If they ask you to apply them, edit `pluginConfigs["toon-mcp-squeeze@filippobuletto"].options` in `~/.claude/settings.json`. Show the change and get confirmation first, keep other keys intact, and store `min_bytes` as a number. New values reach the hook on the next tool call after Claude Code reloads its settings; if they don't, restart the session.

## 5. verify: confirm it works

1. Feed the hook a synthetic event and confirm the output starts with the label and a tabular header:

```bash
jq -nc '{tool_name: "mcp__demo__list", tool_response: [{type: "text", text: ([range(30) | {id: ., name: "user\(.)"}] | tojson)}]}' \
  | CLAUDE_PLUGIN_OPTION_TOON_PATH='${user_config.toon_path}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp-toon.sh" \
  | jq -r '.hookSpecificOutput.updatedToolOutput[0].text' | head -3
```

2. Call a real tool that `include_tools` matches and returns a large JSON list. Its result should start with `[MCP JSON output re-encoded as TOON`. If it doesn't, check `/hooks` for the plugin's PostToolUse entry, rerun step 1, and confirm `toon_path` if toon lives under a version manager.

## Reading converted output

Converted results start with `[MCP JSON output re-encoded as TOON; decode with \`toon --decode\` if JSON needed]`. Read TOON directly. When a script needs real JSON, pipe the TOON body (without the label line) through `toon --decode`.
