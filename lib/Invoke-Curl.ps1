param(
    [Parameter(Mandatory = $true)]
    [string[]]$CurlArguments,

    [switch]$SaveReport,

    [switch]$DebugMode,

    [string]$RequestName = "request",

    [string]$ServiceName = "service",

    [string]$BodyFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$startedAt = Get-Date

$headersFile = [System.IO.Path]::GetTempFileName()
$responseBodyFile = [System.IO.Path]::GetTempFileName()
$diagnosticFile = [System.IO.Path]::GetTempFileName()

function Redact-Text([string]$Text) {
    if ($null -eq $Text) { return "" }
    $result = $Text
    $result = $result -replace '(?im)^((?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|.*(?:token|secret|password|api[-_]?key))\s*:\s*).*$','$1[REDACTED]'
    $result = $result -replace '(?i)("(?:password|passcode|token|access_token|refresh_token|client_secret|secret|api[_-]?key)"\s*:\s*")[^"]*(")','$1[REDACTED]$2'
    $result = $result -replace '(?i)(<(?:password|passcode|token|access_token|refresh_token|client_secret|secret|api[_-]?key)>)[^<]*(</(?:password|passcode|token|access_token|client_secret|secret|api[_-]?key)>)','$1[REDACTED]$2'
    return $result
}

function Redact-Url([string]$Url) {
    if ($null -eq $Url) { return "" }
    return $Url -replace '(?i)([?&](?:token|access_token|refresh_token|secret|password|api[_-]?key)=)[^&]*','$1[REDACTED]'
}

function Format-HeadersMarkdown([string[]]$HeaderLines) {
    $rows = @(
        '| Header | Value |'
        '| --- | --- |'
    )
    foreach ($line in @($HeaderLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()
        if ($trimmed -match '^HTTP/\S+\s+\d+') {
            $name = 'Status'
            $value = $trimmed
        } elseif ($trimmed -match '^([^:]+):\s*(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
        } else {
            $name = 'Info'
            $value = $trimmed
        }
        $name = $name -replace '\|', '\|'
        $value = $value -replace '\|', '\|'
        $rows += "| $name | $value |"
    }
    if ($rows.Count -eq 2) { $rows += '| (none) | |' }
    return ($rows -join "`n")
}

try {
    $curlOptions = @(
        "--silent",
        "--show-error",
        "--dump-header", $headersFile,
        "--output", $responseBodyFile,
        "--write-out", "%{http_code}|%{time_total}|%{size_download}"
    )
    if ($DebugMode) { $curlOptions += "--verbose" }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $metrics = & curl.exe @curlOptions @CurlArguments 2> $diagnosticFile
    $ErrorActionPreference = $previousErrorActionPreference
    $curlExitCode = $LASTEXITCODE
    $finishedAt = Get-Date

    $requestMethod = "GET"
    $requestUrl = ""
    $requestHeaders = @()
    $requestBody = ""
    for ($index = 0; $index -lt $CurlArguments.Count; $index++) {
        switch ($CurlArguments[$index]) {
            "--request" { $requestMethod = $CurlArguments[++$index] }
            "--url" { $requestUrl = $CurlArguments[++$index] }
            "--header" { $requestHeaders += $CurlArguments[++$index] }
            "--data-binary" {
                $dataArgument = $CurlArguments[++$index]
                if ($dataArgument.StartsWith("@")) { $BodyFile = $dataArgument.Substring(1) }
                else { $requestBody = $dataArgument }
            }
            "--data-raw" { $requestBody = $CurlArguments[++$index] }
        }
    }
    if ($BodyFile -and (Test-Path -LiteralPath $BodyFile -PathType Leaf)) {
        $requestBody = Get-Content -Raw $BodyFile
    }

    $responseHeaders = Get-Content -Raw $headersFile
    $responseBody = Get-Content -Raw $responseBodyFile
    $curlError = Get-Content -Raw $diagnosticFile
    if ($null -eq $responseHeaders) { $responseHeaders = "" }
    if ($null -eq $responseBody) { $responseBody = "" }
    if ($null -eq $curlError) { $curlError = "" }

    $metricText = ([string]$metrics).Trim()
    $metricValues = if ($metricText -match "\|") { $metricText -split "\|" } else { @("unavailable", "unavailable", "unavailable") }

    $displayBody = $responseBody.TrimEnd()
    if ($responseBody.Trim()) {
        try { $displayBody = $responseBody | ConvertFrom-Json | ConvertTo-Json -Depth 100 } catch { }
    }

    Write-Output "=== Response headers ==="
    if ($responseHeaders.Trim()) { $responseHeaders.TrimEnd() }
    Write-Output ""
    Write-Output "=== Response body ==="
    if ($displayBody) {
        if (Get-Command bat.exe -ErrorAction SilentlyContinue) {
            $displayLanguage = if ($responseBody.TrimStart().StartsWith("<")) { "xml" } else { "json" }
            $displayBody | bat.exe --language $displayLanguage --style plain --paging never --color always --file-name "response.$displayLanguage"
        } else { $displayBody }
    }
    Write-Output ""
    Write-Output "=== Request details ==="
    Write-Output ("HTTP status:    {0}" -f $metricValues[0])
    Write-Output ("Time:           {0} seconds" -f $metricValues[1])
    Write-Output ("Downloaded:     {0} bytes" -f $metricValues[2])
    if ($DebugMode -and $curlError.Trim()) {
        Write-Output ""
        Write-Output "=== curl debug ==="
        $curlError.TrimEnd()
    } elseif ($curlError.Trim()) {
        Write-Output ""
        Write-Output "=== curl error ==="
        $curlError.TrimEnd()
    }

    if ($SaveReport) {
        $root = Split-Path -Parent $PSScriptRoot
        $reportDirectory = Join-Path $root ("runs\" + $startedAt.ToString("yyyy-MM-dd"))
        $reportName = "{0}_{1}_{2}_{3}.md" -f $startedAt.ToString("HH-mm-ss-fff"), $env:API_ENVIRONMENT, $ServiceName, $RequestName
        $reportPath = Join-Path $reportDirectory ($reportName -replace '[^a-zA-Z0-9_.-]', '_')
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

        $safeRequestHeaders = $requestHeaders | ForEach-Object { Redact-Text $_ }
        $safeResponseHeaders = Redact-Text $responseHeaders
        $safeRequestUrl = Redact-Url $requestUrl
        $requestHeadersMarkdown = Format-HeadersMarkdown $safeRequestHeaders
        $responseHeadersMarkdown = Format-HeadersMarkdown ($safeResponseHeaders -split "`r?`n")
        $requestLanguage = if ($BodyFile -match '\.xml$') { "xml" } elseif ($BodyFile -match '\.json$') { "json" } else { "text" }
        $responseLanguage = if ($responseBody.TrimStart().StartsWith("<")) { "xml" } elseif ($responseBody.TrimStart().StartsWith("{")) { "json" } else { "text" }
        $requestBodyText = if ($requestBody) { (Redact-Text $requestBody).TrimEnd() } else { "(none)" }
        $responseBodyText = if ($displayBody) { (Redact-Text $displayBody).TrimEnd() } else { "(empty)" }
        $errorText = if ($DebugMode -and $curlError.Trim()) { "See Curl debug output below." } elseif ($curlError.Trim()) { $curlError.TrimEnd() } else { "None" }
        $safeDebugText = $errorText -replace '(?im)^([>\<]\s*)(Authorization|Cookie|Set-Cookie):.*$', '$1$2: [REDACTED]'
        $report = @"
# API Run Report

## Run information

- Started: $($startedAt.ToString("o"))
- Finished: $($finishedAt.ToString("o"))
- Service: $ServiceName
- Interface: $RequestName
- Environment: $env:API_ENVIRONMENT
- Request payload: $(if ($BodyFile) { $BodyFile } else { "(none)" })
- Curl exit code: $curlExitCode
- HTTP status: $($metricValues[0])
- Duration: $($metricValues[1]) seconds
- Downloaded: $($metricValues[2]) bytes

## Request

### Method and URL

$requestMethod $safeRequestUrl

### Headers

$requestHeadersMarkdown

### Body

~~~$requestLanguage
$requestBodyText
~~~

## Response

### Headers

$responseHeadersMarkdown

### Body

~~~$responseLanguage
$responseBodyText
~~~

## Errors

~~~text
$errorText
~~~
$(if ($DebugMode) { "`n## Curl debug output`n`n~~~text`n$safeDebugText`n~~~" })
"@
        Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8
        Write-Output ""
        Write-Output "Saved report: $reportPath"
    }

    exit $curlExitCode
} finally {
    Remove-Item -LiteralPath $headersFile, $responseBodyFile, $diagnosticFile -Force -ErrorAction SilentlyContinue
}
