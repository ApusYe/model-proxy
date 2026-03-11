# Four Issues Hardening Plan

## 0. Summary
- 这份计划只覆盖当前代码里仍然成立的 4 个问题：
  1. `PortableSSEStreamNormalizer` 仍保留 `[Int: Any]` 类型擦除；
  2. `ReplayableBranchResponse` 的 `Equatable` 对 `headers` 顺序敏感；
  3. `ResponseRelay` 同时承担 relay、normalize、replay capture、branch commit，职责过重；
  4. `SessionLineageBroker` 与 `BranchRequestCoordinator` 仍是纯内存态，进程重启会丢 branch/session 状态。
- 不包含已经完成的项：
  - `.waited` 边界；
  - replay cache 大小上限与日志；
  - lineage trim / malformed SSE / multi-client 测试补齐。

## 1. 约束前置
- 用户明确要求：
  - 先重新读代码确认这 4 个问题是否成立；
  - 只在问题被验证成立后给出完整修复计划；
  - 当前阶段先出计划，不直接改代码。
- 技术约束：
  - 不回退已完成的 `portableOnly` transcript 隔离；
  - 不回退 branch request coordination；
  - 不改 `.xcodeproj/project.pbxproj`；
  - 不用 `/commit`、skill 名字、prompt 文本做定向逻辑。
- 禁止事项：
  - 不把“内存态”误报成当前 bug；
  - 不把测试语义问题包装成运行时故障；
  - 不在计划里引入未验证的新问题。

## 2. Validated Facts

### 2.1 `[Int: Any]` 类型擦除
- `PortableSSEStreamNormalizer.fullBlocksByIndex` 目前定义为 `[Int: Any]`。
- `orderedBlocks(from:)` 返回 `[Any]`。
- 位置：
  - `ModelProxy/Services/PortableContentNormalizer.swift:57`
  - `ModelProxy/Services/PortableContentNormalizer.swift:204`

### 2.2 `ReplayableBranchResponse` header 比较顺序敏感
- `ReplayableBranchResponse ==` 使用 `lhs.headers.elementsEqual(rhs.headers, ...)`。
- 该比较要求 header 数组顺序完全一致。
- 位置：
  - `ModelProxy/Services/BranchRequestCoordinator.swift:14-17`
- 同时验证到：
  - 运行时 branch 协调并不依赖这个比较；
  - 当前引用只出现在测试断言与 `BranchRequestAcquireDecision` 的等值比较路径。
- 位置：
  - `ModelProxyTests/BranchRequestCoordinatorTests.swift:30`

### 2.3 `ResponseRelay` 职责过重
- 当前 `ResponseRelay.relay(...)` 同时负责：
  - HTTP response head 转发；
  - SSE / non-SSE 分支；
  - usage 提取；
  - error body 预览；
  - portable normalize；
  - replay cache capture；
  - stale guard 后的 branch commit；
  - cached response replay。
- 位置：
  - `ModelProxy/Proxy/ResponseRelay.swift:58-258`

### 2.4 branch/session 状态仍是纯内存
- `SessionLineageBroker` 使用 actor 内部字典 `lineages: [String: ConversationLineage]`；
- `BranchRequestCoordinator` 使用 actor 内部字典 `entries` 与 `latestGenerationByScope`；
- 没有磁盘落盘或重启恢复逻辑。
- 位置：
  - `ModelProxy/Services/SessionLineageBroker.swift:19-23`
  - `ModelProxy/Services/BranchRequestCoordinator.swift:42-52`

## 3. [排除] 该症状排除以下假设
- `header` 顺序敏感已经影响当前运行时 branch replay
  - 因为运行时 branch 协调 key 是 `clientName/vendorKey/portableMessageHashes`，不读取 response headers 参与匹配。
- `内存态` 已经导致当前会话错误
  - 因为当前代码只在进程存活期间使用这些状态；重启会退化为冷启动，但不会回到之前的 signature 污染路径。
- `ResponseRelay` 过重已经在现有测试里暴露确定性故障
  - 因为完整测试当前是通过的；这项目前属于结构风险，不是已复现运行时错误。

