---
id: E001
title: MenuBarExtra Settings Window Requires Policy Switch
category: api-misuse
source_type: error
keywords: [MenuBarExtra, openSettings, LSUIElement, activationPolicy, orderFrontRegardless, menu-bar-app]
date: 2026-03-06
---

## Symptom

在 LSUIElement (menu bar only) app 中，点击 `openSettings()` 可以打开设置窗口，但窗口不会被带到最前面。如果设置窗口被其他 App 遮挡，再次点击设置按钮无法将其置前。`NSApp.activate()` 单独使用无效，同步切换 `activationPolicy` 也无效。

## Root Cause

LSUIElement app 的 activation policy 是 `.accessory`，macOS 不允许 accessory app 将窗口带到其他 app 之上。必须临时切换到 `.regular` policy 才能获得完整的窗口激活权限。但切换 policy 后需要等待系统处理（约 100ms），同步调用会被系统忽略。

## Prevention

对 LSUIElement menu bar app 打开设置窗口的正确模式：

1. 调用 `openSettings()`
2. 异步（`Task`）切换 `NSApp.setActivationPolicy(.regular)`
3. `Task.sleep(100ms)` 等待系统处理
4. `NSApp.activate()` + 找到设置窗口调用 `makeKeyAndOrderFront` / `orderFrontRegardless`
5. 设置窗口关闭时（`onDisappear`）恢复 `NSApp.setActivationPolicy(.accessory)`

关键代码位置：
- `ModelProxy/Views/StatusPopover.swift` — 设置按钮点击处理
- `ModelProxy/App/ModelProxyApp.swift` — Settings scene 的 onDisappear

参考：https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items
