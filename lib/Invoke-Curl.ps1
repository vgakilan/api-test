function Format-ApiJson([string]$Text) {
    # This receives only a sanitized preview, never the raw response.
    if ($Text.TrimStart().StartsWith('{') -or $Text.TrimStart().StartsWith('[')) {
        try {
            $wrapper = ConvertFrom-Json -InputObject ('{"value":' + $Text + '}') -ErrorAction Stop
            return ConvertTo-Json -InputObject $wrapper.value -Depth 100 -ErrorAction Stop -WarningAction Stop
        } catch { }
    }
    return $Text
}

function ConvertTo-CurlConfigValue([string]$Value) {
    if ($Value -match '[\x00-\x1f\x7f]') { Stop-ApiValidation 'Control characters are not allowed in curl options.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Invoke-ApiCurl {
    param(
        [string]$RequestUrl, [string]$Method, [string[]]$Headers, [string]$BodyFile,
        [int[]]$ExpectedStatus, [int]$TimeoutSeconds, [int]$ConnectTimeoutSeconds,
        [long]$MaxResponseBytes, [string]$TemporaryDirectory, [string[]]$SecretValues,
        [switch]$SaveReport, [switch]$DebugMode, [string]$RequestName,
        [string]$ServiceName, [string]$EnvironmentName, [string]$ReportRoot
    )
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $versionText = & $curl.Source --disable --version
    if ($LASTEXITCODE -ne 0 -or $versionText[0] -notmatch '^curl (\d+\.\d+\.\d+)' -or [version]$matches[1] -lt [version]'8.4.0') { Stop-ApiValidation 'curl 8.4.0 or newer is required.' }
    $started = Get-Date
    $headersPath = Join-Path $TemporaryDirectory 'response-headers'
    $bodyPath = Join-Path $TemporaryDirectory 'response-body'
    $options = New-Object 'System.Collections.Generic.List[string]'
    foreach ($flag in @('silent','show-error','globoff')) { $options.Add($flag) }
    $options.Add('proto = "=http,https"')
    $options.Add('connect-timeout = ' + $ConnectTimeoutSeconds)
    $options.Add('max-time = ' + $TimeoutSeconds)
    $options.Add('max-filesize = ' + $MaxResponseBytes)
    $options.Add('dump-header = ' + (ConvertTo-CurlConfigValue $headersPath))
    $options.Add('output = ' + (ConvertTo-CurlConfigValue $bodyPath))
    $options.Add('write-out = "%{http_code}|%{time_total}|%{size_download}"')
    if ($Method -eq 'HEAD') { $options.Add('head') } else { $options.Add('request = ' + (ConvertTo-CurlConfigValue $Method)) }
    $options.Add('url = ' + (ConvertTo-CurlConfigValue $RequestUrl))
    foreach ($header in $Headers) { $options.Add('header = ' + (ConvertTo-CurlConfigValue $header)) }
    if ($BodyFile) { $options.Add('data-binary = ' + (ConvertTo-CurlConfigValue ('@' + $BodyFile))) }
    if ($DebugMode) { $options.Add('verbose') }

    # Only fixed arguments are visible in the process list. Sensitive options go over stdin.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $curl.Source
    $startInfo.Arguments = '--disable --config -'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedProcess = $false
    try {
        $startedProcess = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $configBytes = [Text.Encoding]::UTF8.GetBytes(($options -join "`n") + "`n")
        $process.StandardInput.BaseStream.Write($configBytes, 0, $configBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(($TimeoutSeconds + 5) * 1000)) {
            $process.Kill(); $process.WaitForExit(); $curlExit = 28
        } else { $curlExit = $process.ExitCode }
        $metrics = $stdoutTask.GetAwaiter().GetResult().Trim()
        $diagnostics = $stderrTask.GetAwaiter().GetResult()
    } finally {
        if ($startedProcess -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $status = 0; $duration = 'unavailable'; $downloaded = 'unavailable'
    if ($metrics -match '^(\d{3})\|([0-9.]+)\|([0-9]+)$') {
        $status = [int]$matches[1]; $duration = $matches[2]; $downloaded = $matches[3]
    } elseif ($curlExit -eq 0) { $curlExit = 2 }
    $exitCode = $curlExit
    if ($exitCode -eq 0 -and $status -notin $ExpectedStatus) { $exitCode = 22 }
    $responseHeaders = Read-SafePreview $headersPath $SecretValues -Headers
    $responseBody = if ($Method -eq 'HEAD') { '(HEAD response has no body)' } else { Read-SafePreview $bodyPath $SecretValues }
    $responseBody = Format-ApiJson $responseBody
    $displayBody = $responseBody
    $bat = Get-Command bat.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bat) {
        try {
            # A UTF-8 file avoids Windows PowerShell's lossy native stdin encoding.
            $displayPath = Join-Path $TemporaryDirectory 'sanitized-preview'
            Write-Utf8 $displayPath $responseBody
            $language = if ($responseBody.TrimStart().StartsWith('<')) { 'xml' } elseif ($responseBody.TrimStart() -match '^[\[{]') { 'json' } else { 'txt' }
            $batArguments = @('--no-config', '--language', $language, '--style', 'plain', '--paging', 'never', '--color', 'always', '--', $displayPath)
            $highlighted = @(& $bat.Source @batArguments 2>$null)
            if ($LASTEXITCODE -eq 0 -and $highlighted.Count -gt 0) { $displayBody = $highlighted -join "`n" }
        } catch { } # Optional highlighting must never prevent readable output.
    }
    $safeDiagnostics = if ($diagnostics.Length -gt 262144) { '(diagnostics omitted: exceeds 256 KiB preview limit)' } else { Protect-ApiText $diagnostics $SecretValues }
    $output = New-Object 'System.Collections.Generic.List[string]'
    $output.Add("=== Response headers ===`n$responseHeaders")
    $output.Add("=== Response body ===`n$displayBody")
    $output.Add("HTTP status: $status`nTime: $duration seconds`nDownloaded: $downloaded bytes`nExit code: $exitCode")
    if ($safeDiagnostics) { $output.Add("=== curl diagnostics ===`n$safeDiagnostics") }
    if ($SaveReport) {
        $directory = Join-Path $ReportRoot $started.ToString('yyyy-MM-dd')
        $null = New-Item -ItemType Directory -Path $directory -Force
        $name = '{0}_{1}_{2}.md' -f $started.ToString('HH-mm-ss-fff'), $RequestName, [guid]::NewGuid().ToString('N')
        $reportPath = Join-Path $directory $name
        $requestBody = if ($BodyFile) { Format-ApiJson (Read-SafePreview $BodyFile $SecretValues) } else { '(none)' }
        $safeUrl = Protect-ApiText $RequestUrl $SecretValues
        $safeHeaders = Protect-ApiText ($Headers -join "`n") $SecretValues
        $safeMetadata = Protect-ApiText "Service: $ServiceName`nInterface: $RequestName`nEnvironment: $EnvironmentName" $SecretValues
        $report = "# API Run Report`n`nHTTP $status | $duration seconds | $downloaded bytes`n`n## Summary`n`n"
        $report += ConvertTo-ReportTable "$safeMetadata`nStarted: $($started.ToString('o'))`nFinished: $((Get-Date).ToString('o'))`nCurl exit code: $curlExit`nResult exit code: $exitCode"
        $report += "`n## Request`n`n" + (ConvertTo-ReportBlock "$Method $safeUrl")
        $report += "`n### Headers`n`n" + (ConvertTo-ReportTable $safeHeaders)
        $report += "`n### Body`n`n" + (ConvertTo-ReportBlock $requestBody (Get-PreviewLanguage $requestBody))
        $report += "`n## Response`n`n### Headers`n`n" + (ConvertTo-ReportTable $responseHeaders)
        $report += "`n### Body`n`n" + (ConvertTo-ReportBlock $responseBody (Get-PreviewLanguage $responseBody))
        if ($safeDiagnostics) { $report += "`n## Curl diagnostics`n`n" + (ConvertTo-ReportBlock $safeDiagnostics) }
        Write-Utf8 $reportPath $report
        $output.Add("Saved report: $reportPath")
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output.ToArray() }
}
