param(
    [switch]$Apply,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$AllowedAddresses = @(
    "192.168.178.185",
    "192.168.178.155",
    "192.168.178.200",
    "192.168.178.145",
    "192.168.178.175"
)
$CertificateName = "remote.selfip.net"
$CertificateFolder = "C:\nginx\certstore"
$ExpectedChainPath = "C:\nginx\certstore\remote.selfip.net-chain.pem"
$ExpectedKeyPath = "C:\nginx\certstore\remote.selfip.net-key.pem"
$NginxPath = "C:\nginx\nginx.exe"
$PsExecPath = "C:\tools\PsExec.exe"
$StateFolder = Join-Path $CertificateFolder "reconciliation-state"
$AppliedStatePath = Join-Path $StateFolder "applied.json"
$PendingStatePath = Join-Path $StateFolder "pending.json"
$LogPath = "C:\nginx\logs\certificate-health.log"
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
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

function Get-FileSetFingerprint {
    $hashes = foreach ($file in $CertificateFiles) {
        $path = Join-Path $CertificateFolder $file
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing certificate file: $path" }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($hashes -join "|"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally { $sha.Dispose() }
}

function Invoke-NginxCommand {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $PsExecPath -accepteula -nobanner -s $NginxPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    foreach ($line in $output) {
        if ($line) { Write-HealthLog "       $line" }
    }
    return $exitCode
}

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
$matchedAddress = @($AllowedAddresses | Where-Object { $_ -in $localAddresses })
if ($matchedAddress.Count -ne 1) {
    throw "Safety stop: exactly one approved server address must be present. Found: $($matchedAddress -join ', ')"
}
if (-not (Test-Path -LiteralPath $NginxPath)) { throw "nginx is missing: $NginxPath" }
if (-not (Test-Path -LiteralPath $PsExecPath)) { throw "PsExec is missing: $PsExecPath" }

$certificatePath = Join-Path $CertificateFolder "$CertificateName-crt.pem"
$pem = Get-Content -LiteralPath $certificatePath -Raw
$match = [regex]::Match($pem, "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", "Singleline")
if (-not $match.Success) { throw "No certificate was found in $certificatePath" }
$bytes = [Convert]::FromBase64String(($match.Groups[1].Value -replace "\s", ""))
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
$remainingDays = [Math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
if ($certificate.Subject -notmatch "CN=remote\.selfip\.net(?:,|$)" -or $certificate.NotBefore -gt (Get-Date) -or $remainingDays -lt $MinimumRemainingDays) {
    throw "The local certificate is not safe to load."
}

$chainReferences = @()
$keyReferences = @()
$listenerPorts = @()
foreach ($configurationFile in (Get-ChildItem -LiteralPath "C:\nginx\conf\sites-enabled" -Filter "*.conf" -File)) {
    foreach ($line in (Get-Content -LiteralPath $configurationFile.FullName)) {
        if ($line -match "^\s*ssl_certificate\s+([^;]+);") { $chainReferences += $matches[1].Trim() }
        if ($line -match "^\s*ssl_certificate_key\s+([^;]+);") { $keyReferences += $matches[1].Trim() }
        if ($line -match "^\s*listen\s+([0-9]+)\b") { $listenerPorts += [int]$matches[1] }
    }
}
$expectedChain = $ExpectedChainPath.Replace("\", "/").ToLowerInvariant()
$expectedKey = $ExpectedKeyPath.Replace("\", "/").ToLowerInvariant()
if ($chainReferences.Count -eq 0 -or $keyReferences.Count -eq 0) { throw "No active nginx certificate references were found." }
foreach ($reference in $chainReferences) {
    if ($reference.Replace("\", "/").ToLowerInvariant() -ne $expectedChain) { throw "Unexpected ssl_certificate reference: $reference" }
}
foreach ($reference in $keyReferences) {
    if ($reference.Replace("\", "/").ToLowerInvariant() -ne $expectedKey) { throw "Unexpected ssl_certificate_key reference: $reference" }
}

$fingerprint = Get-FileSetFingerprint
Write-HealthLog "Server $matchedAddress certificate $($certificate.Thumbprint), $remainingDays days remaining."
Write-HealthLog "Configured listeners: $((@($listenerPorts | Sort-Object -Unique)) -join ', ')"

$testResult = Invoke-NginxCommand -Arguments @("-p", "C:\nginx\", "-t")
if ($testResult -ne 0) { throw "nginx validation failed with exit code $testResult." }
if (-not $Apply) {
    Write-HealthLog "[AUDIT] Validation successful; no reload performed."
    exit 0
}

$appliedFingerprint = ""
if (Test-Path -LiteralPath $AppliedStatePath) {
    try { $appliedFingerprint = (Get-Content -LiteralPath $AppliedStatePath -Raw | ConvertFrom-Json).Fingerprint }
    catch { Write-HealthLog "[WARN] Applied state unreadable; reload required." }
}
if ($appliedFingerprint -eq $fingerprint) {
    Write-HealthLog "[ OK ] Exact certificate set already applied; reload not required."
    exit 0
}

$reloadResult = Invoke-NginxCommand -Arguments @("-p", "C:\nginx\", "-s", "reload")
if ($reloadResult -ne 0) { throw "nginx reload failed with exit code $reloadResult." }

New-Item -ItemType Directory -Path $StateFolder -Force | Out-Null
[PSCustomObject]@{
    ServerAddress = [string]$matchedAddress[0]
    CertificateThumbprint = $certificate.Thumbprint
    Fingerprint = $fingerprint
    AppliedAt = (Get-Date).ToString("o")
    ListenerPorts = @($listenerPorts | Sort-Object -Unique)
} | ConvertTo-Json | Set-Content -LiteralPath $AppliedStatePath -Encoding UTF8
if (Test-Path -LiteralPath $PendingStatePath) { Remove-Item -LiteralPath $PendingStatePath -Force }
Write-HealthLog "[ OK ] nginx reloaded and applied state recorded."
