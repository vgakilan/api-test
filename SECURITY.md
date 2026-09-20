# Security and office deployment

## Credentials and request destinations

Use this tool only with approved API destinations and test accounts. It sends the configured request as written, including POST, PATCH and DELETE operations. Review the selected environment and interface before running it. The example configuration uses an intentionally non-resolving test hostname; existing local configurations are never rewritten.

Keep credentials in the ignored root `.env` or your organization's process/CI secret environment. Do not type real secrets into `-Header`, `-Set`, `-Url` or `-Body`: your shell history, PowerShell transcription, or the parent process command line can record them before this tool runs. Do not commit secrets in TOML or payload fixtures. `.gitignore` does not remove files already tracked by Git.

The CLI passes curl's sensitive options through redirected standard input, with only `--disable --config -` in the curl command line. It does not execute a constructed shell command. Curl's default configuration file is disabled, protocols are restricted to HTTP(S), TLS verification remains enabled, URL credentials are rejected, and redirects/retries are disabled. Corporate proxy settings may still come from the process environment. Request definitions and the installed `curl.exe` on PATH are trusted inputs; do not run untrusted repositories or executables.

## Logs and reports

Terminal output, errors from curl, and Markdown reports use the same redaction functions. They mask common credential fields in headers, JSON, XML and query strings, including XML namespaces/attributes and structured JSON credential values. Known `.env`, `-Set`, sensitive process-environment and expanded placeholder values are masked along with URL/JSON/XML encodings. This intentionally may hide non-secret placeholder values too.

Malformed JSON/XML, binary content, and bodies or headers over 256 KiB are omitted from previews. XML DTDs and external entities are prohibited. Terminal control sequences are stripped. Reports escape table values and use dynamically sized code fences so response HTML/Markdown cannot break out into active report markup.

Redaction is a safeguard, not a classification engine. Unknown application-specific secrets, personal data, encoded/transformed values, or tokens returned under innocuous field names may remain. Review reports before sharing; apply company access, retention and deletion policies to `runs/` and CI logs. Reports inherit the destination directory's permissions. Nothing is automatically uploaded. No unredacted response export is provided.

## Temporary data and cleanup

Raw response headers/body and materialized payloads exist briefly in a unique directory under the current user's Windows temporary directory. Its ACL disables inheritance and grants the current Windows identity access. Ordinary completion and handled failures delete that exact directory; cleanup checks its parent and generated name before recursive removal. The CLI does not change the user's `.env`, process environment or global PowerShell execution policy.

An administrator, software running as your identity, endpoint monitoring, backups, or memory inspection can still access sensitive data. A forced process termination or machine crash can leave `api-test-<32 hex digits>` directories behind. Follow company procedures to remove such remnants. Deletion is not guaranteed secure erasure.

## Managed Windows machines

Use an IT-approved PowerShell and curl installation. The runtime requires Windows PowerShell 5.1 or PowerShell 7 on Windows, and curl 8.4.0 or newer. No administrator rights, package installation, PowerShell module downloads or background service are required for normal use. The offline development tests compile a small C# loopback fixture with `Add-Type`; constrained language/AppLocker policy may prevent that. Do not bypass organizational execution policies to run either the CLI or tests.

Prefer a company-managed Schannel build of curl where Windows certificate trust is required. Configure trusted corporate roots/proxies through IT; the CLI has no insecure TLS switch. `.env` values are used for placeholder resolution, not exported as proxy or certificate environment settings. Verify corporate HTTPS/proxy access against an approved non-mutating endpoint before using state-changing interfaces.

## Reporting a security issue

Report suspected exposure through your organization's approved private security channel. Include a minimal reproduction using synthetic values, relevant versions, and sanitized output. Do not attach real `.env` files, authentication headers, or raw reports to public issues. Rotate any exposed credential through the owning service.
