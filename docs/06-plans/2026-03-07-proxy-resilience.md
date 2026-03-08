# Proxy Resilience Implementation Plan

**Goal:** Implement proxy resilience features — per-vendor configurable timeouts, 429-triggered failover with simple counter, debug error text logging, vendor compatibleClientID field, route primary/backup targets.

**Architecture:** Extend existing config models (Vendor, ModelMapping) with timeout fields, compatibleClientID, and backup target fields. Add lightweight in-memory failover state (failCount + activeTarget) to RoutingSnapshot. Modify ProxyForwarder to detect 429 on mapped routes and retry with backup target while preserving original request body. Timeout values read from Vendor config at request time. Settings UI shows Primary/Backup label reflecting current activeTarget state.

**Tech Stack:** Swift 6, macOS 14+, SwiftNIO + NIOHTTP1, AsyncHTTPClient, SwiftUI, OSLog

**Design doc:** none

**Design analysis:** none

**Crystal file:** docs/11-crystals/2026-03-07-proxy-resilience-crystal.md

---

## Decisions

None.

---

## Task 1: Add per-vendor timeout configuration

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift:4-25`
- Test: `ModelProxyTests/ModelProxyTests.swift:10-20`

**Steps:**
1. Add `connectTimeoutSeconds: Int` (default 10) and `readTimeoutSeconds: Int` (default 120) to `Vendor` struct
2. Update `Vendor.init()` with default parameter values
3. Implement legacy-tolerant Codable: missing fields decode as defaults (same pattern as ClientConfig)
4. Add test `vendorCodableRoundTripWithTimeouts()` to verify new fields persist correctly

**Expected values:**
- New fields have default values 10 and 120
- Existing config files without these fields load without errors
- Custom timeout values persist across save/load cycle

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: All tests pass, including new timeout round-trip test

**Crystal ref:** [D-001]

---

## Task 2: Add compatibleClientID field to Vendor model

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift:4-25`
- Test: `ModelProxyTests/ModelProxyTests.swift` (add new test)

**Steps:**
1. Add `compatibleClientID: UUID?` field to `Vendor` struct (optional, nil = compatible with all clients)
2. Update `Vendor.init()` to accept optional `compatibleClientID` parameter with default `nil`
3. Update `Vendor` Codable implementation (legacy-tolerant: missing field decodes as `nil`)
4. Add test case `vendorCodableRoundTripWithCompatibleClientID()` to verify new field persists correctly

**Expected values:**
- New field is optional with `nil` default
- Existing config files without this field load without errors
- Field value persists across save/load cycle

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: All tests pass, including new test for compatibleClientID round-trip

**Crystal ref:** [D-005], [D-008]

---

## Task 3: Extend ModelMapping to support backup targets

**Files:**
- Modify: `ModelProxy/Models/ModelMapping.swift:6-26`
- Test: `ModelProxyTests/ModelProxyTests.swift:56-67`

**Steps:**
1. Add `backupTargetModel: String?` and `backupTargetVendorID: UUID?` fields to `ModelMapping` (both optional)
2. Update `ModelMapping.init()` to accept optional backup parameters with defaults `nil`
3. Update `ModelMapping` Codable (legacy-tolerant: missing fields decode as `nil`)
4. Add test case `modelMappingWithBackupTargetRoundTrip()` to verify both primary and backup persist

**Data flow:** UI inputs → ModelMapping fields → JSON config → RoutingSnapshot RouteTarget array

**Expected values:**
- Both backup fields are optional with `nil` defaults
- Existing config files without backup fields load without errors
- Backup target values persist across save/load cycle

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: All tests pass, including new backup target test

**Crystal ref:** [D-006]

---

## Task 4: Add failover state to RoutingSnapshot and update RequestRouter

