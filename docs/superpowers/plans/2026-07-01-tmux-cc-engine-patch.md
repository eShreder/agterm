# tmux `-CC` — Phase 1: libghostty engine patch + prototype (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch libghostty (built from source by `scripts/setup.sh`) to add a PTY-less
"headless" terminal surface whose screen can be fed external bytes via a new
`ghostty_surface_write_output` C entry, and whose input/resize are delivered to agterm via
C callbacks — then prove it with a running Swift harness. This is the **fork-viability
gate** for the whole tmux `-CC` feature (design spec:
`docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`).

**Architecture:** The patch is additive and lives only in ghostty's io/apprt layer. It
adds a `headless` variant to the existing `termio.Backend` union (a `Headless.zig` backend
that owns no PTY), an `external_output` IO-mailbox message that routes to the existing
`Termio.processOutput`, and C-API surface (`headless` flag + `on_input`/`on_resize`
callbacks + `ghostty_surface_write_output` export) in `apprt/embedded.zig`. Nothing in the
renderer, VT parser, or terminal core changes. `setup.sh` applies the patch as a local
`.patch` over the pinned `GHOSTTY_REV` checkout before building.

**Tech Stack:** Zig 0.15.2 (ghostty engine), `zig build -Demit-xcframework`, XcodeGen +
xcodebuild (agterm app), Swift 6. The ghostty source is fetched by `setup.sh` to a temp
dir; a persistent dev clone already exists at the scratchpad path used below.

## Global Constraints

- libghostty is **built from upstream ghostty source** at `GHOSTTY_REV`
  `4dcb09ada0c0909717d92547623b26eafa50ca8a`; never embed the xcframework
  (`embed: false`).
- The patch must be **additive** — extend the `termio.Backend` `union(Kind)`, do not alter
  `Exec` behavior. An un-patched build, or `headless = false`, must behave exactly as
  today.
- ghostty builds with **zig 0.15.2** (the `zig@0.15` keg); `setup.sh` needs `gettext`
  (`msgfmt`) and Xcode's Metal Toolchain.
- The xcframework, `agterm/Resources/ghostty`, `agterm/Resources/terminfo` are gitignored
  build outputs — never committed. Only `scripts/setup.sh` and `patches/*.patch` are
  committed engine-side.
- Do NOT kill/relaunch the deployed `~/Applications/agterm.app`. The harness runs as an
  isolated dev instance (`open -n --env AGTERM_STATE_DIR=<tmp> --env
  AGTERM_CONTROL_SOCKET=<tmp>/agterm.sock …Debug/agterm.app`), quit by PID.
- After every task the tree must build and `make lint` must pass; Phase 1 adds no
  `swift test` coverage to `agtermCore` (engine + harness only).
- `agtermCore` must stay free of GhosttyKit/AppKit/Metal/CoreGraphics — the harness lives
  in the **app target**, not the core package.

**Dev clone of ghostty (already present, on the pinned SHA):**
`/private/tmp/claude-501/-Users-eshreder-projects-agterm/9d3e587d-3caa-453e-9fee-d80dceac79be/scratchpad/ghostty-src`
Referred to below as `$GH`. All Zig edits are made here first, then captured into
`patches/ghostty-headless.patch`.

## File Structure

| File | Responsibility | Create/Modify |
|---|---|---|
| `scripts/setup.sh` | Apply `patches/*.patch` over the ghostty checkout before `zig build`, idempotently | Modify |
| `patches/ghostty-headless.patch` | The committed engine diff (generated from `$GH` edits) | Create |
| `$GH/src/termio/backend.zig` | `Kind`/`Backend`/`ThreadData`/`Config` gain `headless` arm | Modify (→ patch) |
| `$GH/src/termio/Headless.zig` | PTY-less backend: `queueWrite`→`on_input`, `resize`→`on_resize`, rest no-op | Create (→ patch) |
| `$GH/src/termio/message.zig` | `external_output` mailbox message | Modify (→ patch) |
| `$GH/src/termio/Termio.zig` | Handle `external_output` → `processOutput` | Modify (→ patch) |
| `$GH/src/apprt/embedded.zig` | `Surface.Options` headless fields; headless backend branch; `ghostty_surface_write_output` export | Modify (→ patch) |
| `agterm/Ghostty/HeadlessHarness.swift` | Dev-only harness: build a headless surface, feed VT bytes, log `on_input` | Create |
| `agterm/Ghostty/GhosttySurfaceView.swift` | Add a `headless` creation path used by the harness | Modify |

