# One release command for Repeato. Staging: deploys main's current commit of each app (or given refs) and marks it as the candidate (tag deployed/staging). Prod: tags the staging candidate of each app with one release id vYYYY.MM.DD-N, pushes the tags, deploys backend, console, partner app and customer web in that order, stops at the first failure and writes a release record in releases/. -Tag redeploys an existing release (a rollback when it is older than production: the backend then skips the database steps); -Hotfix releases a fix branched from the production tag.
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging', 'prod')][string]$Env,
    [string[]]$Repos = @('backend', 'console', 'partner', 'customer'),
    [string]$Refs,
    [string]$Tag,
    [ValidateSet('local', 'github')][string]$Via = 'local',
    [switch]$Hotfix,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Common.psm1') -Force
if (-not $env:REPEATO_ISOLATED) { exit (Invoke-Isolated -ScriptPath $PSCommandPath -Bound $PSBoundParameters) }
Set-DryRun $DryRun.IsPresent

$order = Get-RepeatoAppNames
$selected = @($Repos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $selected) { if ($name -notin $order) { throw "Unknown repo '$name'. Use: $($order -join ', ')" } }
$selected = @($order | Where-Object { $_ -in $selected })

$explicitRefs = @{}
if ($Refs) {
    foreach ($pair in $Refs -split ',') {
        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2 -or $parts[0].Trim() -notin $order) { throw "Write -Refs as app=ref pairs, for example: -Refs 'backend=abc1234,console=v2026.11.11-1'" }
        $explicitRefs[$parts[0].Trim()] = $parts[1].Trim()
    }
}
if ($Tag -and $Env -ne 'prod') { throw '-Tag redeploys an existing production release; use it with -Env prod.' }
if ($Tag -and -not (Test-ReleaseTag $Tag)) { throw "-Tag must look like vYYYY.MM.DD-N, got '$Tag'." }
if ($Tag -and $Hotfix) { throw 'Use either -Tag (redeploy an existing release) or -Hotfix (new release from a fix branch).' }

$infraRoot = Get-InfraRoot
$releasesDir = Join-Path $infraRoot 'releases'
$started = Get-Date
$mode = if ($Env -eq 'staging') { 'staging' } elseif ($Tag) { 'rollback' } elseif ($Hotfix) { 'hotfix' } else { 'release' }

Write-Step "Repeato $mode to $Env via $Via$(if (Test-DryRun) { ' (dry run: nothing is tagged, pushed or deployed)' })"

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($name in $selected) {
    $app = Get-RepeatoApp $name
    if (-not (Test-Path (Join-Path $app.Path '.git'))) { throw "No git repository at $($app.Path)" }
    Write-Host "Fetching $($app.Folder)"
    & git -C $app.Path fetch origin --tags --force --quiet
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed in $($app.Folder)" }

    $ref = if ($explicitRefs.ContainsKey($name)) { $explicitRefs[$name] }
    elseif ($Env -eq 'staging') { 'origin/main' }
    elseif ($Tag) { $Tag }
    elseif ($Hotfix) { 'deployed/prod' }
    else { 'deployed/staging' }
    if ($ref -eq 'deployed/staging' -and (Test-DryRun)) {
        & git -C $app.Path rev-parse --quiet --verify 'refs/tags/deployed/staging' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "$($app.Folder) has no deployed/staging tag yet (nothing went to staging through this script): the dry run shows origin/main instead."; $ref = 'origin/main' }
    }
    $commit = Resolve-Commit $app.Path $ref

    $onRemote = [bool](& git -C $app.Path branch -r --contains $commit 2>$null)
    $remoteTag = [bool](& git -C $app.Path ls-remote --tags origin $ref 2>$null)
    if (-not $onRemote -and -not $remoteTag) { throw "$($app.Folder): $ref ($($commit.Substring(0, 7))) is not on GitHub. Push it first." }
    & git -C $app.Path merge-base --is-ancestor $commit origin/main
    $onMain = $LASTEXITCODE -eq 0
    if ($mode -eq 'release' -and -not $onMain) { throw "$($app.Folder): $($commit.Substring(0, 7)) is not on main. A fix from a production tag is a hotfix: use -Hotfix." }
    $dirty = [bool](& git -C $app.Path status --porcelain --untracked-files=no 2>$null)
    if ($dirty) { Write-Warning "$($app.Folder) has uncommitted changes in its working copy. They are not deployed: every build comes from a clean export of the commit." }

    $plan.Add([pscustomobject]@{
        Name    = $name
        App     = $app
        Ref     = $ref
        Commit  = $commit
        Short   = $commit.Substring(0, 7)
        Subject = ((& git -C $app.Path log -1 --format=%s $commit) -join ' ')
        OnMain  = $onMain
        Tag     = $null
        Result  = 'not run'
        Detail  = ''
        Seconds = 0
    })
}

