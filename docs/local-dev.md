# Running and debugging Repeato on this laptop

Everything runs locally: MySQL in Docker, the backend, the console, the partner app and the customer app. Nothing reaches the cloud: no SMS, no real payments, no Google Cloud Storage, no push.

There are two ways to run it. Both use the same settings, so you can mix them freely.

| Way | When | How |
|---|---|---|
| **A. By script** | You want everything up quickly | `pwsh dev/up.ps1`, then `pwsh dev/android.ps1` (section 4) |
| **B. From each repo in VS Code** | You want breakpoints and step-through in one app | F5 with that repo's `local` launch (section 5) |

Typical day: start everything with the script, then stop the one app you are working on and run it with F5 instead (section 5.5).

## 1. Once per laptop

| Tool | Version | Check |
|---|---|---|
| PowerShell | 7.4 or later | `pwsh --version` |
| Docker Desktop | running | `docker ps` |
| Node.js | 22 or later | `node -v` |
| bun | 1.3.14 or later | `bun -v` |
| Flutter | the version in `repeato.mobile.client/pubspec.yaml` | `flutter --version` |
| Android SDK | `emulator`, `platform-tools`, `cmdline-tools/latest`; `ANDROID_HOME` set to its folder (here `C:\Ritesh\android-sdk`), `platform-tools` on `PATH` | `adb version` |
| VS Code | with the Dart, Flutter and JavaScript Debugger extensions | |

The six repositories sit side by side in `C:\Ritesh\workspace\repeato_workspace`. The VS Code launch files rely on that layout. Install each app's packages once, and again after a pull that changes them:

```powershell
cd C:\Ritesh\workspace\repeato_workspace
bun install --cwd repeato.backend
bun install --cwd repeato.console
bun install --cwd repeato.vendor.app
cd repeato.mobile.client; flutter pub get; cd ..
```

Android Studio is not needed. `dev/android.ps1` creates the phone emulator itself (section 4).

## 2. Which settings each app uses

One settings file per app and environment. "dev" always means **this laptop**: the cloud dev environment is retired (`retire-cloud-dev.md`).

| App | Local (this laptop) | Staging | Production |
|---|---|---|---|
| Backend | `repeato.infra/dev/backend.env` | deploy only (`release/release.ps1`) | deploy only |
| Console | `repeato.console/.env.local` (API `http://localhost:3000/api/v1`) | deploy only | deploy only |
| Partner app | `repeato.vendor.app/.env.local` (API `http://localhost:3000/api/v1`) | deploy only | deploy only |
| Customer app on the Android emulator | `repeato.mobile.client/env/dev.json` (backend `http://10.0.2.2:3000`) | `env/staging.json` | `env/prod.json` |
| Customer app in Chrome, or on a phone on USB | `repeato.mobile.client/env/dev-localhost.json` (backend `http://localhost:3000`) | | |

Why the customer app has two local files: inside the Android emulator, `localhost` is the emulator itself, and the laptop is `10.0.2.2`. In Chrome on the laptop, and on a phone on USB after `adb reverse`, the laptop is `localhost`. The keys in both files are the same.

`repeato.infra/dev/backend.env` holds no secrets: a local database, OTP bypass, SMS off, and the backend's own fakes for payments, storage, email and push (`TEST_MODE=true`). Both `dev/up.ps1` and the backend's VS Code launches read it, so the two ways of running always agree.

**Not used locally:** `repeato.backend/.env.development`. It still points at the old cloud dev database `repeato_dev` (34.42.52.204) and sends real SMS. `bun run dev` in the backend reads it, so do not use `bun run dev` there for local work; use the launches below. That file, `.env.staging`, `.env.production` and the partner app's `.env.local` hold real secrets and are tracked in git: gap G562 (rotate, then stop tracking).

## 3. Signing in

| Where | Mobile | OTP |
|---|---|---|
| Console (admin) | `100` (second admin `101`) | `1234` |
| Customer app, partner app | any 10-digit number | any 4 digits |

No SMS is sent (OTP bypass). A new number in the customer app is a new customer. The demo society and its shops are in the local database (data releases); a customer finds them when the platform setting `demo.enabled` (Demo mode) is on in the console.

## 4. Way A: by script

Open PowerShell in `C:\Ritesh\workspace\repeato_workspace\repeato.infra`.

### 4.1 Database, backend, console, partner app, customer web

```powershell
pwsh dev/up.ps1
```

