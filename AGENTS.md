# Codex guidance for Nginx certificate automation

This repository contains only the reusable certificate automation source. It is not a copy of the live `C:\nginx` installation.

## Scope and roles

- The normal production controller is the machine currently using `.185`.
- `.155` is the preferred test target when practical.
- The automation must not change listener ports or unrelated Nginx site configuration.
- Tests under `tests/reconciliation` are supporting test tools, not production tasks.

## Safety and secrets

- Never commit certificates, private keys, passwords, cached Windows credentials, simple-acme state, logs, backups, exported scheduled tasks, or complete Nginx runtime folders.
- Keep health checking, reconciliation and optional external port-80 checking as separate results.
- An external test-provider failure does not by itself mean the certificate or Nginx failed.

## Working method

1. Make source changes in this repository and review the Git diff.
2. Test on `.155` where practical.
3. Back up each exact live target before replacement.
4. Update the source package and the installed automation deliberately; do not copy the complete repository over `C:\nginx`.
5. Verify scheduled-task results, certificate files and Nginx health independently.
6. Commit and push only source that contains no runtime secrets.

Always distinguish local source preparation from an actual installation or production deployment.
