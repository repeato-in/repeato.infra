# Dot-sourced after lib/Common.psm1. The one Vercel deploy procedure shared by the console and the partner app: settings check, Vercel CLI, clean export of the commit (no .git, so the Hobby plan's commit-author check has nothing to block), vercel pull, remote build with the NEXT_PUBLIC_* values passed as --build-env, deploy to the project's production target.

function Invoke-VercelDeploy {
    param(
        [Parameter(Mandatory)][ValidateSet('console', 'partner')][string]$App,
        [Parameter(Mandatory)][ValidateSet('staging', 'prod')][string]$Env,
        [Parameter(Mandatory)][string]$Ref,
        [string]$RepoPath,
        [string]$KeyFile,
        [string]$PlannedTag,
        [scriptblock]$AfterPull,
        [scriptblock]$AfterDeploy,
        [switch]$KeepWorkDir
    )
    $info = Get-RepeatoApp $App
    if (-not $RepoPath) { $RepoPath = $info.Path }
    $commit = Resolve-Commit $RepoPath $Ref
    $shortSha = $commit.Substring(0, 7)
    $releaseName = Get-ReleaseName -Env $Env -Ref $Ref -PlannedTag $PlannedTag
    $suffix = if ($Env -eq 'prod') { 'PROD' } else { 'STAGING' }

    Write-Step "$App $Env deploy of $releaseName ($shortSha) to Vercel"
    $workDir = New-WorkDir "$App-$Env-$shortSha"
    try {
        Import-DeployKeys -App $App -KeyFile $KeyFile
        Assert-EnvSet @('VERCEL_TOKEN', 'VERCEL_ORG_ID', "VERCEL_PROJECT_ID_$suffix", "NEXT_PUBLIC_API_URL_$suffix")
        $env:VERCEL_PROJECT_ID = Get-EnvValue "VERCEL_PROJECT_ID_$suffix"
        $env:NEXT_PUBLIC_API_URL = Get-EnvValue "NEXT_PUBLIC_API_URL_$suffix"
        $env:NEXT_PUBLIC_APP_ENV = $Env
        Set-EnvDefault 'NEXT_PUBLIC_GOOGLE_MAPS_API' '' -Warning 'NEXT_PUBLIC_GOOGLE_MAPS_API is not set: the map picker shows only the latitude and longitude fields.'
        Write-Host "Using Vercel project: $env:VERCEL_PROJECT_ID"
        Write-Host "Using NEXT_PUBLIC_API_URL: $env:NEXT_PUBLIC_API_URL"
        Write-Host "Using NEXT_PUBLIC_APP_ENV: $env:NEXT_PUBLIC_APP_ENV"

        Add-BunToPath
        Invoke-Native bun @('--version') -FailMessage 'bun is not installed'
        Invoke-Native bun @('install', '--global', 'vercel@latest') -FailMessage 'Installing the Vercel CLI failed'
        Add-BunToPath

        $source = Export-Source -RepoPath $RepoPath -Commit $commit -WorkDir $workDir

        Write-Step 'Pulling the Vercel project settings'
        Invoke-Native vercel @('pull', '--yes', '--environment=production', '--token', $env:VERCEL_TOKEN) -WorkingDirectory $source -FailMessage 'vercel pull failed'
        if ($AfterPull) { & $AfterPull $source }

        Write-Step 'Building on Vercel and deploying to the production target of the project'
        $output = Invoke-Native vercel @(
            'deploy', '--yes', '--token', $env:VERCEL_TOKEN, '--prod',
            '--build-env', "NEXT_PUBLIC_API_URL=$env:NEXT_PUBLIC_API_URL",
            '--build-env', "NEXT_PUBLIC_APP_ENV=$env:NEXT_PUBLIC_APP_ENV",
            '--build-env', "NEXT_PUBLIC_GOOGLE_MAPS_API=$env:NEXT_PUBLIC_GOOGLE_MAPS_API"
        ) -WorkingDirectory $source -CaptureOutput -FailMessage 'vercel deploy failed'
        $deployUrl = ([string]$output -split "`n" | Where-Object { $_ -match '^https://\S+$' } | Select-Object -Last 1)
        if (-not $deployUrl) { $deployUrl = '(see the output above)' }
        Write-Host "Deployment URL: $deployUrl"
        if ($AfterDeploy) { & $AfterDeploy $deployUrl }

        Write-DeployResult -App $App -Env $Env -Commit $commit -Detail "url=$deployUrl"
    } finally {
        Remove-WorkDir $workDir -Keep:$KeepWorkDir
    }
}
