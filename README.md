# api-test

A Windows PowerShell API testing CLI built on `curl.exe`. One entry point runs configuration-driven requests, checks HTTP status, and produces redacted terminal output and optional Markdown reports.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- IT-approved `curl.exe` 8.4.0 or newer on PATH (`curl.exe --version`).
- Permission to run project scripts under your organization's execution policy.
- Optional `bat.exe` on PATH for syntax-highlighted response bodies.

No runtime package installation or administrator access is required. See [SECURITY.md](SECURITY.md) for office deployment, credentials, proxies, certificates and report handling. See [CHANGELOG.md](CHANGELOG.md) before migrating from the original CLI.

## Setup and first run

```powershell
# Run once, only if these local files do not already exist.
Copy-Item .env.example .env
Copy-Item config.toml.example config.toml
.\api.ps1 -Help

# Offline validation: real curl, synthetic data, loopback only.
.\tests\Run-Tests.ps1
```

Edit the ignored `config.toml` to select your approved API host, and set credentials in `.env` or your process environment. The example host `api.test.example.invalid` intentionally does not resolve. The included interfaces use `/get` and `/post` demonstration routes; adapt them to your API. Never send office credentials to a public echo service.

After configuring your test system:

```powershell
.\api.ps1 users-list -Env test
.\api.ps1 create-user -Env test -Payload valid.json -ExpectedStatus 200,201
.\api.ps1 get-user -Env test -Payload valid.xml -Set 'USER_ID=123'
```

The first argument is the interface name, optionally grouped one level deep with `/`. `-Env` defaults to `test`; `-Environment` is an alias. `-Payload` can also be the second positional argument. Paths to the default config, `.env`, interfaces and reports are relative to the project, so the CLI can be invoked from another working directory.

## Layout and extension

```text
api.ps1                         User-facing entry point
config.toml.example             Shareable, non-secret template
config.toml                     Ignored local configuration
.env.example / .env             Credential template / ignored local secrets
interface/<name>/request.toml   Request definition
interface/<name>/payloads/      JSON, XML, text or binary payload files
interface/<group>/<name>/       Optional one-level interface grouping
lib/Common.ps1                 Configuration, validation and payload helpers
lib/Invoke-Curl.ps1            Curl execution, status checks and reports
lib/Redaction.ps1              Shared output sanitization
tests/Run-Tests.ps1             Dependency-free offline test runner
tests/LoopbackServer.cs         Local test fixture; no production service
runs/YYYY-MM-DD/                Ignored, sanitized Markdown reports
.github/workflows/ci.yml        Windows PowerShell 5.1 / PowerShell 7 checks
```

Create an interface without needing configuration or credentials:

```powershell
.\api.ps1 create invoice-search
.\api.ps1 create meps/updateEstateClaim
```

Names must start with a letter or digit and contain only letters, digits, `_` or `-`, up to 80 characters per segment. One `/` may separate a group and interface name. Absolute paths, backslashes, empty segments, `.`, `..`, Windows device names, and deeper paths are rejected. Existing interfaces are never overwritten. Edit the generated TOML and add payload files; do not add a separate endpoint script.

For example:

```text
interface/
└── meps/
    ├── sendEstateClaim/
    │   ├── request.toml
    │   └── payloads/
    ├── updateEstateClaim/
    │   ├── request.toml
    │   └── payloads/
    └── getClaimStatus/
        ├── request.toml
        └── payloads/
```

Run a grouped interface with `.\api.ps1 meps/sendEstateClaim -Env test -Payload valid.xml`. Saved reports replace `/` with `-` in the report filename while retaining the grouped name in request metadata.

## Configuration and supported TOML

```toml
[defaults]
user_agent = "api-test/1.0"

[environments.test]
base_url = "https://api.test.example.invalid"

[environments.test.values]
tenant = "demo"
USER_ID = "123"
```

Request example:

```toml
service = "customer-api"
# Optional: overrides [environments.<name].base_url for this interface.
# base_url = "https://meps.stst.example.invalid"
method = "POST"
path = "/users/"
expected_status = [200, 201]
query = ["tenant={{tenant}}"]
headers = [
  "Accept: application/json, application/problem+json",
  "Content-Type: application/json",
  "User-Agent: {{user_agent}}",
  "Authorization: Bearer {{API_TOKEN}}", # comment outside a string
]
```

