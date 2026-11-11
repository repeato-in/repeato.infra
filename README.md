# repeato.infra

Deploy, release and local-stack code for the four Repeato apps. One copy of every procedure lives here; the app repositories only call it.

| App | Repository | Staging | Production |
|---|---|---|---|
| backend | `repeato.backend` | App Engine `api-staging` | App Engine `api` and `admin` |
| console | `repeato.console` | Vercel project (staging) | Vercel project (prod) |
| partner | `repeato.vendor.app` | Vercel project (staging) | Vercel project (prod), Play Store TWA `com.repeato.partner` |
| customer | `repeato.mobile.client` | Firebase Hosting `repeato-web-app-staging` | Firebase Hosting `repeato-web-app` |

Development is fully local (`dev/`). There is no cloud dev environment.

## Layout

```
release/release.ps1        one command: staging, production release, rollback, hotfix
apps/<app>/deploy.ps1      the deploy of one app from one commit or tag (backend, console, partner, customer)
lib/Common.psm1            app list, key loading, clean source export, dry-run runner, checks
lib/VercelDeploy.ps1       the Vercel procedure shared by console and partner
dev/                       compose.yaml, up.ps1, down.ps1: the whole stack on this laptop
runner/README.md           a GitHub self-hosted runner on the laptop or a small VM
releases/                  one release record per staging deploy or production release
docs/                      RUNBOOK, branching model, cloud dev retirement, branch clean-up, git identity
tools/check-scripts.ps1    parse and PSScriptAnalyzer check of every script (also the CI of this repo)
```

## Everyday commands

```powershell
pwsh release/release.ps1 -Env staging            # main of every app to staging
pwsh release/release.ps1 -Env prod               # the staging commits, tagged vYYYY.MM.DD-N, to production
pwsh release/release.ps1 -Env prod -Tag v2026.11.10-1   # roll back to an earlier release
pwsh release/release.ps1 -Env prod -DryRun       # print every step, change nothing
pwsh dev/up.ps1                                  # local stack; dev/down.ps1 stops it
```

Start with `docs/RUNBOOK.md`.
