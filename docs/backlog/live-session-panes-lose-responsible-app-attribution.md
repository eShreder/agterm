---
worth: maybe
where: docs/troubleshooting.md
added: 2026-09-08
---
# troubleshooting covers responsible-app loss only for App Data

A pane carried across a restart in Live sessions mode runs on a daemon whose agterm has exited, so every
process in it answers as its own responsible process. `docs/troubleshooting.md` documents this, but only
as an App Data problem with Full Disk Access as the remedy. FDA does not grant the microphone, so a
reader who meets the same process-attribution loss there finds a section describing their symptom and
prescribing a fix that cannot apply to it. Whether any other TCC service behaves like App Data or like
the microphone is untested.

Measured on a machine running agterm since Sep 7 15:00, with `responsibility_get_pid_responsible_for_pid`
via dlsym on libquarantine:

- fresh instance, plain login-shell pane created by the running app: agterm resolves to itself, the
  pane's zsh resolves to agterm, and a `claude` started in that pane is also attributed to agterm.
  Executable confirmed through `lsof` as the Developer ID signed
  `~/.local/share/claude/versions/2.1.266`. That instance came up with no zmx daemon, so this is the
  non-Live path, and the probed process was awaiting folder trust rather than at its interactive
  prompt. This refutes signing ALONE forcing self-responsibility: a Developer ID hardened-runtime
  binary was attributed to the terminal. It does not establish what happens after trust is granted,
  nor which process or context would eventually make a microphone request. Neither was tested. Note
  that parentage and executable path cannot rule out a later re-exec, since `execve` keeps both the
  pid and the parent pid.
- live instance: a zmx ATTACH CLIENT spawned by the running app resolves to agterm. That client's own
  parentage explains its result; the daemon it attaches to, and any process running inside that daemon,
  were not measured, and a new attachment can coexist with an old daemon whose children are
  self-responsible.
- live instance: six Claude processes, every one started before the running app, each resolve to
  themselves.

Alongside it, and separately: Claude Code ships unbundled at a version-specific path, so TCC stores it
with `client_type=1` and keys the grant on that path, and every upgrade mints a new client. agterm itself
is `client_type=0`, keyed on bundle id. That is upstream packaging rather than agterm's, and it is what
produces one microphone row per version. The connection between the two, that the attribution loss is why
those rows are charged to Claude at all, is inferred rather than measured.

Unresolved, and the reason this is `maybe` rather than `later`. Whether agterm can do anything about the
attribution is unknown, and no remedy comparable to FDA is known for the microphone. It was not tested
whether a microphone request from such a pane is charged to the process rather than to agterm; only
responsibility attribution was measured, and no TCC request was triggered.
