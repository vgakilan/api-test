param(
    [switch]$SaveReport,
    [switch]$DebugMode
)

$arguments = @(
    "--request", "GET",
    "--url", "$env:API_BASE_URL/get?resource=users",
    "--header", "Accept: application/json",
    "--header", "User-Agent: terminal-api-client",
    "--header", "Authorization: Bearer $env:API_TOKEN"
)

& (Join-Path $PSScriptRoot "..\lib\Invoke-Curl.ps1") -CurlArguments $arguments -SaveReport:$SaveReport -DebugMode:$DebugMode -RequestName "users-list"
exit $LASTEXITCODE
