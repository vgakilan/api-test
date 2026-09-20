[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Command,
    [Parameter(Position = 1)] [string]$Payload,
    [Alias('Environment')][string]$Env = 'test',
    [string]$Config,
    [string]$Url,
    [ValidateSet('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS')][string]$Method,
    [string[]]$Header = @(),
    [string[]]$Query = @(),
    [string[]]$Set = @(),
    [string]$Body,
    [switch]$Save,
    [switch]$DebugMode,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $PSScriptRoot 'config.toml' }

function Show-Help {
    @"
PowerShell API test CLI

Run an interface:
  .\api.ps1 <interface> -Env test [-Payload valid.json] [-Set key=value]

Create an interface:
  .\api.ps1 create <interface-name>

Overrides:
  -Url <url> -Method GET|POST|PUT|PATCH|DELETE -Header 'Name: value'
  -Query 'name=value' -Set 'path=value' -Body <file-or-text> -Save -Debug

Examples:
  .\api.ps1 create-user -Env test -Payload valid.json
  .\api.ps1 users-list -Env test -Query 'active=true'
"@
}

if ($Help -or [string]::IsNullOrWhiteSpace($Command)) { Show-Help; exit 0 }

function Read-DotEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $value = $matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) { $value = $value.Substring(1, $value.Length - 2) }
            [Environment]::SetEnvironmentVariable($matches[1], $value)
        }
    }
}

function Parse-Toml([string]$Path) {
    $root = @{}
    $section = $root
    $lines = @(Get-Content -LiteralPath $Path)
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        while ($line -match '=\s*\[' -and $line -notmatch '\]\s*(?:#.*)?$' -and ($lineIndex + 1) -lt $lines.Count) {
            $lineIndex++
            $line += ' ' + $lines[$lineIndex].Trim()
        }
        $line = ($line -replace '\s*#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $section = $root
            foreach ($part in ($matches[1] -split '\.')) {
                if (-not $section.ContainsKey($part)) { $section[$part] = @{} }
                $section = $section[$part]
            }
            continue
        }
        if ($line -notmatch '^([^=]+)=(.*)$') { throw "Invalid TOML line in $Path`: $line" }
        $key = $matches[1].Trim(); $raw = $matches[2].Trim()
        if ($raw -match '^"(.*)"$') { $value = $matches[1] -replace '\\n', "`n" -replace '\\"', '"' }
        elseif ($raw -match "^'(.*)'$") { $value = $matches[1] }
        elseif ($raw -match '^\[(.*)\]$') { $value = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ -ne '' }) }
        elseif ($raw -match '^(true|false)$') { $value = [bool]::Parse($raw) }
        elseif ($raw -match '^-?\d+(\.\d+)?$') { $value = [double]$raw }
        else { $value = $raw }
        $section[$key] = $value
    }
    return $root
}

function Get-Value($Map, [string]$Key, $Default = $null) {
    if ($null -ne $Map -and $Map.ContainsKey($Key)) { return $Map[$Key] }
    return $Default
}

function Expand-Value([string]$Value, [hashtable]$Values) {
    if ($null -eq $Value) { return $Value }
    return [regex]::Replace($Value, '\{\{\s*([^}]+?)\s*\}\}', { param($m)
        $name = $m.Groups[1].Value
        if ($Values.ContainsKey($name)) { return [string]$Values[$name] }
        $envValue = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $envValue) { return $envValue }
        return $m.Value
    })
}

function Find-Payload([string]$InterfacePath, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $candidate = if ([IO.Path]::IsPathRooted($Name)) { $Name } else { Join-Path (Join-Path $InterfacePath 'payloads') $Name }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    $matches = @(Get-ChildItem -LiteralPath (Join-Path $InterfacePath 'payloads') -File -Recurse | Where-Object { $_.Name -eq $Name -or $_.BaseName -eq $Name })
    if ($matches.Count -eq 1) { return $matches[0].FullName }
    if ($matches.Count -gt 1) { throw "Payload '$Name' is ambiguous." }
    throw "Payload not found: $Name"
}

Read-DotEnv (Join-Path $PSScriptRoot '.env')

