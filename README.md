# api-test

A PowerShell-first API testing CLI built on `curl.exe`. Requests are readable TOML, payloads stay in files, and `.env` is reserved for secrets and credentials.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `curl.exe`
- `bat` is optional for syntax-highlighted output

## Quick start

```powershell
Copy-Item .env.example .env
Copy-Item config.toml.example config.toml
.\api.ps1 create-user -Env test -Payload valid.json
.\api.ps1 users-list -Env test
```

The root entry point is `api.ps1`. The first argument is the interface name. `-Env` selects an environment, and `-Payload` selects a file below that interface's `payloads` directory.

## Layout

```text
api-test/
├── api.ps1                    # Single CLI entry point
├── config.toml.example        # Shareable configuration template
├── config.toml                # Local configuration; never committed
├── .env                       # Local secrets; never committed
├── interface/
│   └── create-user/
│       ├── request.toml       # Method, path, headers, query
│       └── payloads/           # JSON, XML, text, multipart, etc.
└── lib/Invoke-Curl.ps1        # curl execution and reporting
```

Create a new interface at any time:

```powershell
.\api.ps1 create invoice-search
```

This creates `interface/invoice-search/request.toml` and its `payloads` directory.

## Configuration

`config.toml.example` documents the supported non-secret settings. Copy it to the ignored local `config.toml` and customize it for each system:

```powershell
Copy-Item config.toml.example config.toml
```

Your local `config.toml` contains settings such as:

```toml
[defaults]
user_agent = "api-test/1.0"

[environments.test]
base_url = "https://httpbin.org"

[environments.test.values]
tenant = "demo"
```

An interface request is intentionally small:

```toml
method = "POST"
path = "/post"
query = ["tenant={{tenant}}"]
headers = [
  "Accept: application/json",
  "Content-Type: application/json",
  "Authorization: Bearer {{API_TOKEN}}"
]
```

Use `{{name}}` placeholders in URLs, query strings, headers, and payload files. Values are resolved from the selected environment, `[environment.values]`, defaults, process environment variables, and finally `-Set name=value` overrides. `.env` is loaded automatically and should contain only secrets/credentials.

## CLI overrides

```powershell
.\api.ps1 create-user -Env test -Payload valid.json `
  -Header 'X-Correlation-Id: quick-check' `
  -Query 'debug=true' `
  -Set 'tenant=staging' `
  -Save
```

Useful options include `-Url`, `-Method`, repeated `-Header`, repeated `-Query`, repeated `-Set`, `-Body` (a file path or inline text), `-Save`, and `-DebugMode`.

The shared runner displays response headers, response body, status, duration, and downloaded bytes. `-Save` writes a redacted Markdown report below `runs/`, which is gitignored.

### Sharing a request/response report

Use `-Save` whenever you want to send a reproducible exchange to a developer:

```powershell
.\api.ps1 create-user -Env test -Payload valid.json -Save
```

The command prints the generated Markdown path. Reports are saved under `runs\YYYY-MM-DD\` with a timestamped filename and include:

- service and interface name
- environment, timestamps, curl exit code, HTTP status, duration, and downloaded bytes
- request method, URL, headers, and payload path/body
- response headers and response body
- curl errors or debug diagnostics when requested with `-DebugMode`

Common credentials and secrets in headers, URLs, JSON, and XML fields are redacted before writing the report. Review the report before sharing it, because application-specific secrets may require manual redaction.

## CI/CD

Set credentials as CI environment variables or create a CI-only `.env` outside version control, then run the same command used locally:

```powershell
.\api.ps1 create-user -Env test -Payload valid.json
```

The process exits with curl's exit code, so transport failures are suitable for pipeline failure handling. HTTP status handling remains visible in the report and terminal output.