$backendItem = $plan | Where-Object { $_.Name -eq 'backend' } | Select-Object -First 1
if ($mode -eq 'rollback' -and $backendItem) {
    $current = (& git -C $backendItem.App.Path rev-parse --quiet --verify 'refs/tags/deployed/prod^{commit}' 2>$null)
    $older = $false
    if ($current -and $current -ne $backendItem.Commit) {
        & git -C $backendItem.App.Path merge-base --is-ancestor $backendItem.Commit $current
        $older = $LASTEXITCODE -eq 0
    }
    if (-not $older) {
        $mode = 'redeploy'
        Write-Host "$Tag is not older than what production runs: redeploying it with the database steps."
    } else {
        Write-Host "$Tag is older than what production runs: rollback, the backend moves traffic only and skips the database steps."
    }
}

$releaseId = $null
if ($Env -eq 'prod') {
    if ($Tag) {
        $releaseId = $Tag
    } else {
        $date = Get-Date -Format 'yyyy.MM.dd'
        $number = 1
        while ($true) {
            $candidate = "v$date-$number"
            $taken = $false
            foreach ($name in $order) {
                $path = (Get-RepeatoApp $name).Path
                & git -C $path rev-parse --quiet --verify "refs/tags/$candidate" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $taken = $true; break }
            }
            if (-not $taken) { $releaseId = $candidate; break }
            $number++
        }
    }
    foreach ($item in $plan) { $item.Tag = $releaseId }
}

$previousProd = $null
$backendPath = (Get-RepeatoApp 'backend').Path
$prodTags = @(& git -C $backendPath tag --list 'v20*' --sort=-creatordate 2>$null | Where-Object { (Test-ReleaseTag $_) -and $_ -ne $releaseId })
if ($prodTags.Count -gt 0) { $previousProd = $prodTags[0] }

Write-Step 'Plan'
$plan | Format-Table @{ n = 'App'; e = { $_.Name } }, @{ n = 'Ref'; e = { $_.Ref } }, @{ n = 'Commit'; e = { $_.Short } }, @{ n = 'On main'; e = { $_.OnMain } }, @{ n = 'Tag'; e = { if ($_.Tag) { $_.Tag } else { '-' } } }, @{ n = 'Commit message'; e = { $_.Subject } } -AutoSize | Out-String | Write-Host
if ($releaseId) { Write-Host "Release id: $releaseId    Previous production release: $(if ($previousProd) { $previousProd } else { 'none found' })" }

$backendInPlan = $plan | Where-Object { $_.Name -eq 'backend' }
$confirmDb = $null
if ($backendInPlan -and $mode -ne 'rollback') {
    $suffix = if ($Env -eq 'prod') { 'PROD' } else { 'STAGING' }
    Import-DeployKeys -App 'backend'
    $confirmDb = Get-EnvValue "DB_NAME_$suffix"
    if (-not $confirmDb -and -not (Test-DryRun)) { throw "DB_NAME_$suffix is not set in the backend key file." }
    Write-Host "Backend database: $confirmDb (migrations and data releases run on it)"
}

if (-not (Test-DryRun) -and -not $Yes) {
    if (-not (Test-Interactive)) { throw 'Not an interactive session: pass -Yes to go ahead without the typed confirmations.' }
    if ($Env -eq 'prod') {
        $typed = Read-Host "Type the release id ($releaseId) to go ahead"
        if ($typed -ne $releaseId) { throw 'Not confirmed. Nothing was tagged or deployed.' }
        if ($confirmDb) {
            $typedDb = Read-Host "Type the production database name ($confirmDb) to allow its migrations and data releases"
            if ($typedDb -ne $confirmDb) { throw 'Database name not confirmed. Nothing was tagged or deployed.' }
        }
    } else {
        $typed = Read-Host 'Type staging to go ahead'
        if ($typed -ne 'staging') { throw 'Not confirmed. Nothing was deployed.' }
    }
}

