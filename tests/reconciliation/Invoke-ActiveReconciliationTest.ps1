param(
    [switch]$ForceSameCertificate,
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
    "$CertificateName-chain.pem",
    "$CertificateName-crt.pem"
)

function Write-TestLog {
    param([string]$Message = "")

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Read-PemCertificate {
    param([string]$Path)

    $pem = Get-Content -LiteralPath $Path -Raw
    $base64 = $pem `
        -replace "-----BEGIN CERTIFICATE-----", "" `
        -replace "-----END CERTIFICATE-----", "" `
        -replace "\s", ""
    $bytes = [Convert]::FromBase64String($base64)
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
}

function Get-CertificateStatus {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Exists = $false
            Valid = $false
            Thumbprint = ""
            RemainingDays = -1
        }
    }

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
        RemainingDays = [Math]::Floor(($certificate.NotAfter - $now).TotalDays)
    }
}

function Assert-TestBoundaries {
    $localAddresses = @(
        Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.AddressState -eq "Preferred" } |
            Select-Object -ExpandProperty IPAddress
    )

    if ($ExpectedControllerAddress -notin $localAddresses) {
        throw "Safety stop: this test may run only on $ExpectedControllerAddress."
    }
    if ($TargetAddress -ne "192.168.178.200") {
        throw "Safety stop: the active test target must be 192.168.178.200."
    }
    if ($TargetAddress -eq "192.168.178.185") {
        throw "Safety stop: production may never be a target of this test."
    }
}

function Assert-HashMatch {
    param(
        [string]$ExpectedPath,
        [string]$ActualPath,
        [string]$Description
    )

    $expectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
    $actualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
    if ($expectedHash -ne $actualHash) {
        throw "Hash verification failed: $Description"
    }
}

Assert-TestBoundaries

foreach ($file in $CertificateFiles) {
    $sourcePath = Join-Path $SourceFolder $file
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required source file is missing: $sourcePath"
    }
}

if (-not (Test-Path -LiteralPath $TargetFolder)) {
    throw "Target share is unavailable: $TargetFolder"
}

$sourceCertificatePath = Join-Path $SourceFolder "$CertificateName-crt.pem"
$targetCertificatePath = Join-Path $TargetFolder "$CertificateName-crt.pem"
$sourceStatus = Get-CertificateStatus -Path $sourceCertificatePath
$targetStatus = Get-CertificateStatus -Path $targetCertificatePath

if (-not $sourceStatus.Valid -or $sourceStatus.RemainingDays -lt $MinimumRemainingDays) {
    throw "The source certificate is not safe to deploy."
}

$requiresUpdate = (
    -not $targetStatus.Valid -or
    $targetStatus.Thumbprint -ne $sourceStatus.Thumbprint -or
    $targetStatus.RemainingDays -lt $MinimumRemainingDays
)

Write-TestLog "========================================================"
Write-TestLog "ACTIVE RECONCILIATION TEST: .155 -> .200"
Write-TestLog "Source thumbprint: $($sourceStatus.Thumbprint)"
Write-TestLog "Target thumbprint: $($targetStatus.Thumbprint)"
Write-TestLog "Update required: $requiresUpdate"
Write-TestLog "Force same-certificate test: $ForceSameCertificate"
Write-TestLog "========================================================"

if (-not $requiresUpdate -and -not $ForceSameCertificate) {
    Write-TestLog "[ OK ] Target is already current. No files were changed."
    Write-TestLog "Use -ForceSameCertificate only for the controlled .200 activation test."
    exit 0
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFolder = Join-Path $TargetFolder "reconciliation-backup\$timestamp"
$incomingFolder = Join-Path $TargetFolder "reconciliation-incoming\$timestamp"
New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
New-Item -ItemType Directory -Path $incomingFolder -Force | Out-Null

Write-TestLog "Backup folder: $backupFolder"
Write-TestLog "Incoming folder: $incomingFolder"

foreach ($file in $CertificateFiles) {
    $activePath = Join-Path $TargetFolder $file
    if (Test-Path -LiteralPath $activePath) {
        $backupPath = Join-Path $backupFolder $file
        Copy-Item -LiteralPath $activePath -Destination $backupPath -Force
        Assert-HashMatch -ExpectedPath $activePath -ActualPath $backupPath -Description "backup of $file"
        Write-TestLog "[ OK ] Backed up and verified: $file"
    }
}

foreach ($file in $CertificateFiles) {
    $sourcePath = Join-Path $SourceFolder $file
    $incomingPath = Join-Path $incomingFolder $file
    Copy-Item -LiteralPath $sourcePath -Destination $incomingPath -Force
    Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $incomingPath -Description "incoming $file"
    Write-TestLog "[ OK ] Prepared and verified: $file"
}

$incomingStatus = Get-CertificateStatus -Path (Join-Path $incomingFolder "$CertificateName-crt.pem")
if (-not $incomingStatus.Valid -or $incomingStatus.Thumbprint -ne $sourceStatus.Thumbprint) {
    throw "Incoming certificate validation failed. Active target files were not changed."
}

try {
    foreach ($file in $CertificateFiles) {
        $sourcePath = Join-Path $SourceFolder $file
        $incomingPath = Join-Path $incomingFolder $file
        $activePath = Join-Path $TargetFolder $file
        Copy-Item -LiteralPath $incomingPath -Destination $activePath -Force
        Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $activePath -Description "activated $file"
        Write-TestLog "[ OK ] Activated and verified: $file"
    }
}
catch {
    Write-TestLog "[ERROR] Activation failed. Restoring the verified backup."
    foreach ($file in $CertificateFiles) {
        $backupPath = Join-Path $backupFolder $file
        $activePath = Join-Path $TargetFolder $file
        if (Test-Path -LiteralPath $backupPath) {
            Copy-Item -LiteralPath $backupPath -Destination $activePath -Force
            Assert-HashMatch -ExpectedPath $backupPath -ActualPath $activePath -Description "rollback $file"
        }
    }
    Write-TestLog "[ OK ] Rollback completed."
    throw
}

$activeStatus = Get-CertificateStatus -Path $targetCertificatePath
if (-not $activeStatus.Valid -or $activeStatus.Thumbprint -ne $sourceStatus.Thumbprint) {
    throw "Active certificate failed final validation. Backup is at $backupFolder"
}

Write-TestLog "[ OK ] Active files on .200 match the valid source certificate."
Write-TestLog "[NEXT] On .200, run Test-TargetNginx.ps1 before reloading nginx."
