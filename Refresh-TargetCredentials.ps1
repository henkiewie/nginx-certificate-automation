param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ControllerAddress = "192.168.178.185"
$AccountName = "Tweaker"
$Targets = @(
    "192.168.178.155",
    "192.168.178.200",
    "192.168.178.145",
    "192.168.178.175"
)
$LogPath = "C:\nginx\logs\credential-refresh.log"
$ConnectionTimeoutMilliseconds = 1500

New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

function Write-RefreshLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
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

function Resolve-NetBiosServerName {
    param([string]$Address)

    $output = & nbtstat.exe -A $Address 2>&1
    foreach ($line in $output) {
        if ([string]$line -match "^\s*([A-Za-z0-9-]{1,15})\s*<20>\s+") {
            return $matches[1].ToUpperInvariant()
        }
    }
    return $null
}

function Test-StoredCredentialUser {
    param([string]$Address, [string]$ExpectedUser)

    $listing = (& cmdkey.exe "/list:$Address" 2>&1 | Out-String)
    return $listing -match [regex]::Escape($ExpectedUser)
}

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)

if ($ControllerAddress -notin $localAddresses) {
    Write-RefreshLog "Standby role detected; credential refresh is required only on the computer currently using $ControllerAddress."
    exit 0
}

if (-not [Environment]::UserInteractive) {
    Write-RefreshLog "Interactive logon is required so Windows can request a changed target password." "ERROR"
    exit 1
}

Write-RefreshLog "Checking target identities from active controller $ControllerAddress."
$failureCount = 0
$changedCount = 0

foreach ($address in $Targets) {
    if (-not (Test-TcpPort -ComputerName $address -Port 445)) {
        Write-RefreshLog "$address is offline on TCP 445; existing stored credential was left unchanged." "WARN"
        continue
    }

    $serverName = Resolve-NetBiosServerName -Address $address
    if (-not $serverName) {
        Write-RefreshLog "Could not discover the physical computer name currently using $address; credential was left unchanged." "ERROR"
        $failureCount++
        continue
    }

    $expectedUser = "$serverName\$AccountName"
    if (-not $Force -and (Test-StoredCredentialUser -Address $address -ExpectedUser $expectedUser)) {
        Write-RefreshLog "$address is $serverName and already has the correct stored username." "OK"
        continue
    }

    Write-Host ""
    Write-Host "$address is currently $serverName." -ForegroundColor Cyan
    Write-Host "Windows will now request the existing password for $expectedUser." -ForegroundColor Yellow
    & cmdkey.exe "/add:$address" "/user:$expectedUser" /pass
    if ($LASTEXITCODE -ne 0) {
        Write-RefreshLog "cmdkey failed for $address and $expectedUser with exit code $LASTEXITCODE." "ERROR"
        $failureCount++
        continue
    }

    # Drop only connections to this exact target so the new credential is used.
    # A missing cached connection is normal. Suppress native stderr so the
    # script's Stop policy does not abort after cmdkey succeeds.
    & net.exe use "\\$address\certstore" /delete /y 2>$null | Out-Null
    & net.exe use "\\$address\IPC$" /delete /y 2>$null | Out-Null

    if (-not (Test-Path -LiteralPath "\\$address\certstore")) {
        Write-RefreshLog "The credential was stored, but \\$address\certstore is still inaccessible." "ERROR"
        $failureCount++
        continue
    }

    Write-RefreshLog "Updated and verified $address as $expectedUser." "OK"
    $changedCount++
}

Write-RefreshLog "Complete: changed=$changedCount failures=$failureCount."
if ($failureCount -gt 0) { exit 1 }
exit 0