if ($Env -eq 'prod' -and -not $Tag) {
    Write-Step "Tagging $releaseId"
    foreach ($item in $plan) {
        Invoke-Native git @('-C', $item.App.Path, 'tag', '-a', $releaseId, $item.Commit, '-m', "Repeato release $releaseId ($mode)") -FailMessage "Tagging $($item.App.Folder) failed"
    }
    foreach ($item in $plan) {
        Invoke-Native git @('-C', $item.App.Path, 'push', 'origin', "refs/tags/$releaseId") -FailMessage "Pushing the tag of $($item.App.Folder) failed"
    }
}

$logDir = Join-Path $releasesDir "logs/$(if ($releaseId) { $releaseId } else { "staging-$($started.ToString('yyyyMMdd-HHmmss'))" })"
if (-not (Test-DryRun)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$pwshPath = (Get-Process -Id $PID).Path
$failed = $false

foreach ($item in $plan) {
    if ($failed) { $item.Result = 'skipped (an earlier app failed)'; continue }
    Write-Step "Deploying $($item.Name) $($item.Short)"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $deployRef = if ($Env -eq 'prod') { $releaseId } else { $item.Commit }
    if ($Via -eq 'github') {
        $workflow = if ($Env -eq 'prod') { 'deploy-production.yml' } else { 'deploy-staging.yml' }
        $dispatchArgs = @('workflow', 'run', $workflow, '-R', $item.App.GitHub, '--ref', 'main')
        if ($Env -eq 'prod') { $dispatchArgs += @('-f', "tag=$releaseId") }
        if (Test-DryRun) {
            Write-Host "[dry-run] gh $($dispatchArgs -join ' '), then watch that run until it ends" -ForegroundColor DarkGray
            $item.Result = 'dry run'
            continue
        }
        $since = (Get-Date).ToUniversalTime().AddSeconds(-5)
        & gh @dispatchArgs
        if ($LASTEXITCODE -ne 0) { $item.Result = 'failed (could not start the workflow)'; $failed = $true; continue }
        $runId = $null
        for ($i = 0; $i -lt 20 -and -not $runId; $i++) {
            Start-Sleep -Seconds 3
            $runs = & gh run list -R $item.App.GitHub --workflow $workflow --event workflow_dispatch --limit 5 --json databaseId,createdAt | ConvertFrom-Json
            $runId = ($runs | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -ge $since } | Select-Object -First 1).databaseId
        }
        if (-not $runId) { $item.Result = 'failed (run not found)'; $failed = $true; continue }
        & gh run watch $runId -R $item.App.GitHub --exit-status
        $code = $LASTEXITCODE
        $item.Detail = "https://github.com/$($item.App.GitHub)/actions/runs/$runId"
    } else {
        $script = Join-Path $infraRoot "apps/$($item.Name)/deploy.ps1"
        $childArgs = @('-NoProfile', '-File', $script, '-Env', $Env, '-Ref', $deployRef, '-RepoPath', $item.App.Path)
        if ($item.Name -eq 'backend') {
            if ($mode -eq 'rollback') { $childArgs += '-SkipDatabase' } elseif ($confirmDb) { $childArgs += @('-ConfirmDb', $confirmDb) }
        }
        if (Test-DryRun) {
            $childArgs += '-DryRun'
            if ($Env -eq 'prod' -and -not $Tag) { $childArgs[6] = $item.Commit; $childArgs += @('-PlannedTag', $releaseId) }
            & $pwshPath @childArgs
            $code = $LASTEXITCODE
        } else {
            $log = Join-Path $logDir "$($item.Name).log"
            & $pwshPath @childArgs 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
            $code = $LASTEXITCODE
            $item.Detail = (Select-String -Path $log -Pattern '^DEPLOY-RESULT ' | Select-Object -Last 1 | ForEach-Object { $_.Line -replace '^DEPLOY-RESULT app=\S+ env=\S+ commit=\S+ ?', '' })
        }
    }
    $clock.Stop()
    $item.Seconds = [int]$clock.Elapsed.TotalSeconds
    if ($code -eq 0) {
        $item.Result = if (Test-DryRun) { 'dry run' } else { 'deployed' }
        $marker = "deployed/$Env"
        Invoke-Native git @('-C', $item.App.Path, 'tag', '-f', $marker, $item.Commit) -FailMessage "Moving $marker failed"
        Invoke-Native git @('-C', $item.App.Path, 'push', '-f', 'origin', "refs/tags/$marker") -FailMessage "Pushing $marker failed"
    } else {
        $item.Result = "failed (exit code $code)"
        $failed = $true
    }
}

