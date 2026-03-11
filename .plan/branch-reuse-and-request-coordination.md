# Branch Reuse And Request Coordination

## 0. Summary / 摘要
- 修正 `portableOnly` 路径下的两个已证实问题：
  - branch reuse 始终未命中，vendor-local transcript 没有被重新接回；
  - 同一 branch 的并发/重试请求没有协调，导致重复打 Qwen，出现一个成功、一个超时的分叉结果。

## 1. 约束前置
- 用户明确要求：
  - App 要“有用”，不能只修协议正确性而不修可用性。
  - 本次先给完整计划，review 成功后再执行。
  - ` /commit ` 只是用户给出的复现场景，不是可 hardcode 的产品规则。
- 技术约束：
  - 不能回退已完成的 `portableOnly` transcript 隔离；主会话继续保持 `signature=false`。
  - 不能把问题重新简化成“禁用 Qwen”或“禁用 thinking”。
  - 不能按 skill 名称、prompt 文本、`/commit` 命令字、模型名组合去做针对性分支逻辑；判断只能基于通用的会话/branch/transcript 状态。
  - 不改 `.xcodeproj/project.pbxproj`。
- 禁止事项：
  - 不引入新的 UX 入口。
  - 不扩大到无证据的问题域；只处理日志已证实的问题。

## 2. Goals & Non-Goals / 目标与非目标
- Goals:
  - [ ] 顺序请求下，第二次及之后的同 branch 请求能命中 vendor-local branch reuse。
  - [ ] 同 branch 的重复/重叠请求不再并发打到同一个 portable vendor。
  - [ ] 旧请求晚到的响应不会覆盖新 branch 状态。
  - [ ] 保持 Anthropic 主会话 `signature=false`，不回归污染问题。
  - [ ] 新增日志能直接说明：reuse 是否命中、请求是否 join/wait/reprepare、响应是否 stale dropped。
- Non-goals:
  - 不改 UI。
  - 不做新的 vendor fallback 策略扩展。
  - 不重新设计 lineage DAG 总体架构。
  - 不处理未证实的“Qwen 请求 schema 非法”推断。

## 3. Current State Recon / 现状勘察（只读证据）

