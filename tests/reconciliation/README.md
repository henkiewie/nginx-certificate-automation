# Certificate reconciliation test: .155 to .200

This isolated test proves certificate inspection and SMB transfer without
changing production or the active certificate files on `.200`.

## Safety boundaries

- The script refuses to run unless the local machine has `192.168.178.155`.
- The only target is `192.168.178.200`.
- Production `192.168.178.185` is hard-blocked as a target.
- The default run is read-only.
- `-Stage` copies into `certstore\reconciliation-test\<timestamp>` only.
- The script does not reload nginx or replace active PEM files.

## Prerequisites

Power on `.200` and confirm that `.155` can access:

```powershell
Test-NetConnection 192.168.178.200 -Port 445
Test-Path "\\192.168.178.200\certstore"
```

## Phase 1: read-only audit

Run on `.155` from elevated PowerShell:

```powershell
Set-Location C:\CertificateReconciliationTest
.\Test-CertificateReconciliation.ps1
```

## Phase 2: isolated staging copy

Only after the dry run succeeds:

```powershell
.\Test-CertificateReconciliation.ps1 -Stage
```

The active `.200` certificate and nginx configuration remain unchanged. A
later, separately approved phase can test backup, activation, nginx validation,
reload, and rollback on `.200`.

## Phase 3: controlled active-file test

`Invoke-ActiveReconciliationTest.ps1` is also locked to `.155 -> .200`. It
creates verified backup and incoming folders before replacing any active file.
Because `.200` already has the same certificate, the controlled test requires
the explicit `-ForceSameCertificate` switch:

```powershell
.\Invoke-ActiveReconciliationTest.ps1 -ForceSameCertificate
```

This replaces the active files with identical verified bytes. It does not
reload nginx.

Copy `Test-TargetNginx.ps1` to `.200`, then validate locally on `.200`:

```powershell
.\Test-TargetNginx.ps1
```

Only after validation succeeds, reload nginx:

```powershell
.\Test-TargetNginx.ps1 -Reload
```

## Phase 4: isolated scheduled-task test

This phase remains hard-locked to `.155 -> .200`. It does not contain `.185`,
`.145`, or `.175` as deployment targets.

### Controller on .155

`Invoke-TestScheduledReconciliation.ps1` runs read-only unless `-Apply` is
specified. The scheduled task uses `-Apply`, runs as the local `Tweaker`
account, and repeats every 30 minutes. It:

- validates the `.155` source certificate;
- skips `.200` without failure when TCP 445 is offline;
- treats an online but inaccessible share as an error;
- compares certificate validity, thumbprint, and hashes of all four files;
- creates verified backup and incoming folders before activation;
- rolls back file-copy or hash-verification failures; and
- writes a reload request for the local `.200` health task.

First run the read-only audit on `.155`:

```powershell
.\Invoke-TestScheduledReconciliation.ps1
```

Install the task only after that succeeds:

```powershell
.\Install-TestControllerTask.ps1
```

The installer securely prompts for the Tweaker password. It is passed to Task
Scheduler for a Password logon and is not stored in this script.

### Local health task on .200

`Invoke-TestTargetHealth.ps1` verifies the certificate, all nginx certificate
references, the configured listener ports, and `nginx -t`. It dynamically
discovers ports and never assumes TCP 443. With `-Apply`, it reloads nginx only
when the four-file certificate fingerprint has changed. Validation and reload
use the established `C:\tools\PsExec.exe -s` method.

First run the read-only audit on `.200`:

```powershell
.\Invoke-TestTargetHealth.ps1
```

Install the SYSTEM task only after that succeeds:

```powershell
.\Install-TestTargetHealthTask.ps1
```

The health task repeats every five minutes. Neither installer automatically
starts its task; this allows task definitions to be inspected before the first
scheduled execution.
