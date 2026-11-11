# Branching and release model (owner decision 2026-11-11)

Trunk-based. `main` is the only long-lived branch in every app repository. Production is a tag, never a branch.

```
feature branch ──PR──▶ main ──(every merge)──▶ STAGING      tag deployed/staging = what staging runs
   (from origin/main)    │
                         │  release.ps1 -Env prod
                         ▼
                 tag vYYYY.MM.DD-N on the tested commit ──▶ PRODUCTION   tag deployed/prod

hotfix:   vYYYY.MM.DD-N ──▶ hotfix branch ──fix──▶ tag vYYYY.MM.DD-(N+1) ──▶ PRODUCTION
                                      └──────PR──────▶ main
rollback: release.ps1 -Env prod -Tag <older vYYYY.MM.DD-N>
```

## Rules

1. **Branch from `origin/main`**, one short-lived branch per change. Pull request into `main`. CI runs on the pull request only.
2. **Every merge to `main` deploys staging** (workflow `deploy-staging.yml`, or `release.ps1 -Env staging` when Actions minutes are out). The deployed commit gets the moving tag `deployed/staging`.
3. **Production is one command**: `release.ps1 -Env prod`. It takes the `deployed/staging` commit of each app, refuses one that is not on `main`, creates the annotated tag `vYYYY.MM.DD-N` (the same id in all four repositories, N counts releases of the day), pushes the tags, deploys backend → console → partner app → customer web, stops at the first failure and writes `releases/vYYYY.MM.DD-N.md`.
4. **Exactly the tested commit goes out.** Every build is a clean export of that commit; nothing from a working copy reaches staging or production.
5. **Hotfix**: branch from the production tag (`git switch -c hotfix-<what> v2026.11.11-1`), fix, push, optionally `release.ps1 -Env staging -Repos <app> -Refs <app>=origin/hotfix-<what>` to try it, then `release.ps1 -Env prod -Hotfix -Repos <app> -Refs <app>=origin/hotfix-<what>`. Then open a pull request of the hotfix branch into `main` so the fix is not lost.
6. **Rollback**: `release.ps1 -Env prod -Tag <previous id>` redeploys the earlier tags. The backend moves traffic back to the earlier App Engine version without database steps. Database changes are never undone automatically; a migration that broke something gets a new forward migration.
7. Old tag shapes (`v1.x.y` from semantic-release, `release-YYYYMMDD-…` from the client release-tag workflows) are no longer created. They stay in history; `deploy-production.yml` refuses them.
8. No `develop`, no `staging` branch, no dev deploy. Development is local (`dev/up.ps1`).

## Cross-repo changes

The order of the workspace stays: backend first, then console, partner app, customer app, each its own pull request. Merge the backend one first so staging has the contract before the clients. One `release.ps1 -Env prod` then ships all four in the same order.