**Files:**
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift:7-118`
- Modify: `ModelProxy/Proxy/RequestRouter.swift:7-37`
- Test: `ModelProxyTests/ModelProxyTests.swift` (add new tests)

**Steps:**
1. Add `RouteState: Sendable` struct inside `RoutingSnapshot` with `failCount: Int` and `activeTarget: ActiveTarget` enum (`.primary` / `.backup`). Both `RouteState` and `ActiveTarget` must conform to `Sendable` (RoutingSnapshot is `Sendable`).
2. Add `private var routeStates: [String: RouteState]` dictionary to `RoutingSnapshot` (keyed by sourceModel)
3. Change `modelMappings` from `[String: RouteTarget]` to `[String: [RouteTarget]]` (array: first = primary, second = backup if present)
4. Update `RoutingSnapshot.init()` to build target array from ModelMapping: primary target first, backup target second (if present)
5. Filter backup target by compatibleClientID: only include if `vendor.compatibleClientID == nil || vendor.compatibleClientID == clientConfig.id`
6. Update `resolve()` to return `(result: ResolveResult, state: RouteState)`. In resolve: look up `routeStates[model]` (default `.primary`, failCount=0). Select target from array based on `activeTarget` index. **Guard: if `activeTarget == .backup` but array has only 1 element (no backup), fall back to primary.**
7. Update prefix-match logic at line 86 (`modelMappings.filter(...).max(...)?.value`) to work with new `[RouteTarget]` value type — extract target from array using same `activeTarget` logic.
8. Keep `ResolveResult` enum unchanged: `.routed(RouteTarget)` / `.blocked(reason:)` — still returns single target
9. Add `mutating func updateRouteState(for model: String, state: RouteState)` on `RoutingSnapshot` to write back mutated state
10. Update `RequestRouter.resolve()` return type to match: `(result: RoutingSnapshot.ResolveResult, model: String, state: RoutingSnapshot.RouteState)` — **must be done in this task to avoid build break**
11. Add `RequestRouter.updateRouteState(model: String, state: RoutingSnapshot.RouteState)` actor method that calls `snapshot.updateRouteState(for:state:)` — this is the write-back path for ProxyForwarder to persist state mutations

**Data flow:** AppConfig + ClientConfig → RoutingSnapshot.init() → modelMappings dictionary (primary/backup arrays) + routeStates dictionary → resolve() → single RouteTarget based on activeTarget. ProxyForwarder mutates state → calls RequestRouter.updateRouteState() → writes back to RoutingSnapshot.

**Expected values:**
- Primary target always present in array
- Backup target only present if vendor has matching compatibleClientID
- resolve() returns single RouteTarget, not array
- RouteState tracks failCount (0-10) and activeTarget (.primary/.backup)
- When activeTarget is .backup but no backup exists, resolve() returns primary target

**Quality markers:**
- RouteState and ActiveTarget explicitly conform to `Sendable`
- RouteState initialized on first resolve() call with defaults: failCount=0, activeTarget=.primary
- State persists across requests via RequestRouter.updateRouteState() write-back
- State resets when RoutingSnapshot is rebuilt on config reload
- No crash when activeTarget=.backup on single-target route

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: Existing routing tests updated for new resolve() signature, new test for compatibleClientID filtering passes, guard for missing backup tested

**Crystal ref:** [D-006], [D-007], [D-008]

---

## Task 5: Add timeout values to RouteTarget and use in ProxyForwarder

**Files:**
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift:9-21` (RouteTarget struct)
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:100`
- Modify: `ModelProxy/Proxy/ProxyServer.swift:57-60`

**Steps:**
1. Add `connectTimeoutSeconds: Int` and `readTimeoutSeconds: Int` to `RouteTarget` struct
2. In `RoutingSnapshot.init()`, copy vendor timeout values into `RouteTarget` (use defaults 10/120 for passthrough)
3. In `ProxyForwarder.forward()` line 100, replace hardcoded `.seconds(120)` with `.seconds(Int64(target.readTimeoutSeconds))`
4. In `ProxyServer.start()` line 59, remove hardcoded read timeout from HTTPClient.Configuration (use default, per-request timeout will override)

**Replaces:** Hardcoded timeout constant at line 100 in ProxyForwarder.swift, hardcoded configuration at line 59 in ProxyServer.swift

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: Compilation succeeds, per-vendor timeouts used at request time

**Crystal ref:** [D-001]

---

## Task 6: Implement 429 detection and failover in ProxyForwarder

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:11-132`
- Modify: `ModelProxy/Proxy/ProxyChannelHandler.swift:57-67`
- Test: `ModelProxyTests/ModelProxyTests.swift` (add new test section)

Note: `RequestRouter.resolve()` signature already updated in Task 4.

