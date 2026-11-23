$ErrorActionPreference = "Stop"

$TaskName = "Refresh Certificate Target Credentials"
$InstallFolder = "C:\nginx\certificate-automation"
$ScriptPath = Join-Path $InstallFolder "Refresh-TargetCredentials.ps1"
$LocalUser = "$env:COMPUTERNAME\Tweaker"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Missing credential refresh script: $ScriptPath"
}
if (-not (Get-LocalUser -Name "Tweaker" -ErrorAction SilentlyContinue)) {
    throw "The required local Tweaker account does not exist."
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $InstallFolder
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $LocalUser
$principal = New-ScheduledTaskPrincipal `
    -UserId $LocalUser `
    -LogonType Interactive `
    -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Refreshes hostname-qualified SMB credentials after role IPs move between interchangeable computers." `
    -Force | Out-Null

Write-Host "Installed '$TaskName' for interactive logon by $LocalUser."
Write-Host "Standby computers exit without prompting. The active .185 computer prompts only for changed target identities."
Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName,State,
        @{Name="UserId";Expression={$_.Principal.UserId}},
        @{Name="LogonType";Expression={$_.Principal.LogonType}},
        @{Name="StartWhenAvailable";Expression={$_.Settings.StartWhenAvailable}}
