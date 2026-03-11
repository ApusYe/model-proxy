# Session Lineage DAG Broker for Cross-Vendor Agent Sessions

## 0. Summary / 摘要
- 将 ModelProxy 从“按单次请求做透明 model 路由”升级为“有状态的会话代理 / transcript broker”。
- 目标是同时保住三件事：Claude Code / Codex 的多模型委派能力、第三方上游的低成本执行价值、Anthropic 主会话不被非签名域 thinking 污染。

## 1. Constraints / 约束前置
- 用户明确要求：
  - 独立分支已创建：`session-lineage-dag-plan`
  - 先调研 Claude Code 与 Codex 的多模型 / fork / sub-agent 场景，写完整实施计划并 review
  - 计划 review 成功前，不执行代码实现
  - 方案优先级：性能与功能完整性优先，不受当前“transparent proxy”产品定位限制
  - 测试必须覆盖 Claude Code 与 Codex 的相关场景
- 技术约束：
  - 当前上游是 stateless `POST /v1/messages`，本地代码中没有 session ID，也没有 agent/fork 状态
  - 现有 proxy 只会替换顶层 `model`，其余 body 字节原样保留，包括 `thinking` / `signature`
  - 当前响应 relay 是 raw byte relay；成功响应不会被解析或改写
  - 现有配置模型只描述 vendor、client、model mapping，不描述 transcript portability / signing domain
- 禁止事项：
  - 本计划阶段不改源码、不跑 build/test、不做写入型验证
  - 不基于未读文件或未查官方资料对 Claude Code / Codex 行为下结论

## 2. Goals & Non-Goals / 目标与非目标
- Goals:
  - [ ] 设计一个最优解，允许一个主会话内多次分支到不同 vendor/model 执行子任务，同时保证主会话可继续
  - [ ] 完整覆盖 Claude Code 已确认支持的 mid-session model switch、sub-agent、独立 subagent model 场景
  - [ ] 完整覆盖 Codex 已确认支持的 session fork、review workflow、multi-agent / parallel delegation 场景
  - [ ] 给出可执行的架构、文件级改动清单、测试矩阵与回滚策略
  - [ ] 明确哪些 transcript 内容可跨 vendor 流动，哪些必须隔离或归约
- Non-goals:
  - 不在本 plan 阶段实现代码
  - 不在本 plan 阶段决定最终 UI 文案细节
  - 不追求兼容未知、未证实存在的 Claude Code / Codex 内部私有协议字段

## 3. Current State Recon / 现状勘察（只读证据）

