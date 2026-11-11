# Deploys repeato.backend to App Engine (staging: api-staging; prod: api and admin) from a clean export of one commit or release tag: install, package-lock.json from bun.lock, Cloud SQL proxy, database bootstrap and check, migrations, data releases, app.yaml from app.yaml.template, upload with retry, health check of the new version, traffic, dispatch rules.
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging', 'prod')][string]$Env,
    [Parameter(Mandatory)][string]$Ref,
    [string]$RepoPath,
    [string]$KeyFile,
    [string]$ConfirmDb,
    [switch]$SkipDatabase,
    [switch]$ForceUpload,
    [string]$PlannedTag,
    [switch]$KeepWorkDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/Common.psm1') -Force
if (-not $env:REPEATO_ISOLATED) { exit (Invoke-Isolated -ScriptPath $PSCommandPath -Bound $PSBoundParameters) }
Set-DryRun $DryRun.IsPresent

$app = Get-RepeatoApp 'backend'
if (-not $RepoPath) { $RepoPath = $app.Path }
$commit = Resolve-Commit $RepoPath $Ref
$shortSha = $commit.Substring(0, 7)

$releaseName = Get-ReleaseName -Env $Env -Ref $Ref -PlannedTag $PlannedTag
if ($Env -eq 'prod') {
    $version = $releaseName.Replace('.', '-')
} else {
    $version = "staging-$shortSha"
}

$suffix = if ($Env -eq 'prod') { 'PROD' } else { 'STAGING' }
$nodeEnv = if ($Env -eq 'prod') { 'production' } else { 'staging' }
$androidStore = 'https://play.google.com/store/apps/details?id=com.repeato.app'
$iosStore = 'https://apps.apple.com/app/repeato/id123456789'
$prodCors = 'https://admin.repeato.in,https://www.admin.repeato.in,https://app.repeato.in,https://www.app.repeato.in,https://go.repeato.in,https://www.repeato.in,https://repeato.in,https://repeato-web-app.web.app,https://repeato-console.vercel.app,capacitor://localhost'
$target = if ($Env -eq 'prod') {
    [pscustomobject]@{
        Services      = @('api', 'admin')
        AppBaseUrl    = 'https://go.repeato.in'
        AppWebBaseUrl = 'https://app.repeato.in'
        GcsEnvPrefix  = 'production'
        CorsOrigin    = $prodCors
        ConsoleUrl    = 'https://admin.repeato.in'
    }
} else {
    [pscustomobject]@{
        Services      = @('api-staging')
        AppBaseUrl    = 'https://api-staging-dot-repeato-439413.uc.r.appspot.com'
        AppWebBaseUrl = 'https://staging.app.repeato.in'
        GcsEnvPrefix  = 'staging'
        CorsOrigin    = 'https://staging.app.repeato.in,https://www.staging.app.repeato.in,https://admin-staging-dot-repeato-439413.uc.r.appspot.com,http://localhost:5173,http://localhost:8080,http://localhost,https://localhost,capacitor://localhost'
        ConsoleUrl    = 'https://admin-staging-dot-repeato-439413.uc.r.appspot.com'
    }
}

Write-Step "Backend $Env deploy of $releaseName ($shortSha) as App Engine version $version to $($target.Services -join ', ')"

$workDir = New-WorkDir "backend-$Env-$shortSha"
$keysDir = Join-Path $workDir 'keys'
$proxyProcess = $null
$savedCloudSdkConfig = $env:CLOUDSDK_CONFIG

function Get-Setting {
    param([string]$Name)
    return Get-EnvValue $Name
}

