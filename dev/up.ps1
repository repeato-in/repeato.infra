# Starts the whole Repeato stack on this laptop with no cloud at all: MySQL repeato-mysql-dev (127.0.0.1:3308, repeato_dev_local), migrations and data releases, then the backend (3000), console (5174), partner app (5175) and customer web (5176) from the working copies, with SMS off, OTP bypass and the backend's own fakes for storage, payments, email and push. Prints the URLs and how to sign in.
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string[]]$Apps = @('backend', 'console', 'partner', 'customer'),
    [switch]$SkipDatabaseSetup,
    [int]$CustomerPort = 5176
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Common.psm1') -Force

$selected = @($Apps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $selected) { if ($name -notin (Get-RepeatoAppNames)) { throw "Unknown app '$name'. Use: $((Get-RepeatoAppNames) -join ', ')" } }

$runDir = Join-Path $PSScriptRoot '.run'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$pidFile = Join-Path $runDir 'pids.json'
$running = @{}
if (Test-Path $pidFile) {
    $saved = Get-Content -Raw $pidFile | ConvertFrom-Json -AsHashtable
    foreach ($key in $saved.Keys) { if (Get-Process -Id $saved[$key] -ErrorAction SilentlyContinue) { $running[$key] = $saved[$key] } }
}

$database = @{ Host = '127.0.0.1'; Port = 3308; Name = 'repeato_dev_local'; User = 'root'; Password = 'repeato-local-root' }
$api = 'http://localhost:3000/api/v1'

$backendEnv = @{
    SKIP_DOTENV                    = 'true'
    NODE_ENV                       = 'development'
    PORT                           = '3000'
    DB_HOST                        = $database.Host
    DB_HOST_PORT                   = [string]$database.Port
    DB_NAME                        = $database.Name
    DB_USERNAME                    = $database.User
    DB_PASSWORD                    = $database.Password
    DB_DIALECT                     = 'mysql'
    DB_SOCKET_PATH                 = ''
    JWT_SECRET                     = 'local-dev-jwt-secret'
    JWT_EXPIRES_IN                 = '3600'
    JWT_REFRESH_SECRET             = 'local-dev-refresh-secret'
    JWT_REFRESH_EXPIRES_IN         = '604800'
    REDIS_DISABLED                 = 'true'
    MESSAGING_ENABLED              = 'false'
    NOTIFICATIONS_ENABLED          = 'false'
    OTP_BYPASS                     = 'true'
    TEST_MODE                      = 'true'
    USE_LOCAL_STORAGE              = 'true'
    GCS_KEY_FILE                   = ''
    GCS_ENV_PREFIX                 = 'dev'
    BACKEND_URL                    = 'http://localhost:3000'
    APP_BASE_URL                   = 'http://localhost:3000'
    APP_WEB_BASE_URL               = "http://localhost:$CustomerPort"
    CONSOLE_URL                    = 'http://localhost:5174'
    APP_DEEP_LINK_SCHEME           = 'repeato'
    APP_ANDROID_STORE_URL          = 'https://play.google.com/store/apps/details?id=com.repeato.app'
    APP_IOS_STORE_URL              = 'https://apps.apple.com/app/repeato/id123456789'
    CORS_ORIGIN                    = "http://localhost:5174,http://localhost:5175,http://localhost:$CustomerPort,http://localhost:3000"
    RAZORPAY_KEY_ID                = 'rzp_test_local'
    RAZORPAY_KEY_SECRET            = 'local-fake-secret'
    RAZORPAY_WEBHOOK_SECRET        = 'local-fake-webhook'
    PRIMARY_MESSAGING_PROVIDER     = 'authkey'
    ANTHROPIC_API_KEY              = ''
    GOOGLE_PLACES_API_KEY          = [string]$env:REPEATO_DEV_GOOGLE_PLACES_API_KEY
    SCHEDULER_TIMEZONE             = 'Asia/Kolkata'
    BACKGROUND_JOB_CLEANUP_ENABLED = 'false'
    DISABLE_SCHEDULERS             = 'true'
}

