# Follow-up Hardening Plan For Validated Gaps

## 0. Summary
- 这份计划只覆盖本轮已验证成立的后续问题：
  1. `SessionLineageBroker.commitResponse(...)` 先改内存再写磁盘，持久化失败会留下内存/磁盘短期不一致；
  2. `ProxyForwarder` 的 `.replay/.waited` 路径没有显式文档说明“为什么不需要 complete lease”；
  3. `PortableSSEStreamNormalizer.finish()` 不会在结束后整体 reset 内部状态，double-finish 会污染结果；
  4. `maxCachedLineagesPerClient = 24` 是 magic number，没有说明；
  5. `BranchReplayRecorder.disable()` 的不可逆语义没有说明；
  6. 缺 5 组测试：
     - `ResponseRelay` channel write failure
     - `ResponseRelay.replay()` path
     - concurrent commits to same lineage
     - SSE normalizer double-finish
     - `LineageStore` malformed JSON recovery

## 1. 约束前置
- 用户明确要求：
  - 先验证这些指控是否属实；
  - 只对验证成立的项出计划；
  - 类似 2/5 这种不是 bug 的项，要把说明补齐。
- 技术约束：
  - 不回退已完成的 branch/session 结构；
  - 不回退 committed branch transcript 持久化；
  - 不扩大到新的架构重写。
- 禁止事项：
  - 不把 2/5 伪装成运行时 bug；
  - 不把“文档说明补齐”降级成只写口头备注；
  - 不引入新的用户可见默认行为。

## 2. Validated Facts

### 2.1 持久化失败的一致性问题
- `SessionLineageBroker.commitResponse(...)` 当前顺序是：
  - 构造新 `lineage`
  - 直接写入 `lineages[context.lineageKey]`
  - `trimLineages(...)`
  - `try store.saveLineages(lineages)`
- 位置：
  - `ModelProxy/Services/SessionLineageBroker.swift:53-88`
- 这意味着：
  - 一旦 `saveLineages(...)` throw，内存已经变了，磁盘可能没变。

### 2.2 `.replay/.waited` 路径没有 lease completion 说明
- `ProxyForwarder.forward(...)` 里：
  - `.acquired(let lease)` 才赋给 `branchLease`
  - `.replay` 直接返回
  - `.waited` 重 prepare 后继续
- 位置：
  - `ModelProxy/Proxy/ProxyForwarder.swift:113-170`
- 当前事实：
  - 这不是 lease 泄漏，因为 `.replay/.waited` 没 acquire 新 lease；
  - 但代码本身没注释解释这层语义。

### 2.3 `finish()` 不 reset 全状态
- `PortableSSEStreamNormalizer.finish()`：
  - 最多清空 `bufferedData`
  - 不会清空 `activeBlocks` / `visibleIndexMap` / `fullBlocksByIndex` / `nextVisibleIndex`
- 位置：
  - `ModelProxy/Services/PortableContentNormalizer.swift:80-100`
- 当前事实：
  - 同一实例 double-finish 会复用旧状态。

### 2.4 magic number 与 recorder 语义说明缺失
- `maxCachedLineagesPerClient = 24`
  - 位置：`ModelProxy/Services/SessionLineageBroker.swift:24`
- `BranchReplayRecorder.disable()` 不可逆
  - 位置：`ModelProxy/Services/BranchReplayRecorder.swift:63-67`
- 当前事实：
  - 两者都没有注释说明设计理由。

### 2.5 测试缺口
- 没有直接覆盖 `ResponseRelay.replay()`。
- 没有直接覆盖 relay 写 channel 失败路径。
- 没有同一 lineage 的并发 commit 测试。
- 没有 double-finish 测试。
- 没有 `FileLineageStore.loadLineages()` 面对坏 JSON 的恢复测试。

## 3. [排除] 该症状排除以下假设
- `.replay/.waited` 路径存在 lease 泄漏
  - 因为这两条路径没有 acquire 到 `branchLease`。
- `BranchReplayRecorder.disable()` 当前已经造成故障
  - 因为它的现有语义就是“超过上限后永久放弃 replay”，不是异常状态。
- `maxCachedLineagesPerClient = 24` 已经导致当前错误
  - 当前没有运行时证据证明 24 本身错；问题是缺说明，不是值已被证伪。

## 4. [剩余可能]
- 持久化失败的一致性问题会在磁盘写失败时制造短期状态分叉；
- double-finish 会在未来重用 normalizer 或异常路径下制造脏输出；
- 缺失的 relay/store 测试会让后续重构没有护栏；
- 2/5 若不写清楚，后续维护很容易被误判成 bug。

## 5. Planned Changes

### 5.1 Fix: `commitResponse(...)` 改成先生成快照，成功后再切换内存状态
- Files:
  - `ModelProxy/Services/SessionLineageBroker.swift`
  - `ModelProxyTests/SessionLineageBrokerTests.swift`
- Change:
  - 在 actor 内先基于当前 `lineages` 生成 `updatedLineages` 本地副本；
  - 对副本执行 branch 更新与 trim；
  - 先 `store.saveLineages(updatedLineages)`；
  - 成功后再 `lineages = updatedLineages`。
- Result:
  - 持久化失败时，内存与磁盘保持旧状态一致；
  - 错误继续上抛，不 silent。
- Tests:
  - 新增 failing store stub，断言 save throw 后：
    - `branches(for:)` 仍返回旧状态；
    - 下一次成功 save 后状态再前进。

### 5.2 Fix: `PortableSSEStreamNormalizer.finish()` 结束后整体 reset
- Files:
  - `ModelProxy/Services/PortableContentNormalizer.swift`
  - `ModelProxyTests/BranchMergeReducerTests.swift`
