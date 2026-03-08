# Decision Crystal: proxy-resilience

Date: 2026-03-07

## Initial Idea
用户在考虑 App 上 App Store 后，proxy 对错误、性能、负载均衡等方面需要哪些处理能力。讨论了超时、重试、429、failover、熔断器等方向的 tradeoff。

## Discussion Points
1. **超时配置**: 当前硬编码 connect 10s / read 120s，不同模型响应速度差异大（reasoning models 可能需要 180s+），应从 config 读取
2. **自动重试**: 初始认为 App Store 场景需要，用户指出工具自己会重试，proxy 只是中介，加重试会导致重复请求叠加，决定不做
3. **429 处理**: 初始方案是读 Retry-After 等待后重发同一 vendor，用户纠正：429 = 限流了，应该换 target model（切到同 route 的备用 target model），不是退避等待。passthrough 不处理
4. **错误码转文本**: 初始以为是改 proxy 响应格式，用户澄清是 traffic log UI 展示层把 200/429 改成可读文本。后又决定不在 menu bar 做，改为反映在 debug 日志里
5. **Failover**: 用户认为配置中多加一个 input area 绑 failover，收益可观。只在同格式 vendor 间有意义
6. **熔断器 vs 动态优先级排序**: 用户提出不需要经典熔断器，有 failover 就够了。主的经常掉就把副的提升为主的，Settings 同步体现。AI 提出两种 UI 方案，用户选择"配置不变 + 主/次标识"
7. **Vendor compatibleClientID 字段**:
   - AI 初始理解为"vendor 接受什么格式的请求" → 用户纠正：是"兼容哪个工具"
   - AI 误将 api.anthropic.com 理解为"也是一个 vendor" → 用户纠正：defaultUpstream 是工具原本要去的地方，不是 vendor
   - AI 误将 apiFormat 与 client 直接关联 → 用户纠正：字段加在 Vendor 上，语义是"兼容哪个 client 工具"
   - 最终确认字段名 `compatibleClientID`，关联到 `ClientConfig.id`
8. **proxy 响应格式**: AI 提议 proxy 自身错误返回 Anthropic JSON 格式，用户否定——proxy 返回啥就转发啥，proxy 不知道原请求想要什么格式

## Rejected Alternatives
- **自动重试（retry with backoff）**: 拒绝因为——proxy 是中介不是客户端，工具自己会重试，proxy 加重试会导致重复请求叠加
- **经典熔断器（circuit breaker）**: 拒绝因为——有 failover + 动态优先级排序就够了，经典熔断器的 open/half-open/closed 状态机对 vendor 数量少的场景过于复杂
- **429 退避等待重发**: 拒绝因为——限流了应该换 target model，不是等着重发同一个
- **错误码文本在 menu bar traffic log 展示**: 拒绝因为——放 debug 日志更合适
- **Proxy 自身错误返回 Anthropic JSON 格式**: 拒绝因为——proxy 不知道原请求期望什么格式，返回什么就转发什么
- **apiFormat 作为"API 协议格式"标签**: 拒绝因为——语义应该是"兼容哪个工具"，不是"接受什么 API 格式"
- **请求/响应格式转换**: 拒绝因为——违反 "no transformation" 约束，维护成本质变

## Decisions (machine-readable)
- [D-001] 超时可配置：connect timeout 和 read timeout 从 config 读取，替代硬编码
- [D-002] 429 触发 failover：收到上游 429 时，若为 mapped route 则立即切到同 route 的备用 target model 发请求；若为 passthrough（原厂直连）则不处理，原样透传 429 给工具
- [D-003] 不做自动重试：proxy 是中介，工具自己处理重试
- [D-004] 错误码可读文本放在 debug 日志中输出，不在 menu bar traffic log UI 展示
- [D-005] Vendor 加 `compatibleClientID: UUID?` 字段，关联到 `ClientConfig.id`，表示该 vendor 兼容哪个工具
- [D-006] Route 配置支持多个 target（主 + 备 target model + vendor），failover 只在同 `compatibleClientID` 的 vendor 之间发生
- [D-007] 简单计数器替代熔断器：failCount 累计失败次数，>=10 次切换主/备 activeTarget，成功重置为 0。Settings 中配置顺序不变，用主/次标识展示当前 activeTarget 状态。状态在 config reload 时重置
- [D-008] `compatibleClientID` 仅作为过滤标签，proxy 不做任何请求/响应格式转换
- [D-009] Proxy 自身错误不改格式，原样返回（不转换为 Anthropic JSON 或其他格式）

## Constraints
- Proxy 不修改请求/响应内容（除 model 字段替换和 API key 替换）
- Proxy 不做请求/响应格式转换
- `compatibleClientID` 是过滤字段，不触发任何转换逻辑
- Settings 中 failover 配置顺序由用户控制，运行时排序只影响实际请求优先级和标识展示，不改用户配置

## Scope Boundaries
- IN: 超时可配置
- IN: 429 触发 failover（仅 mapped route）
- IN: 错误码文本在 debug 日志
- IN: Vendor 加 compatibleClientID 字段
- IN: Route 支持多 vendor failover（主/备）
- IN: 动态优先级排序 + Settings 主/次标识
- OUT: 自动重试
- OUT: 经典熔断器
- OUT: 请求/响应格式转换
- OUT: Proxy 自身错误格式转换
- OUT: Menu bar traffic log 错误码文本展示

## Source Context
- Design doc: none
- Design analysis: none
- Key files discussed: `ModelProxy/Proxy/ProxyForwarder.swift`, `ModelProxy/Proxy/RoutingSnapshot.swift`, `ModelProxy/Proxy/RequestRouter.swift`, `ModelProxy/Models/AppConfig.swift`, `ModelProxy/Models/ClientConfig.swift`, `ModelProxy/Models/Vendor.swift`, `ModelProxy/Models/ModelMapping.swift`
