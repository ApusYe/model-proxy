# ModelProxy

> macOS menu bar app, transparent local API proxy for multi-vendor model routing in Claude Code / Codex.

## Background

### Problem

Claude Code and Codex only support a single API endpoint (`ANTHROPIC_BASE_URL`). When developers want to use models from multiple vendors (Anthropic, DashScope/Qwen, GLM, etc.) in a single session, there's no native way to route different model tiers to different providers.

### Target User

AI developers and power users who use Claude Code or Codex daily and want to:
- Save costs by routing low-tier tasks to cheaper models (e.g., haiku tier -> qwen/glm)
- Keep high-tier tasks on Anthropic (opus/sonnet)
- Monitor token usage across providers

### Core Value

Transparent model routing without modifying any coding tool. Set environment variables, start the proxy, and everything works.

## Feasibility

### Why Build an App (vs script)

A Python proxy script was validated and works. But:
- Script requires manual terminal startup and env var management
- No visibility into routing status or token consumption
- No persistent configuration

A menu bar app provides: auto-start at login, visual monitoring, GUI configuration, one-click control.

### AI Replacement Risk

Low. This is infrastructure tooling. AI capability growth increases the value (more models = more need for routing).

## Market Research

Custom tool for personal use; market research skipped.

## Product Positioning

- Differentiation: Transparent local proxy, no modification to coding tools
- Moat: Personal tool, no moat needed
- Target: Self-use

## Risk & Mitigation (Pre-mortem)

| Failure Scenario | Dimension | Likelihood | Impact | Mitigation |
|-----------------|-----------|------------|--------|------------|
| Claude Code update changes API call pattern, proxy breaks | Technical | Medium | Severe | Proxy does standard HTTP forwarding, not dependent on Claude Code internals; monitor Anthropic API version changes |
| NIO HTTP server handles SSE streaming incorrectly, agent responses hang | Technical | Medium | Severe | Validate streaming with Python proxy as reference; streaming forwarding is a critical test case |
| Vendor API compatibility gaps (headers/response format not fully Anthropic-compatible) | Technical | Low | Manageable | DashScope compatibility already validated; test each new vendor individually |

## Feature Plan

### Complete Features

1. **Local HTTP Proxy** - Listen on localhost, intercept API requests, route by model ID to corresponding vendor
2. **Model Route Configuration** - Define model -> endpoint mappings, support exact match and prefix match
3. **Client Configuration** - Separate configs for Claude Code / Codex: port, model tier mappings, env var export
4. **Menu Bar Status** - System menu bar icon showing proxy on/off state
5. **Traffic Monitor** - Display recent requests: model, route target, response status
6. **Token Statistics** - Extract usage data from API responses, aggregate by model/vendor
7. **Vendor Management** - Add/edit/delete vendors (endpoint + API key + supported models)
8. **Launch at Login** - SMAppService integration
9. **Env Export** - One-click copy shell export commands for current config

### Explicitly Not Doing

- No model capability evaluation / auto-selection (user configures mappings)
- No API response content modification (pure passthrough)
- No multi-user / remote access (localhost only)
- No billing / payment features
- No MCP Server integration (future consideration)

### Tech Stack

| Technology | Choice | Reason |
|-----------|--------|--------|
| Language | Swift | macOS native, good system integration |
| UI | SwiftUI | Menu bar app + Settings window, SwiftUI sufficient |
| Network Proxy | SwiftNIO + NIOHTTP1 | Most mature HTTP server in Swift ecosystem, good streaming support |
| Persistence | UserDefaults + JSON files | Small config data, no database needed |
| Minimum OS | macOS 14 (Sonoma) | SwiftUI Observable macro, Settings scene |

### Data Strategy

- Config: JSON file for vendors and routing rules
- Token stats: In-memory accumulation, optional JSON persistence (by day/model)
- No collection of API request/response content

## References

- Validated Python proxy: `~/Code/Skills/indie-toolkit/llm-extend/proxy.py`
- DashScope Anthropic-compatible API: `https://coding.dashscope.aliyuncs.com/apps/anthropic`
