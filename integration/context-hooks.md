# Optional invocation context hooks

Candidate implementation for TSK-022. No global CLI or harness settings have
been changed. Generate a preview with the candidate:

```powershell
target/server-candidate/debug/tasks.exe context-setup --harness codex
target/server-candidate/debug/tasks.exe context-setup --harness claude-code
```

`preview_only` and `harness` are explanatory fields. Merge only the `hooks`
object into an isolated harness configuration for verification. Replace the
preview's `tasks` command with the absolute candidate executable path; quote
paths containing spaces using that harness's command shell. Do not point hooks
at the installed CLI until that version is explicitly installed. Review existing
hooks before merging. The helper never edits settings.

## Adapter behavior

`tasks context-hook --harness codex` or `--harness claude-code` reads JSON from
stdin, writes a bounded context record, and exits silently. It emits no
additionalContext. Invalid or unavailable optional context does not fail the
harness or an ordinary mutation. It retains only supplied session ID/title,
model, agent ID and execution ID; it does not read transcripts or retain prompts,
tool arguments or full environments. Session records use hashed identities;
different sessions and agents have separate files.

Set `TASKS_CLIENT_DIR` once in the isolated harness environment to a fresh
temporary directory. Production defaults are
`%LOCALAPPDATA%/MaxLogic/tasks-cli/client` on Windows and
`${XDG_CONFIG_HOME:-$HOME/.config}/tasks-cli/client` on Linux. Unix context
directories/files use 0700/0600. Windows uses protected owner/SYSTEM/Administrators
ACLs; synthetic file and concurrent hook cases pass. Live harness acceptance
remains pending.

Configure SessionStart plus PreToolUse for Bash/PowerShell so model changes
refresh the record. SubagentStart retains a supplied agent ID separately.
The installed versions inspected on 2026-10-03 were Codex 0.160.0 and Claude
Code 2.1.287. Actual sessions using these adapters still need verification.

## Ordinary mutations

No metadata arguments are needed. The CLI obtains machine/account names from
the OS and exported session IDs from its environment. Linux walks at most eight
process ancestors within a 100 ms collection deadline. Windows executable
ancestry is currently unavailable because no safe selective native wrapper was
established under the repository's no-unsafe rule. A generic node/python parent
does not identify a harness. Unknown origins and unavailable fields stay empty.

Codex uses `CODEX_THREAD_ID` when present, then `CODEX_SESSION_ID`. If both
differ, the latter is stored separately as `harness_session_id`. Do not assume
that an undocumented hook can publish environment variables. A session-indexed
file can provide a title, but cannot identify the model of a concurrent agent.
Model/agent fields require a matching inherited `TASKS_AGENT_ID`, or an explicit
`TASKS_CONTEXT_FILE` plus matching `TASKS_EXECUTION_ID`. If the installed harness
cannot supply that invocation identity, those fields stay empty. `CODEX_MODEL`
and the globally configured model are deliberately not treated as evidence.

For Claude Code SessionStart, the adapter appends Bash exports to the supplied
`CLAUDE_ENV_FILE`: `AGENT_HARNESS`, `CLAUDE_CODE_SESSION_ID` and
`TASKS_CONTEXT_FILE`. Existing exports are preserved. Claude documents this as a
Bash environment channel; native PowerShell inheritance is not established.
The exported session alone does not establish a concurrent agent's model.

Viewer mutations clear inherited AI session/model metadata. WSL delegation
forwards a bounded typed context envelope to the Windows binary so the original
Linux observation is preserved. None of this local context is authenticated;
the future server replaces actor/installation identity from the credential.

## Remaining acceptance

Run isolated Codex and Claude sessions, ordinary writes and a model change;
compare stored history with the actual hook payloads and confirm no routine hook
text entered the model context. Verify supported Bash/native PowerShell paths
and the selected Windows ancestry behavior before
closing TSK-022. Automated fixtures are not this manual acceptance evidence.

Private hook directory/file creation and reads now use native permission checks
on both platforms. Windows uses protected owner/SYSTEM/Administrators ACLs;
shared, null or inherited ACLs are refused. Unix requires owner-only 0700/0600
and rejects symlinks/hard links. Existing insecure directories are refused rather
than repaired implicitly. The Windows shared-ACL regression and simultaneous
hook fixture pass; no machine interaction or installed harness setting changed.

References: [Codex hooks](https://developers.openai.com/codex/hooks),
[Claude Code hooks](https://code.claude.com/docs/en/hooks).