$recordName = if ($releaseId) { "$releaseId.md" } else { "staging-$($started.ToString('yyyy-MM-dd-HHmmss')).md" }
$who = ((& git -C $backendPath config user.name) -join '') + ' <' + ((& git -C $backendPath config user.email) -join '') + '>'
$lines = [System.Collections.Generic.List[string]]::new()
$title = if ($releaseId) { "Release $releaseId ($mode, $Env)" } else { "Staging deploy $($started.ToString('yyyy-MM-dd HH:mm'))" }
$lines.Add("# $title")
$lines.Add('')
$lines.Add("| | |")
$lines.Add("|---|---|")
$lines.Add("| Started | $($started.ToString('yyyy-MM-dd HH:mm:ss zzz')) |")
$lines.Add("| Finished | $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')) |")
$lines.Add("| By | $who on $([Environment]::MachineName) |")
$lines.Add("| Via | $Via |")
$lines.Add("| Outcome | $(if ($failed) { 'FAILED' } else { 'OK' }) |")
if ($Env -eq 'prod') { $lines.Add("| Previous production release | $(if ($previousProd) { $previousProd } else { 'none found' }) |") }
if ($confirmDb) { $lines.Add("| Backend database | $confirmDb |") }
$lines.Add('')
$lines.Add('| App | Repository | Ref | Commit | Tag | Result | Detail | Seconds |')
$lines.Add('|---|---|---|---|---|---|---|---|')
foreach ($item in $plan) {
    $lines.Add("| $($item.Name) | $($item.App.GitHub) | $($item.Ref) | ``$($item.Commit)`` | $(if ($item.Tag) { $item.Tag } else { '-' }) | $($item.Result) | $($item.Detail) | $($item.Seconds) |")
}
$lines.Add('')
$lines.Add('## Commit messages')
$lines.Add('')
foreach ($item in $plan) { $lines.Add("- $($item.Name) ``$($item.Short)``: $($item.Subject)") }
$lines.Add('')
$lines.Add('## What ran')
$lines.Add('')
$lines.Add('- backend: clean export, bun install, package-lock.json from bun.lock, Cloud SQL proxy, bootstrap and database check, migration status and migrations, data release status, dry run and commit, app.yaml from the template, upload, health check of the new version, traffic, dispatch rules, health check')
$lines.Add('- console and partner: clean export, vercel pull, remote build with --build-env, deploy to the production target of the environment''s Vercel project')
$lines.Add('- customer: clean export, flutter build web --pwa-strategy=none, firebase deploy --only hosting, site check')
if ($Env -eq 'prod') {
    $lines.Add('')
    $lines.Add('## Rollback')
    $lines.Add('')
    if ($previousProd) { $lines.Add("``pwsh release/release.ps1 -Env prod -Tag $previousProd`` (backend: traffic back to the old version, no database steps; database changes are not undone)") } else { $lines.Add('No earlier release tag found.') }
}
$record = $lines -join "`n"

if (Test-DryRun) {
    Write-Step "Release record (dry run, not written: releases/$recordName)"
    Write-Host $record
} else {
    $recordPath = Join-Path $releasesDir $recordName
    Set-Content -LiteralPath $recordPath -Value $record -Encoding utf8NoBOM
    Write-Step "Release record written: $recordPath"
    Write-Host "Keep it: git -C $infraRoot add releases/$recordName; git -C $infraRoot commit -m '$title'; git -C $infraRoot push"
    Write-Host "Logs (not committed): $logDir"
}

if ($failed) { exit 1 }
