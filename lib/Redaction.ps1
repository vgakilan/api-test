function Protect-JsonNode($Node) {
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -match '(?i)authorization|cookie|token|secret|password|passcode|api[_-]?key|credential') { $property.Value = '[REDACTED]' }
            else { $property.Value = Protect-JsonNode $property.Value }
        }
    } elseif ($Node -is [array]) {
        for ($index = 0; $index -lt $Node.Length; $index++) { $Node[$index] = Protect-JsonNode $Node[$index] }
    }
    return ,$Node
}

function Protect-StructuredText([string]$Text) {
    if ($Text.TrimStart().StartsWith('{') -or $Text.TrimStart().StartsWith('[')) {
        try {
            # Wrapping prevents PowerShell pipeline unrolling of top-level JSON arrays.
            $wrapper = ConvertFrom-Json -InputObject ('{"value":' + $Text + '}') -ErrorAction Stop
            return ConvertTo-Json -InputObject (Protect-JsonNode $wrapper.value) -Depth 100 -Compress -ErrorAction Stop -WarningAction Stop
        } catch { return '(invalid or unsupported JSON omitted)' }
    }
    if ($Text.TrimStart().StartsWith('<')) {
        $reader = $null
        try {
            $settings = New-Object Xml.XmlReaderSettings
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($Text)), $settings)
            $document = New-Object Xml.XmlDocument
            $document.XmlResolver = $null
            $document.PreserveWhitespace = $true
            $document.Load($reader)
            foreach ($node in @($document.SelectNodes('//*'))) {
                if ($node.LocalName -match '(?i)authorization|cookie|token|secret|password|passcode|api[_-]?key|credential') { $node.InnerText = '[REDACTED]' }
                foreach ($attribute in @($node.Attributes)) {
                    if ($attribute.LocalName -match '(?i)authorization|cookie|token|secret|password|passcode|api[_-]?key|credential') { $attribute.Value = '[REDACTED]' }
                }
            }
            return $document.OuterXml
        } catch { return '(invalid or unsupported XML omitted)' }
        finally { if ($reader) { $reader.Dispose() } }
    }
    return $Text
}

function Protect-ApiText([string]$Text, [string[]]$Secrets = @()) {
    if (-not $Text) { return '' }
    $result = [regex]::Replace($Text, '\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|$))', '')
    $result = [regex]::Replace($result, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
    $variants = New-Object 'System.Collections.Generic.List[string]'
    foreach ($secret in $Secrets) {
        if ([string]::IsNullOrEmpty($secret)) { continue }
        $variants.Add($secret)
        $variants.Add([Uri]::EscapeDataString($secret))
        $variants.Add([Security.SecurityElement]::Escape($secret))
        $json = ConvertTo-Json -InputObject $secret -Compress
        $variants.Add($json.Substring(1, $json.Length - 2))
    }
    $patterns = @($variants | Select-Object -Unique | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    if ($patterns.Count -gt 0) { $result = [regex]::Replace($result, ($patterns -join '|'), '[REDACTED]') }
    $sensitive = '[\w.-]*(?:authorization|cookie|token|secret|password|passcode|api[_-]?key|credential)[\w.-]*'
    $result = [regex]::Replace($result, '(?im)^([<>*]?\s*' + $sensitive + '\s*:\s*).*$', '$1[REDACTED]')
    $result = [regex]::Replace($result, '(?i)("' + $sensitive + '"\s*:\s*)("(?:\\.|[^"\\])*"|[^,}\r\n]+)', '$1"[REDACTED]"')
    $result = [regex]::Replace($result, '(?is)(?<open><(?<tag>(?:[\w.-]+:)?' + $sensitive + ')\b[^>]*>).*?(?<close></\k<tag>\s*>)', '${open}[REDACTED]${close}')
    $result = [regex]::Replace($result, '(?i)(\b' + $sensitive + '\s*=\s*)("[^"]*"|''[^'']*''|[^&\s<>]+)', '$1[REDACTED]')
    $result = [regex]::Replace($result, '([?&])([^=&#\s]+)=([^&#\s]*)', {
        param($match)
        $key = [Uri]::UnescapeDataString($match.Groups[2].Value)
        if ($key -match '(?i)authorization|cookie|token|secret|password|passcode|api[_-]?key|credential') { return $match.Groups[1].Value + $match.Groups[2].Value + '=[REDACTED]' }
        return $match.Value
    })
    $result = [regex]::Replace($result, '(?i)(https?://)[^/\s@]+@', '$1[REDACTED]@')
    $result = [regex]::Replace($result, '(?im)^\* (?:Uses proxy env variable|Server auth|Proxy auth).*$', '* [REDACTED authentication/proxy diagnostic]')
    $result = [regex]::Replace($result, '\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|$))', '')
    return [regex]::Replace($result, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
}

function Read-SafePreview([string]$Path, [string[]]$Secrets, [switch]$Headers) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '(empty)' }
    # Omit oversized content entirely: truncation before redaction could expose partial secrets.
    if ((Get-Item -LiteralPath $Path).Length -gt 262144) { return '(content omitted: exceeds 256 KiB preview limit)' }
    try { $text = Read-Utf8 $Path } catch { return '(binary or non-UTF-8 content omitted)' }
    if (-not $text) { return '(empty)' }
    if (-not $Headers -and $text -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { return '(binary content omitted)' }
    if (-not $Headers) { $text = Protect-StructuredText $text }
    return Protect-ApiText $text $Secrets
}

function ConvertTo-ReportBlock([string]$Text, [string]$Language = 'text') {
    # A longer fence prevents response content from closing the code block.
    $length = 3
    foreach ($match in [regex]::Matches($Text, '~+')) { $length = [Math]::Max($length, $match.Length + 1) }
    $fence = '~' * $length
    return "$fence$Language`n$($Text.TrimEnd())`n$fence`n"
}

function ConvertTo-ReportTable([string]$Text) {
    $rows = New-Object 'System.Collections.Generic.List[string]'
    $rows.Add('| Field | Value |')
    $rows.Add('| --- | --- |')
    foreach ($line in ($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^([^:]+):\s*(.*)$') { $name = $matches[1]; $value = $matches[2] }
        else { $name = if ($line -match '^HTTP/') { 'Status' } else { 'Info' }; $value = $line }
        $name = [Security.SecurityElement]::Escape($name).Replace('|', '&#124;').Replace('`', '&#96;')
        $value = [Security.SecurityElement]::Escape($value).Replace('|', '&#124;').Replace('`', '&#96;')
        $rows.Add("| $name | $value |")
    }
    if ($rows.Count -eq 2) { $rows.Add('| (none) | |') }
    return ($rows -join "`n") + "`n"
}

function Get-PreviewLanguage([string]$Text) {
    if ($Text.TrimStart().StartsWith('<')) { return 'xml' }
    if ($Text.TrimStart() -match '^[\[{]') { return 'json' }
    return 'text'
}
