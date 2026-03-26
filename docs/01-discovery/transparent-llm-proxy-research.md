# Transparent LLM Traffic Detection & Proxy Research

> Date: 2026-03-20
> Status: Research complete, not viable for primary target (Claude Desktop)
> Context: Evaluate whether ModelProxy can identify LLM requests at the traffic level and proxy them transparently, enabling Claude Desktop App + external API mixed usage
> Related: `forward-proxy-research.md` (HTTPS_PROXY + MITM technical feasibility)

## Research Question

Current ModelProxy routes at the baseURL level — clients must explicitly set `ANTHROPIC_BASE_URL=http://localhost:PORT`. Can we instead detect LLM requests from network traffic and proxy them without app configuration? Primary target: Claude Desktop App with official subscription + external API supplement.

## LLM Traffic Fingerprint

LLM API requests have strong, distinguishable signatures at the HTTP protocol level:

| Layer | Signature | Reliability |
|-------|-----------|-------------|
| DNS/SNI | `api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com` | High (but only identifies vendor, not model) |
| URL path | `POST /v1/messages`, `POST /v1/chat/completions` | High |
| Headers | `x-api-key: sk-ant-*`, `anthropic-version: *`, `Authorization: Bearer sk-*` | High |
| Body structure | JSON with `model`, `messages`, `max_tokens` top-level fields | High |
| Response | `Content-Type: text/event-stream`, SSE `data:` lines with `content_block_delta` | High |

**Conclusion**: If plaintext HTTP is available, LLM request identification is near-100% accurate. The proxy already does this (extracts `model` from body JSON for routing).

**Problem**: All LLM API endpoints use HTTPS. Without TLS decryption, only SNI hostname and connection metadata are visible — insufficient for model-level routing.

## Claude Desktop App: Protocol Analysis

### Architecture

Claude Desktop is an Electron app (Chromium-based). Its chat functionality does NOT use the public Messages API (`api.anthropic.com/v1/messages`).

| Aspect | Claude Desktop App | Claude Code CLI |
|--------|--------------------|-----------------|
| Backend | Anthropic web services (`claude.ai` infrastructure) | `api.anthropic.com` (public API) |
| Authentication | Session token / OAuth (browser-style) | API key (`x-api-key`) |
| Protocol | Internal, undocumented, subject to change | Public Messages API (stable, versioned) |
| Base URL configurable | No | Yes (`ANTHROPIC_BASE_URL`) |
| Proxy support | System proxy (Chromium default) | `HTTPS_PROXY` env var |

### Why Traffic Interception Cannot Work for Claude Desktop

Even if MITM decryption succeeds (Electron apps generally don't do certificate pinning), three fundamental barriers remain:

1. **Authentication model mismatch**: Claude Desktop uses session tokens, not API keys. Third-party APIs require API keys. There is no mapping between the two — you cannot present a session token to an OpenAI endpoint.

2. **Protocol incompatibility**: The internal web service protocol is not the same as the public Messages API. Request/response format differences mean you cannot simply forward a Claude Desktop request to a third-party API without full protocol translation. This protocol is undocumented and changes without notice.

3. **Session state coupling**: Claude Desktop maintains server-side conversation state (history, artifacts, projects). Routing a request to a third-party API would break this state management — the third-party has no knowledge of the conversation context stored on Anthropic's servers.

### Electron Proxy Behavior (for reference)

- Respects macOS system proxy settings by default (Chromium network stack)
- Can be launched with `--proxy-server=http://localhost:PORT`
- Uses system certificate store (no custom certificate pinning in typical Electron builds)
- MITM is technically possible at the TLS layer, but useless given protocol incompatibility above

## Interception Approaches Evaluated

### Approach A: System Proxy + Selective MITM

Set macOS system HTTP proxy to ModelProxy. For known LLM API domains, perform MITM decryption; for others, tunnel transparently.

- **Feasibility**: Technically possible (covered in `forward-proxy-research.md`)
- **For Claude Desktop**: MITM succeeds but intercepted traffic cannot be meaningfully rerouted (protocol/auth mismatch)
- **For Claude Code**: Unnecessary — already supports `ANTHROPIC_BASE_URL`
- **Unique value**: GitHub Copilot and other closed clients (per existing research)

### Approach B: Hosts File / DNS Hijack

Redirect `api.anthropic.com` to `127.0.0.1` via `/etc/hosts`, serve local TLS.

- **Feasibility**: Works for API-based clients
- **For Claude Desktop**: Breaks the app entirely (can't reach web services)
- **Drawbacks**: Requires root, affects all applications, single point of failure

### Approach C: macOS Network Extension

Use `NETransparentProxyProvider` for system-level selective traffic interception.

- **Feasibility**: Most capable but requires special Apple entitlements
- **For Claude Desktop**: Same protocol incompatibility problem
- **Drawbacks**: Extremely complex, not available on Mac App Store without Apple approval

### Approach D: Application-Level Configuration (Current V1)

Clients set `ANTHROPIC_BASE_URL=http://localhost:PORT`. ModelProxy handles routing.

- **Feasibility**: Already implemented and working
- **Client coverage**: All clients supporting custom base URL (Claude Code, Cursor, Continue, OpenWebUI, ChatBox, etc.)
- **Limitation**: Cannot cover closed clients (GitHub Copilot) or apps without base URL config

## Conclusion

| Question | Answer |
|----------|--------|
| Can LLM requests be identified from traffic? | Yes — strong protocol fingerprint at HTTP layer |
| Can traffic be intercepted transparently? | Yes via MITM, but requires custom CA + significant development |
| Can this approach proxy Claude Desktop? | **No** — internal web service protocol, session auth, server-side state; none of these can be translated to third-party API calls |
| Best path for Claude Desktop + external API? | Not possible with current Claude Desktop architecture |
| Best path for mixed official/external usage? | Use clients that support custom base URL (Claude Code, Cursor, etc.) + ModelProxy routing |

## Recommendation

**Do not pursue transparent LLM traffic proxy for Claude Desktop.** The barrier is not technical (TLS/MITM) but architectural (closed protocol + session auth).

For expanding ModelProxy's client coverage:
1. Current reverse proxy (V1) covers the majority of configurable clients
2. Forward proxy mode (V2, per `forward-proxy-research.md`) adds GitHub Copilot and similar closed clients
3. Neither mode can make Claude Desktop work with external APIs — this requires Anthropic to expose a custom endpoint configuration in the app

The most impactful investment remains improving V1 coverage: broader vendor format support, better failover, and UI polish.
