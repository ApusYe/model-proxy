# **Decision Crystal: ModelProxy认证与路由策略**

**Date**: 2026-03-06

## Initial Idea

ModelProxy需要透明代理Claude Code和Codex发送的请求到不同的AI厂商。关键问题：
1. 认证方式有两种（API Key和OAuth），怎么统一处理？
2. 模型映射如何实现？
3. 未映射的模型怎么办？

## Discussion Points

1. **认证替换的通用方案**：
   - 最初假设：两种认证方式需要分别处理
   - 发现：查询Anthropic官方API文档，两种方式都通过HTTP headers传递
     - API Key: `x-api-key` header
     - OAuth: `Authorization: Bearer` header
   - 决定：统一处理 → 在headers中进行替换，不区分认证类型，都支持

2. **baseURL处理**：
   - 最初忽视了baseURL需要替换
   - 发现：Claude Code官方GitHub repo中ANTHROPIC_BASE_URL的默认值为 `https://api.anthropic.com`
   - 决定：原始请求的baseURL来自Claude Code repo的默认值 `https://api.anthropic.com`，替换为目标vendor的baseURL

3. **模型映射结构**：
   - 原始设计：`modelMappings: [model: vendorID]`（只指定vendor，不指定目标model）
   - 用户纠正：目标model应该在映射中，不然怎么转发？
   - 现在改为：`modelMappings: [sourceModel: {targetModel: String, targetVendorID: UUID}]`

4. **未映射模型处理**：
   - 原始设计：使用defaultVendorID（转发到某个default vendor）
   - 用户纠正：未映射就按原请求转发，就是不代理！
   - 决定：未映射模型 → ModelProxy不处理，直接用原baseURL透传请求

5. **模型字段替换**：
   - 当model被映射时，需要修改请求JSON中的`model`字段
   - 从源model名称 → 目标vendor的model名称（如claude-haiku-4-5 → qwen-turbo）

## Rejected Alternatives

- **处理两种认证方式分别逻辑**：拒绝 —— 两种方式本质都是header替换，不需要分别处理
- **使用defaultVendor转发未映射模型**：拒绝 —— 用户明确说"未映射就按原请求转发，不代理"
- **Phase 2仅支持API Key，OAuth留给Phase 3**：拒绝 —— 两种认证方式都要支持，替换逻辑相同

## Decisions (machine-readable)

- [D-001] 认证替换统一通过HTTP headers：替换 `x-api-key` 或 `Authorization` header为目标vendor的凭证，支持API Key和OAuth两种方式
- [D-002] baseURL来源：Claude Code官方repo中ANTHROPIC_BASE_URL的默认值为 `https://api.anthropic.com`，ModelProxy识别并替换为目标vendor的baseURL
- [D-003] modelMappings结构：`[sourceModel: {targetModel, targetVendorID}]`，包含目标model名称和目标vendor UUID
- [D-004] 模型字段替换：当model被映射时，修改请求body中的`model`字段为targetModel值
- [D-005] 未映射模型处理：ModelProxy不处理，直接用原baseURL和原认证信息转发请求（透传）
- [D-006] 审计日志：记录所有转发请求（timestamp, sourceModel, targetModel, targetVendor, authType, status等）

## Constraints

- ModelMappings必须同时指定targetModel和targetVendorID，两个都不能省
- baseURL识别：原始请求的baseURL来自Claude Code repo的默认值 `https://api.anthropic.com`，需要识别并替换为目标vendor的baseURL
- 认证替换必须同时支持API Key和OAuth两种方式，替换逻辑统一

## Scope Boundaries

- **IN**: 基于sourceModel到vendor的精确映射实现路由和转发
- **IN**: 替换认证信息（`x-api-key` header 或 `Authorization` header）为目标vendor的凭证
- **IN**: 替换请求body中的model字段为targetModel
- **IN**: 识别并替换baseURL（`https://api.anthropic.com` → 目标vendor的baseURL）
- **IN**: 未映射模型的透传（不代理）
- **IN**: 审计日志记录转发流量详情
- **OUT**: 厂商级别的model能力自动映射（Phase 3+）

## Source Context

- Design doc: none
- Design analysis: none
- Key files discussed:
  - ClientConfig.swift (modelMappings结构)
  - RoutingSnapshot (Task 1)
  - ProxyForwarder (Task 3)
  - Anthropic API文档
  - Claude Code官方GitHub repo (ANTHROPIC_BASE_URL默认值)
