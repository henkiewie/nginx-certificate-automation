param(
    [switch]$Stage,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$ExpectedControllerAddress = "192.168.178.155"
$TargetAddress = "192.168.178.200"
$CertificateName = "remote.selfip.net"
$SourceFolder = "C:\nginx\certstore"
$TargetFolder = "\\$TargetAddress\certstore"
$LogPath = "C:\nginx\certificate-reconciliation-test.log"

# The private key is copied first and the public certificate last. A future
# active deployment can use the certificate write as its change signal.
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

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($ComputerName, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Read-PemCertificate {
    param([string]$Path)

    $pem = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $base64 = $pem `
        -replace "-----BEGIN CERTIFICATE-----", "" `
        -replace "-----END CERTIFICATE-----", "" `
        -replace "\s", ""

    $bytes = [Convert]::FromBase64String($base64)
    return New-Object `
        System.Security.Cryptography.X509Certificates.X509Certificate2 `
        -ArgumentList @(,$bytes)
}

function Get-CertificateStatus {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Exists = $false
            Valid = $false
            Subject = ""
            Thumbprint = ""
            NotBefore = $null
            NotAfter = $null
            RemainingDays = -1
        }
    }

    $certificate = Read-PemCertificate -Path $Path
    $now = Get-Date
    $remainingDays = [Math]::Floor(($certificate.NotAfter - $now).TotalDays)
    $valid = (
        $certificate.NotBefore -le $now -and
        $certificate.NotAfter -gt $now -and
        $certificate.Subject -match "CN=remote\.selfip\.net(?:,|$)"
    )

    return [PSCustomObject]@{
        Exists = $true
        Valid = $valid
        Subject = $certificate.Subject
        Thumbprint = $certificate.Thumbprint
        NotBefore = $certificate.NotBefore
        NotAfter = $certificate.NotAfter
        RemainingDays = $remainingDays
    }
}

function Assert-TestBoundaries {
    $localAddresses = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.AddressState -eq "Preferred" } |
            Select-Object -ExpandProperty IPAddress
    )

    if ($ExpectedControllerAddress -notin $localAddresses) {
        throw "Safety stop: this test may run only on $ExpectedControllerAddress. Local addresses: $($localAddresses -join ', ')"
    }

    if ($TargetAddress -eq "192.168.178.185") {
        throw "Safety stop: production may never be a target of this test."
    }
}

Assert-TestBoundaries

Write-TestLog "========================================================"
Write-TestLog "CERTIFICATE RECONCILIATION TEST"
Write-TestLog "Controller: $ExpectedControllerAddress"
Write-TestLog "Target: $TargetAddress"
Write-TestLog "Mode: $(if ($Stage) { 'STAGE COPY' } else { 'READ-ONLY DRY RUN' })"
Write-TestLog "========================================================"

foreach ($file in $CertificateFiles) {
    $sourcePath = Join-Path $SourceFolder $file
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required source file is missing: $sourcePath"
    }
}

$sourceCertificatePath = Join-Path $SourceFolder "$CertificateName-crt.pem"
$sourceStatus = Get-CertificateStatus -Path $sourceCertificatePath

Write-TestLog "Source subject: $($sourceStatus.Subject)"
Write-TestLog "Source thumbprint: $($sourceStatus.Thumbprint)"
Write-TestLog "Source expires: $($sourceStatus.NotAfter)"
Write-TestLog "Source remaining days: $($sourceStatus.RemainingDays)"

if (-not $sourceStatus.Valid) {
    throw "The source certificate is not currently valid for $CertificateName."
}

if ($sourceStatus.RemainingDays -lt $MinimumRemainingDays) {
    throw "The source certificate has fewer than $MinimumRemainingDays days remaining. It will not be propagated."
}

if (-not (Test-TcpPort -ComputerName $TargetAddress -Port 445)) {
    throw "Target $TargetAddress is offline or TCP 445 is unavailable. No files were changed."
}

if (-not (Test-Path -LiteralPath $TargetFolder)) {
    throw "Target share is not accessible: $TargetFolder. No files were changed."
}

$targetCertificatePath = Join-Path $TargetFolder "$CertificateName-crt.pem"
$targetStatus = Get-CertificateStatus -Path $targetCertificatePath

if ($targetStatus.Exists) {
    Write-TestLog "Target subject: $($targetStatus.Subject)"
    Write-TestLog "Target thumbprint: $($targetStatus.Thumbprint)"
    Write-TestLog "Target expires: $($targetStatus.NotAfter)"
    Write-TestLog "Target remaining days: $($targetStatus.RemainingDays)"
}
else {
    Write-TestLog "Target certificate is missing."
}

$requiresUpdate = (
    -not $targetStatus.Valid -or
    $targetStatus.Thumbprint -ne $sourceStatus.Thumbprint -or
    $targetStatus.RemainingDays -lt $MinimumRemainingDays
)

if (-not $requiresUpdate) {
    Write-TestLog "[ OK ] Target certificate is current and valid."
}
else {
    Write-TestLog "[ACTION] Target certificate is missing, stale, or invalid."
}

if (-not $Stage) {
    Write-TestLog "[DRY RUN] No files were written."
    Write-TestLog "Run again with -Stage to copy into an isolated staging directory."
    exit 0
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stagingFolder = Join-Path $TargetFolder "reconciliation-test\$timestamp"
New-Item -ItemType Directory -Path $stagingFolder -Force | Out-Null

Write-TestLog "Staging folder: $stagingFolder"

foreach ($file in $CertificateFiles) {
    $sourcePath = Join-Path $SourceFolder $file
    $stagedPath = Join-Path $stagingFolder $file

    Copy-Item -LiteralPath $sourcePath -Destination $stagedPath -Force -ErrorAction Stop

    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $stagedHash) {
        throw "Hash verification failed for staged file: $file"
    }

    Write-TestLog "[ OK ] Staged and verified: $file"
}

$stagedCertificatePath = Join-Path $stagingFolder "$CertificateName-crt.pem"
$stagedStatus = Get-CertificateStatus -Path $stagedCertificatePath

if (
    -not $stagedStatus.Valid -or
    $stagedStatus.Thumbprint -ne $sourceStatus.Thumbprint
) {
    throw "The staged certificate failed validity or identity verification."
}

Write-TestLog "[ OK ] Staged certificate is valid and matches the source."
Write-TestLog "[ OK ] Test completed without changing the active target certificate files."
