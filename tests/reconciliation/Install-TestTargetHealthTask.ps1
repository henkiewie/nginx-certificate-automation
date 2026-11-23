$ErrorActionPreference = "Stop"

$ExpectedAddress = "192.168.178.200"
$TaskName = "Certificate Health TEST (.200)"
$ScriptPath = "C:\nginx\certificate-reconciliation-test\Invoke-TestTargetHealth.ps1"

$addresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
if ($ExpectedAddress -notin $addresses) { throw "Safety stop: install this task only on $ExpectedAddress." }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Missing task script: $ScriptPath" }

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Apply" `
    -WorkingDirectory "C:\nginx\certificate-reconciliation-test"
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -User "SYSTEM" `
    -RunLevel Highest `
    -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName,State,@{Name="UserId";Expression={$_.Principal.UserId}},@{Name="LogonType";Expression={$_.Principal.LogonType}}
