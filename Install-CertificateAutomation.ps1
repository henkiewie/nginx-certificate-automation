$ErrorActionPreference = "Stop"

$ProductionAddress = "192.168.178.185"
$AllowedAddresses = @(
    $ProductionAddress,
    "192.168.178.155",
    "192.168.178.200",
    "192.168.178.145",
    "192.168.178.175"
)
$InstallFolder = "C:\nginx\certificate-automation"
$LogFolder = "C:\nginx\logs"
$HealthScript = Join-Path $InstallFolder "Invoke-CertificateHealth.ps1"
$ReconciliationScript = Join-Path $InstallFolder "Invoke-CertificateReconciliation.ps1"
$HealthTaskName = "Certificate Health"
$ReconciliationTaskName = "Certificate Reconciliation"
$RotationTaskName = "Logrotate Nginx"
$CredentialRefreshInstaller = Join-Path $InstallFolder "Install-CredentialRefresh.ps1"
$RotationScriptSource = Join-Path $InstallFolder "PruneLogFilesNginx.ps1"
$RotationScriptPath = "C:\nginx\PruneLogFilesNginx.ps1"
$BackupFolder = "C:\nginx\certificate-automation-backup\$(Get-Date -Format 'yyyyMMdd_HHmmss')"

$localAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
$matchedAddress = @($AllowedAddresses | Where-Object { $_ -in $localAddresses })
if ($matchedAddress.Count -ne 1) {
    throw "Safety stop: exactly one approved server address must be present. Found: $($matchedAddress -join ', ')"
}
if (-not (Test-Path -LiteralPath $HealthScript)) { throw "Missing health script: $HealthScript" }
if (-not (Test-Path -LiteralPath $CredentialRefreshInstaller)) { throw "Missing credential refresh installer: $CredentialRefreshInstaller" }
New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null

$healthAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$HealthScript`" -Apply" `
    -WorkingDirectory $InstallFolder
$healthTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$healthSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $HealthTaskName -Action $healthAction -Trigger $healthTriggers -Settings $healthSettings -User "SYSTEM" -RunLevel Highest -Force | Out-Null

# Install the same interactive credential-maintenance task on every server.
# The task itself acts only when the computer currently owns production .185.
& $CredentialRefreshInstaller

# Integrate certificate logs with the existing daily nginx log rotation.
if (Test-Path -LiteralPath $RotationScriptSource) {
    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
    if (Test-Path -LiteralPath $RotationScriptPath) {
        Copy-Item -LiteralPath $RotationScriptPath -Destination (Join-Path $BackupFolder "PruneLogFilesNginx.ps1") -Force
    }
    Copy-Item -LiteralPath $RotationScriptSource -Destination $RotationScriptPath -Force

    $rotationTask = Get-ScheduledTask -TaskName $RotationTaskName -ErrorAction SilentlyContinue
    if ($rotationTask) {
        $rotationTaskXmlText = Export-ScheduledTask -TaskName $RotationTaskName
        $rotationTaskXmlText |
            Set-Content -LiteralPath (Join-Path $BackupFolder "Logrotate Nginx.xml") -Encoding Unicode

        [xml]$rotationTaskXml = $rotationTaskXmlText
        $settingsNode = $rotationTaskXml.SelectSingleNode(
            "/*[local-name()='Task']/*[local-name()='Settings']"
        )
        if (-not $settingsNode) { throw "The $RotationTaskName task has no Settings section." }

        $startWhenAvailableNode = $settingsNode.SelectSingleNode(
            "*[local-name()='StartWhenAvailable']"
        )
        if ($startWhenAvailableNode) {
            $startWhenAvailableNode.InnerText = "true"
        }
        else {
            $startWhenAvailableNode = $rotationTaskXml.CreateElement(
                "StartWhenAvailable",
                $rotationTaskXml.DocumentElement.NamespaceURI
            )
            $startWhenAvailableNode.InnerText = "true"
            $allowHardTerminateNode = $settingsNode.SelectSingleNode(
                "*[local-name()='AllowHardTerminate']"
            )
            if ($allowHardTerminateNode) {
                [void]$settingsNode.InsertAfter($startWhenAvailableNode, $allowHardTerminateNode)
            }
            else {
                [void]$settingsNode.PrependChild($startWhenAvailableNode)
            }
        }

        Register-ScheduledTask -TaskName $RotationTaskName -Xml $rotationTaskXml.OuterXml -Force | Out-Null
        Write-Host "Updated existing nginx log rotation and enabled StartWhenAvailable."
    }
    else {
        Write-Warning "Scheduled task '$RotationTaskName' was not found; the rotation script was updated but no new task was created."
    }
}

