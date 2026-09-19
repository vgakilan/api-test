param(
    [Parameter(Mandatory = $true)]
    [string[]]$CurlArguments,

    [switch]$SaveReport,

    [switch]$DebugMode,

    [string]$RequestName = "request",

    [string]$BodyFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$startedAt = Get-Date

$headersFile = [System.IO.Path]::GetTempFileName()
$responseBodyFile = [System.IO.Path]::GetTempFileName()
$diagnosticFile = [System.IO.Path]::GetTempFileName()

try {
    $curlOptions = @(
        "--silent",
        "--show-error",
        "--dump-header", $headersFile,
        "--output", $responseBodyFile,
        "--write-out", "%{http_code}|%{time_total}|%{size_download}"
    )
    if ($DebugMode) { $curlOptions += "--verbose" }

    $metrics = & curl.exe @curlOptions @CurlArguments 2> $diagnosticFile
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
        $reportName = "{0}_{1}_{2}.md" -f $startedAt.ToString("HH-mm-ss"), $env:API_ENVIRONMENT, $RequestName
        $reportPath = Join-Path $reportDirectory ($reportName -replace '[^a-zA-Z0-9_.-]', '_')
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

        $safeRequestHeaders = $requestHeaders | ForEach-Object {
            if ($_ -match '^(Authorization|Cookie|Set-Cookie|.*(token|secret|api[-_]?key))\s*:') { ($_ -replace ':.*$', ': [REDACTED]') } else { $_ }
        }
        $safeResponseHeaders = $responseHeaders -replace '(?im)^(set-cookie|authorization):.*$', '$1: [REDACTED]'
        $requestLanguage = if ($BodyFile -match '\.xml$') { "xml" } elseif ($BodyFile -match '\.json$') { "json" } else { "text" }
        $responseLanguage = if ($responseBody.TrimStart().StartsWith("<")) { "xml" } elseif ($responseBody.TrimStart().StartsWith("{")) { "json" } else { "text" }
        $requestBodyText = if ($requestBody) { $requestBody.TrimEnd() } else { "(none)" }
        $responseBodyText = if ($displayBody) { $displayBody } else { "(empty)" }
        $errorText = if ($DebugMode -and $curlError.Trim()) { "See Curl debug output below." } elseif ($curlError.Trim()) { $curlError.TrimEnd() } else { "None" }
        $safeDebugText = $errorText -replace '(?im)^([>\<]\s*)(Authorization|Cookie|Set-Cookie):.*$', '$1$2: [REDACTED]'
        $report = @"
# API Run Report

## Run information

- Started: $($startedAt.ToString("o"))
- Finished: $($finishedAt.ToString("o"))
- Environment: $env:API_ENVIRONMENT
- Request: $RequestName
- Body file: $BodyFile
- Curl exit code: $curlExitCode
- HTTP status: $($metricValues[0])
- Duration: $($metricValues[1]) seconds
- Downloaded: $($metricValues[2]) bytes

## Request

### Method and URL

$requestMethod $requestUrl

### Headers

$(($safeRequestHeaders -join "`n"))

### Body

````$requestLanguage
$requestBodyText
````

## Response

### Headers

$safeResponseHeaders

### Body

````$responseLanguage
$responseBodyText
````

## Errors

````text
$errorText
````
$(if ($DebugMode) { "`n## Curl debug output`n`n````text`n$safeDebugText`n````" })
"@
        Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8
        Write-Output ""
        Write-Output "Saved report: $reportPath"
    }

    exit $curlExitCode
} finally {
    Remove-Item -LiteralPath $headersFile, $responseBodyFile, $diagnosticFile -Force -ErrorAction SilentlyContinue
}
