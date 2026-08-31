# Notchy

A macOS side-notch widget pinned to the right screen edge showing AI coding
usage limits (Claude, Codex, GLM).

## Build & run

```sh
./make-app.sh && open build/Notchy.app
```

UI development against mock data: `NOTCHY_MOCK=1 open build/Notchy.app`

Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Credentials are read from where the CLIs already keep them (Keychain for
Claude, `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`) and never
leave the machine.
