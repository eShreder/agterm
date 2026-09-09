---
worth: maybe
where: agtermCore/Sources/agtermCore/ControlProtocol.swift:Command
added: 2026-09-08
---
# custom commands are listed over control but cannot be run over it

`keymap.list` projects every custom command as `{name, shortcut}` (`ControlKeymap.projected`), and no verb
in `Command` invokes one. A script can enumerate the user's commands and not fire any of them. The only
paths that reach `CustomCommandRunner` are the keybind monitor and a `custom_command_palette` row, so the
control API is the one surface that cannot reach a user's own commands.

The reason to consider it is #270's line: anything past the built-in minimum gets built over the control
API. A caller that can list a command and not run it sits on the wrong side of that.

Undecided, and the design call comes first: `CustomCommand.id` is regenerated on every parse and names are
display text with no uniqueness check, so a `command.run "<name>"` needs identity semantics that do not
exist today. Index-into-`keymap.list` avoids that and is worse, since the index moves whenever the file is
edited.

Surfaced investigating discussion #570, which asked for a toolbar button bound to a custom command. That
half of #570 is not what this item is about; this one stands whether or not a button ever exists.
