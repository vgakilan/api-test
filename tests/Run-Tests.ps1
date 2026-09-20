[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
$script:checks = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:checks++
    Write-Output "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $thrown = $false
    try { $null = & $Action } catch { $thrown = $true }
    Assert-True $thrown $Name
}

$temp = New-PrivateTempDirectory
$server = $null
$oldNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
try {
    $env:NO_PROXY = '127.0.0.1,localhost'
    $tempAcl = Get-Acl -LiteralPath $temp
    Assert-True $tempAcl.AreAccessRulesProtected 'Temporary directory ACL disables inheritance'
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.ps1' -File)) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True (@($errors).Count -eq 0) "Syntax: $($file.Name)"
    }
    $fixture = Join-Path $temp 'parser.toml'
    Write-Utf8 $fixture @'
path = "/items#fragment"
headers = [
  "Accept: application/json, text/plain", # comment
  'X-Value: # literal',
  "X-Quote: \"quoted\"",
]
expected_status = [200, 201]
enabled = true
[nested.values]
number = 42
'@
    $parsed = Read-ApiToml $fixture
    Assert-True ($parsed.path -eq '/items#fragment') 'Quoted hash preserved'
    Assert-True ($parsed.headers.Count -eq 3 -and $parsed.headers[0] -eq 'Accept: application/json, text/plain') 'Quoted commas and multiline arrays'
    Assert-True ($parsed.headers[2] -eq 'X-Quote: "quoted"') 'Escaped quotes'
    Assert-True ($parsed.nested.values.number -eq 42 -and $parsed.enabled) 'Tables and scalars'
    foreach ($invalid in @(('x = "one"' + "`n" + 'x = "two"'), 'x = ["unterminated"', 'x = nope', 'x = { a = 1 }', 'x = "unfinished', "[x]`n[x]", 'x = ["a" "b"]')) {
        Write-Utf8 $fixture $invalid
        Assert-Throws { Read-ApiToml $fixture } 'Malformed/unsupported TOML rejected'
    }
    $secrets = New-Object 'System.Collections.Generic.List[string]'
    Assert-Throws { Expand-ApiValue '{{missing}}' @{} $secrets } 'Missing placeholder fails'
    Assert-Throws { Expand-ApiValue '{{unfinished' @{} $secrets } 'Malformed placeholder fails'
    $url = Add-ApiQuery 'http://127.0.0.1/items/?existing=1' @('q=a&b = c','empty=') @{} $secrets
    Assert-True ($url -eq 'http://127.0.0.1/items/?existing=1&q=a%26b%20%3D%20c&empty=') 'Query encoding and existing query'
    foreach ($invalidUrl in @('file:///test','https://user:password@example.invalid/','https://example.invalid/#fragment')) {
        Assert-Throws { Add-ApiQuery $invalidUrl @() @{} $secrets } 'Unsafe URL rejected'
    }
    $merged = @(Merge-ApiHeaders @('Authorization: old','Accept: one') @('authorization: new') @{} $secrets)
    Assert-True ($merged.Count -eq 2 -and ($merged -join '|') -notmatch 'old') 'Header overrides replace case-insensitively'
    Assert-Throws { Merge-ApiHeaders @("X-Test: ok`r`nInjected: yes") @() @{} $secrets } 'Header injection rejected'
    Assert-Throws { Assert-InterfaceName '../outside' } 'Interface traversal rejected'
    foreach ($invalidInterface in @('a/b/c', 'a//b', '/a', 'a/', 'a\b', './a', 'a/../b')) {
        Assert-Throws { Assert-InterfaceName $invalidInterface } "Invalid grouped interface rejected: $invalidInterface"
    }
    Assert-Throws { Assert-InterfaceName 'CON' } 'Reserved Windows name rejected'
    $interfaceRoot = Join-Path $temp 'interface'
    $nestedResolved = Resolve-InterfacePath $temp 'meps/sendEstateClaim'
    Assert-True ($nestedResolved -eq [IO.Path]::GetFullPath((Join-Path $interfaceRoot 'meps\sendEstateClaim'))) 'Nested interface resolves inside interface root'
    $flatResolved = Resolve-InterfacePath $temp 'get-user'
    Assert-True ($flatResolved -eq [IO.Path]::GetFullPath((Join-Path $interfaceRoot 'get-user'))) 'Existing flat interface resolves unchanged'
    Assert-True ((Get-InterfaceReportName 'meps/sendEstateClaim') -eq 'meps-sendEstateClaim') 'Nested report name is sanitized'
    Assert-True ((Protect-ApiText 'aaa bbb' @('aaa','bbb')) -eq '[REDACTED] [REDACTED]') 'Equal-length secrets both masked'
    foreach ($sample in @('Authorization: Bearer SYNTHETIC-SECRET','> X-Api-Key: SYNTHETIC-SECRET','{"Authorization":"SYNTHETIC-SECRET"}','<refresh_token>SYNTHETIC-SECRET</refresh_token>','password=SYNTHETIC-SECRET&ok=1')) {
        Assert-True ((Protect-ApiText $sample) -notmatch 'SYNTHETIC-SECRET') 'Sensitive field redaction'
    }
    Assert-True ((Protect-ApiText '<refresh_token>value</refresh_token>') -eq '<refresh_token>[REDACTED]</refresh_token>') 'XML redaction preserves tags'
    $structured = Protect-StructuredText '{"access_token":["FIRST","SECOND"],"nested":{"p\u0061ssword":{"a":"THIRD"}}}'
    Assert-True ($structured -notmatch 'FIRST|SECOND|THIRD') 'Structured redaction masks arrays, objects and escaped JSON keys'
    $structured = Protect-StructuredText '<root xmlns:s="urn:test"><s:refresh_token>FIRST</s:refresh_token><item password="SECOND" /></root>'
    Assert-True ($structured -notmatch 'FIRST|SECOND') 'XML namespaces and sensitive attributes redacted'
    Assert-True ((Protect-StructuredText '<!DOCTYPE root [<!ENTITY x SYSTEM "file:///absent">]><root>&x;</root>') -match 'omitted') 'XML external entities prohibited'
    Assert-True ((Protect-ApiText 'https://example.invalid/?%74oken=SYNTHETIC-SECRET') -notmatch 'SYNTHETIC-SECRET') 'Encoded query keys redacted'
    foreach ($jsonArray in @('[]','[1]','[{"id":1}]')) {
        Assert-True ((Protect-StructuredText $jsonArray) -ceq $jsonArray) 'Top-level JSON array shape preserved'
    }
    Assert-True ((Protect-ApiText ("pass" + [char]27 + "[31mword: SYNTHETIC-SECRET")) -notmatch 'SYNTHETIC-SECRET') 'ANSI sequences cannot bypass redaction'
    $pretty = Format-ApiJson (Protect-StructuredText '{"ok":true,"token":"DISPLAY-SECRET"}')
    Assert-True ($pretty -match '\r?\n\s+"ok"' -and $pretty -notmatch 'DISPLAY-SECRET') 'Readable JSON formatting preserves redaction'
    foreach ($jsonArray in @('[]','[1]','[{"id":1}]')) {
        $formatted = Format-ApiJson $jsonArray
        Assert-True ($formatted.TrimStart().StartsWith('[') -and $formatted.TrimEnd().EndsWith(']')) 'Pretty printing preserves JSON arrays'
    }
    Assert-True ((Format-ApiJson 'plain response') -eq 'plain response') 'Non-JSON output remains readable'
    $block = ConvertTo-ReportBlock "~~~`n<script>example</script>"
    Assert-True ($block.StartsWith("~~~~text`n") -and $block.TrimEnd().EndsWith('~~~~')) 'Report fences contain embedded Markdown safely'
    $table = ConvertTo-ReportTable 'X-Value: <script>|example</script>'
    Assert-True ($table.Contains('&lt;script&gt;&#124;') -and -not $table.Contains('<script>')) 'Report tables escape HTML and pipes'
    Write-Utf8 $fixture ('a' * 262145)
    Assert-True ((Read-SafePreview $fixture @()) -match 'omitted') 'Oversized preview omitted'
    Write-Utf8 $fixture 'exact'
    Assert-True ([IO.File]::ReadAllBytes($fixture).Length -eq 5) 'UTF-8 writer adds no BOM or newline'

    # Exercise the public CLI from an isolated copy; never load the user's .env/config.
    $sandbox = Join-Path $temp 'workspace'
    $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'interface\test\payloads') -Force
    Copy-Item -LiteralPath (Join-Path $root 'api.ps1') -Destination $sandbox
    Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination $sandbox -Recurse
    Add-Type -Path (Join-Path $PSScriptRoot 'LoopbackServer.cs')
    $server = New-Object ApiTestLoopbackServer
    $baseUrl = 'http://127.0.0.1:' + $server.Port
    Write-Utf8 (Join-Path $sandbox 'config.toml') "[environments.test]`nbase_url = `"$baseUrl`"`n"
    Write-Utf8 (Join-Path $sandbox 'interface\test\request.toml') "method = `"GET`"`npath = `"/`"`nheaders = []`n"
    $cli = Join-Path $sandbox 'api.ps1'
    $requestFile = Join-Path $sandbox 'interface\test\request.toml'
    $nestedInterface = Join-Path $sandbox 'interface\meps\sendEstateClaim'
    $null = New-Item -ItemType Directory -Path (Join-Path $nestedInterface 'payloads') -Force
    Write-Utf8 (Join-Path $nestedInterface 'request.toml') "method = `"GET`"`npath = `"/nested`"`nheaders = []`n"
    $nestedOutput = @(& $cli 'meps/sendEstateClaim' -NoDotEnv)
    Assert-True ($LASTEXITCODE -eq 0 -and ($nestedOutput -join "`n") -match 'HTTP status: 200') 'Nested interface request resolves and runs'
    $flatInterface = Join-Path $sandbox 'interface\get-user'
    $null = New-Item -ItemType Directory -Path (Join-Path $flatInterface 'payloads') -Force
    Write-Utf8 (Join-Path $flatInterface 'request.toml') "method = `"GET`"`npath = `"/flat`"`nheaders = []`n"
    $flatOutput = @(& $cli get-user -NoDotEnv)
    Assert-True ($LASTEXITCODE -eq 0 -and ($flatOutput -join "`n") -match 'HTTP status: 200') 'Existing flat interface runs unchanged'
    $overrideInterface = Join-Path $sandbox 'interface\meps\override-host'
    $null = New-Item -ItemType Directory -Path (Join-Path $overrideInterface 'payloads') -Force
    Write-Utf8 (Join-Path $overrideInterface 'request.toml') "base_url = `"$baseUrl/override-host`"`nmethod = `"GET`"`npath = `"/target`"`nheaders = []`n"
    $null = & $cli 'meps/override-host' -NoDotEnv
    $requests = $server.Requests.ToArray()
    Assert-True ($LASTEXITCODE -eq 0 -and $requests[$requests.Length - 1].StartsWith('GET /override-host/target ')) 'Interface base_url overrides environment base_url'
    Write-Utf8 (Join-Path $overrideInterface 'request.toml') "base_url = `"file:///unsafe`"`nmethod = `"GET`"`npath = `"/target`"`nheaders = []`n"
    $beforeRequests = $server.Requests.Count
    $null = & $cli 'meps/override-host' -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 2 -and $server.Requests.Count -eq $beforeRequests) 'Interface base_url requires HTTP(S)'
    Write-Utf8 (Join-Path $overrideInterface 'request.toml') "base_url = `"$baseUrl/?unsafe=true`"`nmethod = `"GET`"`npath = `"/target`"`nheaders = []`n"
    $null = & $cli 'meps/override-host' -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 2 -and $server.Requests.Count -eq $beforeRequests) 'Interface base_url cannot contain a query'
    Write-Utf8 (Join-Path $overrideInterface 'request.toml') "base_url = `"$baseUrl/#unsafe`"`nmethod = `"GET`"`npath = `"/target`"`nheaders = []`n"
    $null = & $cli 'meps/override-host' -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 2 -and $server.Requests.Count -eq $beforeRequests) 'Interface base_url cannot contain a fragment'
    Write-Utf8 (Join-Path $overrideInterface 'request.toml') "base_url = 42`nmethod = `"GET`"`npath = `"/target`"`nheaders = []`n"
    $null = & $cli 'meps/override-host' -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 2 -and $server.Requests.Count -eq $beforeRequests) 'Interface base_url must be a string'
    $null = & $cli create 'meps/updateEstateClaim'
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $sandbox 'interface\meps\updateEstateClaim\request.toml'))) 'Nested interface scaffolding works'
    $out = @(& $cli test -NoDotEnv)
    Assert-True ($LASTEXITCODE -eq 0) 'Real curl GET succeeds'
    Assert-True (($out -join "`n") -notmatch 'RESPONSE-SECRET|RESPONSE-REFRESH|COOKIE-SECRET') 'Terminal redacts response secrets'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/fail"
    Assert-True ($LASTEXITCODE -eq 22) 'HTTP 500 fails'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/missing" -ExpectedStatus 404
    Assert-True ($LASTEXITCODE -eq 0) 'Explicit expected 404 succeeds'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/redirect"
    Assert-True ($LASTEXITCODE -eq 22) 'Redirect is not followed'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/slow" -TimeoutSeconds 1
    Assert-True ($LASTEXITCODE -eq 28) 'Timeout exit preserved'
    $closedListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $closedListener.Start(); $closedPort = $closedListener.LocalEndpoint.Port; $closedListener.Stop()
    $null = & $cli test -NoDotEnv -Url ('http://127.0.0.1:' + $closedPort) -TimeoutSeconds 3
    Assert-True ($LASTEXITCODE -eq 7) 'Connection failure exit preserved'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/chunked" -MaxResponseBytes 512
    Assert-True ($LASTEXITCODE -eq 63) 'Chunked response size limit enforced'
    $null = & $cli test -NoDotEnv -Method HEAD
    Assert-True ($LASTEXITCODE -eq 0) 'HEAD uses curl head mode'
    $payloadText = '{"name":"' + [char]0x00e9 + '","quote":"a\"b"}'
    $out = @(& $cli test -NoDotEnv -Url "$baseUrl/echo" -Method POST -Body $payloadText -Header 'X-Quoted: "a b"' -Save -DebugMode)
    Assert-True ($LASTEXITCODE -eq 0) 'Quoted UTF-8 inline POST and report succeed'
    $bodies = $server.Bodies.ToArray(); $lastBody = $bodies[$bodies.Length - 1]
    Assert-True ([Text.Encoding]::UTF8.GetString($lastBody) -ceq $payloadText) 'Payload bytes preserved without BOM/newline'
    $requests = $server.Requests.ToArray()
    Assert-True ($requests[$requests.Length - 1].Contains('X-Quoted: "a b"')) 'Native header quoting preserved'
    $reports = @(Get-ChildItem -LiteralPath (Join-Path $sandbox 'runs') -File -Recurse)
    Assert-True ($reports.Count -eq 1) 'Report created'
    $report = Read-Utf8 $reports[0].FullName
    Assert-True ($report -match '> POST' -and $report -notmatch 'COOKIE-SECRET') 'Report includes real redacted diagnostics'
    Assert-True ($report.Contains('HTTP 200 |') -and -not ($report -match '\*\*(PASS|FAIL)\*\*') -and $report.Contains('| Field | Value |') -and $report.Contains('~~~json')) 'Report has factual summary, tables and JSON code blocks without a verdict'
    Assert-True ($report -match '"name"\s*:' -and $report -match '\{\r?\n\s+"name"') 'Report request and response JSON is indented'
    Assert-True (-not $report.Contains([string][char]27)) 'Saved report contains no terminal colors'
    $out = @(& $cli test -NoDotEnv -Url "$baseUrl/large")
    Assert-True (($out -join "`n") -match 'omitted') 'Large response bounded in CLI'
    $out = @(& $cli test -NoDotEnv -Url "$baseUrl/binary")
    Assert-True (($out -join "`n") -match 'omitted') 'Binary response safely omitted'
    $null = & $cli test -NoDotEnv -Url "$baseUrl/echo" -Method POST -Body ''
    Assert-True ($LASTEXITCODE -eq 0) 'Explicit empty body accepted'

    # Config errors must stop before HTTP and produce a stable failure exit.
    $beforeRequests = $server.Requests.Count
    $null = & $cli test -NoDotEnv -Env does-not-exist
    Assert-True ($LASTEXITCODE -eq 2) 'Unknown environment fails'
    $null = & $cli test -NoDotEnv -Header 'X-Value: {{MISSING_TEST_PLACEHOLDER_824}}'
    Assert-True ($LASTEXITCODE -eq 2) 'CLI unresolved placeholder fails'
    $null = & $cli test -NoDotEnv -Header "X-Value: ok`r`nInjected: yes"
    Assert-True ($LASTEXITCODE -eq 2) 'CLI header injection fails'
    $null = & $cli test -NoDotEnv -ExpectedStatus 99
    Assert-True ($LASTEXITCODE -eq 2) 'Invalid status fails'
    $null = & $cli test -NoDotEnv -Payload '..\..\outside.json'
    Assert-True ($LASTEXITCODE -eq 2) 'CLI payload traversal fails'
    Write-Utf8 $requestFile "method = `"GET`"`npath = `"/`"`nheaders = `"invalid-array`"`n"
    $null = & $cli test -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 2) 'Wrong configuration type fails'
    Assert-True ($server.Requests.Count -eq $beforeRequests) 'Invalid inputs send no HTTP requests'

    Write-Utf8 $requestFile "method = `"GET`"`npath = `"/missing`"`nexpected_status = [404]`nheaders = []`n"
    $null = & $cli test -NoDotEnv
    Assert-True ($LASTEXITCODE -eq 0) 'Request expected_status applies'
    $null = & $cli test -NoDotEnv -ExpectedStatus 200
    Assert-True ($LASTEXITCODE -eq 22) 'CLI expected statuses override request'
    Write-Utf8 $requestFile "method = `"POST`"`npath = `"/echo`"`nheaders = [`"X-Value: {{API_TEST_FIXTURE_VALUE}}`"]`n"
    Write-Utf8 (Join-Path $sandbox '.env') "API_TEST_FIXTURE_VALUE=dotenv-value`n"
    Write-Utf8 (Join-Path $sandbox 'config.toml') "[defaults]`nAPI_TEST_FIXTURE_VALUE = `"default-value`"`n[environments.test]`nbase_url = `"$baseUrl`"`n[environments.test.values]`nAPI_TEST_FIXTURE_VALUE = `"environment-value`"`n"
    $oldFixtureValue = [Environment]::GetEnvironmentVariable('API_TEST_FIXTURE_VALUE')
    try {
        Remove-Item -LiteralPath Env:API_TEST_FIXTURE_VALUE -ErrorAction SilentlyContinue
        $null = & $cli test -NoDotEnv
        $requests = $server.Requests.ToArray()
        Assert-True ($requests[$requests.Length - 1].Contains('X-Value: environment-value')) 'Environment values override defaults'
        $null = & $cli test
        $requests = $server.Requests.ToArray()
        Assert-True ($requests[$requests.Length - 1].Contains('X-Value: dotenv-value')) 'Dotenv overrides non-secret config'
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable('API_TEST_FIXTURE_VALUE')) 'Dotenv does not mutate process environment'
        $env:API_TEST_FIXTURE_VALUE = 'process-value'
        $null = & $cli test
        $requests = $server.Requests.ToArray()
        Assert-True ($requests[$requests.Length - 1].Contains('X-Value: dotenv-value')) 'Dotenv overrides ambient process environment'
        $null = & $cli test -Set 'API_TEST_FIXTURE_VALUE=override-value' -Header 'X-Value: header-value'
        $requests = $server.Requests.ToArray()
        Assert-True ($requests[$requests.Length - 1].Contains('X-Value: header-value')) 'CLI header replaces configured header'
        $payloadFile = Join-Path $sandbox 'interface\test\payloads\template.json'
        Write-Utf8 $payloadFile '{"custom":"{{API_TEST_FIXTURE_VALUE}}"}'
        $out = @(& $cli test -Payload template.json -Set 'API_TEST_FIXTURE_VALUE=OVERRIDE-SECRET' -Save -DebugMode)
        Assert-True ($LASTEXITCODE -eq 0 -and ($out -join "`n") -notmatch 'OVERRIDE-SECRET') 'Templated payload and debug output redact override secret'
        $bodies = $server.Bodies.ToArray()
        Assert-True ([Text.Encoding]::UTF8.GetString($bodies[$bodies.Length - 1]) -eq '{"custom":"OVERRIDE-SECRET"}') 'Set overrides process values and payload bytes are correct'
        foreach ($saved in @(Get-ChildItem -LiteralPath (Join-Path $sandbox 'runs') -File -Recurse)) {
            Assert-True ((Read-Utf8 $saved.FullName) -notmatch 'OVERRIDE-SECRET|RESPONSE-SECRET|COOKIE-SECRET') 'Saved reports contain no fixture secrets'
        }
        $rawFile = Join-Path $sandbox 'interface\test\payloads\raw.bin'
        [IO.File]::WriteAllBytes($rawFile, [byte[]]@(0,255,1,2))
        $null = & $cli test -Payload raw.bin -RawPayload
        $bodies = $server.Bodies.ToArray()
        Assert-True ($LASTEXITCODE -eq 0 -and [BitConverter]::ToString($bodies[$bodies.Length - 1]) -eq '00-FF-01-02') 'Raw payload preserves binary bytes'
        $null = & $cli test -Payload missing.json -Body 'body-wins'
        Assert-True ($LASTEXITCODE -eq 0) 'Body override bypasses unused payload lookup'
    } finally {
        if ($null -eq $oldFixtureValue) { Remove-Item -LiteralPath Env:API_TEST_FIXTURE_VALUE -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable('API_TEST_FIXTURE_VALUE', $oldFixtureValue) }
    }
    $null = & $cli create example-new
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $sandbox 'interface\example-new\request.toml'))) 'Scaffolding works'
    Write-Output "All $script:checks checks passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    if ($server) { $server.Dispose() }
    if ($null -eq $oldNoProxy) { Remove-Item -LiteralPath Env:NO_PROXY -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable('NO_PROXY', $oldNoProxy) }
    Remove-PrivateTempDirectory $temp
}
