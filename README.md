# ModelProxy

> **macOS menu bar app · Transparent local API proxy for multi-vendor model routing**

Route AI model requests from Claude Code and Codex to different providers based on model ID.

![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift)
![macOS](https://img.shields.io/badge/macOS-14.0+-86909B?logo=apple)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-007AFF)

## What it does

ModelProxy sits between your AI coding tools (Claude Code, Codex) and AI model providers. It intercepts API requests and routes them to the right vendor—Anthropic for Opus/Sonnet, DashScope for Qwen, GLM for others—all configured by model ID matching.

## Why use it

| Benefit | Description |
|---------|-------------|
| **Cost optimization** | Route low-tier tasks to cheaper models (haiku → qwen/glm), keep high-tier tasks on Anthropic |
| **Zero modification** | No changes to Claude Code or Codex—just set environment variables and start the proxy |
| **Full visibility** | Menu bar status, live traffic log, token usage stats across all vendors |
| **Hot-reload config** | Change routing rules without restarting the proxy |

## Screenshot

*Coming soon*

## Quick Start

### 1. Build

```bash
# Clone the repository
git clone git@github.com:n0rvyn/model-proxy.git
cd model-proxy

# Open in Xcode
open ModelProxy.xcodeproj

# Build and run (⌘R)
```

### 2. Configure

The app lives in your menu bar. Click the icon to:
- Start/stop the proxy server
- Configure vendors (endpoints + API keys)
- Set up model routing rules
- View traffic and token stats

### 3. Point your tools to the proxy

```bash
# Claude Code / Codex
export ANTHROPIC_BASE_URL=http://localhost:8080
```

Now requests to `claude-opus-4-6` go to Anthropic, `qwen-plus` goes to DashScope, etc.

## Features

### Core

- **Local HTTP proxy server** - Built on SwiftNIO for async, non-blocking I/O
- **Model-based routing** - Exact match and prefix match for flexible routing
- **Multi-vendor support** - Anthropic, DashScope (Qwen), GLM, and more
- **SSE streaming** - Full passthrough for streaming responses

### Monitoring

- **Traffic log** - See every request: model, route target, status, duration
- **Token statistics** - Aggregated usage by model and vendor
- **Real-time status** - Menu bar icon shows proxy state

### Quality of life

- **Launch at login** - Auto-start via SMAppService
- **One-click env export** - Copy shell export commands for current config
- **Hot-reload configuration** - Changes take effect immediately

## Architecture

```
┌─────────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│  Claude Code    │     │   ModelProxy        │     │  AI Providers    │
│  Codex          │────▶│  - ProxyServer      │────▶│  - Anthropic     │
│  (localhost)    │     │  - RequestRouter    │     │  - DashScope     │
└─────────────────┘     │  - ResponseRelay    │     │  - GLM           │
                        └─────────────────────┘     └──────────────────┘
```

### Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 6 |
| UI | SwiftUI + MenuBarExtra |
| Proxy Server | SwiftNIO + NIOHTTP1 |
| Config Storage | JSON + UserDefaults |
| Minimum OS | macOS 14 (Sonoma) |

## Configuration

### Example routing setup

```json
{
  "vendors": [
    {
      "name": "Anthropic",
      "endpoint": "https://api.anthropic.com",
      "apiKey": "sk-ant-...",
      "models": ["claude-opus-4-6", "claude-sonnet-4-6"]
    },
    {
      "name": "DashScope",
      "endpoint": "https://dashscope.aliyuncs.com",
      "apiKey": "sk-...",
      "models": ["qwen-plus", "qwen-max"]
    }
  ],
  "routing": {
    "claude-opus": "Anthropic",
    "claude-sonnet": "Anthropic",
    "qwen": "DashScope"
  }
}
```

## Development

### Build from command line

```bash
xcodebuild -project ModelProxy.xcodeproj \
  -scheme ModelProxy \
  -destination 'platform=macOS' \
  build
```

### Run tests

```bash
xcodebuild -project ModelProxy.xcodeproj \
  -scheme ModelProxy \
  -destination 'platform=macOS' \
  test
```

## Project Structure

```
ModelProxy/
├── App/               # App entry, ModelProxyApp.swift
├── Proxy/             # HTTP proxy server (SwiftNIO)
│   ├── ProxyServer.swift
│   ├── RequestRouter.swift
│   └── ResponseRelay.swift
├── Models/            # Data models and config
│   ├── AppConfig.swift
│   ├── Vendor.swift
│   └── ClientConfig.swift
├── Services/          # Business logic
└── Views/             # SwiftUI views
    ├── StatusPopover.swift
    └── SettingsView.swift
```

## Roadmap

- [ ] MCP Server integration
- [ ] Model capability auto-discovery
- [ ] Request/response transformation (opt-in)
- [ ] Remote access (multi-user)

## License

MIT

## Acknowledgments

Built for AI developers who juggle multiple model providers in their daily workflow.
