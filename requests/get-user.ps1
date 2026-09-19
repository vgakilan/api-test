param(
    [string]$BodyFile = (Join-Path $PSScriptRoot "..\bodies\get-user\get-user-1.xml"),
    [switch]$SaveReport,
    [switch]$DebugMode
)

$bodyFile = (Resolve-Path -LiteralPath $BodyFile).Path

$arguments = @(
    "--request", "POST",
    "--url", "$env:API_BASE_URL/post",
    "--header", "Content-Type: text/xml; charset=utf-8",
    "--header", "Accept: text/xml",
    "--header", "SOAPAction: GetUser",
    "--header", "Authorization: Bearer $env:API_TOKEN",
    "--data-binary", "@$bodyFile"
)

& (Join-Path $PSScriptRoot "..\lib\Invoke-Curl.ps1") -CurlArguments $arguments -SaveReport:$SaveReport -DebugMode:$DebugMode -RequestName "get-user" -BodyFile $bodyFile
exit $LASTEXITCODE
