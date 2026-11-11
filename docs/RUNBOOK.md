# Repeato owner runbook

Everything you do to change, test, release and roll back Repeato. The model behind it is in `branching.md`.

## 1. Daily flow

1. Start the local stack: `pwsh dev/up.ps1` (from `repeato.infra`). It starts MySQL `repeato-mysql-dev` (127.0.0.1:3308, database `repeato_dev_local`), builds the schema, runs migrations and data releases, then the backend (3000), console (5174), partner app (5175) and customer web (5176) from your working copies. No cloud is touched: SMS off, OTP bypass, the backend's own fakes for payments, storage, email and push (`TEST_MODE=true`), schedulers off.
   - Sign in anywhere with any mobile number and any 4-digit OTP. Console admin: mobile `100`, OTP `1234`.
   - Only some apps: `pwsh dev/up.ps1 -Apps backend,console`. Logs: `dev/.run/<app>.log`.
   - Stop: `pwsh dev/down.ps1` (keeps the data), `-KeepDb` (stop only the apps), `-Reset` (delete the local database too).
   - Optional keys for maps and place search on the laptop: set `$env:REPEATO_DEV_GOOGLE_MAPS_API_KEY` and `$env:REPEATO_DEV_GOOGLE_PLACES_API_KEY` before `up.ps1`.
2. Work on a branch from `origin/main`, push, open a pull request into `main`. CI runs on the pull request.
3. Merge. Staging deploys by itself (workflow **Deploy Staging** in that repository). If Actions minutes are out, or the workflow is switched off, run `pwsh release/release.ps1 -Env staging` (or `-Repos backend` for one app).
4. Test on staging: https://staging.app.repeato.in, the staging console and partner app, `https://api-staging-dot-repeato-439413.uc.r.appspot.com/api/health`.

## 2. Release to production

```powershell
cd C:\Ritesh\workspace\repeato_workspace\repeato.infra
git pull
pwsh release/release.ps1 -Env prod -DryRun     # see the plan: commit per app, release id, every step
pwsh release/release.ps1 -Env prod             # type the release id and the production database name when asked
```

What it does: takes the commit each app runs on staging (tag `deployed/staging`), checks each is on GitHub and on `main`, warns about uncommitted work in your working copies (never deployed), creates the annotated tag `vYYYY.MM.DD-N` on those commits in all four repositories and pushes the tags, then deploys in this order and stops at the first failure:

1. **backend**: clean export, `bun install`, `package-lock.json` from `bun.lock`, Cloud SQL proxy, bootstrap and database check, migration status then migrations, data releases `--status`, `--dry-run`, `--commit --confirm=<DB name>`, `app.yaml` from the template, upload with retry (`--no-promote`), health check of the new version, traffic to it, `dispatch.yaml`, health check of `api` and `admin`.
2. **console**, 3. **partner app**: `vercel pull`, remote build with `--build-env`, deploy to the production target of the prod Vercel project; the partner deploy also checks the Firebase keys and the Play Store ownership file.
4. **customer web**: `flutter build web --pwa-strategy=none`, `firebase deploy --only hosting` to `repeato-web-app`, site check.

It moves `deployed/prod` to each deployed commit and writes `releases/vYYYY.MM.DD-N.md`; commit that file (the script prints the command). Logs stay in `releases/logs/`.

