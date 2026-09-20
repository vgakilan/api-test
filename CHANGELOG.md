# Changelog

## Unreleased - reliability and office-use hardening

- Replaced permissive TOML splitting with a strict, documented subset parser; quoted commas/hashes and multiline arrays work, while duplicates and unsupported syntax fail.
- Added offline regression tests using real curl against an isolated loopback fixture, and a Windows PowerShell 5.1/PowerShell 7 CI matrix.
- Added safe curl stdin configuration, private temporary storage, terminal/report redaction, structured JSON/XML handling, and preserved UTF-8 request bytes without injected BOMs/newlines.
- Added connection/total timeouts, response limits, correct HEAD handling, expected HTTP status assertions, query encoding, and header replacement overrides.
- Added strict environment, placeholder, interface-name, header and payload-path validation; `.env` no longer modifies the process environment.
- Bounded previews and templating work, removed unconditional request-body rereading, and made report names unique across concurrent runs.

### Migration notes

- HTTP responses outside 200-299 now return exit 22 unless explicitly included in `expected_status` or `-ExpectedStatus`. Curl transport exit codes remain unchanged.
- Curl 8.4.0+ is required for response-size enforcement, including chunked responses. Defaults are a 10-second connection timeout, 60-second total timeout and 10 MiB response limit.
- Precedence is now defaults, environment values, process environment, `.env`, then `-Set` (last wins). Explicit project `.env` values override incidental ambient process variables.
- Unknown environments, unresolved placeholders and unsupported TOML now fail early. Use quoted strings, scalar arrays and documented tables; the project does not implement all TOML features.
- Query entries are unencoded `name=value` pairs and are URL-encoded by the CLI. Remove pre-encoding from those entries; existing query text supplied directly in `-Url` is preserved.
- `-Header` replaces a configured header with the same name. Pass array options once, using PowerShell comma-separated arrays; repeating a named PowerShell parameter is not supported.
- `-Payload` stays inside its interface's payload directory. Use `-Body` for an external file and `-RawPayload` for binary or literal content. Templated payloads are limited to 10 MiB; all payloads to 100 MiB.
- Terminal output is redacted and JSON is pretty-printed. Optional `bat` highlighting is preserved, with readable plain text when unavailable. Saved reports are sanitized previews without terminal colors, not byte-for-byte response archives.
- Use `-DebugMode`; `-Debug` remains PowerShell's common parameter. Debug reports now include actual sanitized curl diagnostics.
- The example test URL is now an intentionally invalid hostname. Existing local `config.toml` and `.env` files are not changed.
