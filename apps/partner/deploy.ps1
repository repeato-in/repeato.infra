# Deploys repeato.vendor.app (the partner app, also the Play Store "Repeato Partner" TWA) to its Vercel project for staging or prod from a clean export of one commit or release tag; for prod it also checks the Firebase keys and the Play Store ownership file.
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
. (Join-Path $PSScriptRoot '../../lib/VercelDeploy.ps1')
Set-DryRun $DryRun.IsPresent

$afterPull = $null
$afterDeploy = $null
if ($Env -eq 'prod') {
    $afterPull = {
        param($source)
        $pulledEnv = Join-Path $source '.vercel/.env.production.local'
        if (Test-Path $pulledEnv) {
            if (-not (Select-String -Path $pulledEnv -Pattern '^NEXT_PUBLIC_FIREBASE_API_KEY=' -Quiet)) {
                Write-Warning 'NEXT_PUBLIC_FIREBASE_* keys are not in the Vercel project: order alerts stay off in this build (gap G112).'
            }
        }
    }
    $afterDeploy = {
        param($deployUrl)
        Write-Host "Checking the Play Store ownership file after $deployUrl"
        if (Test-DryRun) { Write-Host '[dry-run] check https://partner.repeato.in/.well-known/assetlinks.json lists the Play fingerprints' -ForegroundColor DarkGray; return }
        $ownership = @()
        try {
            $ownership = @((Invoke-WebRequest -Uri 'https://partner.repeato.in/.well-known/assetlinks.json' -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json)
        } catch {
            Write-Warning "Could not read https://partner.repeato.in/.well-known/assetlinks.json: $($_.Exception.Message)"
        }
        if ($ownership.Count -eq 0) {
            Write-Warning 'The ownership file lists no fingerprints: set TWA_SHA256_FINGERPRINTS in the Vercel project (Production) and deploy again, or the Play Store app shows a browser address bar.'
        } else {
            Write-Host "Ownership file: $($ownership[0].target.package_name) with $(@($ownership[0].target.sha256_cert_fingerprints).Count) fingerprint(s)"
        }
    }
}

Invoke-VercelDeploy -App 'partner' -Env $Env -Ref $Ref -RepoPath $RepoPath -KeyFile $KeyFile -PlannedTag $PlannedTag -AfterPull $afterPull -AfterDeploy $afterDeploy -KeepWorkDir:$KeepWorkDir
