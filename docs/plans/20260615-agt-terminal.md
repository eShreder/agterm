# agt — minimal native macOS SwiftUI terminal on libghostty

## Overview

`agt` is a small, native macOS terminal built on **libghostty** (Ghostty's embedding library, linked as the prebuilt `GhosttyKit.xcframework` — no Zig build, no submodule). The whole app shell is SwiftUI; only the terminal surface itself is a thin AppKit bridge (`NSViewRepresentable` over a Metal-backed `NSView`), because libghostty renders into a Metal layer and needs raw key/IME/mouse events SwiftUI does not expose.

What it does (first cut):
- Two-level sidebar tree: **workspace** (user-named, e.g. "work", "personal") → **sessions** (individual shells).
- One libghostty surface per session (no splits).
- Default session name = basename of the session's working directory; renameable, custom name sticks.
- New session, new workspace, move a session between workspaces, rename, close.
- Auto-persist on every change and on quit; restore the tree + names + each session's cwd on next launch (fresh shells — see limitation).

Problem it solves: Ghostty has no vertical tabs and no workspace grouping; cmux does but is heavy (embedded browser, agent notifications, socket API). `agt` is the stripped-down version: just grouped vertical sessions that persist.

**Known limitation (by design):** restore cannot resurrect a live process. A running `vim`/`npm run dev` is not reattached. What restores is the structure, names, and each session's saved working directory; each session re-spawns a fresh login shell in that directory. True session survival would need a tmux-style backend — out of scope.

**Second limitation:** the saved working directory comes from the `GHOSTTY_ACTION_PWD` callback, which only fires when the shell has ghostty shell-integration / OSC 7 active (auto-injected for zsh/bash/fish/nu when the shell-integration resources are present). If PWD is never reported, a session restores to the directory it was *created* in. Acceptable for the first cut.

## Context (from discovery)

- Working dir `/Users/umputun/dev.umputun/experiments/agt` is empty and not yet a git repo.
- Reference implementation: **macterm** (`thdxg/macterm`, MIT) cloned at `/tmp/macterm`, built under the **same** toolchain we target (`SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`). We adapt its unavoidable-complexity files (ghostty app init, runtime callbacks, surface NSView, resource resolution) with attribution, and write our own model/sidebar/persistence. macterm is the ground truth for what actually compiles under strict concurrency.
- Toolchain verified on this machine: `xcodegen` 2.45.4, `xcodebuild` (Xcode 26.5), `gh` 2.94, `swift` 6 (`swift test`), `zig` present (unused). `mise` NOT installed — bypass it, call `xcodegen`/`xcodebuild`/`swift` directly via shell scripts.
- Prebuilt artifacts exist and are fresh: `thdxg/ghostty` release `build-2026-06-14` ships `GhosttyKit.xcframework.tar.gz` + `ghostty-resources.tar.gz`, fetched with `gh release download`. Both are gitignored, never committed.
- Plan reviewed by four agents: a general plan-review and three Swift-skill expert lenses (SwiftUI, Swift 6 concurrency, Swift Testing). Their findings are baked into the sections below.

## Development Approach

- **Testing approach**: code-first for each unit, then tests in the same task before moving on. The pure, deterministic logic lives in a **host-free `agtCore` Swift package** (Foundation + Observation only, NO GhosttyKit/AppKit/Metal) and is tested with **Swift Testing** via `swift test` — fast, fully parallel, no app host. The GUI/surface bits (Metal rendering, key forwarding, libghostty lifecycle) live in the app target and are **not** unit-tested — they are verified by building and running the app and confirming a working shell.
- Complete each task fully before the next. Small, focused changes.
- **Every task that adds testable logic MUST add/update `agtCore` tests in the same task**, covering success and edge cases. Task 1 (scaffold/spike) has a build-and-run verification instead of unit tests, called out explicitly.
- **The app must build (`xcodebuild`) and launch, and `swift test` must pass, after every task.**
- Swift 6 strict concurrency is on. `agtCore`'s model is `@MainActor`; the C-interop boundary follows the explicit **Concurrency contract** (Technical Details) — this is the highest-risk area and is spelled out so it isn't improvised.

## Testing Strategy

- **Unit tests** (`agtCore` package, Swift Testing, `import Testing`, NO `import XCTest`): model mutations, naming, persistence. `swift test` from the package dir. Required per task as noted.
- **`@MainActor` only where needed**: suites touching `@MainActor` types (`AppStore`, `Session`) are annotated `@MainActor`; pure value-type tests (`Snapshot` Codable round-trip, basename derivation as a free/value function) stay off the main actor to preserve parallelism. Never put `@available` on a suite type.
- **No host, no guard, no smoke test**: because `agtCore` links no GhosttyKit/Metal, there is no `BUNDLE_LOADER`/`TEST_HOST` and no `XCTestConfigurationFilePath` early-return — those were XCTest-era workarounds the split removes.
- **No e2e/UI harness** in the first cut. The surface and SwiftUI wiring are verified manually per the run-verification checkbox in each task.
- Test command: `swift test` (in `agtCore/`). App build/run: `scripts/run.sh`.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- New tasks get a ➕ prefix; blockers get a ⚠️ prefix.
- Keep this file in sync with actual work; update scope here if it changes during implementation.

## Solution Overview

Two modules. The pure model is a host-free package; the app target adds SwiftUI + the libghostty bridge.

```
agtCore  (local SwiftPM package — Foundation + Observation ONLY, no GhosttyKit/AppKit)
 ├─ Workspace            struct { id, name, sessions:[Session] }
 ├─ Session              @Observable @MainActor final class
 │     { id; var customName:String?; var currentCwd:String?; let initialCwd:String
 │       @ObservationIgnored var surface: (any TerminalSurface)? }
 │     displayName = customName ?? basename(currentCwd ?? initialCwd)
 ├─ AppStore             @Observable @MainActor final class
 │     { var workspaces:[Workspace]; var selectedSessionID: UUID? }   // single-ID selection
 │     addWorkspace/addSession/moveSession/rename*/closeSession/selectSession
 │     snapshot() / restore(from:)  + save() hook
 ├─ TerminalSurface      protocol (AnyObject): teardown()    // app's NSView conforms
 ├─ Snapshot             Codable, Equatable, Sendable value types
 ├─ PersistenceStore     load/save JSON at ~/Library/Application Support/agt/
 └─ agtCoreTests         Swift Testing → `swift test`

app target  (XcodeGen project — SwiftUI + GhosttyKit.xcframework)
 ├─ agtApp               @main App; Window("agt"); @State private var store = AppStore()
 │     AppDelegate: init GhosttyApp.shared; restore on launch; save on terminate
 ├─ GhosttyApp           @MainActor singleton: init/config/app_new, 120fps tick
 ├─ GhosttyCallbacks     final class @unchecked Sendable — the C-callback router
 ├─ GhosttyResources     resolve + setenv GHOSTTY_RESOURCES_DIR (terminfo sibling trick)
 ├─ GhosttySurfaceView   NSView, conforms TerminalSurface; ghostty_surface_new; input/focus/resize
 │     holds [weak session]; on PWD → main → session.currentCwd = pwd
 ├─ TerminalView         NSViewRepresentable; makeNSView returns/creates the session's surface
 ├─ ContentView          NavigationSplitView { SidebarView } detail: { TerminalView(active).id(active.id) }
 └─ SidebarView          List(.sidebar) + DisclosureGroup per workspace; rename via @FocusState+TextField
```

Key design decisions (each grounded in a review):
- **Selection is a single `Session.ID?`** (`AppStore.selectedSessionID`), not a `(workspaceID, sessionID)` tuple — tuples aren't `Hashable` and can't back `List(selection:)`. Workspace rows are non-selectable disclosure headers; only sessions are detail targets, so one ID suffices. The active session's owning workspace is derived.
- **Detail pane swaps surfaces via `.id(session.id)`**, not a self-mutating representable. `TerminalView(session).id(session.id)` gives each session its own representable identity; switching sessions dismantles the old `TerminalView` and makes a new one, but because `dismantleNSView` is a no-op and the `Session` owns the surface, the old shell survives and the new session's `makeNSView` returns *its* cached view. This stays inside `NSViewRepresentable`'s documented contract (no "detach prior superview" hack).
- **`Session` is `@Observable @MainActor`**; the `surface` slot is `@ObservationIgnored` so assigning the lazily-created NSView never churns observation. Only `customName`/`currentCwd` are observed, so the sidebar refreshes when PWD arrives.
- **`Session` holds its surface behind the `TerminalSurface` protocol** (defined in `agtCore`); the concrete `GhosttySurfaceView` lives in the app target. This keeps `agtCore` free of GhosttyKit/Metal so its tests run host-free.
- **Single `Window("agt")` scene**, not `WindowGroup` — the whole app state is one persisted tree; a single window quits on close and won't spawn a second empty tree the persistence layer doesn't model.
- **Persistence** is a plain Codable JSON snapshot, saved eagerly (no debounce) after each mutation and on terminate.

## Technical Details

### libghostty integration (confirmed from macterm source)

Startup, once (in `GhosttyApp.init`, `@MainActor`):
1. `GhosttyResources.resolve()` → pick `Bundle.main.resourceURL/ghostty` (must contain `shell-integration/`), `setenv("GHOSTTY_RESOURCES_DIR", dir, 1)`. **Do not** set `TERMINFO` — libghostty derives `TERMINFO = dirname(GHOSTTY_RESOURCES_DIR)/terminfo` at shell spawn, so `terminfo/` must sit as a **sibling** of `ghostty/` inside `Contents/Resources/`.
2. `ghostty_init(argc, argv)`.
3. `ghostty_config_new()` (**guard nil** — returns nil on OOM); optionally `ghostty_config_load_file` a tiny defaults conf; then **explicitly** `ghostty_config_load_file(cfg, expanded ~/.config/ghostty/config)` if it exists (libghostty does NOT read the user's XDG config on its own), then `ghostty_config_load_recursive_files(cfg)` (handles `config-file` includes), then `ghostty_config_finalize`.
4. Build `ghostty_runtime_config_s`: `userdata = Unmanaged.passUnretained(self).toOpaque()` (safe — `GhosttyApp.shared` is a process-lifetime singleton), set `wakeup_cb`, `action_cb`, clipboard cbs, `close_surface_cb`. `ghostty_app_new(&rt, cfg)` — **on nil result, `ghostty_config_free(cfg)` and fail loudly**.
5. `Timer` at 1/120s on `RunLoop.main` `.common` → closure uses `MainActor.assumeIsolated { tick() }` (valid — a main-RunLoop timer is proven main-thread) → `ghostty_app_tick(app)`. Do not use `Task { @MainActor in }` (scheduling latency at 120Hz) or `DispatchQueue.main.async` (redundant).

Per surface (`GhosttySurfaceView.createSurface`, called when the view has a sized window):
- `var c = ghostty_surface_config_new()`; `c.platform_tag = GHOSTTY_PLATFORM_MACOS`; `c.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()`; `c.userdata = Unmanaged.passUnretained(self).toOpaque()` (the `Session` retains this view, so unretained is safe — see the coupling note in Concurrency contract); `c.scale_factor`; `c.working_directory = strdup(cwd)`; `c.command = nil` (login shell). `ghostty_surface_new(app, &c)` → then `set_color_scheme`, `set_display_id`, `set_focus`.
- **`working_directory`/`initial_input` strdup buffers must outlive `ghostty_surface_new`** (libghostty consumes `initial_input` asynchronously after spawn). Store them in a `nonisolated(unsafe)` `[UnsafeMutablePointer<CChar>]`; free only in `destroySurface()`.
- **Guard non-zero backing size before `ghostty_surface_new`** — the Metal layer needs a sized window. If `viewDidMoveToWindow` fires with a zero-size backing, set a `pendingSurfaceCreation` flag and create from `setFrameSize` once size is known (copy macterm's `pendingSurfaceCreation`). This is the single most common blank-surface bug.
- Resize/scale: `ghostty_surface_set_content_scale(s, scale, scale)` + `ghostty_surface_set_size(s, w, h)` from `setFrameSize`, `viewDidChangeBackingProperties`, `viewDidMoveToWindow`.
- Input: `ghostty_surface_key`, `ghostty_surface_mouse_pos/button/scroll`, `ghostty_surface_preedit`. Focus via `becomeFirstResponder`/`resignFirstResponder` → `ghostty_surface_set_focus`.
- Teardown: `ghostty_surface_free` ONLY in explicit `destroySurface()` (+ deinit safety net). `dismantleNSView` is a **no-op**.

### Concurrency contract at the C boundary (Swift 6 strict, `complete`)

This is the highest-risk area. An executor must implement it exactly, not improvise — strict concurrency rejects the naive forms.

1. **Callback router** = `final class GhosttyCallbacks: @unchecked Sendable` (holds no mutable state). It is NOT `@MainActor` — the C closures run synchronously off whatever thread libghostty calls from.
2. **C `@convention(c)` closures capture nothing**; they reach Swift via the `GhosttyApp.shared` singleton, e.g. `rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }`.
3. **Every `@MainActor` state touch from a callback goes through `DispatchQueue.main.async`.** Copy C strings to a Swift `String` **before** the hop (the `char*` is only valid for the synchronous callback duration), then capture the `String` value:
   ```
   case GHOSTTY_ACTION_PWD:
     guard let view = surfaceView(from: target), let p = action.action.pwd.pwd else { return true }
     let pwd = String(cString: p)                 // value, built in nonisolated context
     DispatchQueue.main.async { view.applyPwd(pwd) }   // store on MainActor
   ```
4. **`assumeIsolated` is allowed ONLY in the `RunLoop.main` `Timer` closure** (proven main-thread). NEVER in `action_cb`/`wakeup_cb`/`close_surface_cb` — those aren't guaranteed main-thread and would crash.
5. **`surface: ghostty_surface_t?` and the strdup buffer array are `nonisolated(unsafe)`**, documented invariant: mutated only on `@MainActor` (create/destroy), and the C callbacks that read them are serialized by libghostty's tick model.
6. **`passUnretained(self)` for the view is valid only while the surface-free-ordering rule holds** (fragile point 4): the `Session` retains the view until `destroySurface()`, which is the only place `ghostty_surface_free` runs. If a session were dropped while libghostty still held the unretained `userdata`, `takeUnretainedValue()` would dereference freed memory. The `close_surface_cb` must therefore only recover the view and `DispatchQueue.main.async` to `AppStore.closeSession` (never close/free synchronously from the callback).
7. **Do NOT make `Session` `Sendable`/`actor`** — a `@MainActor` class is already implicitly `Sendable` via its isolation. The Codable `Snapshot` value types are implicitly `Sendable`. Build the snapshot on `@MainActor`, then hand the `Sendable` value to the file writer (never pass `Session`/`AppStore` across isolation).
8. **`agt` drops the appearance/theme feature in the first cut** (callbacks handled: PWD, title, clipboard, close). So macterm's `DispatchQueue.main.async` appearance-observer deferral (a `dispatch_once`-reentrancy dodge on `static let shared`) is **not** copied in unless an appearance observer is actually added.

### Target layout & build

- **`agtCore/`** — local Swift package, `Package.swift` declares a library `agtCore` (deps: none beyond Foundation/Observation) and a test target `agtCoreTests` (dep: `Testing`). Buildable/testable standalone via `swift test`.
- **`project.yml`** (XcodeGen) — app target `agt`: macOS 14 deployment, `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, `ENABLE_HARDENED_RUNTIME YES`, `CODE_SIGN_IDENTITY "-"`, `OTHER_SWIFT_FLAGS: [-Xcc, -Wno-incomplete-umbrella]`, `OTHER_LDFLAGS: [-lc++]`. Depends on the local `agtCore` package.
- Dependency: `framework: GhosttyKit.xcframework` with **`embed: false`** (linked, not copied — embedding breaks signature on non-Developer-ID builds). Link `Metal`, `MetalKit`, `QuartzCore`, `AppKit`, `CoreText`, `IOKit`, `Foundation`, `CoreGraphics`.
- Resources as **folder references** (`type: folder`, `buildPhase: resources`): `agt/Resources/ghostty` and `agt/Resources/terminfo` (sibling layout preserved).
- Entitlements: hardened runtime ON, **NO** app-sandbox; `com.apple.security.cs.disable-library-validation = true`, `com.apple.security.cs.allow-jit = true`, `com.apple.security.cs.allow-unsigned-executable-memory = true`.
- Info.plist: `LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable true`, `NSPrincipalClass NSApplication`, `LSApplicationCategoryType public.app-category.developer-tools`.
- macOS 14 API baseline: `NavigationSplitView`, `@Observable`/`@Bindable`/`.defaultFocus`, `.onChange(of:){ old,new in }` are all available. **No Liquid Glass / iOS 26+ APIs** (`glassEffect`, etc.).

### SwiftUI wiring (named explicitly)

- Ownership: `agtApp`/`ContentView` own the store → `@State private var store = AppStore()` (never `@StateObject`). Consumers that bind into it use `@Bindable var store` locally or a `@Binding` to the specific value. All `@State`/`@FocusState` are `private`.
- Scene: `Window("agt", id: "main") { ContentView().frame(minWidth:, minHeight:) }.defaultSize(...).windowResizability(.contentMinSize)`, toolbar style `.unified`.
- Sidebar: `List(selection: $store.selectedSessionID)` with a `DisclosureGroup` per workspace and a `ForEach(workspace.sessions)` of session rows tagged by `session.id` (stable UUID identity, never `.indices`). `OutlineGroup` is NOT used (headers are non-selectable; only leaves are) — the `DisclosureGroup` idiom is correct here.
- Rename: a single unified row view toggles `Text`↔`TextField` (constant view count). Editing uses a `private @FocusState` keyed by id; enter edit via one trigger (double-click/context menu), commit on `.onSubmit` + focus loss, cancel on Escape; empty name clears `customName` to nil. No tap gesture that also writes `@FocusState` on a `.focusable()` row (double body-eval revokes focus).

### Persistence format

`~/Library/Application Support/agt/workspaces.json`:
```json
{
  "version": 1,
  "selectedSessionID": "uuid",
  "workspaces": [
    { "id": "uuid", "name": "work",
      "sessions": [ { "id": "uuid", "customName": null, "cwd": "/Users/umputun/dev/foo" } ] }
  ]
}
```
On save, a session's `cwd` is its live `currentCwd ?? initialCwd` (`currentCwd` is nil until the first PWD report — see the second known limitation). `Snapshot` types are `Codable, Equatable, Sendable`. Snapshot is built on `@MainActor`; the writer receives the value and writes atomically. On restore, build `Session(initialCwd: cwd, customName: customName)`; surface (and shell) spawns lazily on first display.

### Load-bearing fragile points (encode as checks)

1. **terminfo sibling-dir layout** — `terminfo/` must be a direct sibling of `ghostty/` in `Contents/Resources/`. If broken, `TERM=xterm-ghostty` fails and keys break.
2. **`working_directory`/`initial_input` strdup buffers** (`nonisolated(unsafe)`) must outlive `ghostty_surface_new`; free only in `destroySurface()`.
3. **`GhosttyKit.xcframework` `embed: false`** — never embed.
4. **`dismantleNSView` no-op** — only `destroySurface()` may call `ghostty_surface_free`. This rule is what makes `passUnretained(view)` safe (Concurrency contract #6).
5. **Guard `ghostty_config_new()` nil** — fail loudly.
6. **Non-zero backing size before `ghostty_surface_new`** — defer via `pendingSurfaceCreation`; a zero-size Metal layer renders blank.
7. **C-callback isolation** — router is `@unchecked Sendable`, hops via `DispatchQueue.main.async`, `assumeIsolated` only in the Timer (Concurrency contract).

## What Goes Where

- **Implementation Steps** (`[ ]`): everything buildable here — `agtCore` package, app target, ghostty integration, sidebar, persistence, tests, docs.
- **Post-Completion** (no checkboxes): manual run-verification and `git init` + first commit (dir is not yet a repo).

## Implementation Steps

### Task 1: Scaffold (app target + agtCore package) + GhosttyKit download + render ONE working surface

Highest-risk task first: prove libghostty renders a working shell end-to-end AND that the host-free test package runs, before building UI.

**Files:**
- Create: `.gitignore` (ignore `GhosttyKit.xcframework/`, `agt/Resources/ghostty`, `agt/Resources/terminfo`, `build/`, `agt.xcodeproj/`, `.build/`, `*.tar.gz`)
- Create: `agtCore/Package.swift` (library `agtCore` + test target `agtCoreTests`, Swift 6, strict concurrency)
- Create: `agtCore/Sources/agtCore/Placeholder.swift` (temporary, replaced in Task 2) and `agtCore/Tests/agtCoreTests/SmokeTests.swift` (one `@Test` proving `swift test` runs host-free)
- Create: `project.yml` (XcodeGen: app target `agt` + local `agtCore` package dep, per Technical Details)
- Create: `scripts/setup.sh` (download + extract xcframework and ghostty-resources from `thdxg/ghostty`, pinned tag, idempotent)
- Create: `scripts/run.sh` (setup → `xcodegen generate` → `xcodebuild` Debug → `open`), `scripts/build.sh`, `scripts/test.sh` (`cd agtCore && swift test`)
- Create: `agt/Info.plist`, `agt/agt.entitlements`
- Create: `agt/agtApp.swift` (@main App + `Window("agt")` + AppDelegate that does `_ = GhosttyApp.shared`)
- Create: `agt/Ghostty/GhosttyApp.swift` (adapt macterm: startup sequence with explicit user-config load + `load_recursive_files` + finalize, free config on `app_new` failure, 120fps timer via `assumeIsolated`), attribution header
- Create: `agt/Ghostty/GhosttyCallbacks.swift` (`@unchecked Sendable` router; PWD/title/clipboard/close; `DispatchQueue.main.async` hops), attribution header
- Create: `agt/Ghostty/GhosttyResources.swift` (adapt macterm), attribution header
- Create: `agt/Ghostty/GhosttySurfaceView.swift` (NSView: surface create with non-zero-size guard, `nonisolated(unsafe)` surface+buffers, input/focus/resize), attribution header
- Create: `agt/Views/TerminalView.swift` (`NSViewRepresentable`: `makeNSView` returns/creates the surface; `updateNSView` deferred surface creation + focus; `dismantleNSView` no-op)
- Create: `agt/ContentView.swift` (temporary: a single hardcoded `TerminalView` at `$HOME`, used via `.id("spike")`)

- [ ] write `setup.sh` pinned to release tag `build-2026-06-14` (note how to bump); run it; confirm `GhosttyKit.xcframework/` and `agt/Resources/{ghostty,terminfo}` (terminfo a sibling of ghostty) exist
- [ ] create `agtCore` package skeleton; `cd agtCore && swift test` runs green (host-free, no GhosttyKit) — establishes the test path
- [ ] write `project.yml` (app target + local `agtCore` package dependency, GhosttyKit `embed:false`), `Info.plist`, `agt.entitlements` per Technical Details
- [ ] adapt `GhosttyApp.swift`, `GhosttyCallbacks.swift`, `GhosttyResources.swift` implementing the Concurrency contract verbatim (router `@unchecked Sendable`; hops via `DispatchQueue.main.async`; `assumeIsolated` only in the timer)
- [ ] adapt `GhosttySurfaceView.swift` (surface create with `pendingSurfaceCreation` non-zero-size guard; `nonisolated(unsafe)` surface + strdup buffers; input/focus/resize)
- [ ] add `TerminalView` (NSViewRepresentable: `makeNSView` returns the cached/created surface; `updateNSView` does deferred creation + focus; `dismantleNSView` no-op) and a temporary `ContentView` with one surface at `$HOME`, applied with `.id(...)`
- [ ] `Window("agt")` scene with `.defaultSize`/`.windowResizability(.contentMinSize)` and `minWidth/minHeight`
- [ ] `xcodegen generate` then `xcodebuild` Debug builds with zero errors AND zero strict-concurrency warnings
- [ ] **run-verification**: launch, confirm a live shell, `echo $TERM` → `xterm-ghostty`, run `ls`, confirm rendering/keys work, `cd` and confirm prompt updates (no unit tests this task — pure integration)

### Task 2: agtCore model (Workspace/Session/AppStore/TerminalSurface) + tree sidebar + new workspace/session

**Files:**
- Create: `agtCore/Sources/agtCore/Session.swift` (`@Observable @MainActor final class`; `@ObservationIgnored` surface behind `TerminalSurface`)
- Create: `agtCore/Sources/agtCore/Workspace.swift` (`struct Workspace: Identifiable`)
- Create: `agtCore/Sources/agtCore/TerminalSurface.swift` (`protocol TerminalSurface: AnyObject { func teardown() }`)
- Create: `agtCore/Sources/agtCore/AppStore.swift` (`@Observable @MainActor final class`: workspaces, `selectedSessionID`, mutations)
- Delete: `agtCore/Sources/agtCore/Placeholder.swift`
- Create: `agt/Views/SidebarView.swift` (`List(selection:)` + `DisclosureGroup` per workspace, session rows)
- Modify: `agt/ContentView.swift` (`NavigationSplitView { SidebarView } detail: { TerminalView(active).id(active.id) }`)
- Modify: `agt/agtApp.swift` (`@State private var store`; seed one default workspace + session on first run; the surface factory: lazily create `GhosttySurfaceView` for a session and assign `session.surface`)
- Create: `agtCore/Tests/agtCoreTests/AppStoreTests.swift`

**Design Contract:**
- `Session` (in `agtCore` — exported, app target consumes it): `@Observable @MainActor final class Session { let id: UUID; var customName: String?; var currentCwd: String?; let initialCwd: String; @ObservationIgnored var surface: (any TerminalSurface)?; init(initialCwd:, customName:) }`
- `AppStore` methods: `addWorkspace(name:)`, `addSession(toWorkspace: UUID, cwd: String) -> Session`, `selectSession(_: UUID)`, `closeSession(_: UUID)`, `activeSession: Session?` (derived from `selectedSessionID`). All `@MainActor`.
- `TerminalSurface` protocol kept minimal (`teardown()`); `GhosttySurfaceView` (app target) conforms.

- [ ] `Session`, `Workspace`, `TerminalSurface`, `AppStore` in `agtCore` (no GhosttyKit import)
- [ ] `SidebarView`: two-level `List(selection: $store.selectedSessionID)`, DisclosureGroup per workspace, stable UUID row tags; context menu "New Session"; toolbar "New Workspace"
- [ ] `ContentView` shows `TerminalView(active).id(active.id)`; app-side surface factory assigns `session.surface`
- [ ] write `AppStoreTests` (`@MainActor` suite): add workspace, add session, select, close (incl. closing the active session reselects), empty-state
- [ ] `swift test` green; build + run, confirm multiple sessions across two workspaces each render their own shell, switching does not respawn shells

### Task 3: pwd-basename default naming + rename

**Files:**
- Modify: `agtCore/Sources/agtCore/Session.swift` (`displayName` computed; `currentCwd`)
- Modify: `agtCore/Sources/agtCore/AppStore.swift` (`renameSession`, `renameWorkspace`)
- Modify: `agt/Ghostty/GhosttySurfaceView.swift` (hold `[weak session]`; PWD callback → main → `session.currentCwd = pwd`)
- Modify: `agt/Views/SidebarView.swift` (unified row `Text`↔`TextField`; `@FocusState` rename; commit/cancel)
- Create: `agtCore/Tests/agtCoreTests/SessionTests.swift`

- [ ] `Session.displayName` = `customName ?? (currentCwd ?? initialCwd as NSString).lastPathComponent`; pin behavior for `/` (root) and empty cwd to a concrete value
- [ ] surface updates `session.currentCwd` on main with `[weak session]` (no retain cycle); sidebar refreshes live
- [ ] inline rename for sessions and workspaces via `@FocusState` + `.onSubmit` (+ focus-loss commit, Escape cancel); empty name clears `customName` to nil
- [ ] write `SessionTests`: basename derivation as a tuple `@Test(arguments:)` with literal expected values (nested path, root `/` → pinned value, trailing slash, home); custom-overrides-auto and clear-restores-auto as **separate** non-parameterized `@Test`s (state transitions, not input→output)
- [ ] `swift test` green; build + run, `cd` and confirm the tab name follows the basename, rename and confirm it sticks

### Task 4: Move a session between workspaces (menu)

**Files:**
- Modify: `agtCore/Sources/agtCore/AppStore.swift` (`moveSession(_: UUID, toWorkspace: UUID, at: Int?)`)
- Modify: `agt/Views/SidebarView.swift` (context-menu move)
- Modify: `agtCore/Tests/agtCoreTests/AppStoreTests.swift`

- [ ] `AppStore.moveSession`: remove from source workspace, insert into target, fix `selectedSessionID` if needed, keep the **same** `Session` instance (and its attached surface — no respawn)
- [ ] Sidebar move UI (required): context-menu `Move to ▸ <workspace>` (deterministic across DisclosureGroups; drag-and-drop deferred to Task 4b)
- [ ] write tests: move across workspaces (ordering, selection fixup, moving the active session, moving the last session out of a workspace)
- [ ] `swift test` green; build + run, move a session with a running command and confirm the process survives (same surface instance)

### Task 4b (➕ follow-up): drag-and-drop move

**Files:**
- Modify: `agt/Views/SidebarView.swift`

- [ ] add drag-and-drop via a `Transferable` session id + `.dropDestination` on the workspace header, calling the existing `AppStore.moveSession`
- [ ] keep the context-menu move from Task 4 as fallback
- [ ] run-verify cross-section drag works in SwiftUI `List`; if flaky, leave the menu as the shipped path and note it here (no new unit tests — `moveSession` already covered)

### Task 5: Persistence + restore

**Files:**
- Create: `agtCore/Sources/agtCore/Snapshot.swift` (`Codable, Equatable, Sendable`: version, selectedSessionID, workspaces, sessions {id, customName, cwd})
- Create: `agtCore/Sources/agtCore/PersistenceStore.swift` (load/save JSON at `~/Library/Application Support/agt/workspaces.json`, atomic write, accepts an explicit directory URL for testability)
- Modify: `agtCore/Sources/agtCore/AppStore.swift` (`snapshot()` on `@MainActor`; `restore(from:)`; `save()` after every mutation)
- Modify: `agt/agtApp.swift` (restore on launch; save on `applicationWillTerminate`)
- Create: `agtCore/Tests/agtCoreTests/PersistenceTests.swift`

- [ ] `Snapshot` value types (`Equatable`); `AppStore.snapshot()` captures `currentCwd ?? initialCwd` per session (built on `@MainActor`, handed as a value to the writer); `AppStore.restore(from:)` rebuilds workspaces/sessions (surfaces lazy)
- [ ] `PersistenceStore.save/load` with atomic write; **per-case contract**: missing file → return default (no throw); corrupt JSON or version mismatch → start fresh (recover default, don't crash). Take the storage directory as a parameter so tests use a temp dir
- [ ] hook eager `save()` into every mutation (add/move/rename/close/select) and into terminate
- [ ] on launch: load snapshot, restore; if none, seed one default workspace + session
- [ ] write `PersistenceTests` (class suite with `init`/`deinit` creating/removing a unique temp dir; `try #require` to unwrap): snapshot round-trip `#expect(decoded == original)`; restore rebuild matches tree + names + cwds; missing-file returns default; corrupt-file and version-mismatch recover default (assert recovered value, `#expect(throws:)` only if modeled as throwing)
- [ ] `swift test` green; build + run, create workspaces/sessions/renames, quit, relaunch, confirm tree + names + working directories restore (fresh shells)

### Task 6: Verify acceptance criteria

*(verification-only task — no new tests)*

- [ ] every Overview requirement implemented: two-level tree, one surface/session, pwd-basename naming + rename, new session/workspace, move between workspaces, persist + restore
- [ ] edge cases: closing active session, empty workspace, root-dir naming, missing/corrupt persistence file, surface preserved across move
- [ ] `cd agtCore && swift test` fully green; clean app build from scratch (`rm -rf agt.xcodeproj build`, `scripts/run.sh`) launches and works
- [ ] confirm no committed binaries, no Zig/submodule, zero strict-concurrency warnings

### Task 7: Documentation

- [ ] `README.md`: what agt is, the libghostty/no-Zig approach, build/run (`scripts/setup.sh`, `scripts/run.sh`, `swift test`), the two restore limitations, attribution to macterm (MIT)
- [ ] `ARCHITECTURE.md`: agtCore/app split, surface-ownership + `.id(session.id)` rule, the Concurrency contract, the fragile points
- [ ] `CLAUDE.md`: project-specific notes (toolchain, xcframework source/pin, terminfo sibling trick, surface lifecycle + C-callback isolation gotchas)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*No checkboxes — manual/external.*

**Repo init:** the working dir is not a git repo. Before the first commit, `git init` and confirm `.gitignore` covers `GhosttyKit.xcframework/`, `agt/Resources/{ghostty,terminfo}`, `agt.xcodeproj/`, `build/`, `.build/`. (Per workflow: do not commit/push without explicit go-ahead.)

**Manual verification scenarios:**
- Multiple workspaces, several sessions each; switch rapidly — surfaces must not be torn down or respawned.
- Long-running process (e.g. `top`) survives a session move between workspaces.
- Quit with a session in a deep directory; relaunch; confirm the restored session's fresh shell opens there and the tab name matches the basename.
- A `~/.config/ghostty/config` theme/font is picked up (explicit config load in `GhosttyApp`).

**Out of scope (future cuts):** splits, command palette, quick terminal, global hotkeys, settings UI, Sparkle auto-update, in-terminal search UI, true session/process survival (tmux-style backend), themes/appearance UI, native scrollbar.

---
Smells pre-check: skipped — non-Go project (Swift).
Reviews applied: plan-review (libghostty correctness, test-host, config load) + swiftui-expert (single-ID selection, `.id` representable, `@Observable @MainActor` Session, `@FocusState` rename, `Window` scene) + swift-concurrency (C-boundary contract, `nonisolated(unsafe)`, `assumeIsolated` only in timer) + swift-testing-expert (host-free `agtCore`, tuple parameterized tests, `init`/`deinit` temp-dir, `Equatable` snapshots).
