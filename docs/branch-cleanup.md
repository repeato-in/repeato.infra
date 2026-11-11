# Branch clean-up after the switch to trunk-based

Do this after the `release-model-trunk` pull requests are merged in all four app repositories. The agent changed no GitHub setting.

## 1. `main` is default and protected

`main` is already the default branch of all four repositories (checked 2026-11-11). For each repository: Settings → Branches → Add branch ruleset (or classic protection) for `main`:

- Require a pull request before merging (0 approvals is fine while you are the only reviewer; it still forces the PR, so CI runs).
- Block force pushes and deletions.
- Do **not** mark CI checks as required while CI skips pull requests that touch only docs (`paths-ignore`): such a pull request would wait for a check that never starts. If you want required checks, remove the `paths-ignore` of `ci.yml` first.
- Settings → General → Pull Requests: allow merge commits or squash, tick "Automatically delete head branches".
- Settings → Tags (rulesets → Tag): protect `v*` from deletion and update; leave `deployed/*` free (the scripts move those tags).

## 2. Delete `develop` and `staging`

Both are fully merged into `main` in all four repositories (2026-11-11). Nothing deploys from them any more. Check once more, then delete:

```powershell
foreach ($repo in 'repeato.backend','repeato.console','repeato.vendor.app','repeato.mobile.client') {
  git -C $repo fetch origin
  foreach ($branch in 'develop','staging') {
    git -C $repo merge-base --is-ancestor "origin/$branch" origin/main
    if ($LASTEXITCODE -eq 0) { git -C $repo push origin --delete $branch } else { Write-Warning "$repo $branch has commits not on main" }
  }
}
```

Open pull requests that target `develop` or `staging` must be retargeted to `main` first (GitHub closes them when the base branch is deleted).

## 3. Stale branches

Merged into `main` (safe to delete, 2026-11-11 count): backend 35, console 35, vendor app 11, customer app 30. List and delete them:

```powershell
$repo = 'repeato.backend'
git -C $repo fetch origin --prune
git -C $repo branch -r --merged origin/main | ForEach-Object { $_.Trim() } | Where-Object { $_ -notmatch 'origin/(HEAD|main)' } | ForEach-Object { git -C $repo push origin --delete ($_ -replace '^origin/', '') }
```

Not merged (look before deleting; commits ahead of `main` on 2026-11-11):

| Repository | Branch | Last commit | Ahead |
|---|---|---|---|
| backend | `feature/dinalto-integration` | 2026-11-08 | 26 |
| backend | `release/2026-10-27` | 2026-10-27 | 2 |
| backend | `fix-g481-g484` | 2026-11-11 | 1 (in progress) |
| backend | `bugfix/auth-statuses-active-shops` | 2026-08-26 | 1 |
| backend | `feature/purchase-order-core-planning` | 2026-08-03 | 4 |
| backend | `docs/vendor-notification-wayfinder` | 2026-07-28 | 2 |
| backend | `feat/sbo-vendor-lifecycle-full` | 2026-07-13 | 3 |
| backend | `hs/vendor-type-filter` | 2026-06-13 | 1 |
| backend | `fix/staging-user-photo-gcs-adc` | 2026-06-08 | 1 |
| console | `feature/dinalto-integration` | 2026-11-08 | 16 |
| console | `pr-assets/restaurant-ordering` | 2026-11-08 | 1 |
| console | `fix-g483-setting-wording` | 2026-11-11 | 1 (in progress) |
| console | `feature/purchase-order-core-planning` | 2026-08-03 | 2 |
| console | `feature/delivery-status-button` | 2026-07-08 | 1 |
| console | `hh/sidebar-refactor-prototypes` | 2026-06-21 | 5 |
| console | `temp/dump-vercel-secrets` | 2026-06-13 | 1 (look at it: the name suggests it printed secrets) |
| console | `hs/vendor-type-filter` | 2026-06-13 | 3 |
| console | `vendor-app`, `rider-app`, `rider-app_dev` | 2026-06-11 | 71, 36, 36 |
| console | six `dependabot/npm_and_yarn/*` | 2026-01 to 2026-06 | 1 each (superseded; close the PRs) |
| vendor app | `fix-g482-g485-ads` | 2026-11-11 | 1 (in progress) |
| vendor app | `enable-vendor-to-be-sbo` | 2026-08-13 | 1 |
| vendor app | `feature/vendor-native-feature-inventory` | 2026-07-27 | 1 |
| vendor app | `docs/class-batch-parity-planning` | 2026-07-15 | 1 |
| vendor app | `feat/sbo-vendor-lifecycle-full` | 2026-07-13 | 3 |
| vendor app | `bugfix/otp-four-digit-vendor` | 2026-07-12 | 7 |
| vendor app | `bugfix/sbo-vendorid-contract-vendor-app` | 2026-07-09 | 3 |
| customer app | `feature/dinalto-integration` | 2026-11-08 | 11 |
| customer app | `pr-assets/restaurant-ordering` | 2026-11-08 | 1 |
| customer app | `fix-g481-g484-g486`, `fix-web-image-memory` | 2026-11-11 | 1 each (in progress) |
| customer app | `feature/posthog-analytics` | 2026-07-27 | 11 |

Refresh this list any time:

```powershell
git -C repeato.backend for-each-ref --format='%(refname:short) %(committerdate:short)' refs/remotes/origin |
  ForEach-Object { $name, $date = $_ -split ' '; git -C repeato.backend merge-base --is-ancestor $name origin/main; if ($LASTEXITCODE -ne 0) { "$name $date ahead $(git -C repeato.backend rev-list --count origin/main..$name)" } }
```

## 4. Old tags

`v1.x.y` (backend, semantic-release) and `release-YYYYMMDD-…` (console, customer app) stay as history. No workflow creates them any more and `deploy-production.yml` refuses them. Delete them only if they clutter the tag list.

## 5. Local worktrees

Agents work in worktrees next to the repositories (`repeato.backend-g481`, `…-release-model`, …). Remove a worktree when its branch is merged: `git -C repeato.backend worktree remove ..\repeato.backend-release-model`.
