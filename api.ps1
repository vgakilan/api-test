[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Payload,
    [Alias('Environment')][string]$Env = 'test',
    [string]$Config,
    [string]$Url,
    [ValidateSet('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS')][string]$Method,
    [string[]]$Header = @(),
    [string[]]$Query = @(),
    [string[]]$Set = @(),
    [string]$Body,
    [int[]]$ExpectedStatus = @(),
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 60,
    [ValidateRange(1,300)][int]$ConnectTimeoutSeconds = 10,
    [ValidateRange(1,104857600)][long]$MaxResponseBytes = 10485760,
    [switch]$RawPayload,
    [switch]$NoDotEnv,
    [switch]$Save,
    [switch]$DebugMode,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Help -or [string]::IsNullOrWhiteSpace($Command)) {
    @'
PowerShell API test CLI

  .\api.ps1 <interface> -Env test [-Payload valid.json] [-Set key=value]
  .\api.ps1 create <interface-name-or-group/interface-name>

Overrides (array options are supplied once, with comma-separated values):
  -Url <http(s)-url> -Method GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS
  -Header 'Name: value','Other: value' -Query 'name=value','other=value'
  -Set 'name=value' -Body <file-or-text> -ExpectedStatus 200,201
  -TimeoutSeconds 60 -ConnectTimeoutSeconds 10 -MaxResponseBytes 10485760
  -RawPayload -NoDotEnv -Save -DebugMode -Help

Defaults: only HTTP 2xx succeeds; no redirects or retries; redacted output.
Use -DebugMode for curl diagnostics (-Debug is PowerShell's common parameter).
See README.md for supported TOML, payload handling, security, and exit codes.
'@
    exit 0
}

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$temporaryDirectory = $null
$exitCode = 2
try {
    Assert-InterfaceName $Command
    if ($Command -eq 'create') {
        Assert-InterfaceName $Payload
        $interfacePath = Resolve-InterfacePath $PSScriptRoot $Payload
        if (Test-Path -LiteralPath $interfacePath) { Stop-ApiValidation 'Interface already exists.' }
        $null = New-Item -ItemType Directory -Path (Join-Path $interfacePath 'payloads') -Force
        Write-Utf8 (Join-Path $interfacePath 'request.toml') "method = `"GET`"`npath = `"/`"`nheaders = []`n"
        Write-Output "Created interface/$Payload with request.toml and payloads/"
        exit 0
    }

    if (-not $Config) { $Config = Join-Path $PSScriptRoot 'config.toml' }
    $settings = Read-ApiToml $Config
    Assert-Keys $settings @('defaults','environments') 'configuration'
    $defaults = Get-Value $settings 'defaults' @{}
    $environments = Get-Value $settings 'environments' @{}
    if ($defaults -isnot [hashtable] -or $environments -isnot [hashtable]) { Stop-ApiValidation 'Invalid configuration tables.' }
    if (-not $environments.ContainsKey($Env)) { Stop-ApiValidation 'Selected environment does not exist.' }
    $environment = $environments[$Env]
    if ($environment -isnot [hashtable]) { Stop-ApiValidation 'Invalid environment table.' }
    Assert-Keys $environment @('base_url','values') 'environment'
    if ($environment.ContainsKey('base_url') -and $environment.base_url -isnot [string]) { Stop-ApiValidation 'Environment base_url must be a string.' }
    $environmentValues = Get-Value $environment 'values' @{}
    if ($environmentValues -isnot [hashtable]) { Stop-ApiValidation 'Environment values must be a table.' }

    $interfacePath = Resolve-InterfacePath $PSScriptRoot $Command
    $request = Read-ApiToml (Join-Path $interfacePath 'request.toml')
    Assert-Keys $request @('service','base_url','method','path','headers','query','expected_status') 'request'
    if ($request.ContainsKey('expected_status') -and $request.expected_status -isnot [array]) { Stop-ApiValidation 'expected_status must be an array of integers.' }
    foreach ($key in @('service','method','path')) {
        if ($request.ContainsKey($key) -and $request[$key] -isnot [string]) { Stop-ApiValidation 'Request service, method and path must be strings.' }
    }
    if ($request.ContainsKey('base_url') -and $request.base_url -isnot [string]) { Stop-ApiValidation 'Request base_url must be a string.' }
    $values = @{}
    foreach ($key in $defaults.Keys) { $values[$key] = $defaults[$key] }
    foreach ($key in $environmentValues.Keys) { $values[$key] = $environmentValues[$key] }
    $values['base_url'] = Get-Value $environment 'base_url' ''
    $secretValues = New-Object 'System.Collections.Generic.List[string]'
    # Ambient process state is the fallback; explicit project .env values must win.
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $values[[string]$entry.Key] = [string]$entry.Value
        if ([string]$entry.Key -match '(?i)token|secret|password|passcode|api.?key|credential|authorization|cookie') { $secretValues.Add([string]$entry.Value) }
    }
    if (-not $NoDotEnv) {
        $dotenv = Read-ApiDotEnv (Join-Path $PSScriptRoot '.env')
        foreach ($key in $dotenv.Keys) { $values[$key] = $dotenv[$key]; $secretValues.Add([string]$dotenv[$key]) }
    }
    foreach ($item in $Set) {
        if ($item -notmatch '^([A-Za-z_][A-Za-z0-9_.-]*)=(.*)$') { Stop-ApiValidation 'Invalid -Set; use name=value.' }
        $values[$matches[1]] = $matches[2]
        $secretValues.Add($matches[2])
    }
    foreach ($key in $values.Keys) {
        if ($values[$key] -is [hashtable] -or $values[$key] -is [array]) { Stop-ApiValidation 'Placeholder values must be scalars.' }
    }
    $methodValue = if ($Method) { $Method } else { Get-Value $request 'method' 'GET' }
    if ($methodValue -notmatch '^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$') { Stop-ApiValidation 'Unsupported request method.' }
    $methodValue = $methodValue.ToUpperInvariant()
    $requestUrl = if ($Url) { $Url } else {
        $baseUrl = if ($request.ContainsKey('base_url')) { [string]$request.base_url } else { [string](Get-Value $environment 'base_url' '') }
        if (-not $baseUrl) { Stop-ApiValidation 'Environment base_url is required unless -Url is supplied.' }
        $baseUrl = Expand-ApiValue $baseUrl $values $secretValues
        $null = Add-ApiQuery $baseUrl @() $values $secretValues
        if (([Uri]$baseUrl).Query) { Stop-ApiValidation 'base_url cannot include a query; put query entries in the request.' }
        $baseUrl.TrimEnd('/') + '/' + ([string](Get-Value $request 'path' '/')).TrimStart('/')
    }
    $requestUrl = Expand-ApiValue $requestUrl $values $secretValues
    if ($requestUrl.Length -gt 16384) { Stop-ApiValidation 'URL exceeds 16 KiB.' }
    $queryItems = @(Get-StringArray $request 'query') + $Query
    $requestUrl = Add-ApiQuery $requestUrl $queryItems $values $secretValues
    if ($requestUrl.Length -gt 16384) { Stop-ApiValidation 'URL including query exceeds 16 KiB.' }
    $headers = @(Merge-ApiHeaders @(Get-StringArray $request 'headers') $Header $values $secretValues)

    $statuses = if ($PSBoundParameters.ContainsKey('ExpectedStatus')) { $ExpectedStatus } else { @(Get-Value $request 'expected_status' @(200..299)) }
    if (@($statuses).Count -eq 0) { Stop-ApiValidation 'Expected statuses cannot be empty.' }
    foreach ($status in $statuses) { if ($status -isnot [int] -and $status -isnot [long]) { Stop-ApiValidation 'Expected statuses must be integers.' }; if ($status -lt 100 -or $status -gt 599) { Stop-ApiValidation 'Expected statuses must be between 100 and 599.' } }

    $temporaryDirectory = New-PrivateTempDirectory
    $bodyFile = $null
    if ($PSBoundParameters.ContainsKey('Body')) {
        if ($Body -and (Test-Path -LiteralPath $Body -PathType Leaf)) { $bodyFile = (Resolve-Path -LiteralPath $Body).ProviderPath }
        else { $bodyFile = Join-Path $temporaryDirectory 'body'; Write-Utf8 $bodyFile $Body }
    } elseif ($Payload) { $bodyFile = Find-ApiPayload $interfacePath $Payload }
    if ($bodyFile -and (Get-Item -LiteralPath $bodyFile).Length -gt 104857600) { Stop-ApiValidation 'Payload exceeds the 100 MiB limit.' }
    if ($bodyFile -and -not $RawPayload) {
        if ((Get-Item -LiteralPath $bodyFile).Length -gt 10485760) { Stop-ApiValidation 'Templated payload exceeds 10 MiB; use -RawPayload to send it unchanged.' }
        $raw = Read-Utf8 $bodyFile
        $expanded = Expand-ApiValue $raw $values $secretValues
        if ([Text.Encoding]::UTF8.GetByteCount($expanded) -gt 10485760) { Stop-ApiValidation 'Expanded payload exceeds 10 MiB.' }
        if ($expanded -ne $raw) { $bodyFile = Join-Path $temporaryDirectory 'expanded-body'; Write-Utf8 $bodyFile $expanded }
    }
    if ($methodValue -eq 'HEAD' -and $bodyFile) { Stop-ApiValidation 'HEAD cannot include a payload.' }

    $reportRequestName = Get-InterfaceReportName $Command
    $result = Invoke-ApiCurl -RequestUrl $requestUrl -Method $methodValue -Headers $headers -BodyFile $bodyFile `
        -ExpectedStatus $statuses -TimeoutSeconds $TimeoutSeconds -ConnectTimeoutSeconds $ConnectTimeoutSeconds `
        -MaxResponseBytes $MaxResponseBytes -TemporaryDirectory $temporaryDirectory -SecretValues $secretValues.ToArray() `
        -SaveReport:$Save -DebugMode:$DebugMode -RequestName $reportRequestName -ServiceName ([string](Get-Value $request 'service' $Command)) `
        -EnvironmentName $Env -ReportRoot (Join-Path $PSScriptRoot 'runs')
    foreach ($line in $result.Output) { Write-Output $line }
    $exitCode = $result.ExitCode
} catch {
    # Never print exception text: native/parser/file errors can embed credentials or payloads.
    $safeMessage = 'Check configuration, paths, curl installation and permissions.'
    $exception = $_.Exception
    while ($exception) {
        if ($exception.Data.Contains('ApiSafeMessage')) { $safeMessage = [string]$exception.Data['ApiSafeMessage']; break }
        $exception = $exception.InnerException
    }
    [Console]::Error.WriteLine("API test failed: $safeMessage Exit code: 2.")
    $exitCode = 2
} finally {
    if ($temporaryDirectory) { Remove-PrivateTempDirectory $temporaryDirectory }
}
exit $exitCode