function Get-TemplateSettings {
    param([string]$ServiceName)
    return @{
        SERVICE_NAME                                  = $ServiceName
        NODE_ENV                                      = $nodeEnv
        DB_NAME                                       = Get-Setting "DB_NAME_$suffix"
        DB_USERNAME                                   = Get-Setting 'DB_USERNAME'
        DB_PASSWORD                                   = Get-Setting 'DB_PASSWORD'
        RAZORPAY_KEY_ID                               = Get-Setting "RAZORPAY_KEY_ID_$suffix"
        RAZORPAY_KEY_SECRET                           = Get-Setting "RAZORPAY_KEY_SECRET_$suffix"
        RAZORPAY_WEBHOOK_SECRET                       = Get-Setting "RAZORPAY_WEBHOOK_SECRET_$suffix"
        JWT_SECRET                                    = Get-Setting 'JWT_SECRET'
        JWT_REFRESH_SECRET                            = Get-Setting 'JWT_REFRESH_SECRET'
        MAPPLS_API_KEY                                = Get-Setting 'MAPPLS_API_KEY'
        GOOGLE_PLACES_API_KEY                         = Get-Setting 'GOOGLE_PLACES_API_KEY'
        ANTHROPIC_API_KEY                             = Get-Setting 'ANTHROPIC_API_KEY'
        CONSOLE_URL                                   = $target.ConsoleUrl
        OTP_LOG_HASH_KEY                              = Get-Setting 'OTP_LOG_HASH_KEY'
        SHARE_ADDRESS_SALT                            = Get-Setting 'SHARE_ADDRESS_SALT'
        APP_BASE_URL                                  = $target.AppBaseUrl
        APP_WEB_BASE_URL                              = $target.AppWebBaseUrl
        APP_DEEP_LINK_SCHEME                          = 'repeato'
        APP_ANDROID_STORE_URL                         = $androidStore
        APP_IOS_STORE_URL                             = $iosStore
        ANDROID_APP_SHA256                            = Get-Setting 'ANDROID_APP_SHA256'
        APPLE_TEAM_ID                                 = Get-Setting 'APPLE_TEAM_ID'
        GCS_ENV_PREFIX                                = $target.GcsEnvPrefix
        CORS_ORIGIN                                   = $target.CorsOrigin
        MESSAGING_ENABLED                             = Get-Setting "MESSAGING_ENABLED_$suffix"
        OTP_BYPASS                                    = Get-Setting "OTP_BYPASS_$suffix"
        FIXED_OTP_LOGIN_ENABLED                       = Get-Setting "FIXED_OTP_LOGIN_ENABLED_$suffix"
        SMS_BYPASSED_NUMBERS                          = Get-Setting "SMS_BYPASSED_NUMBERS_$suffix"
        SMS_BYPASSED_OTP                              = Get-Setting "SMS_BYPASSED_OTP_$suffix"
        PRIMARY_MESSAGING_PROVIDER                    = Get-Setting 'PRIMARY_MESSAGING_PROVIDER'
        AUTHKEY_API_KEY                               = Get-Setting 'AUTHKEY_API_KEY'
        AUTHKEY_API_URL                               = Get-Setting 'AUTHKEY_API_URL'
        AUTHKEY_SMS_API_URL                           = Get-Setting 'AUTHKEY_SMS_API_URL'
        AUTHKEY_SENDER_ID                             = Get-Setting 'AUTHKEY_SENDER_ID'
        AUTHKEY_COUNTRY_CODE                          = Get-Setting 'AUTHKEY_COUNTRY_CODE'
        FAST2SMS_API_KEY                              = Get-Setting 'FAST2SMS_API_KEY'
        FAST2SMS_SENDER_ID                            = Get-Setting 'FAST2SMS_SENDER_ID'
        FAST2SMS_OTP_TEMPLATE_ID                      = Get-Setting 'FAST2SMS_OTP_TEMPLATE_ID'
        FAST2SMS_SMS_TEMPLATE_ID                      = Get-Setting 'FAST2SMS_SMS_TEMPLATE_ID'
        FAST2SMS_OTP_ROUTE                            = Get-Setting 'FAST2SMS_OTP_ROUTE'
        FAST2SMS_WEBHOOK_SECRET                       = Get-Setting 'FAST2SMS_WEBHOOK_SECRET'
        MESSAGE_CENTRAL_CUSTOMER_ID                   = Get-Setting 'MESSAGE_CENTRAL_CUSTOMER_ID'
        MESSAGE_CENTRAL_KEY                           = Get-Setting 'MESSAGE_CENTRAL_KEY'
        MESSAGE_CENTRAL_SENDER_ID                     = Get-Setting 'MESSAGE_CENTRAL_SENDER_ID'
        MESSAGE_CENTRAL_ENTITY_ID                     = Get-Setting 'MESSAGE_CENTRAL_ENTITY_ID'
        MESSAGE_CENTRAL_OTP_TEMPLATE_ID               = Get-Setting 'MESSAGE_CENTRAL_OTP_TEMPLATE_ID'
        MESSAGE_CENTRAL_OTP_MESSAGE                   = Get-Setting 'MESSAGE_CENTRAL_OTP_MESSAGE'
        MESSAGE_CENTRAL_SMS_TEMPLATE_ID               = Get-Setting 'MESSAGE_CENTRAL_SMS_TEMPLATE_ID'
        MESSAGE_CENTRAL_CALLBACK_TOKEN                = Get-Setting 'MESSAGE_CENTRAL_CALLBACK_TOKEN'
        SCHEDULER_TIMEZONE                            = Get-Setting 'SCHEDULER_TIMEZONE'
        NOTIFICATIONS_ENABLED                         = Get-Setting 'NOTIFICATIONS_ENABLED'
        BACKGROUND_JOB_RETENTION_DAYS                 = Get-Setting 'BACKGROUND_JOB_RETENTION_DAYS'
        BACKGROUND_JOB_CLEANUP_CRON                   = Get-Setting 'BACKGROUND_JOB_CLEANUP_CRON'
        BACKGROUND_JOB_CLEANUP_ENABLED                = Get-Setting 'BACKGROUND_JOB_CLEANUP_ENABLED'
        BACKGROUND_JOB_CLEANUP_BATCH_SIZE             = Get-Setting 'BACKGROUND_JOB_CLEANUP_BATCH_SIZE'
        SUBSCRIPTION_WALLET_SETTLEMENT_CRON           = Get-Setting 'SUBSCRIPTION_WALLET_SETTLEMENT_CRON'
        SUBSCRIPTION_WALLET_DELIVERY_DAYS_AHEAD       = Get-Setting 'SUBSCRIPTION_WALLET_DELIVERY_DAYS_AHEAD'
        SUBSCRIPTION_WALLET_SETTLEMENT_CHUNK_SIZE     = Get-Setting 'SUBSCRIPTION_WALLET_SETTLEMENT_CHUNK_SIZE'
        SUBSCRIPTION_WALLET_SETTLEMENT_MAX_CHUNKS     = Get-Setting 'SUBSCRIPTION_WALLET_SETTLEMENT_MAX_CHUNKS'
        SUBSCRIPTION_RENEWAL_REMINDER_DAYS            = Get-Setting 'SUBSCRIPTION_RENEWAL_REMINDER_DAYS'
        SUBSCRIPTION_RENEWAL_REMINDER_CRON            = Get-Setting 'SUBSCRIPTION_RENEWAL_REMINDER_CRON'
        CLASS_INSTALLMENT_NOTIFICATION_COOLDOWN_HOURS = Get-Setting 'CLASS_INSTALLMENT_NOTIFICATION_COOLDOWN_HOURS'
        CLASS_INSTALLMENT_LOOKAHEAD_COUNT             = Get-Setting 'CLASS_INSTALLMENT_LOOKAHEAD_COUNT'
    }
}