1. Starts MySQL `repeato-mysql-dev` in Docker on `127.0.0.1:3308`, database `repeato_dev_local` (user `root`, password `repeato-local-root`). The data stays in a Docker volume between runs.
2. Builds the schema, runs every migration, seeds a new database once (roles, admin users, cities, categories) and applies the data releases (demo society included). The first run takes several minutes; later runs only apply what is new.
3. Starts the apps from your working copies, so your uncommitted changes are what runs:

| App | URL | Log |
|---|---|---|
| Backend | http://localhost:3000/api/v1 (health http://localhost:3000/api/health) | `dev/.run/backend.log` |
| Console | http://localhost:5174 | `dev/.run/console.log` |
| Partner app | http://localhost:5175 | `dev/.run/partner.log` |
| Customer web | http://localhost:5176 | `dev/.run/customer.log` |

Errors go to `dev/.run/<app>.err.log`. The console and partner app reload on save. The script runs no debugger; for breakpoints use way B.

Only some apps:

```powershell
pwsh dev/up.ps1 -Apps backend                       # database and backend
pwsh dev/up.ps1 -Apps console,partner               # the backend runs elsewhere (F5)
pwsh dev/up.ps1 -Apps customer -SkipDatabaseSetup   # skip migrations and data releases
```

Running `up.ps1` again starts only what is not running yet, and never starts an app whose port is already taken.

### 4.2 The customer app on the Android phone emulator

With the backend running, in a **second** PowerShell window:

```powershell
pwsh dev/android.ps1
```

1. Makes sure the emulator `Pixel_8` exists: a Pixel 8 (1080 x 2400 at 420 dpi, Android 15 with Google APIs) in its Pixel 8 frame, graphics on the laptop's GPU, 4 GB of memory. The first time it creates it, installs the Android 15 system image if missing and downloads the Pixel 8 frame from Google's Android Studio sources into `<SDK>\skins\pixel_8`.
2. Starts it if it is not running and waits until Android has booted.
3. Runs `flutter run` on it with `env/dev.json`. In that window: `r` hot reload, `R` hot restart, `q` quit. The emulator stays open after `q`, and the next run reuses it.

| Option | What it does |
|---|---|
| `-EmulatorOnly` | only create and start the emulator (for example before pressing F5 in VS Code) |
| `-Recreate` | create the `Pixel_8` emulator again from nothing (a clean phone) |
| `-Device <serial>` | run on that device from `adb devices`; a phone on USB gets `adb reverse` and `env/dev-localhost.json` |
| `-Avd <name>` | use another emulator (`emulator -list-avds`) |

### 4.3 Stop

```powershell
pwsh dev/down.ps1            # stop the apps and the database, keep the data
pwsh dev/down.ps1 -KeepDb    # stop only the apps
pwsh dev/down.ps1 -Reset     # stop everything and delete the local database (the next up.ps1 builds it new)
```

Close the emulator from its window, or `adb -s emulator-5554 emu kill`.

## 5. Way B: from each repo in VS Code (debugging)

Open the repo's folder in VS Code (File, Open Folder), open Run and Debug (Ctrl+Shift+D), pick the launch from the list at the top, and press F5. Breakpoints work in the code of that repo. Each launch uses the local settings of section 2; nothing else needs changing.

### 5.1 Backend (`repeato.backend`)

First, once per session, the database:

```powershell
cd C:\Ritesh\workspace\repeato_workspace\repeato.infra
docker compose -f dev/compose.yaml up -d mysql-dev
```

On a new local database, or after pulling new migrations or data releases, bring the database up to date once:

```powershell
pwsh dev/up.ps1 -Apps backend
pwsh dev/down.ps1 -KeepDb        # stops that backend, keeps the database running for F5
```

Then in VS Code:

| Launch | What it does |
|---|---|
| **Backend: local** | `node src/server.js` with `repeato.infra/dev/backend.env`, debugger attached, port 3000 |
| **Backend: local, restart on save** | the same through nodemon: it restarts and reattaches on every save |
| **Backend: attach (port 9229)** | attach to a backend you started yourself with `node --inspect` |

Check: http://localhost:3000/api/health answers `"dbConnection":"Connected"`.

### 5.2 Console (`repeato.console`)

| Launch | What it does |
|---|---|
| **Console: local (server + browser)** | `bun run dev` on port 5174 with the server debugger, and Chrome with the browser debugger |
| **Console: server (local)** | only the server side (route handlers, server components) |
| **Console: browser (Chrome)** | only Chrome on http://localhost:5174, for a console already running |

Terminal equivalent without breakpoints: `bun run dev`.

### 5.3 Partner app (`repeato.vendor.app`)

