# Deploys the web build of repeato.mobile.client (customer app) to Firebase Hosting (staging: repeato-web-app-staging, prod: repeato-web-app) from a clean export of one commit or release tag. Android and iOS store builds stay separate (docs/RUNBOOK.md).
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging', 'prod')][string]$Env,
    [Parameter(Mandatory)][string]$Ref,
    [string]$RepoPath,
    [string]$KeyFile,
    [string]$PlannedTag,
    [switch]$KeepWorkDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/Common.psm1') -Force
if (-not $env:REPEATO_ISOLATED) { exit (Invoke-Isolated -ScriptPath $PSCommandPath -Bound $PSBoundParameters) }
Set-DryRun $DryRun.IsPresent

$app = Get-RepeatoApp 'customer'
if (-not $RepoPath) { $RepoPath = $app.Path }
$commit = Resolve-Commit $RepoPath $Ref
$shortSha = $commit.Substring(0, 7)
$releaseName = Get-ReleaseName -Env $Env -Ref $Ref -PlannedTag $PlannedTag
$suffix = if ($Env -eq 'prod') { 'PROD' } else { 'STAGING' }
$project = if ($Env -eq 'prod') { 'repeato-web-app' } else { 'repeato-web-app-staging' }
$siteUrl = if ($Env -eq 'prod') { 'https://app.repeato.in' } else { 'https://staging.app.repeato.in' }

Write-Step "Customer web $Env deploy of $releaseName ($shortSha) to Firebase Hosting ($project)"
$workDir = New-WorkDir "customer-$Env-$shortSha"
$savedCredentials = $env:GOOGLE_APPLICATION_CREDENTIALS
try {
    Import-DeployKeys -App 'customer' -KeyFile $KeyFile
    ConvertTo-KeyFile "FIREBASE_SERVICE_ACCOUNT_$($suffix)_JSON" -From @("FIREBASE_SERVICE_ACCOUNT_$suffix") -WorkDir (Join-Path $workDir 'keys')
    Assert-EnvSet @("PUBLIC_BASE_URL_$suffix", "BASE_URL_$suffix", "RAZORPAY_API_KEY_$suffix", "GOOGLE_MAPS_API_KEY_$suffix", "FIREBASE_SERVICE_ACCOUNT_$($suffix)_JSON")

    $source = Export-Source -RepoPath $RepoPath -Commit $commit -WorkDir $workDir

    Write-Step 'Building the web app'
    Invoke-Native flutter @('clean') -WorkingDirectory $source -FailMessage 'flutter clean failed'
    Invoke-Native flutter @('pub', 'get') -WorkingDirectory $source -FailMessage 'flutter pub get failed'
    Invoke-Native flutter @(
        'build', 'web', '--release',
        "--dart-define=APP_ENV=$Env",
        "--dart-define=PUBLIC_BASE_URL=$(Get-EnvValue "PUBLIC_BASE_URL_$suffix")",
        "--dart-define=BASE_URL=$(Get-EnvValue "BASE_URL_$suffix")",
        "--dart-define=RAZORPAY_API_KEY=$(Get-EnvValue "RAZORPAY_API_KEY_$suffix")",
        "--dart-define=GOOGLE_MAPS_API_KEY=$(Get-EnvValue "GOOGLE_MAPS_API_KEY_$suffix")",
        '--pwa-strategy=none'
    ) -WorkingDirectory $source -FailMessage 'flutter build web failed'

    Write-Step 'Deploying to Firebase Hosting'
    if (-not (Get-Command firebase -ErrorAction SilentlyContinue)) {
        Invoke-Native npm @('install', '--global', 'firebase-tools') -FailMessage 'Installing the Firebase CLI failed'
    }
    Invoke-Native firebase @('--version') -FailMessage 'The Firebase CLI does not run'
    $credential = Get-EnvValue "FIREBASE_SERVICE_ACCOUNT_$($suffix)_JSON"
    if (-not (Test-DryRun) -and -not (Test-Path -LiteralPath $credential -PathType Leaf)) { throw "FIREBASE_SERVICE_ACCOUNT_$($suffix)_JSON is neither a file nor JSON text" }
    $env:GOOGLE_APPLICATION_CREDENTIALS = $credential
    Invoke-Native firebase @('deploy', '--only', 'hosting', '--project', $project, '--non-interactive') -WorkingDirectory $source -FailMessage 'Firebase deployment failed'

    if (-not (Wait-HttpOk -Url $siteUrl -Attempts 5)) { throw "$siteUrl does not answer with 200 after the deploy." }
    Write-DeployResult -App 'customer' -Env $Env -Commit $commit -Detail "project=$project url=$siteUrl"
} finally {
    $env:GOOGLE_APPLICATION_CREDENTIALS = $savedCredentials
    Remove-WorkDir $workDir -Keep:$KeepWorkDir
}