**Steps:**
1. In `ProxyForwarder.forward()`, update `router.resolve()` call to capture `RouteState`
2. **CRITICAL:** Before calling `replaceModelField()`, preserve original body: `let originalBodyData = bodyData`
3. After `httpClient.execute()`, check `upstreamResponse.status.code == 429`
4. If 429 and `!target.isPassthrough`:
   - Increment failCount: `state.failCount += 1`
   - If `state.failCount >= 10`: switch `state.activeTarget` (primary ↔ backup), reset `state.failCount = 0`
   - If backup target exists: retry with backup using ORIGINAL body data (`originalBodyData`)
   - Re-call `replaceModelField()` on original body with backup target's model name
   - Rebuild upstream request headers (Host, Authorization, x-api-key) with backup target's baseURL and apiKey
   - Rebuild `entryRouteType` with backup target's model name (for traffic log attribution)
   - Rebuild `onUsage` callback with backup vendor's `vendorID` (for token stats attribution)
   - Log: "Rate limited on \(primaryVendorName), failing over to \(backupVendorName)"
   - Execute retry request; relay backup response, publish traffic entry and token stats for backup vendor
   - If no backup target exists: forward 429 as-is (no retry possible)
5. If 429 and `target.isPassthrough`, forward 429 as-is without retry
6. On any successful response (status < 400): reset `state.failCount = 0`
7. After state mutation (steps 4/6), call `await router.updateRouteState(model: model, state: state)` to persist state back to RoutingSnapshot
8. Pass `router` reference to ProxyForwarder (already available); update `ProxyChannelHandler` if needed

**UX ref:** Tool sees successful response from backup vendor; failover is transparent. Debug log shows "Rate Limited on Vendor A, switched to Vendor B"

**Quality markers:**
- Failover only triggers for 429, not other 4xx/5xx errors
- Failover only happens on mapped routes (not passthrough)
- Original request body preserved before model field replacement
- Traffic log and token stats correctly attribute to backup vendor after failover
- State mutation written back to RequestRouter actor
- Debug log clearly shows failover event
- No retry delay (immediate failover)
- Success resets failCount to 0

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: New test for 429 failover passes, existing tests still pass

**Crystal ref:** [D-002], [D-003], [D-009]

---

## Task 7: Add debug log error code text mapping

**Files:**
- Create: `ModelProxy/Proxy/HTTPStatusText.swift`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:128-131`

**Steps:**
1. Create `enum HTTPStatusText` with static function `text(for code: Int) -> String`
2. Map common codes:
   - 200 → "OK"
   - 400 → "Bad Request"
   - 401 → "Unauthorized"
   - 403 → "Forbidden"
   - 404 → "Not Found"
   - 429 → "Rate Limited"
   - 500 → "Internal Server Error"
   - 502 → "Bad Gateway"
   - 503 → "Service Unavailable"
   - Default → "HTTP \(code)"
3. In `ProxyForwarder.forward()` after response received (around line 128), add debug log: `AppLog.proxy.debug("[Proxy] Response: \(HTTPStatusText.text(for: statusCode))")`

**Design ref:** Error text appears in debug logs only, not in menu bar TrafficLog UI (per crystal D-004)

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: Compilation succeeds, debug log shows "Rate Limited" for 429 responses

**Crystal ref:** [D-004]

---

## Task 8: Update VendorEditSheet UI for compatibleClientID

**Files:**
- Modify: `ModelProxy/Views/VendorEditSheet.swift:12-15`
- Modify: `ModelProxy/Views/VendorEditSheet.swift:69-90`

**Steps:**
1. Add `@State private var compatibleClientID: UUID?` field
2. Add Picker below API Key field: "Compatible Client" with options: "All Clients" (nil) + list of `configStore.config.clients`
3. In `onAppear`, set `compatibleClientID` from existing vendor if editing
4. In `commitVendor()`, set `vendor.compatibleClientID = compatibleClientID`

**UX ref:** User selects "Claude Code" from dropdown when adding a vendor that only works with Claude Code API format. UI shows "All Clients" by default.

**User interaction:** User adds new vendor, sees "Compatible Client" dropdown, selects specific client or leaves as "All Clients". Selection persists.

**Design ref:** Field is labeled "Compatible Client" not "API Format" per crystal D-005 clarification

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: UI compiles, picker shows clients, selection persists

**Crystal ref:** [D-005], [D-008]

---

## Task 9: Update RoutingTabView UI for backup target configuration

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:75-113` (MappingRow editing UI)
- Modify: `ModelProxy/Views/RoutingTabView.swift:170-215` (AddMappingRow UI)

