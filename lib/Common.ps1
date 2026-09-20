Set-StrictMode -Version Latest

function Stop-ApiValidation([string]$Message) {
    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['ApiSafeMessage'] = $Message
    throw $exception
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Read-Utf8([string]$Path) {
    $reader = New-Object IO.StreamReader($Path, (New-Object Text.UTF8Encoding($false, $true)), $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-Value([hashtable]$Map, [string]$Key, $Default = $null) {
    if ($Map.ContainsKey($Key)) { return $Map[$Key] }
    return $Default
}

function Assert-Keys([hashtable]$Map, [string[]]$Allowed, [string]$Context) {
    foreach ($key in $Map.Keys) { if ($key -notin $Allowed) { Stop-ApiValidation "Unknown key in $Context." } }
}

function Assert-InterfaceName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { Stop-ApiValidation 'Invalid interface name.' }
}

function Get-TomlTokens([string]$Text) {
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq "`r" -or $c -eq ' ' -or $c -eq "`t") { $i++; continue }
        if ($c -eq '#') { while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq "`n" -or '[]=,'.IndexOf($c) -ge 0) {
            $tokens.Add(@{ Kind = [string]$c; Value = [string]$c }); $i++; continue
        }
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c; $start = $i; $i++; $closed = $false
            while ($i -lt $Text.Length) {
                if ([int]$Text[$i] -lt 32) { Stop-ApiValidation 'Control character in TOML string.' }
                if ($Text[$i] -eq $quote) { $closed = $true; $i++; break }
                if ($quote -eq '"' -and $Text[$i] -eq '\') { $i++; if ($i -ge $Text.Length) { break } }
                $i++
            }
            if (-not $closed) { Stop-ApiValidation 'Unterminated TOML string.' }
            $raw = $Text.Substring($start, $i - $start)
            if ($quote -eq '"') { $value = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
            else { $value = $raw.Substring(1, $raw.Length - 2) }
            $tokens.Add(@{ Kind = 'string'; Value = [string]$value }); continue
        }
        $start = $i
        while ($i -lt $Text.Length -and -not [char]::IsWhiteSpace($Text[$i]) -and '[]=,#'.IndexOf($Text[$i]) -lt 0) { $i++ }
        if ($start -eq $i) { Stop-ApiValidation 'Invalid TOML token.' }
        $tokens.Add(@{ Kind = 'bare'; Value = $Text.Substring($start, $i - $start) })
    }
    $tokens.Add(@{ Kind = 'eof'; Value = '' })
    return ,$tokens.ToArray()
}

function Read-TomlScalar($Token) {
    if ($Token.Kind -eq 'string') { return $Token.Value }
    if ($Token.Kind -ne 'bare') { Stop-ApiValidation 'Expected TOML scalar.' }
    if ($Token.Value -ceq 'true') { return $true }
    if ($Token.Value -ceq 'false') { return $false }
    if ($Token.Value -match '^-?(0|[1-9][0-9]*)$') { return [long]::Parse($Token.Value, [Globalization.CultureInfo]::InvariantCulture) }
    Stop-ApiValidation 'Unsupported TOML value; strings must be quoted.'
}

function Read-ApiToml([string]$Path) {
    if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 1048576) { Stop-ApiValidation 'TOML exceeds 1 MiB.' }
    $tokens = Get-TomlTokens (Read-Utf8 $Path)
    $root = @{}; $section = $root; $sections = @{}; $i = 0
    while ($tokens[$i].Kind -ne 'eof') {
        if ($tokens[$i].Kind -eq "`n") { $i++; continue }
        if ($tokens[$i].Kind -eq '[') {
            $i++; $name = $tokens[$i].Value
            if ($tokens[$i].Kind -ne 'bare' -or $name -notmatch '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$') { Stop-ApiValidation 'Invalid TOML table.' }
            if ($sections.ContainsKey($name)) { Stop-ApiValidation 'Duplicate TOML table.' }; $sections[$name] = $true
            $i++; if ($tokens[$i].Kind -ne ']') { Stop-ApiValidation 'Invalid TOML table terminator.' }; $i++
            $section = $root
            foreach ($part in $name.Split('.')) {
                if (-not $section.ContainsKey($part)) { $section[$part] = @{} }
                if ($section[$part] -isnot [hashtable]) { Stop-ApiValidation 'TOML table conflicts with a value.' }
                $section = $section[$part]
            }
        } else {
            $key = $tokens[$i].Value
            if ($tokens[$i].Kind -ne 'bare' -or $key -notmatch '^[A-Za-z0-9_-]+$') { Stop-ApiValidation 'Invalid TOML key.' }
            if ($section.ContainsKey($key)) { Stop-ApiValidation 'Duplicate TOML key.' }
            $i++; if ($tokens[$i].Kind -ne '=') { Stop-ApiValidation 'Missing TOML assignment.' }; $i++
            if ($tokens[$i].Kind -eq '[') {
                $i++; $items = New-Object 'System.Collections.Generic.List[object]'
                while ($true) {
                    while ($tokens[$i].Kind -eq "`n") { $i++ }
                    if ($tokens[$i].Kind -eq ']') { $i++; break }
                    $items.Add((Read-TomlScalar $tokens[$i])); $i++
                    while ($tokens[$i].Kind -eq "`n") { $i++ }
                    if ($tokens[$i].Kind -eq ']') { $i++; break }
                    if ($tokens[$i].Kind -ne ',') { Stop-ApiValidation 'Expected TOML array separator.' }; $i++
                }
                $section[$key] = $items.ToArray()
            } else { $section[$key] = Read-TomlScalar $tokens[$i]; $i++ }
        }
        if ($tokens[$i].Kind -notin @("`n",'eof')) { Stop-ApiValidation 'Unexpected TOML content.' }
    }
    return $root
}