---

### Task 1: Patch-application infrastructure in `setup.sh`

Make `setup.sh` apply every `patches/*.patch` over the freshly-fetched ghostty checkout
before building, and make it idempotent (the present-check skip path must not try to
re-apply). Deliverable: `setup.sh` applies a no-op-safe patch step and still builds clean.

**Files:**
- Modify: `scripts/setup.sh`
- Create: `patches/.gitkeep` (so the dir exists before any real patch)

**Interfaces:**
- Produces: a `patches/` directory whose `*.patch` files are applied with
  `git -C "$BUILD_DIR" apply` (or `patch -p1`) after checkout, before `zig build`.

- [ ] **Step 1: Read the current fetch/build section of `setup.sh`**

Run: `sed -n '1,200p' scripts/setup.sh` — identify (a) the `BUILD_DIR=$(mktemp -d)`
checkout of `GHOSTTY_REV`, (b) the `zig build -Demit-xcframework…` invocation, (c) the
present-check that skips the build when artifacts already exist.

Expected: you can point to the exact lines where the checkout completes and where
`zig build` starts.

- [ ] **Step 2: Add the patch-apply step**

Insert, immediately after the `GHOSTTY_REV` checkout and before `zig build`, a loop that
applies each committed patch from the agterm repo root (not `$BUILD_DIR`). Use the repo
root the script already resolves (commonly `SCRIPT_DIR`/`ROOT`); if none exists, derive it
once at the top: `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`.

```bash
# Apply local engine patches (additive; see patches/*.patch).
shopt -s nullglob
for p in "$ROOT"/patches/*.patch; do
  echo "Applying engine patch: $(basename "$p")"
  git -C "$BUILD_DIR" apply --whitespace=nowarn "$p"
done
shopt -u nullglob
```

This runs only on the build path (after a fresh checkout), so the present-check skip path
never re-applies — patches are baked into the already-built artifacts.

- [ ] **Step 3: Create the patches dir placeholder and commit the infra**

```bash
mkdir -p patches && touch patches/.gitkeep
git add scripts/setup.sh patches/.gitkeep
git commit -m "build: apply patches/*.patch over ghostty checkout in setup.sh"
```

- [ ] **Step 4: Verify a clean build still succeeds with no patches present**

Because `patches/` holds only `.gitkeep`, the loop is a no-op. Force a rebuild against a
fresh checkout to exercise the new step.

Run: `rm -rf GhosttyKit.xcframework agterm/Resources/ghostty agterm/Resources/terminfo && scripts/setup.sh`
Expected: the script fetches ghostty, prints no "Applying engine patch" line (none exist
yet), and finishes with the xcframework + resources staged. `ls GhosttyKit.xcframework`
succeeds.

- [ ] **Step 5: Restore artifacts cheaply if you symlinked from a main worktree**

(Skip if you ran the real build in Step 4.) If working in a worktree, re-point the
symlinks per CLAUDE.md rather than rebuilding.

---

### Task 2: `headless` backend variant + `Headless.zig` skeleton

Extend the `termio.Backend` union with a `headless` kind and a `Headless` backend that owns
no PTY. `queueWrite` forwards bytes to an `on_input` C callback; `resize` forwards cols×rows
to `on_resize`; everything else is a no-op. Deliverable: ghostty compiles with the new
variant present (still unused).

**Files:**
- Modify: `$GH/src/termio/backend.zig`
- Create: `$GH/src/termio/Headless.zig`

