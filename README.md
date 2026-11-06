<div align="center">

# toon-mcp-squeeze

A Claude Code plugin that re-encodes JSON returned by MCP tools as [TOON](https://toonformat.dev/) before Claude reads it. Large lists of similar records, such as issues, pods or query rows, become compact tables, often 30-60% fewer tokens.

[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffilippobuletto%2Ftoon-mcp-squeeze%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version)](.claude-plugin/plugin.json)
[![License](https://img.shields.io/github/license/filippobuletto/toon-mcp-squeeze)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/filippobuletto/toon-mcp-squeeze)](https://github.com/filippobuletto/toon-mcp-squeeze/commits/main)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-D97757?logo=claude&logoColor=white)](https://code.claude.com/docs/en/plugins)
[![MCP](https://img.shields.io/badge/MCP-tools-6E56CF?logo=modelcontextprotocol&logoColor=white)](https://modelcontextprotocol.io/)
[![TOON](https://img.shields.io/badge/format-TOON-2B6CB0)](https://toonformat.dev/)
[![Bash](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](scripts/mcp-toon.sh)
[![jq](https://img.shields.io/badge/requires-jq-blue)](https://jqlang.org/)

</div>

```text
[MCP JSON output re-encoded as TOON; decode with `toon --decode` if JSON needed]
[3]{id,name,role}:
  1,alice,admin
  2,bob,dev
  3,carol,dev
```

## How it works

A `PostToolUse` hook matches every `mcp__.*` tool and runs `scripts/mcp-toon.sh`. For each text block in the result that holds a JSON object or array of at least `min_bytes`, the hook replaces the text with a label line and the TOON encoding, using `updatedToolOutput`. Everything else passes through unchanged: images, plain text, small blocks, blocks whose TOON plus label would not be smaller, and tools filtered out by your options.

Claude Code saves results over 50,000 characters to a file in the session's `tool-results` directory, so the hook only sees a message naming that file. In that case the hook writes a TOON copy next to it, points the message at the `.toon` file, and names the original JSON in the label for `jq` queries. Files outside the current session's `tool-results` directory are never read.

The hook fails safe. If toon is missing, a regex is invalid or encoding fails, Claude gets the original output.

Payloads move through temp files, not shell variables, and the toon CLI streams file-to-file. Claude Code still needs the final result as one JSON document, so the hook holds the converted output in memory once at the end.

## Requirements

- `bash` and `jq`
- The toon CLI: `npm i -g @toon-format/cli`

## Install

```text
/plugin marketplace add filippobuletto/toon-mcp-squeeze
/plugin install toon-mcp-squeeze@toon-mcp-squeeze
```

Then run `/toon-mcp-squeeze:setup`. It checks prerequisites, helps you choose which MCP tools to convert, measures savings and verifies the hook.

## Options

Set the options in `/config` or `/plugin`. Claude Code passes them to the hook as `CLAUDE_PLUGIN_OPTION_<KEY>`.

| Option | Default | Meaning |
| :- | :- | :- |
| `include_tools` | `mcp__.*` | Regex for the whole tool name. Only matching tools are converted |
| `exclude_tools` | empty | Regex for the whole tool name. Matching tools are never converted |
| `min_bytes` | `500` | Text blocks smaller than this pass through |
| `toon_path` | empty (`toon` on PATH) | Absolute path to toon, for installs under nvm, volta, asdf and similar |

Example: convert GitHub and Kubernetes tools, but not file contents:

- `include_tools`: `mcp__github__.*|mcp__kubernetes__.*`
- `exclude_tools`: `mcp__github__get_file_contents`

## Good and poor fits

TOON pays off on uniform arrays of objects. It saves little on deeply nested or irregular JSON. Exclude tools whose output Claude copies back verbatim, such as file contents or manifests it edits and re-applies.

## Development

```bash
bash tests/run.sh                 # hook behavior tests, needs jq and toon
bash scripts/doctor.sh mcp__x__y  # prerequisite check plus filter preview for tool names
claude plugin validate .
claude --plugin-dir .             # load the plugin from this checkout
```

## License

MIT
