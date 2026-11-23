# prune logfiles:

# Set the path to the Nginx log directory
$nginxLogPath = "C:\nginx\logs"
$psExecPath = "C:\tools\PsExec.exe"

if (-not (Test-Path -LiteralPath $psExecPath)) {
    throw "PsExec was not found at $psExecPath"
}

# Set the number of days to keep log files
$daysToKeepLog = 0

# Set the number of days to keep zip files
$daysToKeepZip = 3

# Get the current date and subtract the number of days to keep
$cutOffDate = (Get-Date).AddDays(-$daysToKeepLog)
$cutOffDateZip = (Get-Date).AddDays(-$daysToKeepZip)

# Get all the log files in the Nginx log directory
$logFiles = Get-ChildItem -Path $nginxLogPath -Filter "*.log" -File

# Iterate through each log file
foreach ($logFile in $logFiles) {
    # Check if the log file is older than the cutoff date
    if ($logFile.LastWriteTime -lt $cutOffDate) {
        #compress to a zipfile
        copy-Item c:\nginx\logs\$logfile c:\nginx\logs\$(get-date -f yyyy-MM-dd)-$logfile
        Get-ChildItem c:\nginx\logs\$(get-date -f yyyy-MM-dd)-$logfile | Compress-Archive -update -DestinationPath  "C:\nginx\logs\$(get-date -f yyyy-MM-dd).zip"
        # Delete the log file
        Write-Host "Updated log file: $($logFile.Name)"
        Remove-Item -Path $logFile.FullName -Force
        Remove-Item -Path c:\nginx\logs\$(get-date -f yyyy-MM-dd)-$logfile
        Write-Host "Deleted log file: $($logFile.Name)"
    }
}

# Get all the zip files in the Nginx log directory
$zipFiles = Get-ChildItem -Path $nginxLogPath -Filter "*.zip" -File

Write-Host $zipFiles

# Iterate through each zip file
foreach ($zipFile in $zipFiles) {
    # Check if the zip file is older than the cutoff date
    if ($zipFile.LastWriteTime -lt $cutOffDateZip) {
        # Delete the zip file
        Remove-Item -Path $zipFile.FullName -Force
        Write-Host "Deleted zip file: $($zipFile.Name)"
    }
}

# create new nginx process and creat new logfiles without loosing connections PseExec needed hen service runs ubder system
& $psExecPath /accepteula -s C:\nginx\nginx.exe -s reload -p C:\nginx
& $psExecPath /accepteula -s C:\nginx\nginx.exe -s reopen -p C:\nginx

Write-Host "Log file pruning completed."