**Interfaces:**
- Consumes: the existing `Backend` contract (`deinit`, `initTerminal`, `threadEnter`,
  `threadExit`, `focusGained`, `resize(grid_size, screen_size)`,
  `queueWrite(alloc, td, data, linefeed)`, `childExitedAbnormally`, `getProcessInfo`) seen
  in `backend.zig`.
- Produces: `termio.Headless` with a `Config` carrying the callback pointers:
  `on_input: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void`,
  `on_resize: ?*const fn (?*anyopaque, u16, u16) callconv(.c) void`,
  `userdata: ?*anyopaque`.

- [ ] **Step 1: Read the full backend contract and one method body to mirror**

Run: `sed -n '1,130p' $GH/src/termio/backend.zig` and
`grep -n "pub fn resize\|pub fn queueWrite\|pub fn threadEnter\|pub fn deinit" $GH/src/termio/Exec.zig`
Expected: you have the exact parameter types of every method the union dispatches, and you
can see how `Exec.queueWrite`/`Exec.resize` are shaped (to mirror types, not behavior).

- [ ] **Step 2: Add the `headless` arm to `backend.zig`**

In `$GH/src/termio/backend.zig`: extend `pub const Kind = enum { exec, headless };`; add
`headless: termio.Headless.Config` to `Config`, `headless: termio.Headless` to `Backend`,
and `headless: termio.Headless.ThreadData` to `ThreadData`; add a `.headless => |*h| …`
arm to every `switch (self.*)` (each method already lists `.exec`). The compiler enumerates
missing arms for you — add each until exhaustive.

- [ ] **Step 3: Write `Headless.zig`**

Create `$GH/src/termio/Headless.zig` mirroring `Exec`'s method signatures but with no PTY.
Shape (adjust types to whatever Step 1 showed exactly):

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

pub const Config = struct {
    on_input: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
    on_resize: ?*const fn (?*anyopaque, u16, u16) callconv(.c) void = null,
    userdata: ?*anyopaque = null,
};

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void { _ = self; _ = alloc; }
    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void { _ = self; _ = config; }
};

cfg: Config,

pub fn init(cfg: Config) Headless { return .{ .cfg = cfg }; }
pub fn deinit(self: *Headless) void { _ = self; }
pub fn initTerminal(self: *Headless, t: *terminal.Terminal) void { _ = self; _ = t; }
pub fn threadEnter(self: *Headless, alloc: Allocator, io: *termio.Termio, td: *termio.Termio.ThreadData) !void { _ = self; _ = alloc; _ = io; _ = td; }
pub fn threadExit(self: *Headless, td: *termio.Termio.ThreadData) void { _ = self; _ = td; }
pub fn focusGained(self: *Headless, td: *termio.Termio.ThreadData, focused: bool) !void { _ = self; _ = td; _ = focused; }

pub fn resize(self: *Headless, grid_size: renderer.GridSize, screen_size: renderer.ScreenSize) !void {
    _ = screen_size;
    if (self.cfg.on_resize) |cb| cb(self.cfg.userdata, @intCast(grid_size.columns), @intCast(grid_size.rows));
}

pub fn queueWrite(self: *Headless, alloc: Allocator, td: *termio.Termio.ThreadData, data: []const u8, linefeed: bool) !void {
    _ = alloc; _ = td; _ = linefeed;
    if (self.cfg.on_input) |cb| cb(self.cfg.userdata, data.ptr, data.len);
}

pub fn childExitedAbnormally(self: *Headless, gpa: Allocator, t: *terminal.Terminal, exit_code: u32, runtime_ms: u64) !void {
    _ = self; _ = gpa; _ = t; _ = exit_code; _ = runtime_ms;
}
pub fn getProcessInfo(self: *Headless, comptime info: ProcessInfo) ?ProcessInfo.Type(info) { _ = self; _ = info; return null; }