function Get-StringArray([hashtable]$Map, [string]$Key) {
    if (-not $Map.ContainsKey($Key)) { return }
    if ($Map[$Key] -isnot [array]) { Stop-ApiValidation 'Headers and query must be arrays.' }
    foreach ($item in $Map[$Key]) { if ($item -isnot [string]) { Stop-ApiValidation 'Headers and query must contain strings.' }; $item }
}

function Read-ApiDotEnv([string]$Path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { Stop-ApiValidation 'Dotenv exceeds 1 MiB.' }
    foreach ($line in ((Read-Utf8 $Path) -split '\r?\n')) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { Stop-ApiValidation 'Invalid dotenv entry.' }
        $key = $matches[1]; $value = $matches[2].Trim()
        if ($result.ContainsKey($key)) { Stop-ApiValidation 'Duplicate dotenv entry.' }
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            if ($value.Length -lt 2 -or $value[$value.Length - 1] -ne $value[0]) { Stop-ApiValidation 'Unterminated dotenv value.' }
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

function Expand-ApiValue([string]$Text, [hashtable]$Values, [System.Collections.Generic.List[string]]$Secrets) {
    $expanded = [regex]::Replace($Text, '\{\{\s*([^}]+?)\s*\}\}', {
        param($match)
        $name = $match.Groups[1].Value
        if (-not $Values.ContainsKey($name)) { Stop-ApiValidation 'Unresolved placeholder.' }
        $value = [string]$Values[$name]
        if ($value -match '\{\{') { Stop-ApiValidation 'Nested placeholders are unsupported.' }
        if ($null -ne $Secrets) { $Secrets.Add($value) }
        return $value
    })
    if ($expanded.Contains('{{')) { Stop-ApiValidation 'Malformed or unresolved placeholder.' }
    return $expanded
}

function Add-ApiQuery([string]$Url, [string[]]$Items, [hashtable]$Values, [System.Collections.Generic.List[string]]$Secrets) {
    $uri = $null
    if ($Url -match '[\x00-\x20\x7f]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Fragment) { Stop-ApiValidation 'URL must be HTTP(S), without credentials, fragments or whitespace.' }
    foreach ($item in $Items) {
        $parts = $item -split '=', 2
        if ($parts.Count -ne 2 -or -not $parts[0]) { Stop-ApiValidation 'Query entries must use name=value.' }
        $key = [Uri]::EscapeDataString((Expand-ApiValue $parts[0] $Values $Secrets))
        $value = [Uri]::EscapeDataString((Expand-ApiValue $parts[1] $Values $Secrets))
        $separator = if ($Url.Contains('?')) { if ($Url.EndsWith('?') -or $Url.EndsWith('&')) { '' } else { '&' } } else { '?' }
        $Url += "$separator$key=$value"
    }
    return $Url
}

function Merge-ApiHeaders([string[]]$Configured, [string[]]$Overrides, [hashtable]$Values, [System.Collections.Generic.List[string]]$Secrets) {
    $headers = [ordered]@{}
    foreach ($line in @($Configured) + @($Overrides)) {
        $line = Expand-ApiValue $line $Values $Secrets
        if ($line -match '[\x00-\x1f\x7f]' -or $line -notmatch '^([!#$%&''*+.^_`|~0-9A-Za-z-]+):\s*(.*)$') { Stop-ApiValidation 'Invalid HTTP header.' }
        $name = $matches[1]; $value = $matches[2]
        if ($name -in @('Content-Length','Transfer-Encoding')) { Stop-ApiValidation 'curl manages framing headers.' }
        if ($name -match '(?i)authorization|cookie|token|secret|password|api.?key') { $Secrets.Add($value) }
        $headers[$name] = $value
    }
    if ($headers.Count -gt 100 -or (($headers.GetEnumerator() | ForEach-Object { $_.Key.Length + $_.Value.Length } | Measure-Object -Sum).Sum -gt 65536)) { Stop-ApiValidation 'Headers exceed 100 entries or 64 KiB.' }
    foreach ($name in $headers.Keys) {
        if ($headers[$name] -eq '') { "$name;" } else { '{0}: {1}' -f $name, $headers[$name] }
    }
}

function Find-ApiPayload([string]$InterfacePath, [string]$Name) {
    $payloadRoot = [IO.Path]::GetFullPath((Join-Path $InterfacePath 'payloads')) + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $payloadRoot $Name))
    if (-not $candidate.StartsWith($payloadRoot, [StringComparison]::OrdinalIgnoreCase)) { Stop-ApiValidation 'Payload must stay inside the interface payloads directory; use -Body for external files.' }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $found = @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse | Where-Object { $_.Name -eq $Name -or $_.BaseName -eq $Name })
    if ($found.Count -ne 1) { Stop-ApiValidation 'Payload missing or ambiguous.' }
    return $found[0].FullName
}

function New-PrivateTempDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('api-test-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path
    try {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
        return $path
    } catch { Remove-Item -LiteralPath $path -Force; throw }
}

function Remove-PrivateTempDirectory([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved) -ne $parent -or (Split-Path -Leaf $resolved) -notmatch '^api-test-[a-f0-9]{32}$') { Stop-ApiValidation 'Refusing unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'Redaction.ps1')
. (Join-Path $PSScriptRoot 'Invoke-Curl.ps1')