### 3.1 当前请求路径
- `ProxyChannelHandler.channelRead()` 收满请求后，直接把 `head/body` 交给 `ProxyForwarder.forward()`；无 session state、无 per-conversation memory。[ModelProxy/Proxy/ProxyChannelHandler.swift:30](./ModelProxy/Proxy/ProxyChannelHandler.swift#L30)
- `ProxyForwarder.forward()` 只做：
  - 提取 API key
  - 用 `RequestRouter.resolve()` 解析顶层 `model`
  - 记录 `thinking/signature` 诊断日志
  - 原样 body 转给 `executeUpstream()`
  - 收到响应后交给 `ResponseRelay.relay()` 原样回写。[ModelProxy/Proxy/ProxyForwarder.swift:11](./ModelProxy/Proxy/ProxyForwarder.swift#L11)
- `RequestRouter.resolve()` 仅解析 request JSON 顶层 `model`，完全不知道主会话 / sub-agent / fork。[ModelProxy/Proxy/RequestRouter.swift:20](./ModelProxy/Proxy/RequestRouter.swift#L20)
- `RoutingSnapshot.resolve()` 只做 source-model -> RouteTarget 解析；无 transcript portability 规则。[ModelProxy/Proxy/RoutingSnapshot.swift:125](./ModelProxy/Proxy/RoutingSnapshot.swift#L125)
- `ResponseRelay.relay()` 按 chunk 透传 SSE / 非流式响应；成功响应不解析 content block，不做任何 sanitizer / merge reducer。[ModelProxy/Proxy/ResponseRelay.swift:17](./ModelProxy/Proxy/ResponseRelay.swift#L17)

### 3.2 当前配置与入口
- `Vendor` 目前只有 endpoint、key、timeout、compatibleClientID、supportedModels；无 signing-domain / replay-portability 能力位。[ModelProxy/Models/Vendor.swift:3](./ModelProxy/Models/Vendor.swift#L3)
- `ConfigStore` 负责 config.json 读写与迁移；后续若新增 vendor/session policy 字段，需要从这里做兼容迁移。[ModelProxy/Services/ConfigStore.swift:32](./ModelProxy/Services/ConfigStore.swift#L32)
- `VendorEditSheet` 当前 UI 仅支持基础 vendor 属性编辑；若要开放 transcript policy / domain capability，需要扩展此处。[ModelProxy/Views/VendorEditSheet.swift:24](./ModelProxy/Views/VendorEditSheet.swift#L24)

### 3.3 已确认问题证据
- 本地测试已明确验证：`replaceModelField()` 只改顶层 `model`，不会碰 `thinking/signature`。[ModelProxyTests/ModelProxyTests.swift:558](./ModelProxyTests/ModelProxyTests.swift#L558)
- 用户提供的 debug 日志已证实：
  - `/commit` 对应的 Haiku->Qwen 请求在出站前已携带 `msg[1]..msg[27]` 全签名 thinking 历史
  - 后续主会话 Opus->Anthropic 请求再次携带这批 signed thinking 历史
  - Anthropic 在 `messages.1.content.0` 直接返回 `Invalid signature in thinking`
- 这说明当前冲突点是：**Anthropic signed thinking replay × 请求级跨 vendor 透明转发**。

### 3.4 官方行为边界（已查证）
- Claude Code:
  - 支持 `/model` 在 session 中切换模型；`opusplan` 还会在 plan 与 execution 间自动换模型。来源：Anthropic Claude Code Model Configuration docs
  - 支持 subagents；每个 subagent 有独立 context window，并在任务结束后返回结果。来源：Anthropic Subagents docs
  - 官方 settings 文档列出 `CLAUDE_CODE_SUBAGENT_MODEL` 环境变量，证明 subagent model 是可单独配置维度。来源：Anthropic Claude Code Settings docs
  - tool use / extended thinking 文档明确要求 thinking blocks 原样回放，并通过 cryptographic signatures 校验真实性；兼容域只声明 Anthropic API / Bedrock / Vertex。来源：Anthropic Context Windows / Extended Thinking docs
- Codex:
  - 本机 `codex --help` 显示原生支持 `fork` 命令，且 `fork --help` 明确支持 `--model` 覆盖，这证明“fork 后用其它模型继续”是本地 CLI 已支持能力
  - 本机 `codex review --help` 显示 review 是独立命令，模型可通过 `-c model=...` 配置覆盖
  - OpenAI 官方 Codex 产品页明确写明 multi-agent workflows；OpenAI 官方 Codex 发布文写明并行任务、独立环境、异步 delegation 是产品方向

## 4. End-to-End Data Path / 完整路径与并行入口检查

### 4.1 当前主路径
1. `ProxyChannelHandler.channelRead()` 收到完整 HTTP request  
   位置：[ModelProxy/Proxy/ProxyChannelHandler.swift:30](./ModelProxy/Proxy/ProxyChannelHandler.swift#L30)
2. `ProxyForwarder.forward()` 读取 body、记录 thinking/signature 结构、解析 route  
   位置：[ModelProxy/Proxy/ProxyForwarder.swift:11](./ModelProxy/Proxy/ProxyForwarder.swift#L11)
3. `RequestRouter.resolve()` 提取顶层 `model`  
   位置：[ModelProxy/Proxy/RequestRouter.swift:20](./ModelProxy/Proxy/RequestRouter.swift#L20)
4. `RoutingSnapshot.resolve()` 解析 target  
   位置：[ModelProxy/Proxy/RoutingSnapshot.swift:125](./ModelProxy/Proxy/RoutingSnapshot.swift#L125)
5. `ProxyForwarder.executeUpstream()` 替换顶层 `model` 后发往目标 vendor  
   位置：[ModelProxy/Proxy/ProxyForwarder.swift:219](./ModelProxy/Proxy/ProxyForwarder.swift#L219)
6. `ResponseRelay.relay()` 把响应原样回给客户端  
   位置：[ModelProxy/Proxy/ResponseRelay.swift:17](./ModelProxy/Proxy/ResponseRelay.swift#L17)

### 4.2 并行路径与架构冲突
- ⚠️ 并行路径：当前系统中，同一“会话延续”有两条无协调的语义路径
  - 路径 A：客户端在本地构造 transcript 并重放给上游
  - 路径 B：proxy 仅按单次请求做 model/vendor 路由，不关心 transcript portability
- 协调机制：无
- 计划处理：新增 **Session Lineage Broker**，成为 transcript portability 的唯一协调层；后续所有跨 vendor/fork 语义统一由该层决策

## 5. Scenario Matrix / 场景矩阵

### 5.1 Claude Code 场景（本次必须覆盖）
- C1: 单模型主会话，无 subagent，无 vendor 切换
- C2: 主会话 mid-session `/model` 切换，但仍在同一 signing domain（Anthropic API / Bedrock / Vertex）
- C3: 主会话固定在 Anthropic signing domain；subagent 单独使用 Haiku / Sonnet / Opus
- C4: subagent model 通过 `CLAUDE_CODE_SUBAGENT_MODEL` 或 subagent 配置单独指定，且映射到第三方兼容 vendor
- C5: 同一主会话中多次调用 subagent，且各 subagent 可能路由到不同 vendor
- C6: 主会话 -> subagent(Qwen) -> 返回主会话 -> 主会话继续走 Anthropic；这是当前已复现故障场景
- C7: 主会话中模型多次切换 + subagent 混用（如 `/model sonnet` 之后再次 fork）
- C8: 同 signing-domain 之间的 replay（Anthropic API ↔ Bedrock / Vertex）保持透明

### 5.2 Codex 场景（本次必须覆盖）
- O1: 单模型主会话，无 fork
- O2: `codex fork --model ...` 在已有会话上 fork 到不同模型
- O3: 同一仓库内多个 parallel work sessions / worktrees 并行运行
- O4: `codex review` 独立 agent-style workflow，模型通过 `-c model=...` 覆盖
- O5: 主会话继续使用模型 A，同时异步 fork / review / cloud task 用模型 B
- O6: Codex 多 agent / parallel task 返回结果后继续原会话

### 5.3 明确不纳入首批验证的场景
- 未能从官方文档或本机 CLI 证实存在的“nested subagent recursively spawning subagent”场景
- 未能证实的厂商私有 thinking block 语义

## 6. Options / 方案选择

### Option A: Stateless Request/Response Scrubber
- Summary:
  - 出 Anthropic signing domain 前，剥掉 request 中 replay-sensitive blocks；回站时也剥掉 response 中的 non-portable blocks
- Changes:
  - 主要改 `ProxyForwarder.swift` 与 `ResponseRelay.swift`
- Pros:
  - 性能高、额外状态少
  - 不需要维护会话 DAG
- Cons:
  - 只能做局部包改写，无法表达 branch lineage、result merge、vendor-local transcript
  - 很难覆盖 Claude/Codex 多次 fork / 并行 agent 场景
- Risks:
  - 对 SSE 改写要求高；协议脆弱
  - 会不断叠加 vendor-specific if/else
- Validation:
  - 只能验证“单次请求不污染”，无法验证复杂 lineage
- Rollback:
  - 删除 scrubber 路径，回到当前 transparent relay
- Cost:
  - Medium

### Option B: Signing-Domain Guard + Passthrough Fallback
- Summary:
  - 检测到 replay-sensitive 请求就强制回 Anthropic signing domain
- Pros:
  - 稳
  - 最少协议改写
- Cons:
  - 直接牺牲第三方分流价值
  - 无法满足“保留低成本 vendor thinking 能力”
- Risks:
  - 用户感知成本上升，主功能缩水
- Validation:
  - 简单
- Rollback:
  - 移除 guard
- Cost:
  - Low

### Option C: Session Lineage DAG + Dual Transcript Isolation + Branch Merge Reducer（推荐）
- Summary:
  - 引入 broker 层，把会话从线性 transcript 升级为 lineage DAG
  - 每个 signing domain / vendor branch 维护自己的 canonical transcript
  - merge 回主会话时只传 portable result，不回灌 raw thinking/signature
- Changes:
  - 新增 session broker、request projector、response normalizer、branch merge reducer、capability model
  - proxy 从 request-level router 升级为 session-aware broker
- Pros:
  - 同时保住：
    - 第三方分流价值
    - 第三方 vendor 的内部 thinking 能力
    - 主会话稳定性
    - Claude / Codex 多 agent / fork / parallel workflow 的扩展性
  - 可把 vendor portability 问题抽象成统一规则
- Cons:
  - 不再是透明 proxy
  - 实现与调试复杂度最高
- Risks:
  - 需要定义 lineage key、branch key、portable block 规则
  - 需要新的测试基座
- Validation:
  - 可用明确的 scenario matrix 做端到端验证
- Rollback:
  - 保留旧 transparent pipeline behind feature flag，按 client 或 config 切换
- Cost:
  - High

### Why Option C
- 用户明确要“最优解”，并暂时不受当前 App 定位限制
- Option C 是唯一同时覆盖 Claude Code subagent、Codex fork/review、多 vendor thinking、主会话连续性 的方案

## 7. Recommended Architecture / 推荐架构

### 7.1 核心对象
- `SessionLineageBroker`
  - 唯一协调层；输入为 client identity + request body + resolved route
  - 负责 lineage key 解析、branch 创建、domain decision、projection、merge
- `ConversationLineage`
  - 一个主会话的 lineage DAG
  - 包含主干、多个 branch、每个 branch 的 signing/transcript domain
- `BranchTranscript`
  - vendor-local canonical transcript
  - 存储 portable / nonportable block 分层结果
- `TranscriptProjector`
  - 将某个 canonical transcript 投影成目标 vendor 可安全消费的 request body
- `BranchMergeReducer`
  - 从 branch 响应中提炼可携带回主会话的 portable result
- `VendorDomainPolicy`
  - 描述 vendor 所属 `signingDomain`、`transcriptDomain`、`replayPolicy`

### 7.1.1 Protocol 边界
- `SessionLineageBrokering`
  - broker 协议；`SessionLineageBroker` 为默认实现
- `TranscriptProjecting`
  - projector 协议；`TranscriptProjector` 为默认实现
- `BranchMergeReducing`
  - reducer 协议；`BranchMergeReducer` 为默认实现
- `PortableContentNormalizing`
  - response normalizer 协议；`PortableContentNormalizer` 为默认实现
- 目的：
  - 满足项目规则“所有 Service 使用 Protocol 抽象”
  - 让 broker / projector / reducer 可独立单测与替换

### 7.2 数据规则
- `portable blocks`
  - `text`
  - 安全的 `tool_use` / `tool_result`
  - 可归约的摘要 / structured result
- `nonportable blocks`
  - Anthropic `thinking`
  - Anthropic `redacted_thinking`
  - `signature`
  - 第三方 vendor 自有 thinking / reasoning blocks
- 规则：
  - branch 内部允许保留 vendor-local thinking
  - merge 回主会话时只允许 portable blocks
  - 同 signing domain 间允许 raw replay；跨 signing domain 时必须经过 projector + reducer

### 7.3 关键推导键
- `lineageKey`
  - 基于 client identity + 可稳定提取的 request transcript fingerprint
  - 计划实现为 `clientID + canonicalPortablePrefixHash`
  - `canonicalPortablePrefixHash` 由以下序列生成：
    - message role
    - content block type
    - `text` 文本 hash
    - `tool_use` 的 `id/name/input` hash
    - `tool_result` 的 `tool_use_id/content` hash
  - 明确排除：
    - `thinking`
    - `redacted_thinking`
    - `signature`
    - vendor-private reasoning blocks
  - 不使用顶层 `model`、channel ID、请求时间戳作为 lineage 标识
- `branchKey`
  - 基于 `lineageKey + divergencePointHash + targetTranscriptDomain`
  - `divergencePointHash` = 当前请求相对主干新增的 portable suffix hash
- `signingDomain`
  - `anthropic-official`
  - `bedrock-anthropic`
  - `vertex-anthropic`
  - `compatible-third-party`
- `transcriptDomain`
  - 用于决定 canonical transcript 的归属和 portability 规则；不必等同于 baseURL host

### 7.4 Anthropic Beta Helper（次要，不作为主方案）
- 可调研是否利用 Anthropic `clear_thinking_20251015` beta 优化主会话 transcript 累积
- 但它不能替代 cross-vendor lineage broker，因为问题不是上下文大小，而是跨域 replay 语义

### 7.5 Broker 生命周期与缓存策略
- 主方案：**内存态 broker + 可重建 lineage**
- 不做磁盘持久化 session store
- 理由：
  - 请求本身已携带足够 transcript，可在 app 重启后重新构建 lineage
  - 避免持久化敏感 transcript 元数据
  - 性能优先，减少磁盘 I/O
- 运行时策略：
  - 按 `clientID` 维护 LRU lineage cache
  - branch 完成后保留最近 N 个 lineage / branch 元信息用于后续 merge 与 debug
  - cache miss 时从当前 request body 重建主干 portable graph

### 7.6 Merge Payload 规则
- reducer **不做自由摘要**，避免损失工具执行结果与可见输出
- reducer 输出固定为 `PortableAssistantTurn`：
  - 可见 `text`
  - 安全 `tool_use`
  - 安全 `tool_result`
  - vendor/domain provenance metadata（仅本地，不回传上游）
- reducer 不输出：
  - raw thinking
  - redacted_thinking
  - signature
  - vendor-private reasoning traces

## 8. Planned Changes / 文件与改动概览

### Files to Modify
- `ModelProxy/Proxy/ProxyChannelHandler.swift`
  - Purpose: 将“单次请求转发”改为先交给 session broker 做 lineage 解析
  - Type of change: 核心路径改造
- `ModelProxy/Proxy/ProxyForwarder.swift`
  - Purpose: 从 request-level router 升级为 broker-aware forwarder；引入 request projection / branch merge hooks
  - Type of change: 核心路径改造
- `ModelProxy/Proxy/ResponseRelay.swift`
  - Purpose: 为成功响应加入 optional normalizer / reducer，不再只做 raw relay
  - Type of change: 核心路径改造
- `ModelProxy/Proxy/ProxyServer.swift`
  - Purpose: 注入 broker 及其依赖
  - Type of change: 依赖注入
- `ModelProxy/Proxy/RoutingSnapshot.swift`
  - Purpose: RouteTarget 扩展 domain / replay policy 能力位
  - Type of change: 数据模型扩展
- `ModelProxy/Models/Vendor.swift`
  - Purpose: 增加 vendor transcript/signing capability 字段
  - Type of change: 配置模型扩展
- `ModelProxy/Models/AppConfig.swift`
  - Purpose: 配置承载新 domain policy / feature flag
  - Type of change: 配置模型扩展
- `ModelProxy/Services/ConfigStore.swift`
  - Purpose: config.json 向后兼容迁移
  - Type of change: 迁移 / persistence
- `ModelProxy/Views/VendorEditSheet.swift`
  - Purpose: 编辑 vendor domain / replay policy
  - Type of change: 设置 UI 扩展
- `ModelProxyTests/ModelProxyTests.swift`
  - Purpose: 保留并迁移现有测试；部分测试拆分到新文件
  - Type of change: 测试重组

### Files to Add
- `ModelProxy/Models/SessionLineage.swift`
  - Purpose: lineage DAG、branch、portable/nonportable block 结构
- `ModelProxy/Models/TranscriptDomain.swift`
  - Purpose: signingDomain / transcriptDomain / replay policy 枚举与 helper
- `ModelProxy/Services/SessionLineageBroker.swift`
  - Purpose: 核心 broker
- `ModelProxy/Services/TranscriptProjector.swift`
  - Purpose: 请求投影
- `ModelProxy/Services/BranchMergeReducer.swift`
  - Purpose: branch -> main result reduction
- `ModelProxy/Services/PortableContentNormalizer.swift`
  - Purpose: 统一不同 vendor 返回的 portable content block
- `ModelProxy/Services/ConversationFingerprint.swift`
  - Purpose: lineageKey / branchKey 生成
- `ModelProxyTests/SessionLineageBrokerTests.swift`
  - Purpose: lineage / branch / replay policy 纯逻辑测试
- `ModelProxyTests/TranscriptProjectorTests.swift`
  - Purpose: 各种 block portability 与 cross-domain 投影测试
- `ModelProxyTests/BranchMergeReducerTests.swift`
  - Purpose: merge 规则测试
- `ModelProxyTests/ProxySessionIntegrationTests.swift`
  - Purpose: Claude/Codex 场景矩阵集成测试
- `docs/01-discovery/claude-codex-session-behavior-research.md`
  - Purpose: 固化官方调研与场景矩阵，便于后续维护

### Files to Remove (if any)
- None planned in first implementation

## 9. Milestones & Acceptance Criteria / 里程碑与验收标准

### Milestone 1: 固化官方行为矩阵与领域模型
- What changes:
  - 新建调研文档，记录 Claude Code / Codex 已确认支持的多模型与 sub-agent 场景
  - 定义 `signingDomain`、`transcriptDomain`、`portable block` 术语
- Files:
  - `docs/01-discovery/claude-codex-session-behavior-research.md`
  - `ModelProxy/Models/TranscriptDomain.swift`
  - `ModelProxy/Models/Vendor.swift`
  - `ModelProxy/Models/AppConfig.swift`
- Acceptance criteria:
  - 文档覆盖本计划中的 C1-C8、O1-O6 场景
  - 新配置模型能表达 vendor portability policy
- Rollback:
  - 删除新增模型与文档，配置回退到旧 schema

### Milestone 2: 引入 Session Lineage Broker 与 request projection
- What changes:
  - 新增 broker、fingerprint、lineage/branch 模型
  - 请求路径从 `ProxyForwarder.forward()` 接入 broker
  - 跨 domain request 不再直接原样透传，而是先做 transcript projection
- Files:
  - `ModelProxy/Services/SessionLineageBroker.swift`
  - `ModelProxy/Services/ConversationFingerprint.swift`
  - `ModelProxy/Services/TranscriptProjector.swift`
  - `ModelProxy/Models/SessionLineage.swift`
  - `ModelProxy/Proxy/ProxyChannelHandler.swift`
  - `ModelProxy/Proxy/ProxyForwarder.swift`
  - `ModelProxy/Proxy/ProxyServer.swift`
- Acceptance criteria:
  - broker 能稳定区分 lineage 与 branch
  - 对同 signing domain 请求，行为与当前透明转发一致
  - 对跨 signing domain 请求，request body 被安全投影
- Rollback:
  - feature flag 切回旧 forward path

### Milestone 3: 响应 normalizer 与 branch merge reducer
- What changes:
  - 非透明域响应进入 reducer，生成 portable result
  - 主会话不再回灌第三方 raw thinking/signature
- Files:
  - `ModelProxy/Services/BranchMergeReducer.swift`
  - `ModelProxy/Services/PortableContentNormalizer.swift`
  - `ModelProxy/Proxy/ResponseRelay.swift`
  - `ModelProxy/Proxy/ProxyForwarder.swift`
- Acceptance criteria:
  - 当前已复现的 `/commit -> Qwen -> 主会话继续 Opus` 场景不再触发 `Invalid signature`
  - 第三方 branch 结果仍能被主会话消费
- Rollback:
  - 关闭 reducer，恢复原 response relay

### Milestone 4: 配置、UI、迁移与 observability
- What changes:
  - vendor 编辑 UI 增加 domain/replay policy
  - config.json 迁移
  - debug log 增加 lineage/branch/reducer 观测字段
- Files:
  - `ModelProxy/Models/Vendor.swift`
  - `ModelProxy/Models/AppConfig.swift`
  - `ModelProxy/Services/ConfigStore.swift`
  - `ModelProxy/Views/VendorEditSheet.swift`
  - `ModelProxy/Proxy/ProxyForwarder.swift`
  - `ModelProxy/Services/AppLogManager.swift`
- Acceptance criteria:
  - 旧 config 能无损迁移
  - 用户能显式配置 vendor domain policy
  - UI 范围限定为：仅扩展现有 `VendorEditSheet` 的 `Vendor Details` section；不新增页面、不改导航
  - 调试日志可追溯每次 merge/reduce 决策
- Rollback:
  - 保留旧 config 默认值与 feature flag

### Milestone 5: 场景矩阵测试补齐
- What changes:
  - 新增 unit + integration 测试文件
  - 覆盖 Claude Code / Codex 场景矩阵
- Files:
  - `ModelProxyTests/SessionLineageBrokerTests.swift`
  - `ModelProxyTests/TranscriptProjectorTests.swift`
  - `ModelProxyTests/BranchMergeReducerTests.swift`
  - `ModelProxyTests/ProxySessionIntegrationTests.swift`
  - `ModelProxyTests/ModelProxyTests.swift`
- Acceptance criteria:
  - 每个必须覆盖场景至少一条自动化测试
  - 当前已复现 bug 有回归测试
- Rollback:
  - 单独回滚新增测试文件与 test target 引用

## 10. Test Plan / 测试计划（PLAN 阶段只描述，不执行）

### Planned automated tests
- `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
- `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`

### Unit tests to add
- Vendor domain policy Codable migration
- Lineage key stability for same conversation / branch split
- Transcript projection:
  - Anthropic official -> Anthropic official = no-op
  - Anthropic official -> third-party = strip/reduce replay-sensitive blocks
  - third-party branch local transcript stays vendor-local
- Branch merge reducer:
  - portable text/tool results re-enter main session
  - nonportable thinking/signature never re-enter main session

### Integration scenarios to automate
- Claude Code:
  - C2 `/model` same-domain switch keeps replay valid
  - C4 subagent custom model -> third-party vendor does not poison main session
  - C5 multiple subagent calls in one main session stay resumable
  - C6 reproduced `/commit -> Qwen -> Opus` bug is fixed
  - C8 Anthropic API / Bedrock / Vertex raw replay remains transparent
- Codex:
  - O2 `fork --model` produces isolated branch lineage
  - O4 `review` uses independent branch/reducer path
  - O5 multiple model-specific agent runs do not corrupt original session lineage

### Manual checks
- Claude Code:
  - 新开会话，运行 `/commit` 自定义或内置 commit workflow，确认主会话可继续
  - mid-session `/model sonnet` -> `/model opus` -> subagent -> 回主会话
- Codex:
  - `codex fork --last -m <other-model>`
  - `codex review --uncommitted -c model=\"...\"`
- Debug:
  - 检查日志里是否出现 lineageKey、branchKey、projectionPolicy、mergePolicy

## 11. Risks & Replan Triggers / 风险与再规划触发条件
- Risks:
  - 无显式 session ID，lineage fingerprint 可能误判；需要稳定且可回归验证的 key strategy
  - 第三方 vendor 返回格式可能并不完全遵守 Anthropic/OpenAI 兼容格式，normalizer 需要容错
  - 如果 Claude Code / Codex 本身在后续版本改变 transcript 组织方式，broker 规则要及时调整
  - 配置复杂度上升，需要清晰默认值与 known-vendor presets
- Replan triggers:
  - 发现无法稳定生成 lineageKey，导致同一会话被拆成多条 lineage
  - 发现 Claude Code / Codex 有官方支持但当前计划未覆盖的新 branch/fork 模式
  - 发现 response normalizer 需要重写超过一种 vendor 的私有协议格式
  - 发现 feature flag 双路径无法共存，需要改为一次性切换

## 12. TODOs / 下一步工作
- [ ] 写调研文档，固化 Claude Code / Codex 场景矩阵与官方证据
- [ ] 细化 `lineageKey` / `branchKey` 生成算法，并列出候选字段优先级
- [ ] 设计 `portable block` schema 与 reducer 输入输出
- [ ] 设计 feature flag 与 fallback 策略
- [ ] 设计测试 fixtures（Claude request/response、Codex fork/review request/response）

## Notes / 备注
- 当前仓库已有未提交修改：`ModelProxy/Proxy/ProxyForwarder.swift`。执行阶段需先读清这些修改与本计划是否冲突，再决定如何落地。
- 本方案本质上把 ModelProxy 升级为“stateful conversation broker”，不是简单 proxy 补丁。
- 若执行中发现 Codex 的本地 CLI 与官方文档对某个 fork/review 场景描述不一致，应先更新本计划和调研文档，再继续。

[自检-表面] 本次任务最容易违反哪条规则？
答：规则 8「复杂度不授权偏离」— 因为 session broker 很复杂，最容易退回到“先做简单 guard/fallback”这种偏离最优解的偷懒路线。

[自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最可能实际未生效？
答：`lineageKey` 稳定识别 — 看起来只要算出一个 fingerprint 就完成了，但如果不同 fork / compact / review 请求的结构略变，运行时会把同一会话拆裂，导致 reducer 根本没接上。

[自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：会话 lineage / branch merge broker — 已查 Anthropic 官方文档与本机 Codex CLI；平台提供 subagent/fork 能力，但没有跨 vendor transcript portability 协调层，所以这部分不是平台已覆盖能力。
