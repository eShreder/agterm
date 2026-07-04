# Driving agterm from a dev container

## Build agtermctl for Linux (inside the container image)

```dockerfile
FROM swift:6.0 AS agtermctl
COPY agtermCore /src
RUN cd /src && swift build -c release --product agtermctl

# then, in the dev image:
COPY --from=agtermctl /src/.build/release/agtermctl /usr/local/bin/agtermctl
```

## Forward the control socket to the remote host

```
# ~/.ssh/config on the mac — the local path MUST be quoted (the space in "Application Support"
# otherwise splits the argument and ssh rejects the config with "Bad forwarding specification")
Host <host>
  RemoteForward /home/<user>/.agterm/agterm.sock "/Users/<you>/Library/Application Support/agterm/agterm.sock"
```

Server prep (once): `mkdir -m 700 ~/.agterm`, and `StreamLocalBindUnlink yes` in `sshd_config`
so a reconnect can rebind the forwarded socket path.
Security: the forwarded socket grants FULL control of your mac terminal — keep the directory `0700`;
this design trusts your own uid on your own server, nothing more.

## Enter the container so both resize and the socket work

```bash
docker exec -it \
  -e TMUX_PANE \
  -e AGTERM_CONTROL_SOCKET=/agterm/agterm.sock \
  <container> <shell>
# container started with: -v ~/.agterm:/agterm   (mount the DIRECTORY, not the socket file —
# a re-bound socket after ssh reconnect stays visible through the dir mount)
```

`docker exec -it` forwards terminal resize; a long-lived exec created by an older client keeps its
stale pty size (nvim symptom) — re-enter to pick up the current size.

## Address your own session from a hook

```bash
agtermctl session status active --target "tmux:$TMUX_PANE"
agtermctl notify "build done" --target "tmux:$TMUX_PANE"
```

Only each tmux window's LEADING pane is mirrored (splits are not), so `$TMUX_PANE` resolves only there.