const Headless = @This();
```

Note: `grid_size.columns`/`.rows` field names must match `renderer.GridSize` — confirm
with `grep -n "columns\|rows" $GH/src/renderer/size.zig` (or wherever `GridSize` is
defined) and adjust.

- [ ] **Step 4: Export `Headless` from the termio module**

Run: `grep -n "pub const Exec" $GH/src/termio.zig` to find the module's re-exports; add
`pub const Headless = @import("termio/Headless.zig");` alongside `Exec`.

- [ ] **Step 5: Compile the engine (this is the test)**

Run (from `$GH`, with the `zig@0.15` keg on PATH):
`zig build -Demit-xcframework=true -Dxcframework-target=native 2>&1 | tail -40`
Expected: builds with no errors. If the compiler reports a missing union arm or a type
mismatch, fix at the exact location it names and rebuild. The `headless` variant is present
but unconstructed, so no behavior changes.

- [ ] **Step 6: Capture progress into the patch and commit**

```bash
git -C "$GH" add -A
git -C "$GH" diff --cached > /Users/eshreder/projects/agterm/patches/ghostty-headless.patch
cd /Users/eshreder/projects/agterm
git add patches/ghostty-headless.patch
git commit -m "engine: add headless termio backend variant (no PTY)"
```

(`$GH` is a throwaway clone; staging there is only to generate the diff. Keep the changes
staged in `$GH` so the next task's diff is cumulative.)

---

### Task 3: `external_output` mailbox message → `processOutput`

Add an IO-mailbox message carrying external bytes; on the IO thread `Termio` feeds them to
the existing `processOutput`. This is how tmux `%output` reaches the screen. Deliverable:
engine compiles with the new message handled.

**Files:**
- Modify: `$GH/src/termio/message.zig`
- Modify: `$GH/src/termio/Termio.zig`

**Interfaces:**
- Consumes: the existing `Message` union and `WriteReq` data containers in `message.zig`;
  `Termio.processOutput(self, buf: []const u8)` at `Termio.zig:643`.
- Produces: `Message.external_output` (a `WriteReq`-style payload) handled in `Termio`'s
  message pump by calling `self.processOutput(bytes)`.

- [ ] **Step 1: Read the message union and the message pump**

Run: `sed -n '1,120p' $GH/src/termio/message.zig` and
`grep -n "write_small\|write_stable\|write_alloc\|fn handleMessage\|switch (message)\|switch (msg)" $GH/src/termio/Termio.zig $GH/src/termio/Thread.zig`
Expected: you can see how `write_small/stable/alloc` are declared and where incoming
messages are switched and dispatched (the pump that ultimately calls `queueWrite`).

- [ ] **Step 2: Add `external_output` to the `Message` union**

In `message.zig`, add a variant reusing the same `WriteReq` machinery as `write_alloc`
(arbitrary-length, owned bytes), e.g. `external_output: WriteReq.Alloc,` plus, if helpful,
a constructor mirroring the existing `write(...)` helper that yields
`Message{ .external_output = … }`.

- [ ] **Step 3: Handle it in the message pump**

In the `switch` that handles incoming IO messages (Step 1 location), add an arm that pulls
the byte slice out of the `WriteReq` (same accessor the `write_*` arms use to get
`[]const u8`) and calls `self.processOutput(slice)`, then frees the alloc’d request exactly
as the `write_alloc` arm does. Do NOT route it through `backend.queueWrite` (that is the
*input* path).

- [ ] **Step 4: Compile the engine (test)**

Run: `cd $GH && zig build -Demit-xcframework=true -Dxcframework-target=native 2>&1 | tail -40`
Expected: builds clean. Fix any exhaustiveness/type errors at the named location.

- [ ] **Step 5: Update the patch and commit**

```bash
git -C "$GH" add -A
git -C "$GH" diff --cached > /Users/eshreder/projects/agterm/patches/ghostty-headless.patch
cd /Users/eshreder/projects/agterm
git add patches/ghostty-headless.patch
git commit -m "engine: route external_output mailbox message to processOutput"
```

---

### Task 4: C API — headless `Surface.Options` + backend branch + `ghostty_surface_write_output`

Expose the headless path to C: option fields + callbacks, a branch that builds the
`Headless` backend, and the write-output export. Deliverable: the regenerated `ghostty.h`
declares `ghostty_surface_write_output` and the new option fields; engine compiles.

**Files:**
- Modify: `$GH/src/apprt/embedded.zig`

**Interfaces:**
- Consumes: `apprt.Surface.Options` (the struct returned by `ghostty_surface_config_new`,
  ~`embedded.zig:409`+, with `command`/`initial_input`/`wait_after_command`); the
  `initConfig`/`newSurface` translation (~`embedded.zig:529`); the export pattern
  (`export fn ghostty_surface_*`).
- Produces (the C surface later phases consume):
  - `Surface.Options.headless: bool = false`
  - `Surface.Options.on_input: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null`
  - `Surface.Options.on_resize: ?*const fn (?*anyopaque, u16, u16) callconv(.c) void = null`
  - `Surface.Options.headless_userdata: ?*anyopaque = null`
  - `export fn ghostty_surface_write_output(surface: *Surface, ptr: [*]const u8, len: usize) void`

- [ ] **Step 1: Locate the backend construction site**

The `termio.Backend{ .exec = … }` value is built somewhere between the apprt surface config
and `termio.Options`. Find it:
Run: `grep -rn "\.exec = \|termio.Backend\|backend = \|Exec.Config\|termio.Options" $GH/src/apprt/embedded.zig $GH/src/Surface.zig`
Expected: you can point to the exact expression that constructs the `exec` backend for a
normal surface — that is where the `headless` branch goes.

- [ ] **Step 2: Add the option fields**

In `apprt.Surface.Options` (the struct in `embedded.zig`), add the four fields listed in
**Produces** above, with defaults so existing callers (and `ghostty_surface_config_new`)
are unaffected.

- [ ] **Step 3: Branch to the headless backend**

At the construction site from Step 1: if `opts.headless`, build
`termio.Backend{ .headless = termio.Headless.init(.{ .on_input = opts.on_input,
.on_resize = opts.on_resize, .userdata = opts.headless_userdata }) }` instead of the `exec`
backend, and skip the command/`wait-after-command` setup (which only applies to `exec`).
Keep the `else` path byte-for-byte as today.

- [ ] **Step 4: Export `ghostty_surface_write_output`**

Add next to the other `ghostty_surface_*` exports:

```zig
export fn ghostty_surface_write_output(surface: *Surface, ptr: [*]const u8, len: usize) void {
    surface.core_surface.io.queueMessage(
        termio.Message.write(surface.app.core_app.alloc, ptr[0..len]) catch return, // external_output ctor
        .unlocked,
    );
}
```

Adjust to the real accessors: it must (a) allocate a `WriteReq.Alloc` from the surface's
allocator, (b) wrap it as `Message{ .external_output = … }` (the ctor from Task 3 Step 2),
and (c) post it via the surface's `io.queueMessage(msg, .unlocked)` (mirror how
`ghostty_surface_text`/key paths reach `io.queueMessage`). Confirm the exact path with
`grep -n "io.queueMessage\|core_surface\|\.io\b" $GH/src/apprt/embedded.zig`.

- [ ] **Step 5: Compile + verify the generated header declares the symbol**

Run: `cd $GH && zig build -Demit-xcframework=true -Dxcframework-target=native 2>&1 | tail -40`
Expected: builds clean.
Run: `grep -rn "ghostty_surface_write_output\|headless" $GH/zig-out/**/ghostty.h 2>/dev/null || find $GH/zig-out -name ghostty.h -exec grep -n "ghostty_surface_write_output" {} +`
Expected: the generated `ghostty.h` declares `ghostty_surface_write_output` and the new
`headless`/`on_input`/`on_resize` option fields.

- [ ] **Step 6: Finalize the patch and commit**

```bash
git -C "$GH" add -A
git -C "$GH" diff --cached > /Users/eshreder/projects/agterm/patches/ghostty-headless.patch
cd /Users/eshreder/projects/agterm
git add patches/ghostty-headless.patch
git commit -m "engine: C API for headless surface + ghostty_surface_write_output"
```

---

### Task 5: Rebuild the xcframework via `setup.sh` and verify the patched API ships

Run the real `setup.sh` so the committed patch is applied over a fresh checkout and the
staged `GhosttyKit.xcframework` carries the new symbol + header. Deliverable: agterm's
xcframework exposes `ghostty_surface_write_output`.

**Files:** none (build only)

- [ ] **Step 1: Force a fresh patched build**

Run: `rm -rf GhosttyKit.xcframework agterm/Resources/ghostty agterm/Resources/terminfo && scripts/setup.sh 2>&1 | tail -30`
Expected: output includes `Applying engine patch: ghostty-headless.patch` and finishes with
the xcframework staged.

- [ ] **Step 2: Verify the header and the binary**

Run: `grep -rn "ghostty_surface_write_output" GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h`
Expected: the declaration is present.
Run: `nm -gU GhosttyKit.xcframework/macos-arm64/libghostty.a 2>/dev/null | grep ghostty_surface_write_output || nm -g $(find GhosttyKit.xcframework -name 'libghostty*' | head -1) | grep write_output`
Expected: the symbol `_ghostty_surface_write_output` appears.

- [ ] **Step 3: Confirm the app still builds against the patched framework**

Run: `make build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. (No app code uses the new API yet; this proves the
patched framework links cleanly.)

