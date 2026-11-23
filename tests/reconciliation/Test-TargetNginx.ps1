param(
    [switch]$Reload,
    [int]$MinimumRemainingDays = 14
)

$ErrorActionPreference = "Stop"

$ExpectedTargetAddress = "192.168.178.200"
$CertificatePath = "C:\nginx\certstore\remote.selfip.net-crt.pem"
$NginxFolder = "C:\nginx"
$NginxPath = Join-Path $NginxFolder "nginx.exe"

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
if ($ExpectedTargetAddress -notin $localAddresses) {
    throw "Safety stop: this test may run only on $ExpectedTargetAddress."
}

$pem = Get-Content -LiteralPath $CertificatePath -Raw
$base64 = $pem `
    -replace "-----BEGIN CERTIFICATE-----", "" `
    -replace "-----END CERTIFICATE-----", "" `
    -replace "\s", ""
$bytes = [Convert]::FromBase64String($base64)
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
$remainingDays = [Math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)

Write-Host "Certificate subject: $($certificate.Subject)"
Write-Host "Certificate thumbprint: $($certificate.Thumbprint)"
Write-Host "Certificate expires: $($certificate.NotAfter)"
Write-Host "Certificate remaining days: $remainingDays"

if ($certificate.Subject -notmatch "CN=remote\.selfip\.net(?:,|$)") {
    throw "Unexpected certificate identity."
}
if ($certificate.NotBefore -gt (Get-Date) -or $remainingDays -lt $MinimumRemainingDays) {
    throw "Certificate is not currently safe to use."
}
if (-not (Test-Path -LiteralPath $NginxPath)) {
    throw "nginx.exe is missing: $NginxPath"
}

Push-Location $NginxFolder
try {
    & $NginxPath -t
    if ($LASTEXITCODE -ne 0) {
        throw "nginx configuration validation failed with exit code $LASTEXITCODE."
    }
    Write-Host "[ OK ] nginx configuration and certificate files validated."

    if (-not $Reload) {
        Write-Host "[DRY RUN] nginx was not reloaded. Run again with -Reload after reviewing this result."
        exit 0
    }

    & $NginxPath -s reload
    if ($LASTEXITCODE -ne 0) {
        throw "nginx reload failed with exit code $LASTEXITCODE."
    }
    Write-Host "[ OK ] nginx reload command completed successfully."
}
finally {
    Pop-Location
}
