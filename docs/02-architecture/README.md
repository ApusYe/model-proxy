# Architecture

## Overview

```
Claude Code / Codex
  |
  | HTTP POST /v1/messages
  | (ANTHROPIC_BASE_URL = localhost:PORT)
  |
  v
+------------------+
|  ProxyServer     |  SwiftNIO HTTP Server
|  (localhost)     |
+------------------+
  |
  | RequestRouter: match model ID
  |
  +---> model matches vendor route ---> Vendor API (e.g., DashScope)
  |                                     - Replace API key
  |                                     - Forward request body
  |                                     - Relay response (streaming)
  |
  +---> no match (default) -----------> api.anthropic.com
                                        - Forward original API key
                                        - Relay response (streaming)
```

## Layers

| Layer | Responsibility | Key Types |
|-------|---------------|-----------|
| App | Menu bar lifecycle, SwiftUI scenes | `ModelProxyApp` |
| Views | Popover, settings, status display | `StatusPopover`, `SettingsView` |
| Proxy | HTTP server, routing, relay | `ProxyServer`, `RequestRouter`, `ResponseRelay` |
| Models | Config, vendor, statistics | `AppConfig`, `Vendor`, `TokenStats` |

## Data Flow

1. **Request in**: NIO channel reads HTTP request -> parse JSON body -> extract `model` field
2. **Route**: `RequestRouter` matches model against vendor routes (exact match > prefix match > default)
3. **Forward**: Create upstream HTTP request with correct endpoint + API key
4. **Relay**: Stream response bytes back to client channel (supports SSE streaming)
5. **Stats**: Extract `usage` from response JSON (for non-streaming) or final SSE event (for streaming), update `TokenStats`

## Persistence

- **Config**: `~/Library/Application Support/ModelProxy/config.json`
- **Stats**: In-memory `TokenStats`, optional daily JSON export
- **Secrets**: API keys stored in config (user's local machine only)