---

### Task 6: Swift harness — render external bytes + catch a keystroke

Add a dev-only path that creates a headless surface, feeds it VT bytes through
`ghostty_surface_write_output`, and logs bytes received via `on_input`. Deliverable: run an
isolated dev instance, see red `hello` rendered, type a key, see it logged. **This is the
fork-viability gate.**

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Create: `agterm/Ghostty/HeadlessHarness.swift`

**Interfaces:**
- Consumes: `ghostty_surface_write_output`, the `headless`/`on_input`/`on_resize` option
  fields, and the existing `createSurface()` flow in `GhosttySurfaceView.swift`
  (`createSurface()` at ~`438-527`, where `ghostty_surface_config_s` is filled).
- Produces: `GhosttySurfaceView.makeHeadless(onInput:)` — a creation path that sets
  `config.headless = true` and registers an `on_input` C trampoline routed back to a Swift
  closure via the `GhosttyApp.shared`-style userdata registry.

- [ ] **Step 1: Read the existing surface-creation flow**

Run: `sed -n '438,527p' agterm/Ghostty/GhosttySurfaceView.swift` and
`grep -n "GhosttyApp.shared\|userdata\|Unmanaged\|surface_config" agterm/Ghostty/GhosttySurfaceView.swift`
Expected: you see how `ghostty_surface_config_s` is populated and how the existing code
maps a C `userdata` pointer back to a Swift object.

