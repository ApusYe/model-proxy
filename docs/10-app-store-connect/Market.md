# Model Proxy - App Store Marketing

## App Information | 应用信息

| Field | Value |
|-------|-------|
| App Name | Model Proxy |
| Subtitle | API Proxy for AI Models |
| Category | Utilities |
| Price | Free |
| Copyright | © 2026 Norvyn Zhang |

## Description | 应用描述

Model Proxy is a lightweight macOS menu bar utility for developers who work with multiple AI service providers. It runs a local HTTP proxy server that transparently routes API requests to the right provider based on model ID.

### Key Features

- **Multi-Vendor Routing**: Route requests to Anthropic, OpenAI, Alibaba Cloud, or any custom API endpoint based on model ID matching.
- **Transparent Proxy**: Works with Claude Code, Codex CLI, and any tool that makes HTTP API calls. No code changes needed.
- **Real-Time Traffic Monitor**: See every request flowing through the proxy with model, route type, status, and duration.
- **Token Usage Tracking**: Track input and output token consumption per model across sessions.
- **Flexible Configuration**: Define vendors, model mappings, and per-client settings with hot-reload support.
- **Privacy First**: Runs entirely on localhost. API keys stored locally. Request content is never read or logged.

### Who Is This For

- Developers using AI coding assistants with multiple model providers
- Teams who want to route different models to cost-effective alternatives
- Anyone who needs visibility into their AI API usage

---

Model Proxy 是一款轻量级 macOS 菜单栏工具，面向使用多个 AI 服务商的开发者。它运行本地 HTTP 代理服务器，根据模型 ID 将 API 请求透明路由到正确的服务商。

### 核心功能

- **多服务商路由**：根据模型 ID 匹配，将请求路由到 Anthropic、OpenAI、阿里云或任何自定义 API 端点。
- **透明代理**：适用于 Claude Code、Codex CLI 及任何 HTTP API 调用工具，无需修改代码。
- **实时流量监控**：查看通过代理的每个请求的模型、路由类型、状态和耗时。
- **Token 用量追踪**：按模型追踪输入和输出 Token 消耗。
- **灵活配置**：定义服务商、模型映射和客户端设置，支持热重载。
- **隐私优先**：完全在 localhost 运行，API 密钥本地存储，请求内容不被读取或记录。

## Keywords | 关键词

api,proxy,ai,model,routing,developer,claude,openai,anthropic,llm

## Support URL

https://notion.so/support-page-url

## Privacy Policy URL

https://notion.so/privacy-policy-url

## App Review Notes | 审核备注

Model Proxy is a developer utility that runs a local HTTP proxy server on localhost. It routes API requests from AI coding tools (such as Claude Code and Codex CLI) to different AI service providers based on model ID configuration.

Key points for review:
- The app listens only on localhost (127.0.0.1) and is not accessible from other devices.
- No user account or login is required.
- Users provide their own API keys for third-party AI services.
- The app does not read, modify, or store API request/response content.
- No test account is needed to review this app.

To test: Launch the app, click the menu bar icon, and explore the configuration panel and traffic log. The proxy functionality requires configuring an AI development tool to point to the local proxy address.
