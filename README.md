# Terminal API Client

A curl-based API client managed from PowerShell. It supports reusable environments, request definitions, JSON/XML payloads, response metadata, and readable terminal output without requiring Bruno or Postman.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `curl.exe` 8+
- `bat` is optional and is used for syntax-highlighted response bodies

Verify curl:

```powershell
curl.exe --version
```

Verify bat, if installed:

```powershell
bat.exe --version
```

## Usage

The general command format is:

```powershell
.\api.ps1 <environment> <request> [body-name-or-path]
```

Examples:

```powershell
.\api.ps1 test users-list
.\api.ps1 test user-create
.\api.ps1 test user-create user-create-1
.\api.ps1 test get-user get-user-1
```

Save a complete Markdown debug report by adding `-Save`:

```powershell
.\api.ps1 test user-create user-create-1 -Save
```

Reports are created automatically under:

```text
runs\YYYY-MM-DD\HH-mm-ss_environment_request.md
```

Each report contains run metadata, request method and URL, redacted request headers, request body, response headers, response body, HTTP status, timing, downloaded bytes, and curl errors. The terminal output is still displayed normally.

## Debugging

Use the native PowerShell `-Debug` switch to enable curl verbose diagnostics:

```powershell
.\api.ps1 test user-create user-create-1 -Debug
```

Combine it with `-Save` to include the diagnostics in the Markdown report:

```powershell
.\api.ps1 test user-create user-create-1 -Debug -Save
```

Debug output includes connection, DNS, TLS, request, and response details. It may contain sensitive information, so use it carefully. Saved reports redact common sensitive headers such as `Authorization`, cookies, tokens, secrets, and API keys.

The third argument is optional. When supplied, the client searches the `bodies` directory recursively by filename. Extensions are optional, so `user-create-1` can resolve to `user-create-1.json` and `get-user-1` can resolve to `get-user-1.xml`.

If multiple files have the same name but different extensions, provide an explicit path or extension.

## Directory structure

```text
api-test/
├── api.ps1                 # Main command-line entry point
├── environments/           # Environment-specific variables
│   └── test.ps1
├── requests/               # Reusable endpoint definitions
│   ├── get-user.ps1
│   ├── user-create.ps1
│   └── users-list.ps1
├── bodies/                 # JSON, XML, or other request payloads
│   ├── create-user/
│   └── get-user/
└── lib/                    # Shared PowerShell infrastructure
    └── Invoke-Curl.ps1
```

## Environments

Environment files define values shared by requests, such as the base URL and authentication token:

```powershell
$env:API_BASE_URL = "https://api-test.example.com"
$env:API_TOKEN = "replace-me"
```

Do not commit real credentials. Prefer a local, ignored secrets file or secure environment variables for tokens and client secrets.

To add another environment:

1. Create `environments\staging.ps1` or `environments\prod.ps1`.
2. Define the required environment variables.
3. Run the same request with the new environment name.

Example:

```powershell
.\api.ps1 staging user-create user-create-1
```

## Request definitions

Each request definition is a PowerShell script that builds curl arguments. It should describe the HTTP method, URL, headers, authentication, and body handling.

Example JSON request:

```powershell
$arguments = @(
    "--request", "POST",
    "--url", "$env:API_BASE_URL/users",
    "--header", "Accept: application/json",
    "--header", "Content-Type: application/json",
    "--header", "Authorization: Bearer $env:API_TOKEN",
    "--data-binary", "@$BodyFile"
)
```

Example SOAP request:

```powershell
$arguments = @(
    "--request", "POST",
    "--url", "$env:API_BASE_URL/users",
    "--header", "Content-Type: text/xml; charset=utf-8",
    "--header", "Accept: text/xml",
    "--header", "SOAPAction: GetUser",
    "--data-binary", "@$BodyFile"
)
```

Request scripts should call the shared helper:

```powershell
& (Join-Path $PSScriptRoot "..\lib\Invoke-Curl.ps1") -CurlArguments $arguments
exit $LASTEXITCODE
```

## Request bodies

Keep large payloads in separate files:

- `.json` for JSON APIs
- `.xml` for SOAP or XML APIs
- Other extensions when required by the service

Payload files are selected by name:

```powershell
.\api.ps1 test user-create user-create-1
.\api.ps1 test get-user get-user-1
```

The request definition controls the content type; the body file contains only the payload.

## Response output

The shared helper displays:

- HTTP response headers
- JSON bodies with PowerShell formatting and optional `bat` highlighting
- Plain text or XML bodies without JSON conversion
- HTTP status code
- Total request time
- Downloaded byte count
- Curl errors

The helper uses temporary files for response separation and removes them after each request.

## Security guidelines

- Never commit access tokens, passwords, private keys, or client secrets.
- Do not place secrets directly in request scripts or body files.
- Use environment variables or a local ignored secrets file.
- Use HTTPS for non-local services.
- Review headers and payloads before running requests against production.
- Keep production environment files separate from test credentials.

## Troubleshooting

### Request file not found

The request name must match a file under `requests`:

```text
requests\user-create.ps1
```

Run it with:

```powershell
.\api.ps1 test user-create
```

### Body file not found

Check that the body exists below `bodies` and that its filename is unique:

```text
bodies\create-user\user-create-1.json
```

### HTTP status 000

Curl did not receive an HTTP response. Check the URL, DNS, VPN, proxy, TLS configuration, and network connectivity.

### PowerShell blocks script execution

Use an appropriate execution policy for your environment. For a user-scoped development setup:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Follow your organization’s security policy for managed machines.