function Start-AppProcess {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment, [int]$Port)
    if ($running.ContainsKey($Name)) { Write-Host "$Name already runs (pid $($running[$Name]))"; return }
    if (Test-TcpPort -HostName '127.0.0.1' -Port $Port) { Write-Warning "Port $Port is taken by another program: $Name not started. Free it or stop the other server."; return }
    $log = Join-Path $runDir "$Name.log"
    $errorLog = Join-Path $runDir "$Name.err.log"
    $command = (Get-Command $FilePath -ErrorAction Stop).Source
    $process = Start-Process -FilePath $command -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment -RedirectStandardOutput $log -RedirectStandardError $errorLog -PassThru -NoNewWindow
    $running[$Name] = $process.Id
    $running | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding utf8NoBOM
    Write-Host "$Name started (pid $($process.Id)), log $log"
}

function Invoke-BackendTool {
    param([string]$Label, [string]$FilePath, [string[]]$Arguments)
    Write-Host "> $Label"
    $command = (Get-Command $FilePath -ErrorAction Stop).Source
    $process = Start-Process -FilePath $command -ArgumentList $Arguments -WorkingDirectory (Get-RepeatoApp 'backend').Path -Environment $backendEnv -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Label failed (exit code $($process.ExitCode))" }
}

