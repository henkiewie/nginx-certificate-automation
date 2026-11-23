param(
    [switch]$Apply,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$ExpectedControllerAddress = "192.168.178.155"
$TargetAddress = "192.168.178.200"
$CertificateName = "remote.selfip.net"
$SourceFolder = "C:\nginx\certstore"
$TargetFolder = "\\$TargetAddress\certstore"
$LogPath = "C:\nginx\certificate-reconciliation-test.log"
$CertificateFiles = @(
    "$CertificateName-key.pem",
    "$CertificateName-chain-only.pem",
    "$CertificateName-crt.pem",
    "$CertificateName-chain.pem"
)

function Write-ReconciliationLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-LocalIPv4Address {
    return @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.AddressState -eq "Preferred" } |
            Select-Object -ExpandProperty IPAddress
    )
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMilliseconds = 1500)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Read-PemCertificate {
    param([string]$Path)

    $pem = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match(
        $pem,
        "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) { throw "No certificate was found in $Path" }
    $bytes = [Convert]::FromBase64String(($match.Groups[1].Value -replace "\s", ""))
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
}

function Get-CertificateStatus {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Exists = $false; Valid = $false; Thumbprint = ""; NotAfter = $null; RemainingDays = -1 }
    }

    try {
        $certificate = Read-PemCertificate -Path $Path
        $now = Get-Date
        return [PSCustomObject]@{
            Exists = $true
            Valid = (
                $certificate.NotBefore -le $now -and
                $certificate.NotAfter -gt $now -and
                $certificate.Subject -match "CN=remote\.selfip\.net(?:,|$)"
            )
            Thumbprint = $certificate.Thumbprint
            NotAfter = $certificate.NotAfter
            RemainingDays = [Math]::Floor(($certificate.NotAfter - $now).TotalDays)
        }
    }
    catch {
        return [PSCustomObject]@{ Exists = $true; Valid = $false; Thumbprint = ""; NotAfter = $null; RemainingDays = -1 }
    }
}