- Change:
  - 把 `finish()` 拆成：
    - finalize current buffered/active state
    - build assistant turn
    - `resetState()` 清空：
      - `bufferedData`
      - `activeBlocks`
      - `visibleIndexMap`
      - `nextVisibleIndex`
      - `fullBlocksByIndex`
- Result:
  - 同一 normalizer double-finish 不会重复吐旧结果。
- Tests:
  - 新增：
    - 第一次 `finish()` 正常返回 turn
    - 第二次 `finish()` 返回 `nil`
    - 第二次前后状态不污染下一次新的 `push(...)`

### 5.3 Clarify: `.replay/.waited` 为什么不需要 `complete(lease:)`
- Files:
  - `ModelProxy/Proxy/ProxyForwarder.swift`
  - `ModelProxy/Services/BranchRequestCoordinator.swift`
  - `.plan/four-issues-hardening.md` 或相关架构计划文件（如果需要同步）
- Change:
  - 在 `ProxyForwarder.forward(...)` 的 switch 上方补注释：
    - `.replay` 是 follower 直接消费 leader 结果；
    - `.waited` 是等待前序 leader 释放后重新 acquire；
    - 只有 `.acquired` 才拥有需要 `complete(...)` 的 lease。
  - 在 `BranchRequestCoordinator` 协议或类型头部补同一层语义注释。
- Result:
  - 后续维护者不会把这条路径误判成资源泄漏。

### 5.4 Clarify: `24` 与 recorder disable 的设计理由
- Files:
  - `ModelProxy/Services/SessionLineageBroker.swift`
  - `ModelProxy/Services/BranchReplayRecorder.swift`
- Change:
  - 给 `maxCachedLineagesPerClient = 24` 补注释，写明：
    - 当前目标是限制每个 client 的 branch cache 内存与磁盘尺寸；
    - 这个值对应“保留最近 24 条 lineage”而非业务协议要求。
  - 给 `BranchReplayRecorder.disable()` 补注释，写明：
    - 超上限后当前请求永久放弃 replay capture；
    - 不尝试重新启用，是为了避免部分 replay 响应。
- Result:
  - 2/5 类问题从“隐含语义”变成显式约束。

### 5.5 Tests: 补 5 个缺口
- Files:
  - `ModelProxyTests/ResponseRelayTests.swift`
  - `ModelProxyTests/BranchMergeReducerTests.swift`
  - `ModelProxyTests/SessionLineageBrokerTests.swift`
  - `ModelProxyTests/ProxySessionIntegrationTests.swift`（如有必要）
  - `ModelProxyTests/LineageStoreTests.swift`（新增）
- Change:
  - `ResponseRelay` write failure:
    - 用可控 fake/failing channel 或测试替身，断言 relay 遇到 write error 时不会 crash。
  - `ResponseRelay.replay()`:
    - 覆盖 cached response head/body/end 回放顺序。
  - concurrent commits same lineage:
    - 同一 broker、同一 lineage 做并发 commit，断言最终状态一致且不会丢 branch。
  - SSE normalizer double-finish:
    - 如 5.2 所述。
  - `LineageStore` malformed JSON:
    - 坏文件内容下，验证默认 store 装配的恢复策略。
- 关于 malformed JSON recovery 的具体策略：
  - 当前有两种可选实现：

| 方案名 | 架构合理性 | 实现量 | 风险或代价 | 适用场景 |
|---|---|---:|---|---|
| A. `SessionLineageBroker.init` 继续 `try? loadLineages()`，坏文件时回退空字典，并加日志 | 高 | 低 | 会丢坏文件中的状态 | 当前最适合 |
| B. `FileLineageStore.loadLineages()` 内部吞错并 rename 坏文件 | 中 | 中 | store 自身语义更重 | 想把恢复逻辑集中到 store 层 |

  - 推荐：**A**
  - 理由：当前 broker 已经是恢复边界，最小改动即可让坏文件恢复行为显式可测。

## 6. Test Plan
- `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
- `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests test`
- `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`

## 7. Acceptance Criteria
- `commitResponse(...)` 在 save throw 时不再先污染内存状态；
- same normalizer 实例 double-finish 不再重复产出旧 turn；
- `ProxyForwarder` 与 `BranchReplayRecorder` 的关键语义都有代码内注释；
- 5 个测试缺口全部补齐并通过；
- 完整测试继续通过。

## 8. Risks
- 并发 commit 测试如果直接依赖 actor 调度顺序，容易写成脆弱测试；
- ResponseRelay write failure test 需要可控 channel 替身，不能直接依赖真实 NIO channel 随机报错；
- malformed JSON recovery 若只做 broker 层回退，必须把日志也一起补上，否则恢复行为仍然不透明。

## 9. TODO
- [ ] 调整 `commitResponse(...)` 的 save/apply 顺序
- [ ] 为持久化失败补测试
- [ ] 给 `PortableSSEStreamNormalizer` 增加 `resetState()`
- [ ] 补 double-finish 测试
- [ ] 补 `.replay/.waited` 路径语义注释
- [ ] 补 `24` 与 recorder disable 的注释
- [ ] 补 `ResponseRelay` write failure / replay tests
- [ ] 补 malformed lineage file recovery test

## [自检-表面] 本次任务最容易违反哪条规则？
答：规则 7「证据先于声称」；因为 2/5 这种项很容易凭感觉说“只是注释问题”，但必须先证明它不是运行时 bug。

## [自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最可能实际未生效？
答：malformed lineage file recovery；如果只补测试、不把 broker 初始化时的恢复与日志语义写清，坏文件场景仍然是不透明的。

## [自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：无；这些问题都在 app 自己的状态一致性与流式协议处理边界内。
