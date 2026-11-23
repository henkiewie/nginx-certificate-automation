param(
    [switch]$Apply,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$ExpectedTargetAddress = "192.168.178.200"
$CertificateName = "remote.selfip.net"
$CertificateFolder = "C:\nginx\certstore"
$CertificatePath = Join-Path $CertificateFolder "$CertificateName-crt.pem"
$ExpectedChainPath = "C:\nginx\certstore\remote.selfip.net-chain.pem"
$ExpectedKeyPath = "C:\nginx\certstore\remote.selfip.net-key.pem"
$NginxFolder = "C:\nginx"
$NginxPath = "C:\nginx\nginx.exe"
$PsExecPath = "C:\tools\PsExec.exe"
$StateFolder = Join-Path $CertificateFolder "reconciliation-state"
$AppliedStatePath = Join-Path $StateFolder "applied.json"
$PendingStatePath = Join-Path $StateFolder "pending.json"
$LogPath = "C:\nginx\certificate-health-test.log"
$CertificateFiles = @(
    "$CertificateName-key.pem",
    "$CertificateName-chain-only.pem",
    "$CertificateName-crt.pem",
    "$CertificateName-chain.pem"
)

function Write-HealthLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-FileFingerprint {
    $hashes = foreach ($file in $CertificateFiles) {
        $path = Join-Path $CertificateFolder $file
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing certificate file: $path" }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($hashes -join "|"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
    finally { $sha.Dispose() }
}

function Invoke-NginxCommand {
    param([string[]]$Arguments)

    # PsExec writes normal status messages to stderr. With the script-wide
    # Stop preference PowerShell would convert the first of those messages
    # into a terminating NativeCommandError before LASTEXITCODE can be read.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $PsExecPath -accepteula -nobanner -s $NginxPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $output) {
        if ($line) { Write-HealthLog "       $line" }
    }
    return $exitCode
}

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
if ($ExpectedTargetAddress -notin $localAddresses) {
    throw "Safety stop: this script may run only on $ExpectedTargetAddress."
}

Write-HealthLog "========================================================"
Write-HealthLog "TARGET CERTIFICATE HEALTH TEST: .200"
Write-HealthLog "Mode: $(if ($Apply) { 'APPLY' } else { 'READ-ONLY AUDIT' })"
Write-HealthLog "========================================================"

if (-not (Test-Path -LiteralPath $NginxPath)) { throw "nginx is missing: $NginxPath" }
if (-not (Test-Path -LiteralPath $PsExecPath)) { throw "PsExec is missing: $PsExecPath" }

$pem = Get-Content -LiteralPath $CertificatePath -Raw
$match = [regex]::Match(
    $pem,
    "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $match.Success) { throw "No certificate was found in $CertificatePath" }
$bytes = [Convert]::FromBase64String(($match.Groups[1].Value -replace "\s", ""))
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
$remainingDays = [Math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
if (
    $certificate.Subject -notmatch "CN=remote\.selfip\.net(?:,|$)" -or
    $certificate.NotBefore -gt (Get-Date) -or
    $remainingDays -lt $MinimumRemainingDays
) {
    throw "The local certificate is not safe to load."
}

$configurationFiles = Get-ChildItem -LiteralPath "C:\nginx\conf\sites-enabled" -Filter "*.conf" -File
$chainReferences = @()
$keyReferences = @()
$listenerPorts = @()
foreach ($configurationFile in $configurationFiles) {
    foreach ($line in (Get-Content -LiteralPath $configurationFile.FullName)) {
        if ($line -match "^\s*ssl_certificate\s+([^;]+);") { $chainReferences += $matches[1].Trim() }
        if ($line -match "^\s*ssl_certificate_key\s+([^;]+);") { $keyReferences += $matches[1].Trim() }
        if ($line -match "^\s*listen\s+([0-9]+)\b") { $listenerPorts += [int]$matches[1] }
    }
}

$normalizedExpectedChain = $ExpectedChainPath.Replace("\", "/").ToLowerInvariant()
$normalizedExpectedKey = $ExpectedKeyPath.Replace("\", "/").ToLowerInvariant()
foreach ($reference in $chainReferences) {
    if ($reference.Replace("\", "/").ToLowerInvariant() -ne $normalizedExpectedChain) {
        throw "Unexpected ssl_certificate reference: $reference"
    }
}
foreach ($reference in $keyReferences) {
    if ($reference.Replace("\", "/").ToLowerInvariant() -ne $normalizedExpectedKey) {
        throw "Unexpected ssl_certificate_key reference: $reference"
    }
}
if ($chainReferences.Count -eq 0 -or $keyReferences.Count -eq 0) {
    throw "No active nginx certificate references were found."
}

$fingerprint = Get-FileFingerprint
Write-HealthLog "Certificate thumbprint: $($certificate.Thumbprint)"
Write-HealthLog "Certificate expires: $($certificate.NotAfter)"
Write-HealthLog "Certificate remaining days: $remainingDays"
Write-HealthLog "Configured listeners: $((@($listenerPorts | Sort-Object -Unique)) -join ', ')"

$testExitCode = Invoke-NginxCommand -Arguments @("-p", "C:\nginx\", "-t")
if ($testExitCode -ne 0) { throw "nginx validation failed with exit code $testExitCode." }
Write-HealthLog "[ OK ] nginx configuration and certificate/key pair validated."

if (-not $Apply) {
    Write-HealthLog "[AUDIT] No reload or state change was performed."
    exit 0
}

$appliedFingerprint = ""
if (Test-Path -LiteralPath $AppliedStatePath) {
    try { $appliedFingerprint = (Get-Content -LiteralPath $AppliedStatePath -Raw | ConvertFrom-Json).Fingerprint }
    catch { Write-HealthLog "[WARN] Existing applied state could not be read; a reload will be performed." }
}

if ($appliedFingerprint -eq $fingerprint) {
    Write-HealthLog "[ OK ] This exact certificate set was already applied; reload not required."
    exit 0
}

$reloadExitCode = Invoke-NginxCommand -Arguments @("-p", "C:\nginx\", "-s", "reload")
if ($reloadExitCode -ne 0) { throw "nginx reload failed with exit code $reloadExitCode." }

New-Item -ItemType Directory -Path $StateFolder -Force | Out-Null
$state = [PSCustomObject]@{
    CertificateThumbprint = $certificate.Thumbprint
    Fingerprint = $fingerprint
    AppliedAt = (Get-Date).ToString("o")
    ListenerPorts = @($listenerPorts | Sort-Object -Unique)
}
$state | ConvertTo-Json | Set-Content -LiteralPath $AppliedStatePath -Encoding UTF8
if (Test-Path -LiteralPath $PendingStatePath) {
    Remove-Item -LiteralPath $PendingStatePath -Force
}

Write-HealthLog "[ OK ] nginx reloaded through PsExec/SYSTEM and applied state was recorded."