The parser intentionally supports a small TOML subset: bare keys, dotted table names, single-line single/double-quoted strings, signed decimal integers, booleans, and arrays of scalars. Arrays may span lines and have a trailing comma. Double-quoted strings support JSON-compatible escapes (`\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, `\uXXXX`); single-quoted strings are literal. Quoted commas and `#` are preserved. Duplicate keys/tables, bare string values, inline tables, array tables, floats, dates, multiline strings and unsupported syntax are rejected. TOML key lookup is case-insensitive in this project. Files are limited to 1 MiB.

Allowed root configuration tables are `defaults` and `environments`. Each selected environment accepts `base_url` and a `values` table. Defaults and environment values are scalar placeholder values, not curl options. Request keys are `service`, optional `base_url`, `method`, `path`, `headers`, `query` and `expected_status`. An interface `base_url`, when present, must be a string and overrides the selected environment's `base_url`; otherwise the environment value is used. Unknown request/environment keys fail. `headers` and `query` must be arrays of strings; `expected_status` must be an array of integers from 100 to 599. Methods are GET, POST, PUT, PATCH, DELETE, HEAD and OPTIONS.

Use an absolute HTTP(S) base URL without a query or fragment. The request path is appended to it, preserving a trailing slash. URL precedence is `-Url` > interface `base_url` > environment `base_url`. URL user information, fragments, whitespace and control characters are rejected. Completed URLs are limited to 16 KiB.

For example, both interfaces can use the same `stst` environment while targeting different hosts:

```toml
# interface/meps/sendEstateClaim/request.toml
base_url = "https://meps.stst.example.invalid"
method = "POST"
path = "/estate/claims"

# interface/kis/getClaimStatus/request.toml
base_url = "https://kis.stst.example.invalid"
method = "GET"
path = "/claims/status"
```

## Placeholder and credential resolution

`{{name}}` placeholders work in URLs, headers, query entries and text payloads. Precedence, lowest to highest:

1. `[defaults]`
2. `[environments.<name>.values]` (and the environment's `base_url` value)
3. Process environment variables
4. Root `.env`
5. `-Set name=value`

Missing or nested placeholders fail before a request is sent. Values are case-insensitive. Empty defined values are allowed. `.env` supports blank lines, full-line `#` comments, optional `export`, and `NAME=value` with optional enclosing quotes. Values are literal; there is no shell expansion, escape processing or inline-comment removal. Duplicate/malformed entries fail. `.env` never changes the process environment; `-NoDotEnv` skips it entirely.

Use `.env` or a CI secret store for credentials. Inline credential overrides can be recorded by shell history before the CLI can redact them.

## Overrides and payloads

```powershell
.\api.ps1 create-user -Env test -Payload valid.json `
  -Header 'X-Correlation-Id: office-check','Accept: application/json' `
  -Query 'search=alpha & beta','active=true' `
  -Set 'tenant=staging' `
  -ExpectedStatus 201 -TimeoutSeconds 30 -Save -DebugMode

# Explicit external file, sent unchanged (also supports binary files).
.\api.ps1 create-user -Body 'C:\approved-fixtures\request.json' -RawPayload
```

Pass array parameters (`-Header`, `-Query`, `-Set`, `-ExpectedStatus`) once with comma-separated PowerShell values. For multiple values from another shell, invoke a PowerShell script or `-Command`; Windows PowerShell `-File` does not reliably bind native-shell array arguments.

Headers supplied on the CLI replace configured headers by case-insensitive name; the last value wins. An empty header value sends an empty header. Newlines/control characters are rejected, and curl owns `Content-Length` and `Transfer-Encoding`. Headers are limited to 100 entries and 64 KiB of name/value text. Query entries append to the existing query; names and values are URL-encoded separately. Supply unencoded `name=value` pairs; pre-encoded text would be encoded again. Existing query text inside `-Url` is left intact.

`-Payload` resolves beneath that interface's `payloads` directory, with a fallback search by filename or basename when unique. Traversal outside that directory is rejected. `-Body` takes precedence over `-Payload`; an existing file is used, otherwise the argument is literal text (including an explicitly empty string). If you intended a file, verify it exists: a misspelled `-Body` path is treated as text by design. Relative `-Body` and `-Config` paths use the current working directory.

Text templates are decoded with strict text handling and expanded once. Changed templates and inline text are written as UTF-8 without adding a BOM or newline; unchanged files retain their original bytes. Placeholder insertion is literal; supply JSON/XML-safe values or prepare the final payload file yourself. Templates and their expanded result are limited to 10 MiB. `-RawPayload` bypasses decoding/expansion and preserves original bytes; all payloads are limited to 100 MiB. Curl may buffer `--data-binary` uploads internally, so this is not an unbounded streaming upload tool. HEAD requests cannot include a payload. Multipart construction is not implemented.

## Execution limits and exit codes

| Setting | Default | Allowed range |
| --- | --- | --- |
| `-ConnectTimeoutSeconds` | 10 seconds | 1-300 |
| `-TimeoutSeconds` | 60 seconds | 1-3600 |
| `-MaxResponseBytes` | 10 MiB | 1 byte-100 MiB |
| Expected HTTP status | 200-299 | Explicit list: 100-599 |
| Terminal/report preview per body or headers | 256 KiB | Fixed; larger content is omitted |

The total timeout includes connection time. A watchdog terminates curl if it exceeds the total timeout by five seconds. No automatic redirects or retries occur, including for POST and DELETE. Curl's personal configuration is disabled for deterministic behavior. Proxy/certificate settings from the process environment still apply. TLS certificate verification is enabled.

| Exit code | Meaning |
| --- | --- |
| `0` | Transport succeeded and HTTP status matched |
| `2` | Configuration, validation, local execution/report failure, or curl initialization error |
| `22` | Unexpected HTTP status |
| `28` | Timeout |
| `63` | Response exceeded the configured size limit |
| Other nonzero | Curl transport error, preserved unchanged |

Use `expected_status = [404]` or `-ExpectedStatus 404` for a deliberate negative test. A CLI status list replaces the request list. HTTP status matching is the only built-in response assertion; business-schema/content assertions and multi-request scheduling are outside the current scope.

## Output and reports

Normal output includes redacted response headers/body, HTTP status, elapsed time, downloaded bytes and the final exit code. JSON is pretty-printed with indentation. When `bat.exe` is on PATH, response bodies receive syntax highlighting without a pager; otherwise, or if highlighting fails, readable plain text is displayed. Redaction happens before formatting, and saved reports stay free of terminal color codes. `-DebugMode` includes sanitized curl diagnostics; `-Debug` is PowerShell's common parameter.

`-Save` writes a uniquely named Markdown report under `runs/YYYY-MM-DD/` with HTTP status, duration and downloaded bytes, metadata and header tables, and language-tagged code blocks for request/response bodies. Reports record the exchange without a pass/fail verdict. JSON is indented; curl diagnostics appear when present. Open the file in your editor's Markdown preview for the formatted view. Request bodies are reread only when saving. JSON/XML previews may be normalized for structural redaction; these are not byte-exact archives. Oversized, binary or malformed structured content is omitted. Raw temporary response data is removed on normal completion or handled failure. Existing reports are not rewritten; run again with `-Save` to generate the new layout.

Review saved reports before sharing: application-specific confidential data can remain despite redaction. There is no automatic report deletion; follow your company's retention policy. See [SECURITY.md](SECURITY.md).

## CI and maintenance

```powershell
# Credentials supplied by your CI secret environment.
& .\api.ps1 users-list -Env test -NoDotEnv
exit $LASTEXITCODE
```

Run checks locally after changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\api.ps1 -Help
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
git diff --check
```

The process-scoped `Bypass` examples are for development where policy permits; they do not override centrally enforced policy. Tests copy only the CLI/library into a private temporary workspace, create synthetic configuration/secrets, bind a loopback server on an assigned port, and clean up afterward. They never read your local `.env` or contact external APIs. The GitHub Actions workflow runs the same tests in both Windows shells with read-only repository permissions.

Failures include safe validation messages without echoing values. For a generic local-execution failure, check curl version/PATH, file existence, directory permissions and UTF-8 encoding. For TLS/proxy failures, work with IT rather than disabling verification. Offline tests do not validate your organization's DNS, proxy, TLS trust, credentials or application behavior; check an approved read-only endpoint before office rollout.
