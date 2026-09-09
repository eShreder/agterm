---
worth: maybe
where: docs/troubleshooting.md
added: 2026-09-08
---
# troubleshooting covers responsible-app loss only for App Data, not other TCC services

A pane carried across a restart in Live sessions mode runs on a daemon whose agterm has exited, so every
process in it answers as its own responsible process. `docs/troubleshooting.md` documents this, but only
as an App Data problem with Full Disk Access as the remedy. The same attribution loss reaches every
TCC-gated resource, and FDA does not grant those, so a reader hitting it on the microphone finds a
section that describes their symptom and prescribes a fix that cannot work for it.

Measured on a machine running agterm since Sep 7 15:00, with `responsibility_get_pid_responsible_for_pid`
via dlsym on libquarantine:

- fresh instance, pane created by the running app: agterm resolves to itself, the pane's zsh resolves to
  agterm, and a `claude` started in that pane also resolves to agterm. Executable confirmed through
  `lsof` as the Developer ID signed `~/.local/share/claude/versions/2.1.266`, so an independently signed
  hardened-runtime binary does inherit.
- live instance: `zmx` under a daemon the running app created resolves to agterm; six Claude processes,
  every one started before the app, each resolve to themselves.

What makes it visible for the microphone rather than only annoying: Claude Code ships unbundled at a
version-specific path, so TCC stores it with `client_type=1` and keys the grant on that path, and every
upgrade mints a new client. agterm itself is `client_type=0`, keyed on bundle id. The path half is
upstream packaging, not agterm's.

Unresolved, and the reason this is `maybe` rather than `later`. Whether agterm can do anything about the
attribution at all is unknown, and no remedy comparable to FDA is known for the microphone. It was not
tested whether a microphone request from such a pane is in fact charged to the process rather than to
agterm; only the responsibility attribution was measured, and no TCC request was triggered. Different
TCC services do not necessarily share one policy, so nothing here should be generalised from the App Data
case without testing the service in question.
