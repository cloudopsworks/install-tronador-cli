$ErrorActionPreference = 'Stop'

$repository = 'cloudopsworks/tronador-cli'
$projectName = 'tronador-cli'
$binaryName = 'tronador.exe'
$requestedVersion = $env:INPUT_VERSION
$installDir = $env:INPUT_INSTALL_DIR

function Fail([string]$Message) {
    throw "Error: $Message"
}

function Resolve-Tag([string]$Version) {
    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'latest') {
        $tag = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest").tag_name
        if ([string]::IsNullOrWhiteSpace($tag)) {
            Fail 'Unable to resolve the latest stable Tronador release'
        }
        return $tag
    }

    if ($Version -notmatch '^[0-9A-Za-z._-]+$') {
        Fail "Version must be 'latest' or a release tag containing only letters, numbers, dots, underscores, and hyphens"
    }

    if ($Version.StartsWith('v')) {
        return $Version
    }

    return "v$Version"
}

function Resolve-Architecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()) {
        'x64' { return 'amd64' }
        'arm64' { return 'arm64' }
        default { Fail "Unsupported Windows architecture: $($_)" }
    }
}

function Write-GitHubOutput([string]$Key, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Key=$Value"
    }
}

if ([string]::IsNullOrWhiteSpace($installDir)) {
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $installDir = Join-Path ([System.IO.Path]::GetTempPath()) 'tronador-cli/bin'
    } else {
        $installDir = Join-Path $env:RUNNER_TEMP 'tronador-cli/bin'
    }
}
if ($installDir -match "[\r\n]") {
    Fail 'install-dir must not contain a newline'
}
if (-not [System.IO.Path]::IsPathFullyQualified($installDir)) {
    Fail 'install-dir must be an absolute path'
}

$tag = Resolve-Tag $requestedVersion
$assetVersion = $tag.TrimStart('v')
$architecture = Resolve-Architecture
$archive = "${projectName}_${assetVersion}_windows_${architecture}.zip"
$checksums = "${projectName}_${assetVersion}_SHA256SUMS"
$baseUrl = "https://github.com/$repository/releases/download/$tag"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tronador-cli-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $archivePath = Join-Path $tempDir $archive
    $checksumsPath = Join-Path $tempDir $checksums
    $extractDir = Join-Path $tempDir 'extract'

    Write-Host "Downloading Tronador $tag for windows/$architecture"
    Invoke-WebRequest -Uri "$baseUrl/$archive" -OutFile $archivePath
    Invoke-WebRequest -Uri "$baseUrl/$checksums" -OutFile $checksumsPath

    $escapedArchive = [regex]::Escape($archive)
    $expected = Get-Content -Path $checksumsPath | ForEach-Object {
        if ($_ -match "^\s*([0-9a-fA-F]{64})\s+\*?$escapedArchive\s*$") { $Matches[1] }
    } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($expected)) {
        Fail "Checksum for $archive was not found in $checksums"
    }

    $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected.ToLowerInvariant() -ne $actual) {
        Fail "Checksum verification failed for $archive"
    }

    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
    $binary = Get-ChildItem -Path $extractDir -File -Recurse | Where-Object { $_.Name -eq $binaryName } | Select-Object -First 1
    if ($null -eq $binary) {
        Fail "Unable to find $binaryName in $archive"
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path $binary.FullName -Destination (Join-Path $installDir $binaryName) -Force

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
        Add-Content -Path $env:GITHUB_PATH -Value $installDir
    }
    Write-GitHubOutput 'version' $tag
    Write-GitHubOutput 'path' (Join-Path $installDir $binaryName)
    Write-Host "Installed $binaryName $tag to $(Join-Path $installDir $binaryName)"
}
finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
