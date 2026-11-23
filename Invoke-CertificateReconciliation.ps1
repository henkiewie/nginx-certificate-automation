param(
    [switch]$Apply,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$ControllerAddress = "192.168.178.185"
$CertificateName = "remote.selfip.net"
$SourceFolder = "C:\nginx\certstore"
$LogPath = "C:\nginx\logs\certificate-reconciliation.log"
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
$ConnectionTimeoutMilliseconds = 1500
$Targets = @(
    [PSCustomObject]@{ Name = "Spare";     Address = "192.168.178.155" },
    [PSCustomObject]@{ Name = "Test";      Address = "192.168.178.200" },
    [PSCustomObject]@{ Name = "New server"; Address = "192.168.178.145" },
    [PSCustomObject]@{ Name = "Additional"; Address = "192.168.178.175" }
)
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

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if (-not $task.Wait($ConnectionTimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Read-PemCertificate {
    param([string]$Path)
    $pem = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($pem, "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", "Singleline")
    if (-not $match.Success) { throw "No certificate was found in $Path" }
    $bytes = [Convert]::FromBase64String(($match.Groups[1].Value -replace "\s", ""))
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
}

function Get-CertificateStatus {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Valid = $false; Thumbprint = ""; RemainingDays = -1; NotAfter = $null }
    }
    try {
        $certificate = Read-PemCertificate -Path $Path
        $now = Get-Date
        return [PSCustomObject]@{
            Valid = ($certificate.NotBefore -le $now -and $certificate.NotAfter -gt $now -and $certificate.Subject -match "CN=remote\.selfip\.net(?:,|$)")
            Thumbprint = $certificate.Thumbprint
            RemainingDays = [Math]::Floor(($certificate.NotAfter - $now).TotalDays)
            NotAfter = $certificate.NotAfter
        }
    }
    catch {
        return [PSCustomObject]@{ Valid = $false; Thumbprint = ""; RemainingDays = -1; NotAfter = $null }
    }
}

function Get-FileSetFingerprint {
    param([string]$Folder)
    $hashes = foreach ($file in $CertificateFiles) {
        $path = Join-Path $Folder $file
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($hashes -join "|"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally { $sha.Dispose() }
}

function Assert-HashMatch {
    param([string]$ExpectedPath, [string]$ActualPath, [string]$Description)
    $expected = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
    $actual = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
    if ($expected -ne $actual) { throw "Hash verification failed: $Description" }
}

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
if ($ControllerAddress -notin $localAddresses) {
    throw "Safety stop: reconciliation may run only on production $ControllerAddress."
}
if ($Targets.Address -contains $ControllerAddress) {
    throw "Safety stop: production is present in its own target list."
}

Write-ReconciliationLog "========================================================"
Write-ReconciliationLog "CERTIFICATE RECONCILIATION"
Write-ReconciliationLog "Mode: $(if ($Apply) { 'APPLY' } else { 'READ-ONLY AUDIT' })"
Write-ReconciliationLog "========================================================"

foreach ($file in $CertificateFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceFolder $file))) {
        throw "Required source file is missing: $file"
    }
}

$sourceStatus = Get-CertificateStatus -Path (Join-Path $SourceFolder "$CertificateName-crt.pem")
$sourceFingerprint = Get-FileSetFingerprint -Folder $SourceFolder
if (-not $sourceStatus.Valid -or $sourceStatus.RemainingDays -lt $MinimumRemainingDays) {
    throw "Production source certificate is not safe to propagate."
}
Write-ReconciliationLog "Source thumbprint: $($sourceStatus.Thumbprint)"
Write-ReconciliationLog "Source expires: $($sourceStatus.NotAfter)"

$failureCount = 0
$updatedCount = 0
$offlineCount = 0