- [ ] **Step 2: Add the headless creation path**

In `GhosttySurfaceView.swift`, add `makeHeadless(onInput:)` that fills the config like
`createSurface()` but sets `config.headless = true`, leaves `command`/`working_directory`
unset, and sets `config.on_input` to a `static` C trampoline plus `config.headless_userdata`
to an `Unmanaged.passRetained(self).toOpaque()` (or the existing registry key). The
trampoline copies the bytes into a Swift `Data` **before** any hop and dispatches to the
stored `onInput` closure on `DispatchQueue.main`:

```swift
private static let onInputTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { ud, ptr, len in
    guard let ud, let ptr else { return }
    let bytes = Data(bytes: ptr, count: len)            // copy out of C before hopping
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async { view.headlessOnInput?(bytes) }
}
```

Store `headlessOnInput: ((Data) -> Void)?` on the view. Add a `writeOutput(_ data: Data)`
that calls `data.withUnsafeBytes { ghostty_surface_write_output(surface, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }`.

- [ ] **Step 3: Write the harness**

Create `agterm/Ghostty/HeadlessHarness.swift`. Gate it behind an env var so it never
affects normal launches:

```swift
import Foundation

enum HeadlessHarness {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["AGTERM_HEADLESS_HARNESS"] == "1" }

    // Called by the app after a window + GhosttySurfaceView exist.
    static func run(on view: GhosttySurfaceView) {
        view.headlessOnInput = { data in
            let log = "/tmp/agterm-headless-harness.log"
            let line = "on_input \(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined())\n"
            if let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }() {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            }
        }
        // Feed red "hello" + newline after the surface is live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view.writeOutput(Data("\u{1b}[31mhello\u{1b}[0m\r\n".utf8))
        }
    }
}
```