function Write-AppYaml {
    param([string]$SourceDir, [string]$ServiceName)
    $templatePath = Join-Path $SourceDir 'app.yaml.template'
    $settings = Get-TemplateSettings $ServiceName
    if (Test-DryRun) {
        Write-Host "[dry-run] render app.yaml for $ServiceName from app.yaml.template ($($settings.Count) settings)" -ForegroundColor DarkGray
        return
    }
    $template = Get-Content -Raw -LiteralPath $templatePath
    $rendered = [regex]::Replace($template, '\$([A-Z][A-Z0-9_]*)', { param($match) [string]$settings[$match.Groups[1].Value] })
    Set-Content -LiteralPath (Join-Path $SourceDir 'app.yaml') -Value $rendered -Encoding utf8NoBOM
}

function Invoke-AppDeployWithRetry {
    param([string]$SourceDir, [string]$ServiceName, [int]$MaxAttempts = 3)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "Deploy attempt $attempt/$MaxAttempts for service '$ServiceName'"
        try {
            Invoke-Native gcloud @('app', 'deploy', 'app.yaml', '--project', $env:GCP_PROJECT, '--version', $version, '--no-promote', '--quiet') -WorkingDirectory $SourceDir -CaptureOutput -FailMessage "gcloud app deploy failed for '$ServiceName'" | Out-Null
            return
        } catch {
            $isFetchFailure = $_.Exception.Message -like '*Failed to download at least one file*'
            if (-not $isFetchFailure -or $attempt -eq $MaxAttempts) { throw }
            $backoffSeconds = 10 * $attempt
            Write-Warning "Transient Cloud Build fetch failure for '$ServiceName'. Retrying in $backoffSeconds seconds..."
            Start-Sleep -Seconds $backoffSeconds
        }
    }
}