## 4. [剩余可能]
- `[Int: Any]` 会放大后续 SSE / branch merge 演进时的运行时类型错误风险；
- `ReplayableBranchResponse` 的顺序敏感比较会制造脆弱测试，阻碍后续重构；
- `ResponseRelay` 再继续堆逻辑时最容易引入流式回归；
- 纯内存态在 App 重启后会丢 branch reuse，影响性能与连续性。

## 5. Bug vs Tradeoff

| 项目 | 当前性质 | 对 App 的直接影响 |
|---|---|---|
| `[Int: Any]` 类型擦除 | 工程缺口 | 当前用户影响低；后续改动更容易埋运行时错误 |
| `ReplayableBranchResponse` header 顺序敏感比较 | 测试语义问题 | 当前用户几乎无感；测试脆弱 |
| `ResponseRelay` 职责过重 | 结构风险 | 当前能跑；后续继续加逻辑时回归风险最高 |
| 纯内存 branch/session 状态 | 架构 tradeoff | 进程重启后 branch reuse 丢失，退化为冷启动 |

## 6. Options

| 方案名 | 架构合理性 | 实现量 | 风险或代价 | 适用场景 |
|---|---|---:|---|---|
| A. 只修类型/测试语义，不动结构与持久化 | 中 | 低 | 能收紧两处明显缺口，但 `ResponseRelay` 和重启退化都还在 | 只追求最小收口 |
| B. 修类型/测试语义 + 拆 `ResponseRelay` + 维持内存态 | 高 | 中到高 | 能显著降低演进风险；重启仍然冷启动 | 推荐；先把运行时代码结构理顺 |
| C. 方案 B + branch/session 最小持久化 | 最高 | 高 | 设计面更大，需要明确定义恢复边界与清理策略 | 如果你要把重启后连续性也一起收掉 |

- 推荐：**方案 C**
- 推荐理由：它是唯一同时收掉“结构风险”和“重启后冷启动退化”的路线。

## 7. Planned Changes

### 7.1 Issue 1: 去掉 `[Int: Any]`
- Files:
  - `ModelProxy/Services/PortableContentNormalizer.swift`
  - `ModelProxyTests/BranchMergeReducerTests.swift`
- Change:
  - `fullBlocksByIndex` 从 `[Int: Any]` 改为 `[Int: [String: Any]]`
  - `orderedBlocks(from:)` 改为返回 `[[String: Any]]`
  - 保持现有输出语义不变
- Acceptance:
  - 编译通过；
  - 现有 SSE normalize tests 全绿；
  - 不再出现 `Any` 跨越 full block 存储路径。

### 7.2 Issue 2: 修 `ReplayableBranchResponse` header 比较语义
- Files:
  - `ModelProxy/Services/BranchRequestCoordinator.swift`
  - `ModelProxyTests/BranchRequestCoordinatorTests.swift`
- Change:
  - 去掉顺序敏感 header 比较；
  - 两个可选实现：
    - A. 保留 `Equatable`，先把 headers 规范化成小写 name + `[String: [String]]` 的顺序无关结构再比较；
    - B. 取消 `ReplayableBranchResponse: Equatable`，测试里只断言 `statusCode/bodyChunks/关键 header`。
- 推荐：
  - **B**
- 原因：
  - 这个 `Equatable` 主要是测试方便，不值得把 production type 绑死在 header 规范化逻辑上。
- Acceptance:
  - 相关测试仍表达同样的业务意图；
  - 不再因为 header 顺序不同导致测试误红。

### 7.3 Issue 3: 拆 `ResponseRelay`
- Files:
  - `ModelProxy/Proxy/ResponseRelay.swift`
  - `ModelProxy/Services/PortableContentNormalizer.swift`
  - `ModelProxy/Services/BranchReplayRecorder.swift`（新增）
  - `ModelProxyTests/ResponseRelayTests.swift`
  - `ModelProxyTests/ProxySessionIntegrationTests.swift`
- Change:
  - 把 `ResponseRelay` 分成 3 层：
    1. `ResponseRelay` 只负责 channel write / end / close；
    2. `PortableResponseNormalizer` 负责 portable JSON/SSE 规范化；
    3. `BranchReplayRecorder` 负责 replay cache capture、上限控制、形成 `ReplayableBranchResponse`。
  - `stale guard + lineageBroker.commitResponse(...)` 保留在 branch-specific coordinator path，但从 `ResponseRelay` 主循环中抽成独立 helper。
