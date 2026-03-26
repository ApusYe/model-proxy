---
type: crystal
status: active
tags: [proxy-encoding, content-encoding, decompression, minimax]
refs: []
---

# Decision Crystal: Proxy Content-Encoding Handling

Date: 2026-03-26

## Initial Idea
用 MiniMax 替换阿里云 Qwen3.5 来路由 Haiku 后，Claude Code 报 BrotliDecompressionError 和 socket connection closed unexpectedly。Menu bar 返回 200 但客户端报错。需要诊断并修复。

## Discussion Points
1. **Accept-Encoding 透传问题**: 发现代理把客户端的 `Accept-Encoding: br, gzip, deflate` 原封不动转发给上游，MiniMax 返回 Brotli 压缩响应。阿里云不支持 Brotli 所以之前没出问题。
2. **压缩数据破坏 SSE 流**: 代理的 stream normalizer 把 Brotli 二进制当文本解析，输出乱码；客户端收到乱码 + `Content-Encoding: br` 头，解压失败。
3. **修复策略选择**: 最初方案是直接去掉 Accept-Encoding（上游返回未压缩数据）。用户提出：如果代理能正确解压，既解决问题又提升性能。最终确认 AsyncHTTPClient 的 NIOHTTPDecompression 支持 gzip/deflate 但不支持 Brotli，因此采用：启用 gzip/deflate 自动解压 + 剔除 br。

## Rejected Alternatives
- **完全去掉 Accept-Encoding**: 用户认为损失了代理与上游之间的压缩传输性能，不够完善
- **启用解压 + 保留 Brotli**: AsyncHTTPClient 不支持 Brotli 解压，技术上不可行
- **只去掉响应 Content-Encoding 头**: 客户端收到的仍然是压缩数据（或被 normalizer 破坏的数据），不解决根本问题

## Decisions (machine-readable)
- [D-001] 启用 AsyncHTTPClient 的 gzip/deflate 自动解压（`decompression: .enabled(limit: .ratio(10))`）
- [D-002] 代理控制发往上游的 Accept-Encoding 头，只声明 `gzip, deflate`，不包含 `br`
- [D-003] 在 ResponseRelay 的 relay 和 replay 两个路径中防御性地去掉 `content-encoding` 响应头

## Constraints
- AsyncHTTPClient (NIOHTTPDecompression) 不支持 Brotli；如果未来支持了可以重新评估
- 代理作为内容感知中间人（SSE 解析、token 统计、stream normalization），必须保证收到的是未压缩文本
- 任何新增的上游 vendor 都可能支持不同的压缩格式，代理必须主动控制 Accept-Encoding 而非被动透传

## Source Context
- Design doc: none
- Design analysis: none
- Key files discussed: ModelProxy/Proxy/ProxyForwarder.swift, ModelProxy/Proxy/ResponseRelay.swift, ModelProxy/Proxy/ProxyServer.swift