# Export and remove superseded test tasks so they cannot create duplicate
# five-minute or thirty-minute runs. Their XML remains recoverable.
$testTaskNames = @(
    "Certificate Health TEST (.200)",
    "Certificate Reconciliation TEST (.155 to .200)"
)
foreach ($testTaskName in $testTaskNames) {
    $testTask = Get-ScheduledTask -TaskName $testTaskName -ErrorAction SilentlyContinue
    if ($testTask) {
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
        $taskBackupName = ($testTaskName -replace '[^A-Za-z0-9._-]', '_') + ".xml"
        $taskBackupPath = Join-Path $BackupFolder $taskBackupName
        Export-ScheduledTask -TaskName $testTaskName |
            Set-Content -LiteralPath $taskBackupPath -Encoding Unicode
        Stop-ScheduledTask -TaskName $testTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $testTaskName -Confirm:$false
        Write-Host "Archived and removed test task: $testTaskName"
    }
}

$legacyTestPaths = @(
    "C:\nginx\certificate-reconciliation-test",
    "C:\nginx\certstore\scheduled-task-test",
    "C:\nginx\certificate-reconciliation-test.log",
    "C:\nginx\certificate-health-test.log",
    "C:\nginx\certstore\Test-TargetNginx.ps1"
)
foreach ($legacyPath in $legacyTestPaths) {
    if (Test-Path -LiteralPath $legacyPath) {
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
        $destination = Join-Path $BackupFolder (Split-Path $legacyPath -Leaf)
        if (Test-Path -LiteralPath $destination) {
            $destination = "$destination.$(Get-Date -Format 'HHmmssfff')"
        }
        try {
            Move-Item -LiteralPath $legacyPath -Destination $destination -ErrorAction Stop
            Write-Host "Archived and removed test item: $legacyPath"
        }
        catch {
            # A recently stopped scheduled PowerShell process can retain a
            # short-lived handle to its script directory. Preserve a complete
            # archive now and allow installation to finish. The unused source
            # can be removed later without affecting the consolidated tasks.
            Copy-Item -LiteralPath $legacyPath -Destination $destination -Recurse -Force -ErrorAction Stop
            Write-Warning "Archived test item, but removal is deferred because it is still in use: $legacyPath"
        }
    }
}

if ($matchedAddress[0] -eq $ProductionAddress) {
    if (-not (Test-Path -LiteralPath $ReconciliationScript)) { throw "Missing reconciliation script: $ReconciliationScript" }

    $securePassword = Read-Host "Enter the local Tweaker password for the reconciliation task" -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $reconciliationAction = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ReconciliationScript`" -Apply" `
            -WorkingDirectory $InstallFolder
        $reconciliationTriggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes 30))
        )
        $reconciliationSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        Register-ScheduledTask `
            -TaskName $ReconciliationTaskName `
            -Action $reconciliationAction `
            -Trigger $reconciliationTriggers `
            -Settings $reconciliationSettings `
            -User "$env:COMPUTERNAME\Tweaker" `
            -Password $plainPassword `
            -RunLevel Highest `
            -Force | Out-Null
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        Remove-Variable plainPassword,securePassword -ErrorAction SilentlyContinue
    }

    $callbackPath = "C:\nginx\reload-nginx.bat"
    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
    if (Test-Path -LiteralPath $callbackPath) {
        Copy-Item -LiteralPath $callbackPath -Destination (Join-Path $BackupFolder "reload-nginx.bat") -Force
    }
    Copy-Item -LiteralPath (Join-Path $InstallFolder "reload-nginx.bat") -Destination $callbackPath -Force

    $legacyDeploymentScript = "C:\nginx\certificate-deployment.ps1"
    if (Test-Path -LiteralPath $legacyDeploymentScript) {
        Move-Item -LiteralPath $legacyDeploymentScript -Destination (Join-Path $BackupFolder "certificate-deployment.ps1") -Force
        Write-Host "Archived superseded GUI deployment script."
    }
    Write-Host "Recoverable archive: $BackupFolder"
}

Write-Host "Installed certificate automation for $($matchedAddress[0])."
Get-ScheduledTask -TaskName "Certificate *" |
    Select-Object TaskName,State,@{Name="UserId";Expression={$_.Principal.UserId}},@{Name="LogonType";Expression={$_.Principal.LogonType}}
$installedRotationTask = Get-ScheduledTask -TaskName $RotationTaskName -ErrorAction SilentlyContinue
if ($installedRotationTask) {
    $installedRotationTask |
        Select-Object TaskName,State,@{Name="UserId";Expression={$_.Principal.UserId}},@{Name="StartWhenAvailable";Expression={$_.Settings.StartWhenAvailable}}
}
