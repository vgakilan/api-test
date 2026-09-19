param(
    [switch]$SaveReport,
    [switch]$DebugMode
)

$arguments = @(
    "--request", "POST",
    "--url", "$env:API_BASE_URL/post",
    "--header", "Accept: application/json",
    "--header", "Content-Type: application/json",
    "--header", "Authorization: Bearer $env:API_TOKEN",
    "--data-raw", '{"name":"example","enabled":true}'
)

& (Join-Path $PSScriptRoot "..\lib\Invoke-Curl.ps1") -CurlArguments $arguments -SaveReport:$SaveReport -DebugMode:$DebugMode -RequestName "example-request"
exit $LASTEXITCODE
