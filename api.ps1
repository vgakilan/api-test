[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Environment,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Request,

    [Parameter(Position = 2)]
    [string]$Body,

    [switch]$Save
)

$root = $PSScriptRoot
$environmentFile = Join-Path $root "environments\$Environment.ps1"
$requestFile = Join-Path $root "requests\$Request.ps1"

if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
    throw "Environment file not found: $environmentFile"
}

if (-not (Test-Path -LiteralPath $requestFile -PathType Leaf)) {
    throw "Request file not found: $requestFile"
}

. $environmentFile
$env:API_ENVIRONMENT = $Environment
$env:API_REQUEST = $Request

$requestArguments = @{}
if ($Save) { $requestArguments.SaveReport = $true }
if ($DebugPreference -eq "Continue") { $requestArguments.DebugMode = $true }
if ($Body) {
    if ([System.IO.Path]::IsPathRooted($Body)) {
        $bodyPath = $Body
    } else {
        $bodyPath = Join-Path $root $Body
        if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
            $bodyLeaf = Split-Path -Leaf $Body
            $bodyExtension = [System.IO.Path]::GetExtension($bodyLeaf)
            $bodyStem = [System.IO.Path]::GetFileNameWithoutExtension($bodyLeaf)
            $matches = @(Get-ChildItem -LiteralPath (Join-Path $root "bodies") -Recurse -File | Where-Object {
                if ($bodyExtension) { $_.Name -eq $bodyLeaf } else { $_.BaseName -eq $bodyStem }
            })

            if ($matches.Count -eq 1) {
                $bodyPath = $matches[0].FullName
            } elseif ($matches.Count -eq 0) {
                throw "Body file not found: $Body"
            } else {
                throw "Multiple body files found for '$bodyStem'. Use a relative or absolute path."
            }
        }
    }

    if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
        throw "Body file not found: $bodyPath"
    }
    $requestArguments.BodyFile = (Resolve-Path -LiteralPath $bodyPath).Path
}

& $requestFile @requestArguments
exit $LASTEXITCODE