if ($Command -eq 'create') {
    if ([string]::IsNullOrWhiteSpace($Payload)) { throw 'Usage: .\api.ps1 create <interface-name>' }
    $interfacePath = Join-Path $PSScriptRoot (Join-Path 'interface' $Payload)
    if (Test-Path -LiteralPath $interfacePath) { throw "Interface already exists: $Payload" }
    New-Item -ItemType Directory -Path (Join-Path $interfacePath 'payloads') -Force | Out-Null
    @"
method = "GET"
path = "/"
headers = []
"@ | Set-Content -LiteralPath (Join-Path $interfacePath 'request.toml') -Encoding utf8
    Write-Output "Created interface/$Payload with request.toml and payloads/"
    exit 0
}

if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) { throw "Config not found: $Config" }
$settings = Parse-Toml $Config
$interfacePath = Join-Path $PSScriptRoot (Join-Path 'interface' $Command)
$requestPath = Join-Path $interfacePath 'request.toml'
if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) { throw "Interface not found: $Command. Create it with '.\api.ps1 create $Command'." }
$request = Parse-Toml $requestPath
$environment = Get-Value (Get-Value $settings 'environments' @{}) $Env @{}
$defaults = Get-Value $settings 'defaults' @{}
$values = @{}
foreach ($key in $environment.Keys) { if ($environment[$key] -is [hashtable]) { foreach ($nested in $environment[$key].Keys) { $values[$nested] = $environment[$key][$nested] } } else { $values[$key] = $environment[$key] } }
foreach ($key in $defaults.Keys) { if (-not $values.ContainsKey($key)) { $values[$key] = $defaults[$key] } }
foreach ($item in $Set) { if ($item -notmatch '^([^=]+)=(.*)$') { throw "Invalid -Set value: $item" }; $values[$matches[1]] = $matches[2] }

$methodValue = if ($Method) { $Method } else { [string](Get-Value $request 'method' 'GET') }
$baseUrl = [string](Get-Value $environment 'base_url' '')
$pathValue = [string](Get-Value $request 'path' '/')
$requestUrl = if ($Url) { $Url } else { (($baseUrl.TrimEnd('/') + '/' + $pathValue.TrimStart('/')).TrimEnd('/')) }
$requestUrl = Expand-Value $requestUrl $values
$queryItems = @(Get-Value $request 'query' @()) + $Query
if ($queryItems.Count -gt 0) { $requestUrl += '?' + (($queryItems | ForEach-Object { Expand-Value $_ $values }) -join '&') }
$headers = @()
foreach ($headerValue in @(Get-Value $request 'headers' @())) { $headers += (Expand-Value $headerValue $values) }
$headers += $Header | ForEach-Object { Expand-Value $_ $values }
$payloadPath = Find-Payload $interfacePath $Payload
$temporaryPayload = $null
if ($Body) {
    if (Test-Path -LiteralPath $Body -PathType Leaf) { $payloadPath = (Resolve-Path -LiteralPath $Body).Path } else { $payloadPath = Join-Path ([IO.Path]::GetTempPath()) ("api-test-body-{0}.tmp" -f [guid]::NewGuid()); Set-Content -LiteralPath $payloadPath -Value $Body -Encoding utf8; $temporaryPayload = $payloadPath }
}
if ($payloadPath) {
    $raw = Get-Content -Raw -LiteralPath $payloadPath
    $expanded = Expand-Value $raw $values
    if ($expanded -ne $raw) {
        $expandedPath = Join-Path ([IO.Path]::GetTempPath()) ("api-test-payload-{0}{1}" -f [guid]::NewGuid(), [IO.Path]::GetExtension($payloadPath))
        Set-Content -LiteralPath $expandedPath -Value $expanded -Encoding utf8
        if ($temporaryPayload) { Remove-Item -LiteralPath $temporaryPayload -Force -ErrorAction SilentlyContinue }
        $payloadPath = $expandedPath; $temporaryPayload = $expandedPath
    }
}
$arguments = @('--request', $methodValue, '--url', $requestUrl)
foreach ($headerValue in $headers) { $arguments += @('--header', $headerValue) }
if ($payloadPath) { $arguments += @('--data-binary', "@$payloadPath") }
try {
    & (Join-Path $PSScriptRoot 'lib\Invoke-Curl.ps1') -CurlArguments $arguments -SaveReport:$Save -DebugMode:$DebugMode -RequestName $Command -BodyFile $payloadPath
    $exitCode = $LASTEXITCODE
} finally {
    if ($temporaryPayload) { Remove-Item -LiteralPath $temporaryPayload -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