function Test-VersionExists {
    param([string]$ServiceName)
    if (Test-DryRun) { return $false }
    $found = & gcloud app versions list --service $ServiceName --project $env:GCP_PROJECT --filter "version.id=$version" --format 'value(version.id)' 2>$null
    return ($LASTEXITCODE -eq 0 -and [string]$found -match [regex]::Escape($version))
}

function Get-ProxyPath {
    if ($env:CLOUD_SQL_PROXY -and (Test-Path $env:CLOUD_SQL_PROXY)) { return $env:CLOUD_SQL_PROXY }
    $onLaptop = Join-Path (Split-Path -Parent (Get-RepeatoKeysDir)) 'cloud-sql-proxy.exe'
    if ($IsWindows -and (Test-Path $onLaptop)) { return $onLaptop }
    $name = if ($IsWindows) { 'cloud-sql-proxy.x64.exe' } else { 'cloud-sql-proxy.linux.amd64' }
    $binDir = Join-Path (Get-InfraRoot) '.work/bin'
    $path = Join-Path $binDir $name
    if (-not (Test-Path $path)) {
        if (Test-DryRun) { Write-Host "[dry-run] download Cloud SQL proxy v2.21.2 to $path" -ForegroundColor DarkGray; return $path }
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Invoke-WebRequest -Uri "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.21.2/$name" -OutFile $path -UseBasicParsing
        if (-not $IsWindows) { & chmod +x $path }
    }
    return $path
}

