# Remove Agent Center integration

Close running agents, then run this command in a terminal on the host:

```sh
~/.config/tessera/agent-uninstall.sh
```

This command ships with integrations installed or updated by the app. It works
for installations made from iOS and Android, over SSH or Mosh with or without
tmux. Update an older integration first if it does not contain the remover.

The remover validates configuration files before editing them, removes Tessera's
exact hook handlers and shell startup lines, and preserves unrelated user
settings, hooks, transcripts, and files. It supports the same `CODEX_HOME`,
`CLAUDE_CONFIG_DIR`, `KIMI_CODE_HOME`, and `ZDOTDIR` overrides as installation;
run it with those environment variables set as they were during installation.

Restart existing shells and agents afterward: running processes retain their
loaded configuration and command caches. Locked helper versions remain while
their processes are active; these inactive-on-disk artifacts do not reinstall
hooks. Deleting the mobile app does not remove remote integration.

If a configuration is malformed or changes during removal, the command stops
and leaves helper files available for remaining hooks. Correct the configuration
and rerun the command. Repeating successful removal is safe.