function Get-FileFingerprint {
    param([string]$Folder)

    $hashes = foreach ($file in $CertificateFiles) {
        $path = Join-Path $Folder $file
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $text = $hashes -join "|"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
    finally { $sha.Dispose() }
}

function Assert-HashMatch {
    param([string]$ExpectedPath, [string]$ActualPath, [string]$Description)

    $expected = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
    $actual = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
    if ($expected -ne $actual) { throw "Hash verification failed: $Description" }
}

$localAddresses = Get-LocalIPv4Address
if ($ExpectedControllerAddress -notin $localAddresses) {
    throw "Safety stop: this script may run only on $ExpectedControllerAddress."
}
if ($TargetAddress -ne "192.168.178.200" -or $TargetAddress -eq "192.168.178.185") {
    throw "Safety stop: the only permitted target is 192.168.178.200."
}

Write-ReconciliationLog "========================================================"
Write-ReconciliationLog "SCHEDULED RECONCILIATION TEST: .155 -> .200"
Write-ReconciliationLog "Mode: $(if ($Apply) { 'APPLY' } else { 'READ-ONLY AUDIT' })"
Write-ReconciliationLog "========================================================"

foreach ($file in $CertificateFiles) {
    $sourcePath = Join-Path $SourceFolder $file
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Missing source file: $sourcePath" }
}

$sourceCertificatePath = Join-Path $SourceFolder "$CertificateName-crt.pem"
$sourceStatus = Get-CertificateStatus -Path $sourceCertificatePath
$sourceFingerprint = Get-FileFingerprint -Folder $SourceFolder

Write-ReconciliationLog "Source thumbprint: $($sourceStatus.Thumbprint)"
Write-ReconciliationLog "Source expires: $($sourceStatus.NotAfter)"
Write-ReconciliationLog "Source remaining days: $($sourceStatus.RemainingDays)"

if (-not $sourceStatus.Valid -or $sourceStatus.RemainingDays -lt $MinimumRemainingDays) {
    throw "Source certificate is not safe to propagate."
}

if (-not (Test-TcpPort -ComputerName $TargetAddress -Port 445)) {
    Write-ReconciliationLog "[OFFLINE] .200 or TCP 445 is unavailable; no files were changed."
    exit 0
}
if (-not (Test-Path -LiteralPath $TargetFolder)) {
    throw "Target is online but $TargetFolder is inaccessible under the current account."
}

$targetStatus = Get-CertificateStatus -Path (Join-Path $TargetFolder "$CertificateName-crt.pem")
$targetFingerprint = Get-FileFingerprint -Folder $TargetFolder
$requiresUpdate = (
    -not $targetStatus.Valid -or
    $targetStatus.RemainingDays -lt $MinimumRemainingDays -or
    $targetStatus.Thumbprint -ne $sourceStatus.Thumbprint -or
    $targetFingerprint -ne $sourceFingerprint
)

Write-ReconciliationLog "Target thumbprint: $($targetStatus.Thumbprint)"
Write-ReconciliationLog "Target remaining days: $($targetStatus.RemainingDays)"
Write-ReconciliationLog "All-file fingerprint match: $($targetFingerprint -eq $sourceFingerprint)"

if (-not $requiresUpdate) {
    Write-ReconciliationLog "[ OK ] .200 already has the complete valid certificate set."
    exit 0
}
if (-not $Apply) {
    Write-ReconciliationLog "[AUDIT] .200 requires reconciliation; no files were changed."
    exit 2
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFolder = Join-Path $TargetFolder "reconciliation-backup\$timestamp"
$incomingFolder = Join-Path $TargetFolder "reconciliation-incoming\$timestamp"
New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
New-Item -ItemType Directory -Path $incomingFolder -Force | Out-Null

Write-ReconciliationLog "Backup folder: $backupFolder"
Write-ReconciliationLog "Incoming folder: $incomingFolder"

foreach ($file in $CertificateFiles) {
    $activePath = Join-Path $TargetFolder $file
    if (Test-Path -LiteralPath $activePath) {
        $backupPath = Join-Path $backupFolder $file
        Copy-Item -LiteralPath $activePath -Destination $backupPath -Force
        Assert-HashMatch -ExpectedPath $activePath -ActualPath $backupPath -Description "backup $file"
    }

    $sourcePath = Join-Path $SourceFolder $file
    $incomingPath = Join-Path $incomingFolder $file
    Copy-Item -LiteralPath $sourcePath -Destination $incomingPath -Force
    Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $incomingPath -Description "incoming $file"
    Write-ReconciliationLog "[ OK ] Backed up and staged: $file"
}

$incomingStatus = Get-CertificateStatus -Path (Join-Path $incomingFolder "$CertificateName-crt.pem")
if (-not $incomingStatus.Valid -or $incomingStatus.Thumbprint -ne $sourceStatus.Thumbprint) {
    throw "Staged certificate validation failed; active files were not changed."
}

try {
    foreach ($file in $CertificateFiles) {
        $sourcePath = Join-Path $SourceFolder $file
        $incomingPath = Join-Path $incomingFolder $file
        $activePath = Join-Path $TargetFolder $file
        Copy-Item -LiteralPath $incomingPath -Destination $activePath -Force
        Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $activePath -Description "active $file"
        Write-ReconciliationLog "[ OK ] Activated and verified: $file"
    }
}
catch {
    Write-ReconciliationLog "[ERROR] Activation failed; restoring verified backup."
    foreach ($file in $CertificateFiles) {
        $backupPath = Join-Path $backupFolder $file
        $activePath = Join-Path $TargetFolder $file
        if (Test-Path -LiteralPath $backupPath) {
            Copy-Item -LiteralPath $backupPath -Destination $activePath -Force
            Assert-HashMatch -ExpectedPath $backupPath -ActualPath $activePath -Description "rollback $file"
        }
    }
    Write-ReconciliationLog "[ OK ] Rollback completed."
    throw
}

$stateFolder = Join-Path $TargetFolder "reconciliation-state"
New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
$pending = [PSCustomObject]@{
    Source = $ExpectedControllerAddress
    Target = $TargetAddress
    CertificateThumbprint = $sourceStatus.Thumbprint
    Fingerprint = $sourceFingerprint
    RequestedAt = (Get-Date).ToString("o")
    BackupFolder = $backupFolder
}
$pending | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateFolder "pending.json") -Encoding UTF8

Write-ReconciliationLog "[ OK ] Reconciliation completed and target reload was requested."
