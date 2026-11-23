# Certificate automation v1.4.1

This package consolidates the tested certificate process without changing any
nginx listener ports or site configuration files.

## Installed behavior

- All approved servers run `Certificate Health` as SYSTEM every five minutes.
- Certificate automation logs are written into the existing `C:\nginx\logs`
  directory so the established daily nginx ZIP rotation also archives them.
- Health dynamically reads nginx listeners and requires every enabled SSL site
  to use `remote.selfip.net-chain.pem` and `remote.selfip.net-key.pem`.
- Health validates the certificate, all four file hashes, and `nginx -t`.
- nginx reload uses the established `C:\tools\PsExec.exe -s` method and occurs
  only when the four-file fingerprint changes.
- Production `.185` additionally runs `Certificate Reconciliation` as Tweaker
  every 30 minutes.
- Every server receives the same interactive `Refresh Certificate Target
  Credentials` logon task. It exits without prompting on standby addresses. On the
  computer currently using `.185`, it discovers the physical hostname behind
  each target IP and prompts only when the stored `HOSTNAME\Tweaker` username
  is no longer correct after an IP-role change.
- Reconciliation checks `.155`, `.200`, `.145`, and `.175`. Offline machines
  are skipped. An online machine with an inaccessible share is an error.
- Changed targets are backed up, staged, hash-verified, activated, and given a
  local reload request. Their health task performs the local validation/reload.
- The simple-acme callback on production is changed from the hidden GUI script
  to the local health script. The previous batch file and GUI deployment
  script are moved into a timestamped recoverable archive.
- Superseded `.155/.200` test tasks are exported to XML and removed. Their test
  scripts and logs are moved into the same timestamped archive.
- If Windows temporarily keeps a stopped test script folder open, the installer
  archives a complete copy, reports deferred removal, and continues normally.
- Certificate backup/incoming/state folders, active certificates, simple-acme
  data, and nginx site configurations are never deleted by the installer.

## Installation layout

Extract/copy this package to exactly:

`C:\nginx\certificate-automation`

Run from elevated PowerShell:

```powershell
Set-Location C:\nginx\certificate-automation
.\Install-CertificateAutomation.ps1
```

### Upgrade an existing v1.3 installation

Do not rerun the complete installer merely to add credential refresh. Extract
v1.4.1 over the existing `C:\nginx\certificate-automation` folder and run only:

```powershell
Set-Location C:\nginx\certificate-automation
.\Install-CredentialRefresh.ps1
```

This adds or refreshes the identical logon task without changing Certificate
Health, Certificate Reconciliation, simple-acme, nginx, shares, or passwords.

On every server this installs the SYSTEM health task and the interactive
credential-refresh logon task. On `.185` it also asks once for the Tweaker
password, installs reconciliation, and replaces the ACME callback batch after
backing up the previous batch file.

The credential-refresh task never changes a Windows password. It corrects the
stored IP-to-`HOSTNAME\Tweaker` credential when a different physical computer
takes a role IP. The existing password is requested by Windows only for the
changed online target. Offline targets are left unchanged. Version 1.4.1 also
treats a missing cached SMB connection as normal, so a successful credential
update continues to the next target. To run it visibly after a test-role IP
change:

```powershell
Set-Location C:\nginx\certificate-automation
.\Refresh-TargetCredentials.ps1
```

The installer does not start either task immediately. Their first time-based
triggers start two or three minutes after installation.

## Log files

- `C:\nginx\logs\certificate-health.log`
- `C:\nginx\logs\certificate-reconciliation.log` (production `.185` only)
- `C:\nginx\logs\credential-refresh.log`

The existing `Logrotation Nginx` scheduled task processes every `*.log` in
this directory. No separate certificate-log rotation task is required. The
installer backs up and updates `C:\nginx\PruneLogFilesNginx.ps1`, preserves the
existing task action and trigger, and enables `StartWhenAvailable` so a machine
that was off at 01:00 performs the missed rotation after it starts.