### 3.1 请求主路径
- `ProxyForwarder.forward`：
  - 读取原请求，记录 `ThinkingDiag`，调用 `lineageBroker.prepareRequest(...)`，再发往上游。
  - 位置：[ProxyForwarder.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift#L11)
- `SessionLineageBroker.prepareRequest`：
  - 直接委托 `TranscriptProjector.prepareRequest(...)`，然后记录 `Lineage` 日志。
  - 位置：[SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift#L24)
- `TranscriptProjector.prepareRequest`：
  - `portableOnly` 时去掉 replay-sensitive block，计算 portable message hashes，尝试命中已有 branch。
  - 位置：[TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift#L18)
- `ResponseRelay.relay`：
  - 只有响应完整结束后，才调用 `lineageBroker.commitResponse(...)` 写回 branch transcript。
  - 位置：[ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift#L82)

### 3.2 已证实事实
- 最新日志里：
  - `portableOnly` 已生效；
  - `ProjectionDiag` 显示包装前后结构稳定，且同样结构可得到 `200 OK`；
  - `Lineage` 连续多次显示 `reused=false reusedPortable=0`；
  - 相同 `lineage + branch` 上存在一条请求成功、另一条超时。
- 这说明：
  - 问题不是“portable 包装稳定地生成了非法 JSON”；
  - 问题在 branch reuse 和并发协调层。

### 3.3 [排除] 该症状排除以下假设
- `portableOnly` 没有接上
  - 因为日志已显示 `replay=portableOnly`。
- Anthropic 主会话仍被污染
  - 因为主会话日志已显示 `signature=false` 且 `Opus -> Anthropic 200 OK`。
- 请求结构本身稳定非法
  - 因为同一类 `ProjectionDiag` 结构既有 `200 OK`，也有 timeout。

### 3.4 [剩余可能]
- branch transcript 没有被正确匹配回后续请求；
- branch transcript 虽然已提交，但 portable hash / full message 重建条件不一致；
- 第二个请求在第一个请求提交 branch 之前就被发出，导致永远只能走 `reused=false`；
- 旧请求响应晚到后，没有 stale guard。

### 3.5 [并行路径]
- 核心函数：`lineageBroker.commitResponse(...)`
  - 调用者只有 [ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift#L86) 和 [ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift#L138)
  - 协调机制：无
  - 计划处理：在 broker / coordinator 层新增 generation 协调，不新增第三条写入路径。

## 4. Options / 方案选择

| 方案名 | 架构合理性 | 实现量 | 风险或代价 | 适用场景 |
|---|---|---:|---|---|
| A. 修 branch reuse + 加 in-flight coordinator | 最高；保持现有 session-lineage 设计，只补缺失的状态协调 | 中到高 | 需要新增 actor 状态机和 generation 控制；日志与测试量增加 | 当前最适合；问题已被日志证实 |
| B. 全局串行化 portable vendor 请求 | 中；能压掉并发，但过于粗暴，损失吞吐 | 中 | 不同 branch 也会被串住；无法解释 reuse 失效本身 | 临时止血，但不是根治 |
| C. 取消 vendor-local reuse，改成纯 stateless portable 请求 | 低；等于放弃 branch 设计价值 | 低到中 | 成本高、上下文质量变差、偏离既有设计 | 只有 branch 设计被证伪时才考虑 |

- 推荐：**方案 A**
- 推荐理由：它直接修复日志已证实的两个真实缺口，同时保留 session-lineage 的核心价值。

## 5. Planned Changes / 文件与改动概览

### Files to Modify
- [ModelProxy/Services/TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift)
  - Purpose: 修复 branch 匹配与 rehydrate 逻辑；支持在等待前序请求完成后重新 prepare。
  - Type of change: 逻辑修复 / 匹配规则调整 / 诊断增强
- [ModelProxy/Services/SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift)
  - Purpose: 管理 committed branches 与 in-flight branch 状态；提供 generation 协调。
  - Type of change: actor 状态扩展 / 协调逻辑
- [ModelProxy/Models/SessionLineage.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/SessionLineage.swift)
  - Purpose: 为 branch context / in-flight tokens 添加协调字段。
  - Type of change: 数据结构扩展
- [ModelProxy/Proxy/ProxyForwarder.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift)
  - Purpose: 在发上游前接入 coordinator；记录 join/wait/reprepare 诊断。
  - Type of change: 请求调度接入 / 日志增强
- [ModelProxy/Proxy/ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift)
  - Purpose: 提交 branch response 前增加 stale response guard；必要时 drop 旧响应提交。
  - Type of change: 响应提交协调

### Files to Add
- [ModelProxy/Services/BranchRequestCoordinator.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/BranchRequestCoordinator.swift)
  - Purpose: 同 branch 的 in-flight 请求 join / wait / generation 管理。
- [ModelProxyTests/BranchRequestCoordinatorTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/BranchRequestCoordinatorTests.swift)
  - Purpose: 覆盖 exact duplicate、successor request、stale completion 等场景。

### Files to Modify (Tests)
- [ModelProxyTests/TranscriptProjectorTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/TranscriptProjectorTests.swift)
  - Purpose: 锁定 branch reuse 命中条件。
- [ModelProxyTests/SessionLineageBrokerTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/SessionLineageBrokerTests.swift)
  - Purpose: 验证 commit 后可重用、generation 递增、stale drop。
- [ModelProxyTests/ProxySessionIntegrationTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/ProxySessionIntegrationTests.swift)
  - Purpose: 覆盖 Claude Code portable vendor branch 顺序请求、并发请求、回主会话三段流程。

## 6. Milestones & Acceptance Criteria / 里程碑与验收标准

### Milestone 1: 锁定 branch reuse 失效的根因
- What changes:
  - 用当前日志对应的 1-message / 3-message fixture 补 deterministic tests。
  - 明确“前一轮 commit 成功后，下一轮为什么仍然 `reused=false`”。
  - 在 plan 执行阶段，如果发现不是 hash prefix 失配，而是提交时序问题，及时收窄实现。
- Files:
  - [ModelProxyTests/TranscriptProjectorTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/TranscriptProjectorTests.swift)
  - [ModelProxyTests/SessionLineageBrokerTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/SessionLineageBrokerTests.swift)
- Acceptance criteria:
  - 新测试能稳定复现当前 `reused=false` 的失效路径。
  - 失效原因可以被归类为：匹配错误 / 提交时序 / 两者都有。
- Rollback:
  - 删除新测试与诊断字段，不影响运行时代码。

### Milestone 2: 让 committed branch 真正可复用
- What changes:
  - 修复 `bestMatchingBranch(...)` 需要的输入与 `commitResponse(...)` 产物的一致性。
  - 如果上一轮已成功提交，下一轮同 branch 请求应 rehydrate full vendor-local messages。
  - `Lineage` 日志应能显示 `reused=true` 与 `reusedPortable>0`。
- Files:
  - [ModelProxy/Services/TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift)
  - [ModelProxy/Services/SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift)
  - [ModelProxy/Models/SessionLineage.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/SessionLineage.swift)
- Acceptance criteria:
  - 顺序两轮 portable vendor 请求下，第二轮起日志出现 `reused=true`。
  - `ProjectionDiag` 的 prepared full transcript 反映已重接 vendor-local assistant turn。
- Rollback:
  - 回退 reuse 命中逻辑到当前实现，保留 diagnostics。

### Milestone 3: 新增同 branch in-flight 请求协调
- What changes:
  - 新增 `BranchRequestCoordinator` actor。
  - exact duplicate 请求：join 已有 in-flight，不重复发上游。
  - successor 请求：若前序同 branch 请求仍在飞，先 wait；待 commit 后重新 `prepareRequest` 再决定是否发上游。
  - 为每个 branch request 分配 generation token。
- Files:
  - [ModelProxy/Services/BranchRequestCoordinator.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/BranchRequestCoordinator.swift)
  - [ModelProxy/Services/SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift)
  - [ModelProxy/Proxy/ProxyForwarder.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift)
- Acceptance criteria:
  - 同一 `lineage + branch + portable hashes` 的重试不会并发打两次 Qwen。
  - successor 请求能在前序 commit 后重新 prepare，并有明确 `CoordinatorDiag` 日志。
- Rollback:
  - 去掉 coordinator 注入，恢复当前直接 dispatch。

### Milestone 4: 加 stale response guard
- What changes:
  - `ResponseRelay` 在 commit 前校验 generation 是否仍为当前 branch 最新。
  - 旧请求晚到时，允许响应转发给客户端，但不覆盖 branch transcript。
  - 记录 `staleCommitDropped` 诊断日志。
- Files:
  - [ModelProxy/Proxy/ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift)
  - [ModelProxy/Services/SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift)
  - [ModelProxy/Models/SessionLineage.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/SessionLineage.swift)
- Acceptance criteria:
  - 构造“旧请求超时， newer request 先成功”的测试后，最终 branch state 来自新请求。
  - 日志可区分 `commitResponse` 与 `stale drop`。
- Rollback:
  - 去掉 generation check，恢复当前 commit 行为。

### Milestone 5: 集成验证与日志审计
- What changes:
  - 用集成测试覆盖当前 Claude Code 观测到的通用 portable branch 场景，而不是某个 skill 名称。
  - 审核 `Lineage` / `ProjectionDiag` / `CoordinatorDiag` 日志是否能直接回答“reuse 是否命中、是否重复发上游、是否 drop stale”。
- Files:
  - [ModelProxyTests/ProxySessionIntegrationTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/ProxySessionIntegrationTests.swift)
  - [ModelProxyTests/BranchRequestCoordinatorTests.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxyTests/BranchRequestCoordinatorTests.swift)
- Acceptance criteria:
  - 完整 `xcodebuild test` 通过。
  - 复现场景中，日志不再连续出现同 branch 的 `reused=false reusedPortable=0`。
- Rollback:
  - 保留测试与 diagnostics，回退 coordinator 接入。

## 7. Test Plan / 测试计划（PLAN 阶段只描述，不执行）
- Planned automated tests (to run in EXECUTE):
  - `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
  - `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
- Planned targeted test cases:
  - 顺序 portable requests：第 2 次命中 `reused=true`
  - exact duplicate in-flight：只发 1 次 upstream
  - successor request while previous in-flight：wait + reprepare
  - stale completion after newer success：old response 不覆盖 branch state
  - main Anthropic session after portable branch：仍 `signature=false`
  - 同一机制在不同 prompt / 不同 tool_use 负载下成立；不依赖 ` /commit ` 字样
- Manual checks:
  1. 开新会话，触发一个会 fork 到 portable vendor 的 Claude Code sub-agent/skill 场景
  2. 观察第二轮同 branch 请求日志是否出现 `reused=true`
  3. 同时确认没有重复的同 branch Qwen dispatch
  4. branch 结束后回主会话提问，确认 Anthropic 继续 `200 OK`

## 8. Risks & Replan Triggers / 风险与再规划触发条件
- Risks:
  - coordinator 锁粒度过粗，导致不同 branch 也被串行化；
  - generation 设计不当，可能 drop 本该保留的 commit；
  - reprepare 时机放错，会让请求等待过久。
- Replan triggers:
  - 如果 Milestone 1 证明 `reused=false` 不是匹配/时序问题，而是 Claude Code 请求本身没有携带可重用 portable 前缀，则暂停并重写 plan。
  - 如果 coordinator 需要改变用户可见行为，例如丢弃某些请求而不是等待，则停下确认。
  - 如果实现过程中发现必须修改 vendor config 或 UI 才能完成，则回到 PLAN 模式补计划。

## 9. TODOs / 下一步工作
- [ ] 用当前日志对应的 fixture 锁定 `reused=false` 的具体原因
- [ ] 新增 `BranchRequestCoordinator`
- [ ] 接入 stale response generation guard
- [ ] 补齐 coordinator / integration tests
- [ ] 复现一次 `/commit` 并对照新日志审计

## Notes / 备注
- 当前新增的 `ProjectionDiag` 已经完成“排除 stable malformed JSON”这一步；它不需要再删回去。
- 本次计划不处理“把 Qwen 500/timeout 自动 fallback 到 defaultUpstream”的可用性策略；先把 branch reuse 与请求协调修对，否则 fallback 会掩盖真实问题。
- 任何测试 fixture 中出现 ` /commit `，都只能作为复现样本数据；实现代码不得读取或依赖该字样。

## [自检-表面] 本次任务最容易违反哪条规则？
答：规则 9「遇阻修阻不绕路」；因为很容易把当前问题绕成“直接 fallback 到 Anthropic”，但这会掩盖已证实的 branch reuse / 并发协调缺口。

## [自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最可能实际未生效？
答：Milestone 2 的 branch reuse 命中；日志里必须真的出现 `reused=true`，否则只是测试构造过了，不代表真实 `/commit` 路径生效。

## [自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：无平台 API 可直接解决；这是 app 内部会话/branch 协调状态机，不是被 SwiftUI/AppKit 现成 API 覆盖的问题。
