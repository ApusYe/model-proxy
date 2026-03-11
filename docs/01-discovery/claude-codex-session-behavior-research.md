# Claude Code and Codex Session Behavior Research

## Verified Claude Code behaviors
- Claude Code supports mid-session model changes through `/model`.
- Claude Code sub-agents run with their own context window and return results to the parent task.
- Claude Code supports a dedicated sub-agent model setting through `CLAUDE_CODE_SUBAGENT_MODEL`.
- Anthropic signed thinking blocks must be replayed only inside Anthropic-compatible signing domains.

## Verified Codex behaviors
- `codex fork --model ...` creates a forked session with a model override.
- `codex review -c model=...` runs review with an explicit model override.
- Codex supports parallel and delegated agent workflows.

## Scenario coverage targets

### Claude Code
- C1: single-model main session
- C2: same-domain model switch inside one session
- C3: main session plus sub-agent on Anthropic signing domain
- C4: sub-agent routed to a third-party compatible vendor
- C5: multiple sub-agent invocations in one parent session
- C6: `/commit -> Qwen -> main Opus` regression path
- C7: mixed `/model` switching and sub-agent routing
- C8: transparent replay across Anthropic API, Bedrock, and Vertex

### Codex
- O1: single-model main session
- O2: `fork --model` branch isolation
- O3: parallel work sessions in the same repo
- O4: `review` with model override
- O5: main session plus asynchronous delegated task on another model
- O6: branch result returns without corrupting the origin session

## Broker implications
- Cross-domain branches need vendor-local transcripts.
- Main sessions must only receive portable blocks.
- Same signing-domain traffic stays transparent.
