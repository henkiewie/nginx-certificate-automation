@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\nginx\certificate-automation\Invoke-CertificateHealth.ps1" -Apply
exit /b %ERRORLEVEL%