| Launch | What it does |
|---|---|
| **Partner app: local (server + browser)** | `bun run dev:debug` on port 5175 (inspector 9230), and Chrome with the browser debugger |
| **Partner app: server (local)** | only the server side |
| **Partner app: browser (Chrome)** | only Chrome on http://localhost:5175 |

Terminal equivalent without breakpoints: `bun run dev`.

### 5.4 Customer app (`repeato.mobile.client`)

Pick the device in VS Code's status bar (bottom right) first: **Pixel_8** for the emulator (start it with `pwsh dev/android.ps1 -EmulatorOnly` if it is not listed), **Chrome** for the web, or your phone.

| Launch | Device | Settings |
|---|---|---|
| **Customer app: local backend (Android emulator)** | Pixel_8 | `env/dev.json` |
| **Customer app: local backend (Chrome)** | Chrome, http://localhost:56617 | `env/dev-localhost.json` |
| **Customer app: local backend (phone on USB)** | your phone | `env/dev-localhost.json`, runs `adb reverse tcp:3000 tcp:3000` first |
| **Customer app: local backend (profile mode, emulator)** | Pixel_8 | `env/dev.json`, for measuring speed |
| **Customer app: staging backend (release mode)** | any | `env/staging.json` |
| **Customer app: production backend (release mode)** | any | `env/prod.json`: real customers' data, look only |

Hot reload is on save; the debug toolbar has hot restart. Terminal equivalent:

```powershell
cd C:\Ritesh\workspace\repeato_workspace\repeato.mobile.client
flutter run -d emulator-5554 --dart-define-from-file=env/dev.json
```

(`flutter devices` lists the device ids.)

### 5.5 Mixing the two ways

Example: debug the backend, run everything else by script.

```powershell
cd C:\Ritesh\workspace\repeato_workspace\repeato.infra
pwsh dev/up.ps1                  # everything, migrations included
pwsh dev/down.ps1 -KeepDb        # stop the apps, keep the database
# VS Code, repeato.backend: F5 "Backend: local"
pwsh dev/up.ps1 -Apps console,partner,customer -SkipDatabaseSetup
pwsh dev/android.ps1             # optional: the app on the emulator
```

Debugging the console instead: `pwsh dev/up.ps1 -Apps backend,partner,customer`, then F5 "Console: local (server + browser)" in `repeato.console`. The rule: an app runs either from the script or from VS Code, never both, because both use the same port. If you try, `up.ps1` says the port is taken and skips that app.

## 6. iPhone

An iPhone build needs a Mac with Xcode; this Windows laptop cannot run the iOS simulator. On Windows, check iPhone layouts in the customer web (Chrome's device toolbar set to an iPhone), and on a real iPhone through TestFlight (`repeato.mobile.client/docs/06-deployment/ios-app-store.md`).

## 7. When something goes wrong

| Symptom | Cause and fix |
|---|---|
| `docker compose could not start repeato-mysql-dev` | Docker Desktop is not running. Start it, wait for "Engine running", run again. |
| Backend F5: `ECONNREFUSED 127.0.0.1:3308` | The database is not running: `docker compose -f dev/compose.yaml up -d mysql-dev` in `repeato.infra`. |
| Backend F5: `Table ... doesn't exist` or a missing column | The local database is behind: `pwsh dev/up.ps1 -Apps backend`, then `pwsh dev/down.ps1 -KeepDb`, then F5 again. |
| `Port 3000 is taken by another program` | A backend already runs (F5, or `bun run dev`). Stop one of them. |
| An app "does not answer yet" | Read `dev/.run/<app>.log` and `<app>.err.log`. Most often packages are missing: section 1. |
| A migration or data release fails | The message names it. Fix and run `up.ps1` again; it continues. For a clean start: `down.ps1 -Reset`. |
| The customer app shows a network error | Emulator: the backend is not running, or you picked a `localhost` launch on the emulator (use the Android emulator launch). Phone on USB: `adb reverse tcp:3000 tcp:3000` was not run (use the phone launch or `android.ps1 -Device`). |
| The emulator is slow or black | Windows Hypervisor Platform must be on (Windows Features). Close other emulators. As a last step `pwsh dev/android.ps1 -Recreate`. |
| The emulator window is taller than the screen | Use the zoom buttons on its side bar, or drag a corner; it remembers the size. |
| `No Android SDK found` | Set `ANDROID_HOME` to the SDK folder in Windows environment variables and open a new window. |
| Sign-in sends a real SMS | The backend was started with `bun run dev`, which reads `.env.development`. Stop it and use **Backend: local** or `dev/up.ps1`. |

Tests never use this database: backend tests run on the test containers (`repeato-test` on 127.0.0.1:3307 and 3309), which `dev/down.ps1` never touches.