- [ ] **Step 4: Wire the harness into a headless window when the env var is set**

Find where a normal surface/window is created at launch and add: if
`HeadlessHarness.isEnabled`, create the view via `makeHeadless`, add it to a window, and
call `HeadlessHarness.run(on: view)`. Keep it minimal and behind the env gate (one `if` in
the existing window-bring-up path). Confirm the insertion point with
`grep -n "makeKeyAndOrderFront\|GhosttySurfaceView(\|createSurface" agterm/Ghostty/*.swift agterm/*.swift`.

- [ ] **Step 5: Build, lint**

Run: `make build 2>&1 | tail -5 && make lint 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` and lint clean.

- [ ] **Step 6: Run the gate — isolated dev instance**

```bash
TMP=$(mktemp -d)
open -n --env AGTERM_HEADLESS_HARNESS=1 \
        --env AGTERM_STATE_DIR="$TMP" \
        --env AGTERM_CONTROL_SOCKET="$TMP/agterm.sock" \
        build/DerivedData/Build/Products/Debug/agterm.app
```
Expected: a window shows red `hello`. Then click the window, type `abc`, and:
Run: `cat /tmp/agterm-headless-harness.log`
Expected: a line like `on_input 3 bytes: 616263`.
Quit the dev instance by PID only (`kill <pid>`; never `pkill`). Leave the deployed app
untouched.

- [ ] **Step 7: Commit the harness**

```bash
git add agterm/Ghostty/HeadlessHarness.swift agterm/Ghostty/GhosttySurfaceView.swift
git commit -m "ghostty: headless surface harness proving write_output + on_input (Phase 1 gate)"
```

- [ ] **Step 8: Record the gate result**

If the gate is **green** (render + input both work): Phase 1 is done — the fork is viable.
Proceed to write the Phase 2 plan (`agtermCore` parser + mapping).
If **red**: stop and diagnose the engine seam before any further phase; the whole feature
depends on this. Capture the failure mode (no render? crash? input not delivered?) in the
spec's Risks section.

---

## Self-Review

**Spec coverage (Phase 1 only):** the spec's "Engine patch" component and "Phase-A
prototype (viability gate)" are covered by Tasks 1–6. Spec components 2–5 (parser/mapping,
gateway/surfaces, control API, agent-skill/GUI) are intentionally out of scope for this
plan and get their own plans after the gate — see the handoff. No Phase-1 requirement is
left unimplemented.

**Placeholder scan:** engine-internal steps deliberately say "confirm with grep / adjust
to the real accessors" because they patch an external Zig codebase at exact anchors; this
is verification-against-source, not a vague "add error handling" placeholder. Every such
step names the exact file, the grep to run, and the shape of the code. Build/verify/harness
steps have exact commands and expected output.

**Type consistency:** the C callback signatures
(`fn (?*anyopaque, [*]const u8, usize)` for input, `fn (?*anyopaque, u16, u16)` for resize)
and `ghostty_surface_write_output(*Surface, [*]const u8, usize)` are identical across
Tasks 2, 4, and 6. The `external_output` message ctor introduced in Task 3 is the one
consumed by the export in Task 4.
