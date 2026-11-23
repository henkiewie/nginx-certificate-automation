$ErrorActionPreference = "Stop"

$ExpectedAddress = "192.168.178.155"
$TaskName = "Certificate Reconciliation TEST (.155 to .200)"
$ScriptPath = "C:\nginx\certificate-reconciliation-test\Invoke-TestScheduledReconciliation.ps1"

$addresses = @(
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
)
if ($ExpectedAddress -notin $addresses) { throw "Safety stop: install this task only on $ExpectedAddress." }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Missing task script: $ScriptPath" }

$securePassword = Read-Host "Enter the local Tweaker password for the scheduled task" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Apply" `
        -WorkingDirectory "C:\nginx\certificate-reconciliation-test"
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30))
    )
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -User "$env:COMPUTERNAME\Tweaker" `
        -Password $plainPassword `
        -RunLevel Highest `
        -Force | Out-Null
}
finally {
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    Remove-Variable plainPassword,securePassword -ErrorAction SilentlyContinue
}

Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName,State,@{Name="UserId";Expression={$_.Principal.UserId}},@{Name="LogonType";Expression={$_.Principal.LogonType}}
