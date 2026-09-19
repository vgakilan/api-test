param(
    [string]$BodyFile = (Join-Path $PSScriptRoot "..\bodies\create-user\user-create.json"),
    [switch]$SaveReport,
    [switch]$DebugMode
)

$bodyFile = (Resolve-Path -LiteralPath $BodyFile).Path

$arguments = @(
    "--request", "POST",
    "--url", "$env:API_BASE_URL/post",
    "--header", "Accept: application/json",
    "--header", "Content-Type: application/json",
    "--header", "User-Agent: terminal-api-client",
    "--header", "Authorization: Bearer $env:API_TOKEN",
    "--data-binary", "@$bodyFile"
)

& (Join-Path $PSScriptRoot "..\lib\Invoke-Curl.ps1") -CurlArguments $arguments -SaveReport:$SaveReport -DebugMode:$DebugMode -RequestName "user-create" -BodyFile $bodyFile
exit $LASTEXITCODE