foreach ($target in $Targets) {
    Write-ReconciliationLog "Target: $($target.Name) - $($target.Address)"
    if (-not (Test-TcpPort -ComputerName $target.Address -Port 445)) {
        Write-ReconciliationLog "[OFFLINE] TCP 445 unavailable; target skipped."
        $offlineCount++
        continue
    }

    $targetFolder = "\\$($target.Address)\certstore"
    if (-not (Test-Path -LiteralPath $targetFolder)) {
        Write-ReconciliationLog "[ERROR] Target is online but certstore is inaccessible."
        $failureCount++
        continue
    }

    $targetStatus = Get-CertificateStatus -Path (Join-Path $targetFolder "$CertificateName-crt.pem")
    $targetFingerprint = Get-FileSetFingerprint -Folder $targetFolder
    $requiresUpdate = (
        -not $targetStatus.Valid -or
        $targetStatus.RemainingDays -lt $MinimumRemainingDays -or
        $targetStatus.Thumbprint -ne $sourceStatus.Thumbprint -or
        $targetFingerprint -ne $sourceFingerprint
    )

    if (-not $requiresUpdate) {
        Write-ReconciliationLog "[ OK ] Valid and fully synchronized."
        continue
    }
    if (-not $Apply) {
        Write-ReconciliationLog "[AUDIT] Update required; no files changed."
        continue
    }

    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFolder = Join-Path $targetFolder "reconciliation-backup\$timestamp"
        $incomingFolder = Join-Path $targetFolder "reconciliation-incoming\$timestamp"
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        New-Item -ItemType Directory -Path $incomingFolder -Force | Out-Null

        foreach ($file in $CertificateFiles) {
            $activePath = Join-Path $targetFolder $file
            if (Test-Path -LiteralPath $activePath) {
                $backupPath = Join-Path $backupFolder $file
                Copy-Item -LiteralPath $activePath -Destination $backupPath -Force
                Assert-HashMatch -ExpectedPath $activePath -ActualPath $backupPath -Description "backup $file"
            }
            $sourcePath = Join-Path $SourceFolder $file
            $incomingPath = Join-Path $incomingFolder $file
            Copy-Item -LiteralPath $sourcePath -Destination $incomingPath -Force
            Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $incomingPath -Description "incoming $file"
        }

        $incomingStatus = Get-CertificateStatus -Path (Join-Path $incomingFolder "$CertificateName-crt.pem")
        if (-not $incomingStatus.Valid -or $incomingStatus.Thumbprint -ne $sourceStatus.Thumbprint) {
            throw "Incoming certificate validation failed."
        }

        try {
            foreach ($file in $CertificateFiles) {
                $sourcePath = Join-Path $SourceFolder $file
                $incomingPath = Join-Path $incomingFolder $file
                $activePath = Join-Path $targetFolder $file
                Copy-Item -LiteralPath $incomingPath -Destination $activePath -Force
                Assert-HashMatch -ExpectedPath $sourcePath -ActualPath $activePath -Description "active $file"
            }
        }
        catch {
            foreach ($file in $CertificateFiles) {
                $backupPath = Join-Path $backupFolder $file
                $activePath = Join-Path $targetFolder $file
                if (Test-Path -LiteralPath $backupPath) {
                    Copy-Item -LiteralPath $backupPath -Destination $activePath -Force
                    Assert-HashMatch -ExpectedPath $backupPath -ActualPath $activePath -Description "rollback $file"
                }
            }
            throw
        }

        $stateFolder = Join-Path $targetFolder "reconciliation-state"
        New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
        [PSCustomObject]@{
            Source = $ControllerAddress
            Target = $target.Address
            CertificateThumbprint = $sourceStatus.Thumbprint
            Fingerprint = $sourceFingerprint
            RequestedAt = (Get-Date).ToString("o")
            BackupFolder = $backupFolder
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateFolder "pending.json") -Encoding UTF8

        Write-ReconciliationLog "[ OK ] Updated, verified, and reload requested."
        $updatedCount++
    }
    catch {
        Write-ReconciliationLog "[ERROR] $($_.Exception.Message)"
        $failureCount++
    }
}

Write-ReconciliationLog "Complete: updated=$updatedCount offline=$offlineCount failures=$failureCount"
if ($failureCount -gt 0) { exit 1 }
exit 0