- Acceptance:
  - 外部调用接口不变，`ProxyForwarder` 不需要知道更多细节；
  - replay size limit 日志继续存在；
  - stale drop 日志继续存在；
  - 现有 full test 全绿。

### 7.4 Issue 4: branch/session 最小持久化
- Files:
  - `ModelProxy/Services/SessionLineageBroker.swift`
  - `ModelProxy/Models/SessionLineage.swift`
  - `ModelProxy/Services/LineageStore.swift`（新增）
  - `ModelProxy/Services/BranchRequestCoordinator.swift`
  - `ModelProxyTests/SessionLineageBrokerTests.swift`
  - `ModelProxyTests/ProxySessionIntegrationTests.swift`
- Change:
  - 只持久化 committed branch transcript，不持久化 in-flight request coordination。
  - `LineageStore` 负责：
    - 以 `clientName/lineageKey/branchKey` 存取 committed branch；
    - 启动时懒加载；
    - 保持与当前 `24` 条/client 的 trim 语义一致；
    - 仅恢复 `branches`，不恢复 `entries/latestGenerationByScope`。
  - `BranchRequestCoordinator` 继续内存态；进程重启后的 in-flight state 直接丢弃。
- Acceptance:
  - App 重启后，同一 portable branch 的后续请求能继续命中已提交 branch reuse；
  - 没有尝试恢复旧 in-flight wait/join；
  - trim 规则对内存与落盘都一致。

## 8. Test Plan

### 8.1 Automated
- `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
- `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests test`
- `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`

### 8.2 New / Updated Tests
- `[类型收紧]`
  - `BranchMergeReducerTests` 继续覆盖：
    - SSE thinking block suppress；
    - malformed JSON fail-open；
    - missing `content_block_stop` finalize。
- `[header 语义]`
  - 新增一条测试：相同 headers 不同顺序时，branch replay 语义断言仍通过。
- `[ResponseRelay 拆分]`
  - recorder 只测 capture/disable/finalize；
  - relay 只测 head/body/end write 顺序；
  - integration test 继续锁 stale guard + portable branch reuse。
- `[持久化]`
  - 新增测试：commit branch -> 重建 broker/store -> prepareRequest 命中 reused branch；
  - 新增测试：超过 24 条后，最旧落盘 lineage 被 trim。

## 9. Risks
- 持久化 branch transcript 后，磁盘数据版本兼容会成为新维护点；
- `ResponseRelay` 拆分时如果 helper 边界划错，容易把当前日志和 replay 语义改坏；
- 如果把 `ReplayableBranchResponse` 的 `Equatable` 直接删除，测试要同步改成更精确的断言，不能退化成弱断言。

## 10. Replan Triggers
- 如果在实现持久化时发现 `BranchTranscript` 当前结构不能稳定编码/解码，则暂停，先补模型编码层计划；
- 如果 `ResponseRelay` 拆分后必须改变 `ProxyForwarder` 的外部调用接口，且会扩散到多条路径，则暂停重写计划；
- 如果重启恢复 branch reuse 会引入用户可见的新默认行为，需要先回到计划审查。

## 11. TODO
- [ ] 收紧 `PortableSSEStreamNormalizer` 的 full block 存储类型
- [ ] 修 `ReplayableBranchResponse` 的测试语义
- [ ] 拆出 `BranchReplayRecorder`
- [ ] 把 branch commit/stale guard 从 `ResponseRelay` 主循环里抽成 helper
- [ ] 为 committed branch transcript 增加最小持久化
- [ ] 补持久化与 trim 的测试

## [自检-表面] 本次任务最容易违反哪条规则？
答：规则 8「复杂度不授权偏离」；因为 `ResponseRelay` 拆分和 branch 持久化很容易被借口成“先不做”，但这两项正是当前剩余问题的主体。

## [自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最可能实际未生效？
答：Issue 4 的最小持久化；如果只把 branch 写到磁盘，却没有在 `prepareRequest(...)` 真正参与 `existingBranches` 选择，表面有 store，实际仍是冷启动。

## [自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：无；这几项都属于 app 内部协议状态与流式响应处理，不是平台现成 API 能直接替代的问题。
