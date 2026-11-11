# Retire the cloud dev environment

Owner decision 2026-11-11: development is fully local (`dev/up.ps1`). The cloud dev environment goes. Nothing here has been done yet; the agent deleted nothing in the cloud. Do it after the first staging deploy through the new workflows has worked, top to bottom. Each step says how to check before you delete.

## What the cloud dev environment is

| Part | Name |
|---|---|
| Backend service | App Engine `api-dev` in project `repeato-439413` (versions `dev-<sha>`) |
| Dev databases on the Cloud SQL instance `repeato-db` | `repeato_dev` (what `.env.development` and `DB_NAME_DEV` point at) and `repeato-dev` (what the removed `db-*` workflows wrote to); check which exist |
| Customer web | Firebase project `repeato-web-app-dev` (alias `dev` removed from `.firebaserc`) |
| Console, partner app | the Vercel projects of `VERCEL_PROJECT_ID_DEV` in each key file |
| Workflows | `deploy-dev.yml` in backend, console and customer app, the five backend `db-*.yml` (removed on the `release-model-trunk` branches) |
| Secrets | every `*_DEV` name, the GitHub environment `dev` in the backend repository, variable `CONSOLE_URL_DEV` |

## Steps

1. **Merge the `release-model-trunk` branches** (they remove the dev workflows and the dev scripts).
2. **Save the dev data you want to keep** (optional):
   ```powershell
   gcloud sql databases list --instance repeato-db --project repeato-439413
   gcloud sql export sql repeato-db gs://<a bucket you own>/backups/repeato_dev-2026-11.sql.gz --database=repeato_dev --project repeato-439413
   ```
   Or load it into the local stack instead: `dev/up.ps1 -Apps backend`, then restore the dump into `repeato_dev_local` on 127.0.0.1:3308.
3. **Point your laptop at the local database.** `repeato.backend/.env.development` still names the remote host `34.42.52.204` and `repeato_dev`. Set `DB_HOST=127.0.0.1`, `DB_HOST_PORT=3308`, `DB_NAME=repeato_dev_local`, `DB_USERNAME=root`, `DB_PASSWORD=repeato-local-root`, `MESSAGING_ENABLED=false`, `OTP_BYPASS=true` there (it is your own file, not committed), or always start the backend through `dev/up.ps1`, which ignores that file.
4. **App Engine `api-dev`.** Check nothing routes to it (`dispatch.yaml` has no dev rule) and look at its traffic in the console, then:
   ```powershell
   gcloud app versions list --service api-dev --project repeato-439413
   gcloud app services delete api-dev --project repeato-439413
   ```
5. **Dev databases.** After step 2:
   ```powershell
   gcloud sql databases delete repeato_dev --instance repeato-db --project repeato-439413
   gcloud sql databases delete repeato-dev --instance repeato-db --project repeato-439413   # only if it exists
   ```
   Never touch `repeato_staging` or `repeato_prod`.
6. **Firebase `repeato-web-app-dev`.** `firebase hosting:disable --project repeato-web-app-dev`, then in the Firebase console delete the project (Project settings → Delete project; it stays recoverable for 30 days). Delete its service account key file `repeato-data\keys\repeato-web-app-dev-firebase-adminsdk-*.json` and revoke the key in GCP IAM of that project.
7. **Vercel dev projects.** In the Vercel dashboard open the console and partner projects whose ids are `VERCEL_PROJECT_ID_DEV` (key files), remove their domains (for example `dev.*`), then Settings → Delete Project.
8. **DNS.** Remove the records of the dev hosts (for example `dev.app.repeato.in`, `www.dev.app.repeato.in`) at your DNS provider.
9. **GitHub.**
   - backend: Settings → Environments → delete `dev`; Secrets → delete `DB_NAME_DEV`, `RAZORPAY_KEY_ID_DEV`, `RAZORPAY_KEY_SECRET_DEV`, `RAZORPAY_WEBHOOK_SECRET_DEV`, `MESSAGING_ENABLED_DEV`, `OTP_BYPASS_DEV`, `FIXED_OTP_LOGIN_ENABLED_DEV`, `SMS_BYPASSED_NUMBERS_DEV`, `SMS_BYPASSED_OTP_DEV`; Variables → delete `CONSOLE_URL_DEV`.
   - console: delete `VERCEL_PROJECT_ID_DEV`, `NEXT_PUBLIC_API_URL_DEV`.
   - customer app: delete `PUBLIC_BASE_URL_DEV`, `BASE_URL_DEV`, `RAZORPAY_API_KEY_DEV`, `GOOGLE_MAPS_API_KEY_DEV`, `FIREBASE_SERVICE_ACCOUNT_DEV`.
   - Old runs of the dev workflows can stay; delete them from Actions if you want a clean list.
10. **Key files.** Remove the `*_DEV` lines from the four `repeato-data\keys\*_deploy_key.js` files (`DB_NAME_DEV`, `MESSAGING_ENABLED_DEV`, `OTP_BYPASS_DEV`, `FIXED_OTP_LOGIN_ENABLED_DEV`, `SMS_BYPASSED_*_DEV`, `RAZORPAY_*_DEV`, `VERCEL_PROJECT_ID_DEV`, `NEXT_PUBLIC_API_URL_DEV`, `PUBLIC_BASE_URL_DEV`, `BASE_URL_DEV`, `RAZORPAY_API_KEY_DEV`, `GOOGLE_MAPS_API_KEY_DEV`, `FIREBASE_SERVICE_ACCOUNT_DEV_JSON`). No script reads them any more.
11. **Cloud Storage.** Files of dev live under the `dev/` prefix of the bucket `repeato-mobile-client`. Look first (`gcloud storage ls gs://repeato-mobile-client/dev/ --project repeato-439413`), then remove it if nothing else uses it: `gcloud storage rm -r gs://repeato-mobile-client/dev/`.
12. **Production CORS.** The old production workflow allowed `dev.app.repeato.in` and several `localhost` and `100.x` addresses on the `api` service. The new script uses the same production list for `api` and `admin` as the old PowerShell script (no dev or private addresses). Nothing to do; noted so the change is not a surprise.
