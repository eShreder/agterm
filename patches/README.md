# Engine patches

`scripts/setup.sh` applies every `patches/*.patch` over the freshly-fetched
ghostty source checkout (at the pinned `GHOSTTY_REV`) **before** building
`GhosttyKit.xcframework`. This lets agterm carry small, additive libghostty
changes without forking the upstream repo. The patches are the only committed
engine-side artifact — the xcframework and staged resources are gitignored build
outputs.

## Current patches

- **`ghostty-headless.patch`** — adds a PTY-less "headless" `termio` backend
  (`termio.Backend.headless` + `Headless.zig`), an `external_output` IO-mailbox
  message routed to `Termio.processOutput`, and the C API for it
  (`Surface.Options` headless fields, a headless-backend construction branch,
  and `ghostty_surface_write_output`). Strictly additive: an unpatched build, or
  `headless = false`, behaves exactly as upstream. Backs the native tmux `-CC`
  work (see `docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`).

## Maintenance notes

- **After pulling a change to any `patches/*.patch` (or `setup.sh`), rebuild the
  engine.** The app target hard-references the patched symbols from
  always-compiled code, and `setup.sh`'s present-check is existence-based, not
  content-aware — so a stale pre-patch `GhosttyKit.xcframework` on disk produces
  confusing "no member 'headless'"-style compile errors rather than a
  rerun-setup hint. Force a clean rebuild:

  ```sh
  rm -rf GhosttyKit.xcframework agterm/Resources/ghostty agterm/Resources/terminfo
  scripts/setup.sh
  ```

- **`include/ghostty.h` is hand-maintained upstream, not generated.** Any patch
  that adds a C export or struct field must edit `include/ghostty.h` by hand, and
  its layout must track the corresponding Zig `extern struct` exactly. A drift
  between the C header and the Zig struct (e.g. a field added in a different
  order) compiles clean on both sides but makes Swift and Zig read fields at
  mismatched offsets — silent memory corruption, no error. This hand-written
  hunk is the most fragile part to re-apply on a `GHOSTTY_REV` bump; re-verify it
  field-by-field.

- **Re-applying on a `GHOSTTY_REV` bump:** the patches are additive and target
  the `termio.Backend` union, the IO mailbox, `apprt/embedded.zig`, `Surface.zig`,
  and `include/ghostty.h`. Conflicts are most likely if upstream reworks the
  backend union or the surface-options struct. Re-test the headless viability
  harness (`AGTERM_HEADLESS_HARNESS=1`) after any bump.