Add-BunToPath
Write-Step 'Database: repeato-mysql-dev on 127.0.0.1:3308'
& docker compose -f (Join-Path $PSScriptRoot 'compose.yaml') up -d mysql-dev
if ($LASTEXITCODE -ne 0) { throw 'docker compose could not start repeato-mysql-dev (is Docker Desktop running?)' }
$healthy = $false
for ($i = 1; $i -le 60; $i++) {
    $state = (& docker inspect --format '{{.State.Health.Status}}' repeato-mysql-dev 2>$null)
    if ($state -eq 'healthy') { $healthy = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $healthy) { throw 'repeato-mysql-dev did not become healthy in two minutes (docker logs repeato-mysql-dev)' }
Write-Host 'repeato-mysql-dev is healthy'

if ('backend' -in $selected -and -not $SkipDatabaseSetup) {
    Write-Step "Schema, migrations and data releases on $($database.Name)"
    if ($backendEnv.DB_HOST -ne '127.0.0.1' -or $backendEnv.DB_NAME -ne 'repeato_dev_local') { throw 'The local stack only ever writes to repeato_dev_local on 127.0.0.1.' }
    Invoke-BackendTool 'Create the tables from the models (fresh database only)' 'node' @('scripts/bootstrap-db.js')
    Invoke-BackendTool 'Run migrations' 'bun' @('x', 'sequelize-cli', 'db:migrate')
    Invoke-BackendTool 'Create the remaining model tables' 'node' @('scripts/bootstrap-db.js', '--after-migrations')
    $countRoles = "require('mysql2/promise').createConnection({host:process.env.DB_HOST,port:Number(process.env.DB_HOST_PORT),user:process.env.DB_USERNAME,password:process.env.DB_PASSWORD,database:process.env.DB_NAME}).then(async(c)=>{const [[r]]=await c.query('SELECT COUNT(*) AS n FROM Roles');await c.end();process.exit(r.n>0?0:3)}).catch((e)=>{console.error(e.message);process.exit(1)})"
    $probe = Start-Process -FilePath (Get-Command node).Source -ArgumentList @('-e', "`"$countRoles`"") -WorkingDirectory (Get-RepeatoApp 'backend').Path -Environment $backendEnv -NoNewWindow -Wait -PassThru
    if ($probe.ExitCode -eq 3) {
        foreach ($seed in @('01-seed-tariff-plans.js', '02-seed-tariff-plan-versions.js', '03-seed-roles.js', '04-seed-users.js', '05-seed-role-assignments.js', '06b-seed-cities.js', '11-seed-unit-types.js', '13-seed-product-categories.js')) {
            Invoke-BackendTool "Baseline seed $seed (new database)" 'bun' @('x', 'sequelize-cli', 'db:seed', '--seed', $seed)
        }
    } elseif ($probe.ExitCode -ne 0) {
        throw 'Could not read the Roles table of repeato_dev_local'
    }
    Invoke-BackendTool 'Apply data releases' 'node' @('src/scripts/runDataReleases.js', '--commit', "--confirm=$($database.Name)")
}

Write-Step 'Apps'
if ('backend' -in $selected) {
    Start-AppProcess -Name 'backend' -FilePath 'node' -Arguments @('src/server.js') -WorkingDirectory (Get-RepeatoApp 'backend').Path -Environment $backendEnv -Port 3000
}
if ('console' -in $selected) {
    Start-AppProcess -Name 'console' -FilePath 'bun' -Arguments @('run', 'dev') -WorkingDirectory (Get-RepeatoApp 'console').Path -Environment @{ NEXT_PUBLIC_API_URL = $api; NEXT_PUBLIC_APP_ENV = 'dev' } -Port 5174
}
if ('partner' -in $selected) {
    Start-AppProcess -Name 'partner' -FilePath 'bun' -Arguments @('run', 'dev') -WorkingDirectory (Get-RepeatoApp 'partner').Path -Environment @{ PORT = '5175'; NEXT_PUBLIC_API_URL = $api; NEXT_PUBLIC_APP_ENV = 'dev' } -Port 5175
}
if ('customer' -in $selected) {
    $defines = @(
        '--dart-define=APP_ENV=dev',
        "--dart-define=BASE_URL=$api",
        '--dart-define=PUBLIC_BASE_URL=http://localhost:3000',
        '--dart-define=RAZORPAY_API_KEY=rzp_test_local'
    )
    if ($env:REPEATO_DEV_GOOGLE_MAPS_API_KEY) { $defines += "--dart-define=GOOGLE_MAPS_API_KEY=$env:REPEATO_DEV_GOOGLE_MAPS_API_KEY" }
    Start-AppProcess -Name 'customer' -FilePath 'flutter' -Arguments (@('run', '-d', 'web-server', '--web-port', [string]$CustomerPort, '--web-hostname', 'localhost') + $defines) -WorkingDirectory (Get-RepeatoApp 'customer').Path -Environment @{} -Port $CustomerPort
}

Write-Step 'Waiting for the apps to answer'
$checks = [ordered]@{ backend = 'http://localhost:3000/api/health'; console = 'http://localhost:5174'; partner = 'http://localhost:5175'; customer = "http://localhost:$CustomerPort" }
foreach ($name in $checks.Keys) {
    if ($name -notin $selected -or -not $running.ContainsKey($name)) { continue }
    $ok = Wait-HttpOk -Url $checks[$name] -Attempts 40 -DelaySeconds 5 -Accept @(200, 307, 308)
    if (-not $ok) { Write-Warning "$name does not answer yet: see $(Join-Path $runDir "$name.log")" }
}

Write-Host ''
Write-Host 'Repeato runs locally:' -ForegroundColor Green
Write-Host "  Backend      http://localhost:3000/api/v1   (database $($database.Name) on 127.0.0.1:$($database.Port), user root, password $($database.Password))"
Write-Host '  Console      http://localhost:5174'
Write-Host '  Partner app  http://localhost:5175'
Write-Host "  Customer web http://localhost:$CustomerPort"
Write-Host ''
Write-Host 'Sign in: any mobile number with any 4-digit OTP (OTP bypass, no SMS is sent). Console admin: mobile 100, OTP 1234 (seeded admin; 101 is a second admin).'
Write-Host 'Payments, file storage, email and push use the backend''s local fakes (TEST_MODE=true); nothing reaches Razorpay, Google Cloud, AuthKey or Firebase.'
Write-Host "Logs: $runDir    Stop everything: pwsh $(Join-Path $PSScriptRoot 'down.ps1')"