Options: `-Repos backend,console` (only some apps), `-Refs "backend=<sha>,console=<tag>"` (other commits than staging's), `-Yes` (no typed confirmations), `-Via github` (start the **Deploy Production** workflows one by one with `gh` instead of deploying from the laptop; needs Actions minutes or a self-hosted runner, and the variable `PROD_DEPLOY_ON_TAG` must not be `true`).

Before a release with migrations or data releases, still read the rollout notes of that change (for example `repeato.backend/docs/deploy/rollout-2026-11.md` section 2): back up, check drift, run hand steps.

Store apps are not part of the command: Android AAB from a checkout of the tag (`flutter build appbundle`), iOS with **iOS to TestFlight** and `release_tag` = the tag, the partner Play bundle with **Play Store bundle** only when the TWA shell changes.

## 3. Hotfix

```powershell
git -C ..\repeato.backend fetch origin --tags
git -C ..\repeato.backend switch -c hotfix-otp v2026.11.11-1
# fix, commit, push: git push -u origin hotfix-otp
pwsh release/release.ps1 -Env staging -Repos backend -Refs "backend=origin/hotfix-otp"   # optional try on staging
pwsh release/release.ps1 -Env prod -Hotfix -Repos backend -Refs "backend=origin/hotfix-otp"
```

Then open a pull request `hotfix-otp` → `main`. Until it is merged, a normal release refuses a staging commit that is not on `main`.

## 4. Rollback

```powershell
pwsh release/release.ps1 -Env prod -Tag v2026.11.10-1                 # every app back to that release
pwsh release/release.ps1 -Env prod -Tag v2026.11.10-1 -Repos backend  # only one app
```

The backend version of that tag still exists on App Engine, so only traffic moves back (seconds, no database steps). Console, partner and customer web are rebuilt from the tag. Database changes stay: fix forward with a new migration. If the tag was a hotfix of one app only, pass `-Repos` with that app. On GitHub the same is **Deploy Production** → Run workflow → `tag`.

## 5. Where the keys are

| What | Where |
|---|---|
| Deploy keys (PowerShell `$env:` lines, one file per app) | `C:\Ritesh\workspace\repeato-data\keys\<repo>_deploy_key.js`: `repeato.backend_deploy_key.js`, `repeato.console_deploy_key.js`, `repeato.vendor.app_deploy_key.js`, `repeato.mobile.client_deploy_key.js` |
| Service account files they point at | same folder (`GCP_SA_KEY_FILE`, `GCLOUD_SQL_KEY_FILE`, `FIREBASE_SERVICE_ACCOUNT_*_JSON`) |
| Cloud SQL proxy | `C:\Ritesh\workspace\repeato-data\cloud-sql-proxy.exe` (elsewhere the script downloads v2.21.2 into `.work/bin`) |
| The same values for GitHub | each app repository → Settings → Secrets and variables → Actions |

The deploy scripts load their key file themselves and run in a child process, so no key stays in your terminal. Other folders: `$env:REPEATO_KEYS_DIR`, `$env:REPEATO_WORKSPACE`. Nothing in this repository holds a secret; it is public.

Names each script needs (staging `_STAGING`, production `_PROD`):

- backend: `GCP_PROJECT` (GitHub: `GCP_PROJECT_ID`), `GCP_SA_KEY_FILE` (GitHub: `GCP_SA_KEY`, JSON), `GCLOUD_SQL_KEY_FILE` (GitHub: `GCP_CLOUD_SQL_SA_KEY`, else the `GCP_SA_KEY`), `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME_*`, `RAZORPAY_KEY_ID_*`, `RAZORPAY_KEY_SECRET_*`, `RAZORPAY_WEBHOOK_SECRET_*`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `MESSAGING_ENABLED_*`, `OTP_BYPASS_*`, `PRIMARY_MESSAGING_PROVIDER`, `AUTHKEY_API_KEY`, `AUTHKEY_API_URL`, `AUTHKEY_SMS_API_URL`, `AUTHKEY_SENDER_ID`, `AUTHKEY_COUNTRY_CODE`; optional `FIXED_OTP_LOGIN_ENABLED_*`, `SMS_BYPASSED_NUMBERS_*`, `SMS_BYPASSED_OTP_*`, `FAST2SMS_*`, `MESSAGE_CENTRAL_*`, `MAPPLS_API_KEY`, `GOOGLE_PLACES_API_KEY`, `ANTHROPIC_API_KEY`, `OTP_LOG_HASH_KEY`, `SHARE_ADDRESS_SALT`, `ANDROID_APP_SHA256`, `APPLE_TEAM_ID` (GitHub variables or secrets), and the scheduler settings (defaults as before).
- console and partner: `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID_*`, `NEXT_PUBLIC_API_URL_*`, optional `NEXT_PUBLIC_GOOGLE_MAPS_API`.
- customer: `PUBLIC_BASE_URL_*`, `BASE_URL_*`, `RAZORPAY_API_KEY_*`, `GOOGLE_MAPS_API_KEY_*`, `FIREBASE_SERVICE_ACCOUNT_*_JSON` (GitHub: `FIREBASE_SERVICE_ACCOUNT_*`, JSON).

`RELEASE_TOKEN` is no longer needed by any deploy (the old scripts only checked that it was set).

## 6. First-time setup (owner steps, in this order)

Nothing below was done by the agent that built this repository: no GitHub setting, secret, Vercel or Firebase setting was changed.

### 6.1 Urgent: secrets that were committed

The removed backend workflows `db-clean.yml` and `db-clean-seed.yml` (and `db-reset.yml`) contained, in plain text, the private key of the service account `repeato-cloud-db-mysql@repeato-439413.iam.gserviceaccount.com`, a database password for the user `repeato` and a Razorpay test key and secret. They stay in the git history of `repeato.backend` even after the removal. Treat them as leaked:

1. GCP → IAM → Service accounts → `repeato-cloud-db-mysql` → Keys: create a new key, put it in `repeato-data\keys\repeato-cloud-db-mysql.json` (and the GitHub secret `GCP_CLOUD_SQL_SA_KEY` if you use one), then delete the old key (id starting `64152669`).
2. Cloud SQL → `repeato-db` → Users → `repeato`: set a new password; update `DB_PASSWORD` in the backend key file and the GitHub secret. If production uses the same user and password, plan this as a short maintenance step (deploy staging and production right after with the new value).
3. Razorpay dashboard (test mode): regenerate the test key; update `RAZORPAY_KEY_*_STAGING` wherever that test key was used.

### 6.2 This repository

The branches `main` (first commit, README only) and `infra-v1` (everything) are pushed. Because `infra-v1` reached GitHub first, GitHub made it the **default branch**: Settings → General → Default branch → switch to `main`. Then open the pull request `infra-v1` → `main` and merge it. The app repository workflows check out `repeato-in/repeato.infra` at `main` (variable `INFRA_REF` to pin another ref), so merge this before the app repository branches. The repository is public, so no token is needed; if you make it private, add a fine-grained token with read access to its contents as the secret `INFRA_READ_TOKEN` in each app repository (the workflows already use it when it exists).

### 6.3 Merge the app repository branches

Each app repository has the pushed branch `release-model-trunk`. Open and merge the pull requests in this order: backend, console, partner app, customer app. Do it before the first `release.ps1 -Env prod`: a pushed `v*` tag on an older commit would start the old `deploy.yml` of that commit.

### 6.4 GitHub secrets and variables

| Repository | Add | Already there (check) |
|---|---|---|
| backend | nothing new | `GCP_SA_KEY`, `GCP_PROJECT_ID`, every name of section 5 used by the old workflows |
| console | nothing new | `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID_STAGING`, `VERCEL_PROJECT_ID_PROD`, `NEXT_PUBLIC_API_URL_STAGING`, `NEXT_PUBLIC_API_URL_PROD`, `NEXT_PUBLIC_GOOGLE_MAPS_API` |
| partner (`repeato.vendor.app`) | **all of** `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID_STAGING`, `VERCEL_PROJECT_ID_PROD`, `NEXT_PUBLIC_API_URL_STAGING`, `NEXT_PUBLIC_API_URL_PROD`, `NEXT_PUBLIC_GOOGLE_MAPS_API` (this repository never had deploy workflows) | `ANDROID_KEYSTORE_*` for the Play bundle |
| customer | nothing new | `PUBLIC_BASE_URL_*`, `BASE_URL_*`, `RAZORPAY_API_KEY_*`, `GOOGLE_MAPS_API_KEY_*`, `FIREBASE_SERVICE_ACCOUNT_STAGING`, `FIREBASE_SERVICE_ACCOUNT_PROD` |

Variables (Settings → Secrets and variables → Actions → Variables; per repository or once for the organization):

| Variable | Meaning | Default when unset |
|---|---|---|
| `DEPLOY_RUNNER` | runner label for the deploy workflows (`repeato-laptop`, `repeato-vm`) | `ubuntu-latest` |
| `CI_RUNNER` | runner label for CI, must be Linux with Docker | `ubuntu-latest` |
| `STAGING_DEPLOY_ON_MAIN` | `false` stops the automatic staging deploy on merge (then use `release.ps1 -Env staging`) | on |
| `PROD_DEPLOY_ON_TAG` | `true` lets a pushed release tag deploy production on GitHub; leave unset when you release from the laptop | off |
| `INFRA_REF` | ref of repeato.infra the workflows use | `main` |

The workflows hand the repository's secrets and variables to the script (`toJSON(secrets)`, `toJSON(vars)`), so a new setting needs only the secret and a line in the script, never a workflow edit.

### 6.5 Vercel

1. The console and partner `vercel.json` now say `"git": { "deploymentEnabled": false }`, so Vercel no longer builds on its own when someone pushes; only the scripts deploy. In each Vercel project you may also disconnect the Git repository (Settings → Git → Disconnect); not required.
2. The scripts upload a clean export with no `.git`, so the Hobby plan has no commit author to block; merges by `ritesh405` no longer stop deploys. `git-identity.md` is still worth doing for clean history.
3. Partner production: `TWA_SHA256_FINGERPRINTS` and the five `NEXT_PUBLIC_FIREBASE_*` keys stay in the Vercel project settings (unchanged).

### 6.6 Branches and protection

Follow `branch-cleanup.md`: protect `main`, then delete `develop` and `staging` once nothing points at them.

### 6.7 Runner (optional, saves Actions minutes)

`runner/README.md`. Without a runner, deploy from the laptop with `release.ps1` (no minutes used) and let GitHub run only CI.

### 6.8 Retire the cloud dev environment

`retire-cloud-dev.md`, after the first staging deploy through the new workflow worked.

### 6.9 Check it once

```powershell
pwsh release/release.ps1 -Env staging -DryRun
pwsh release/release.ps1 -Env staging          # first real staging deploy through the new scripts
pwsh release/release.ps1 -Env prod -DryRun
```

## 7. New laptop

1. Install: Git, PowerShell 7.4+ (`winget install Microsoft.PowerShell`), Node 22.16.0, bun 1.3.14, Docker Desktop, Google Cloud CLI, Flutter 3.41.5, GitHub CLI (`gh auth login`), optionally `npm i -g firebase-tools` (the script installs it when missing).
2. Clone into `C:\Ritesh\workspace\repeato_workspace`: `repeato.backend`, `repeato.console`, `repeato.vendor.app`, `repeato.mobile.client`, `repeato.infra`. Set the git identity (`git-identity.md`).
3. Copy `C:\Ritesh\workspace\repeato-data\` (keys folder and `cloud-sql-proxy.exe`) from the old laptop or your safe store. Never into a repository.
4. `bun install` in backend, console and vendor app; `flutter pub get` in the customer app.
5. `pwsh repeato.infra/dev/up.ps1` and sign in with mobile `100`, OTP `1234`.
6. `pwsh repeato.infra/release/release.ps1 -Env prod -DryRun` to see that every key is found (a missing name shows as a warning).

## 8. When something fails

- The release stops at the failing app; the apps before it are deployed, the ones after it are not. Fix and rerun with the same tag: `release.ps1 -Env prod -Tag <id> -Repos <failed app and the ones after it>`.
- Backend failed after the migrations: the database is already migrated; the old version keeps serving (traffic moves only after the health check). Fix forward.
- `Something already listens on 127.0.0.1:3306`: another MySQL or proxy runs; stop it, or set `$env:CLOUD_SQL_PROXY_PORT`.
- A setting is missing: the script names it; add it to the key file (and the GitHub secret).
- `app.yaml.template uses settings this script does not set`: a backend change added a template variable; add it to `apps/backend/deploy.ps1` (`Get-TemplateSettings`) in the same change.
