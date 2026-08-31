# Notchy

A macOS side-notch widget pinned to the right screen edge showing AI coding
usage limits (Claude, Codex, GLM). See [PLAN.md](PLAN.md) for the full spec.

## Build & run

```sh
./make-app.sh && open build/Notchy.app
```

UI development against mock data: `NOTCHY_MOCK=1 open build/Notchy.app`

Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Credentials are read from where the CLIs already keep them (Keychain for
Claude, `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`) and never
leave the machine.

## Code signing (one-time)

The Claude provider reads the CLI's OAuth token from the Keychain item
`Claude Code-credentials`. macOS ties the "Always Allow" grant to the app's
code signature, so an ad-hoc signed binary — the SwiftPM default — is a new
app on every rebuild and re-prompts for the login password forever.

`make-app.sh` signs with a self-signed identity named `Notchy Self-Signed`
(override with `NOTCHY_SIGN_IDENTITY`). To create it:

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout key.pem -out cert.pem -config cert.cnf   # CN=Notchy Self-Signed,
                                                         # extendedKeyUsage=codeSigning
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
        -out cert.p12 -passout pass:PASS -name "Notchy Self-Signed"
    security import cert.p12 -k ~/Library/Keychains/login.keychain-db \
        -P PASS -T /usr/bin/codesign
    security add-trusted-cert -r trustRoot -p codeSign \
        -k ~/Library/Keychains/login.keychain-db cert.pem
    rm -f key.pem cert.p12          # the private key now lives in the Keychain

Then launch the app once and click **Always Allow**. The grant now pins the
certificate rather than the build, so it survives rebuilds.

Trade-off: the ACL widens from "this exact build" to "anything signed with
this certificate and the identifier `dev.coacci.Notchy`". Revoke by deleting
the `Notchy Self-Signed` identity from Keychain Access.

## License

MIT — see [LICENSE](LICENSE). A personal side project, provided as is; use it
however you like.

Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI or Z.ai.
The logos in `Sources/Notchy/Resources/` are those companies' trademarks,
included only to label each provider's slot; they are not covered by the MIT
license above and remain the property of their owners. The SVG files come from
[lobe-icons](https://github.com/lobehub/lobe-icons) (MIT).