try {
    Import-DeployKeys -App 'backend' -KeyFile $KeyFile
    Set-EnvAlias 'GCP_PROJECT' @('GCP_PROJECT_ID')
    ConvertTo-KeyFile 'GCP_SA_KEY_FILE' -From @('GCP_SA_KEY') -WorkDir $keysDir
    ConvertTo-KeyFile 'GCLOUD_SQL_KEY_FILE' -From @('GCP_CLOUD_SQL_SA_KEY', 'GCP_SA_KEY_FILE') -WorkDir $keysDir
    $env:SKIP_DOTENV = 'true'

    Assert-EnvSet @('GCP_PROJECT', 'GCP_SA_KEY_FILE', "DB_NAME_$suffix", 'DB_USERNAME', 'DB_PASSWORD', "RAZORPAY_KEY_ID_$suffix", "RAZORPAY_KEY_SECRET_$suffix", "RAZORPAY_WEBHOOK_SECRET_$suffix", 'JWT_SECRET', 'JWT_REFRESH_SECRET', "MESSAGING_ENABLED_$suffix", "OTP_BYPASS_$suffix", 'PRIMARY_MESSAGING_PROVIDER', 'AUTHKEY_API_KEY', 'AUTHKEY_API_URL', 'AUTHKEY_SMS_API_URL', 'AUTHKEY_SENDER_ID', 'AUTHKEY_COUNTRY_CODE', 'GCLOUD_SQL_KEY_FILE')

    Set-EnvDefault "SMS_BYPASSED_NUMBERS_$suffix" ''
    Set-EnvDefault "SMS_BYPASSED_OTP_$suffix" ''
    Set-EnvDefault 'MAPPLS_API_KEY' '' -Warning 'MAPPLS_API_KEY is not set: place search will fall back to our own societies, pincodes and cities.'
    Set-EnvDefault 'GOOGLE_PLACES_API_KEY' '' -Warning 'GOOGLE_PLACES_API_KEY is not set: place search (Google, ADR-0015 Decision 19) will fall back to our own societies, pincodes and cities.'
    foreach ($name in @('FAST2SMS_API_KEY', 'FAST2SMS_SENDER_ID', 'FAST2SMS_OTP_TEMPLATE_ID', 'FAST2SMS_SMS_TEMPLATE_ID', 'FAST2SMS_OTP_ROUTE', 'MESSAGE_CENTRAL_CUSTOMER_ID', 'MESSAGE_CENTRAL_KEY', 'MESSAGE_CENTRAL_SENDER_ID', 'MESSAGE_CENTRAL_ENTITY_ID', 'MESSAGE_CENTRAL_OTP_TEMPLATE_ID', 'MESSAGE_CENTRAL_OTP_MESSAGE', 'MESSAGE_CENTRAL_SMS_TEMPLATE_ID', 'MESSAGE_CENTRAL_CALLBACK_TOKEN', 'FAST2SMS_WEBHOOK_SECRET')) { Set-EnvDefault $name '' }
    if ($env:PRIMARY_MESSAGING_PROVIDER -eq 'fast2sms' -and ([string]::IsNullOrWhiteSpace($env:FAST2SMS_API_KEY) -or ($env:FAST2SMS_OTP_ROUTE -ne 'otp' -and ([string]::IsNullOrWhiteSpace($env:FAST2SMS_SENDER_ID) -or [string]::IsNullOrWhiteSpace($env:FAST2SMS_OTP_TEMPLATE_ID))))) {
        throw 'PRIMARY_MESSAGING_PROVIDER is fast2sms: set FAST2SMS_API_KEY, FAST2SMS_SENDER_ID and FAST2SMS_OTP_TEMPLATE_ID (or FAST2SMS_OTP_ROUTE=otp) first (backend docs/deploy/switch-sms-provider.md)'
    }
    if ($env:PRIMARY_MESSAGING_PROVIDER -eq 'messagecentral' -and ([string]::IsNullOrWhiteSpace($env:MESSAGE_CENTRAL_CUSTOMER_ID) -or [string]::IsNullOrWhiteSpace($env:MESSAGE_CENTRAL_KEY) -or [string]::IsNullOrWhiteSpace($env:MESSAGE_CENTRAL_SENDER_ID) -or [string]::IsNullOrWhiteSpace($env:MESSAGE_CENTRAL_ENTITY_ID) -or [string]::IsNullOrWhiteSpace($env:MESSAGE_CENTRAL_OTP_TEMPLATE_ID) -or -not ($env:MESSAGE_CENTRAL_OTP_MESSAGE -like '*{#var#}*'))) {
        throw 'PRIMARY_MESSAGING_PROVIDER is messagecentral: set MESSAGE_CENTRAL_CUSTOMER_ID, MESSAGE_CENTRAL_KEY, MESSAGE_CENTRAL_SENDER_ID, MESSAGE_CENTRAL_ENTITY_ID, MESSAGE_CENTRAL_OTP_TEMPLATE_ID and MESSAGE_CENTRAL_OTP_MESSAGE (with {#var#}) first (backend docs/deploy/switch-sms-provider.md)'
    }
    Set-EnvDefault 'ANTHROPIC_API_KEY' '' -Warning 'ANTHROPIC_API_KEY is not set: reading shop documents (ADR-0024) will say it is not set up.'
    Set-EnvDefault 'OTP_LOG_HASH_KEY' ''
    Set-EnvDefault 'SHARE_ADDRESS_SALT' ''
    Set-EnvDefault 'ANDROID_APP_SHA256' 'E1:21:A9:0F:65:2D:41:7B:44:20:7C:25:5A:7E:3A:DE:5A:0C:3B:67:4C:67:1B:C4:77:19:1B:8A:25:F6:25:DE'
    Set-EnvDefault 'APPLE_TEAM_ID' '' -Warning 'APPLE_TEAM_ID is not set: share links open in the browser on iPhone until the Apple team id is set (ADR-0023).'
    Set-EnvDefault 'SCHEDULER_TIMEZONE' 'Asia/Kolkata'
    Set-EnvDefault 'NOTIFICATIONS_ENABLED' 'true'
    Set-EnvDefault 'BACKGROUND_JOB_RETENTION_DAYS' '90'
    Set-EnvDefault 'BACKGROUND_JOB_CLEANUP_CRON' '0 3 * * *'
    Set-EnvDefault 'BACKGROUND_JOB_CLEANUP_ENABLED' 'true'
    Set-EnvDefault 'BACKGROUND_JOB_CLEANUP_BATCH_SIZE' '500'
    Set-EnvDefault 'SUBSCRIPTION_WALLET_SETTLEMENT_CRON' '*/15 * * * *'
    Set-EnvDefault 'SUBSCRIPTION_WALLET_DELIVERY_DAYS_AHEAD' '1'
    Set-EnvDefault 'SUBSCRIPTION_WALLET_SETTLEMENT_CHUNK_SIZE' '50'
    Set-EnvDefault 'SUBSCRIPTION_WALLET_SETTLEMENT_MAX_CHUNKS' '20'
    Set-EnvDefault 'SUBSCRIPTION_RENEWAL_REMINDER_DAYS' '3'
    Set-EnvDefault 'SUBSCRIPTION_RENEWAL_REMINDER_CRON' '0 20 * * *'
    Set-EnvDefault 'CLASS_INSTALLMENT_NOTIFICATION_COOLDOWN_HOURS' '24'
    Set-EnvDefault 'CLASS_INSTALLMENT_LOOKAHEAD_COUNT' '4'

    Write-Step 'Checking every app.yaml.template setting is set by this script'
    $template = (& git -C $RepoPath show "$($commit):app.yaml.template") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "No app.yaml.template at $shortSha" }
    $known = (Get-TemplateSettings 'check').Keys
    $unknown = @([regex]::Matches($template, '\$([A-Z][A-Z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $_ -notin $known })
    if ($unknown.Count -gt 0) { throw "app.yaml.template at $shortSha uses settings this script does not set: $($unknown -join ', '). Add them to apps/backend/deploy.ps1 first." }
    Write-Host 'Every template setting is covered.'

    $source = Export-Source -RepoPath $RepoPath -Commit $commit -WorkDir $workDir

    Write-Step 'Installing dependencies and writing package-lock.json from bun.lock for the App Engine build'
    Add-BunToPath
    Invoke-Native bun @('install', '--frozen-lockfile') -WorkingDirectory $source -FailMessage 'Installing dependencies failed'
    Invoke-Native node @('scripts/npm-lock-from-bun.js') -WorkingDirectory $source -FailMessage 'Writing package-lock.json from bun.lock failed'

    Write-Step 'Authenticating to GCP (private gcloud config for this run, your own gcloud login is untouched)'
    if (-not (Test-DryRun)) { $env:CLOUDSDK_CONFIG = Join-Path $workDir 'gcloud'; New-Item -ItemType Directory -Path $env:CLOUDSDK_CONFIG -Force | Out-Null }
    Invoke-Native gcloud @('auth', 'activate-service-account', '--key-file', $env:GCP_SA_KEY_FILE, '--quiet') -FailMessage 'gcloud authentication failed'
    Invoke-Native gcloud @('config', 'set', 'project', $env:GCP_PROJECT, '--quiet') -FailMessage 'Setting the gcloud project failed'

    $dbName = Get-EnvValue "DB_NAME_$suffix"
    if ($SkipDatabase) {
        Write-Warning 'Skipping the database steps (-SkipDatabase): no migrations or data releases.'
    } else {
        $proxyPort = if ($env:CLOUD_SQL_PROXY_PORT) { [int]$env:CLOUD_SQL_PROXY_PORT } else { 3306 }
        Write-Step "Starting the Cloud SQL proxy on 127.0.0.1:$proxyPort"
        if (-not (Test-DryRun) -and (Test-TcpPort -HostName '127.0.0.1' -Port $proxyPort)) {
            throw "Something already listens on 127.0.0.1:$proxyPort. Stop it (or set CLOUD_SQL_PROXY_PORT) so the migrations cannot reach the wrong database."
        }
        $proxyExe = Get-ProxyPath
        $proxyArgs = @("--credentials-file=$env:GCLOUD_SQL_KEY_FILE", "--port=$proxyPort", "$($env:GCP_PROJECT):us-central1:repeato-db")
        if (Test-DryRun) {
            Write-Host "[dry-run] $(Format-Command $proxyExe $proxyArgs)" -ForegroundColor DarkGray
        } else {
            $proxyProcess = Start-Process -FilePath $proxyExe -ArgumentList $proxyArgs -PassThru -NoNewWindow
            $ready = $false
            for ($i = 1; $i -le 15; $i++) {
                if (Test-TcpPort -HostName '127.0.0.1' -Port $proxyPort) { $ready = $true; break }
                Write-Host "Waiting for proxy... ($i/15)"
                Start-Sleep -Seconds 2
            }
            if (-not $ready) { throw 'Cloud SQL Proxy failed to start' }
            Write-Host 'Cloud SQL Proxy is ready'
        }

        $env:DB_HOST = '127.0.0.1'
        $env:DB_HOST_PORT = [string]$proxyPort
        $env:DB_NAME = $dbName
        $env:DB_DIALECT = 'mysql'
        $env:NODE_ENV = $nodeEnv

        Write-Step "Bootstrapping the $Env database schema (fresh database only)"
        Invoke-Native node @('scripts/bootstrap-db.js') -WorkingDirectory $source -FailMessage 'Bootstrapping the database failed'

        Write-Step "Checking the connection reaches $dbName"
        $verify = @'
const mysql = require('mysql2/promise');
(async () => {
  const expected = String(process.env.DB_NAME || '').trim();
  const conn = await mysql.createConnection({ host: process.env.DB_HOST, port: Number(process.env.DB_HOST_PORT || 3306), user: process.env.DB_USERNAME, password: process.env.DB_PASSWORD, database: expected });
  const [[dbRow]] = await conn.query('SELECT DATABASE() AS dbName');
  const connected = String(dbRow.dbName || '').trim();
  const [[tblRow]] = await conn.query('SELECT COUNT(*) AS total FROM information_schema.tables WHERE table_schema = DATABASE()');
  console.log('Target DB (from settings):', expected);
  console.log('Connected DB:', connected);
  console.log('Total tables in connected DB:', tblRow.total);
  if (!expected || connected !== expected) throw new Error('Connected DB does not match the configured database name');
  await conn.end();
})().catch((err) => { console.error('DB verification failed:', err.message); process.exit(1); });
'@
        Invoke-Native node @('-e', $verify) -WorkingDirectory $source -FailMessage 'Database check failed'

        Write-Step 'Migrations: status, then run'
        Invoke-Native bun @('x', 'sequelize-cli', 'db:migrate:status') -WorkingDirectory $source -AllowFailure
        Invoke-Native bun @('x', 'sequelize-cli', 'db:migrate') -WorkingDirectory $source -FailMessage 'Migrations failed'
        Invoke-Native node @('scripts/bootstrap-db.js', '--after-migrations') -WorkingDirectory $source -FailMessage 'Creating the remaining model tables failed'

        Write-Step 'Data releases: status and dry run'
        Invoke-Native node @('src/scripts/runDataReleases.js', '--status') -WorkingDirectory $source -FailMessage 'Reading the data release status failed'
        Invoke-Native node @('src/scripts/runDataReleases.js', '--dry-run') -WorkingDirectory $source -FailMessage 'The data release dry run failed'

        if (-not $ConfirmDb) {
            if (Test-DryRun) {
                $ConfirmDb = $dbName
            } elseif (Test-Interactive) {
                $ConfirmDb = Read-Host "Type the database name ($dbName) to apply the data releases"
            } else {
                $ConfirmDb = $dbName
                Write-Host "Non-interactive run: confirming the data releases for $dbName"
            }
        }
        if ($ConfirmDb -ne $dbName) { throw "Database name not confirmed (typed '$ConfirmDb'). Nothing was deployed; migrations already ran." }
        Write-Step "Data releases: commit on $dbName"
        Invoke-Native node @('src/scripts/runDataReleases.js', '--commit', "--confirm=$dbName") -WorkingDirectory $source -FailMessage 'Data releases failed'
    }

    foreach ($service in $target.Services) {
        Write-Step "Service $service, version $version"
        if (-not $ForceUpload -and (Test-VersionExists $service)) {
            Write-Host "Version $version already exists on ${service}: no upload, only traffic."
        } else {
            Write-AppYaml -SourceDir $source -ServiceName $service
            Invoke-AppDeployWithRetry -SourceDir $source -ServiceName $service
        }
        $versionUrl = "https://$version-dot-$service-dot-$($env:GCP_PROJECT).uc.r.appspot.com/api/health"
        if (-not (Wait-HttpOk -Url $versionUrl)) { throw "The new version $version of $service does not answer $versionUrl with 200. Traffic was not moved." }
        Invoke-Native gcloud @('app', 'services', 'set-traffic', $service, '--project', $env:GCP_PROJECT, '--splits', "$version=1", '--quiet') -FailMessage "Setting traffic on $service failed"
    }

    Write-Step 'Deploying dispatch routing rules'
    Invoke-Native gcloud @('app', 'deploy', 'dispatch.yaml', '--project', $env:GCP_PROJECT, '--quiet') -WorkingDirectory $source -FailMessage 'Deploying dispatch rules failed'

    foreach ($service in $target.Services) {
        $serviceUrl = "https://$service-dot-$($env:GCP_PROJECT).uc.r.appspot.com/api/health"
        if (-not (Wait-HttpOk -Url $serviceUrl -Attempts 5)) { throw "$service does not answer $serviceUrl with 200 after the traffic move." }
    }

    Write-DeployResult -App 'backend' -Env $Env -Commit $commit -Detail "version=$version services=$($target.Services -join ',')"
} finally {
    if ($proxyProcess -and -not $proxyProcess.HasExited) { Stop-Process -Id $proxyProcess.Id -Force }
    $env:CLOUDSDK_CONFIG = $savedCloudSdkConfig
    Remove-WorkDir $workDir -Keep:$KeepWorkDir
}