**Steps:**
1. Add `@State private var backupTargetModel: String = ""` and `@State private var backupTargetVendorID: UUID? = nil`
2. Add button "Add Backup Target" next to primary vendor picker (only visible when backup fields are empty)
3. When clicked, show second row with target model field + vendor picker for backup
4. Add "Remove Backup" button when backup is configured
5. In save/add logic, include `backupTargetModel` and `backupTargetVendorID` in `ModelMapping` creation
6. Filter backup vendor picker: only show vendors with `compatibleClientID == nil || compatibleClientID == clientConfig.id` (requires passing client context)

**UX ref:** User sees primary target fields, clicks "Add Backup Target" to reveal backup fields. Backup vendor picker is filtered to compatible vendors only.

**User interaction:** User clicks "Add Backup Target", picker shows only vendors compatible with the current client. User selects backup vendor and model, then saves.

**Quality markers:**
- Backup fields only visible when configured or "Add" button clicked
- Vendor picker filters by compatibleClientID
- Save button disabled if backup model is empty but backup vendor is set (or vice versa)

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: UI compiles, backup fields appear on button click, vendor picker shows filtered list

**Crystal ref:** [D-006], [D-008]

---

## Task 10: Add Primary/Backup indicator to Settings UI

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:116-156` (display-only mapping row)

**Steps:**
1. Pass client context to `MappingRow` (need to know which client's routing is being displayed)
2. In display row (non-editing state), check if mapping has backup target
3. If backup exists, show badge next to vendor name: "Primary" or "Backup" based on current activeTarget state
4. To get state, need to read from RoutingSnapshot's routeStates dictionary via router
5. Use small colored badge or text label (e.g., blue "Primary" / gray "Backup")

**UX ref:** User views routing table, sees "Primary" or "Backup" badge on vendor name. Badge reflects current activeTarget state.

**User interaction:** User views routing rules list, sees badge indicating which target is currently active. No user action needed — this is read-only display.

**Design ref:** Badge updates dynamically when failover state changes. Does not affect user's configured mapping order.

**Quality markers:**
- Badge updates when activeTarget switches
- No badge shown when only primary target exists (no failover)
- Badge doesn't affect user's configured mapping order

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: UI compiles, badges appear for mappings with backup targets

**Crystal ref:** [D-007]

---

## Task 11: Add comprehensive tests for failover and timeouts

**Files:**
- Modify: `ModelProxyTests/ModelProxyTests.swift` (add 6+ new test functions)

**Steps:**
1. Add test `routingSnapshotFiltersBackupByCompatibleClientID()` — create mapping with backup, verify backup excluded when compatibleClientID doesn't match client
2. Add test `routingSnapshotWithBackupTargetResolvesCorrectly()` — verify resolve() returns correct target based on activeTarget state
3. Add test `vendorTimeoutRoundTrip()` — encode/decode Vendor with custom timeouts
4. Add test `modelMappingWithBackupRoundTrip()` — verify backup fields persist
5. Add test `routeStateFailCountThreshold()` — verify failCount >= 10 switches activeTarget
6. Add test `routeStateResetsOnSuccess()` — verify success resets failCount to 0

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test`
Expected: All new tests pass, all existing tests still pass

---

## Task 12: Manual integration testing

**Steps:**
1. Create two vendors with same `compatibleClientID` and different models
2. Create mapping with primary + backup targets
3. Start proxy, send request through mapped model
4. Verify debug log shows primary vendor used
5. Simulate 429 from primary vendor (need to mock or use real rate limit)
6. Verify proxy switches to backup vendor automatically
7. Check debug log shows "Rate Limited" text
8. Send 10+ failing requests to trigger failCount threshold switch
9. Verify Settings label updates from "Primary" to "Backup"
10. Send successful request, verify failCount resets
11. Change timeout config values, restart proxy, verify new timeouts applied
12. Test passthrough route returns 429 without retry

**Verify:**
Manual testing checklist completed without errors

---

## Summary

This plan implements proxy resilience features through 12 tasks spanning config models, routing logic, proxy forwarding, and UI updates. Key architectural changes:

1. **Config extensibility**: Per-vendor timeout fields and backup target fields enable runtime configuration without code changes
2. **Simple failover**: In-memory failCount counter on route state, threshold-based switching (failCount >= 10), state resets on config reload
3. **429-triggered retry**: Mapped routes retry with backup target on 429, passthrough routes forward 429 as-is
4. **Client compatibility**: `compatibleClientID` field filters failover candidates, preventing incompatible format requests
5. **Body preservation**: Original request body preserved before model field replacement for retry scenarios

All changes maintain backward compatibility with existing config files and preserve the "no transformation" constraint. The proxy remains transparent to tools — failover is invisible, and errors are forwarded as-is.