# Shared helpers for the Repeato deploy and release scripts: the app list, key loading, clean source exports, dry-run aware command runner and small checks.

Set-StrictMode -Version 3.0

$script:DryRun = $false
$script:InfraRoot = Split-Path -Parent $PSScriptRoot

$script:Apps = [ordered]@{
    backend  = [pscustomobject]@{ Name = 'backend';  Folder = 'repeato.backend';       GitHub = 'repeato-in/repeato.backend';       KeyFile = 'repeato.backend_deploy_key.js' }
    console  = [pscustomobject]@{ Name = 'console';  Folder = 'repeato.console';       GitHub = 'repeato-in/repeato.console';       KeyFile = 'repeato.console_deploy_key.js' }
    partner  = [pscustomobject]@{ Name = 'partner';  Folder = 'repeato.vendor.app';    GitHub = 'repeato-in/repeato.vendor.app';    KeyFile = 'repeato.vendor.app_deploy_key.js' }
    customer = [pscustomobject]@{ Name = 'customer'; Folder = 'repeato.mobile.client'; GitHub = 'repeato-in/repeato.mobile.client'; KeyFile = 'repeato.mobile.client_deploy_key.js' }
}

function Get-InfraRoot {
    [OutputType([string])]
    param()
    return $script:InfraRoot
}

function Get-RepeatoWorkspace {
    [OutputType([string])]
    param()
    if ($env:REPEATO_WORKSPACE) { return $env:REPEATO_WORKSPACE }
    return Split-Path -Parent $script:InfraRoot
}

function Get-RepeatoKeysDir {
    [OutputType([string])]
    param()
    if ($env:REPEATO_KEYS_DIR) { return $env:REPEATO_KEYS_DIR }
    return Join-Path (Split-Path -Parent (Get-RepeatoWorkspace)) 'repeato-data/keys'
}

function Get-RepeatoAppNames {
    [OutputType([string[]])]
    param()
    return [string[]]$script:Apps.Keys
}

function Get-RepeatoApp {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Apps.Contains($Name)) { throw "Unknown app '$Name'. Use one of: $((Get-RepeatoAppNames) -join ', ')" }
    $app = $script:Apps[$Name]
    return [pscustomobject]@{
        Name    = $app.Name
        Folder  = $app.Folder
        GitHub  = $app.GitHub
        KeyFile = Join-Path (Get-RepeatoKeysDir) $app.KeyFile
        Path    = Join-Path (Get-RepeatoWorkspace) $app.Folder
    }
}

function Set-DryRun {
    param([bool]$Enabled)
    $script:DryRun = $Enabled
}

function Test-DryRun {
    [OutputType([bool])]
    param()
    return $script:DryRun
}

function Test-Interactive {
    [OutputType([bool])]
    param()
    if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true') { return $false }
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Protect-Text {
    [OutputType([string])]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($item in Get-ChildItem Env:) {
        if ($item.Name -match '(TOKEN|SECRET|PASSWORD|KEY|SALT|_JSON$|MAPS_API)' -and $item.Value -and $item.Value.Length -ge 6) {
            $result = $result.Replace($item.Value, '***')
        }
    }
    return $result
}

function Format-Command {
    [OutputType([string])]
    param([string]$FilePath, [string[]]$ArgumentList)
    $parts = @($FilePath) + @($ArgumentList | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } })
    return Protect-Text ($parts -join ' ')
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [string]$FailMessage,
        [switch]$CaptureOutput,
        [switch]$AllowFailure
    )
    $shown = Format-Command -FilePath $FilePath -ArgumentList $ArgumentList
    if ($WorkingDirectory) { $shown = "(in $WorkingDirectory) $shown" }
    if ($script:DryRun) {
        Write-Host "[dry-run] $shown" -ForegroundColor DarkGray
        if ($CaptureOutput) { return '' }
        return
    }
    Write-Host "> $shown" -ForegroundColor DarkGray
    $previous = $null
    if ($WorkingDirectory) { $previous = Get-Location; Set-Location -LiteralPath $WorkingDirectory }
    try {
        if ($CaptureOutput) {
            $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            $output | ForEach-Object { Write-Host (Protect-Text $_) }
        } else {
            & $FilePath @ArgumentList
            $code = $LASTEXITCODE
        }
    } finally {
        if ($previous) { Set-Location -LiteralPath $previous }
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        if (-not $FailMessage) { $FailMessage = "Command failed: $shown" }
        if ($CaptureOutput) { throw (Protect-Text "$FailMessage (exit code $code): $($output -join "`n")") }
        throw "$FailMessage (exit code $code)"
    }
    if ($CaptureOutput) { return ($output -join "`n") }
}

function Import-DeployKeys {
    param([Parameter(Mandatory)][string]$App, [string]$KeyFile)
    $info = Get-RepeatoApp $App
    if (-not $KeyFile) { $KeyFile = $info.KeyFile }
    if (Test-Path -LiteralPath $KeyFile -PathType Leaf) {
        Write-Host "Loading deploy keys from $KeyFile"
        $text = Get-Content -Raw -LiteralPath $KeyFile
        & ([scriptblock]::Create($text))
    } elseif ($env:REPEATO_SECRETS_JSON -or $env:REPEATO_VARS_JSON) {
        Write-Host 'Loading deploy keys from the GitHub secrets and variables of this run'
    } else {
        Write-Warning "No key file at $KeyFile and no GitHub secrets: using only variables already set in this session."
    }
    foreach ($jsonName in @('REPEATO_VARS_JSON', 'REPEATO_SECRETS_JSON')) {
        $json = [Environment]::GetEnvironmentVariable($jsonName)
        if (-not $json) { continue }
        $values = $json | ConvertFrom-Json -AsHashtable
        foreach ($name in $values.Keys) {
            if ($name -in @('github_token', 'GITHUB_TOKEN')) { continue }
            if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
                [Environment]::SetEnvironmentVariable($name, [string]$values[$name])
            }
        }
        [Environment]::SetEnvironmentVariable($jsonName, $null)
    }
}

function Get-EnvValue {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return [string][Environment]::GetEnvironmentVariable($Name)
}

function Set-EnvValue {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

function Set-EnvAlias {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$From)
    if (Get-EnvValue $Name) { return }
    foreach ($source in $From) {
        $value = Get-EnvValue $source
        if ($value) { Set-EnvValue $Name $value; return }
    }
}

function Set-EnvDefault {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value, [string]$Warning)
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue $Name))) { return }
    Set-EnvValue $Name $Value
    if ($Warning) { Write-Warning $Warning }
}

function Assert-EnvSet {
    param([Parameter(Mandatory)][string[]]$Names)
    $missing = @($Names | Where-Object { [string]::IsNullOrWhiteSpace((Get-EnvValue $_)) })
    if ($missing.Count -eq 0) { return }
    if ($script:DryRun) { Write-Warning "Not set (a real run stops here): $($missing -join ', ')"; return }
    throw "Set these first (key file or GitHub secrets): $($missing -join ', ')"
}

function ConvertTo-KeyFile {
    param([Parameter(Mandatory)][string]$Name, [string[]]$From = @(), [Parameter(Mandatory)][string]$WorkDir)
    $value = Get-EnvValue $Name
    if (-not $value) {
        foreach ($source in $From) { $value = Get-EnvValue $source; if ($value) { break } }
    }
    if (-not $value) { return }
    if ($value.TrimStart().StartsWith('{')) {
        if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
        $file = Join-Path $WorkDir "$($Name.ToLowerInvariant()).json"
        Set-Content -LiteralPath $file -Value $value -Encoding utf8NoBOM
        Set-EnvValue $Name $file
        return
    }
    Set-EnvValue $Name $value
}

function Resolve-Commit {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Ref)
    $commit = (& git -C $RepoPath rev-parse --verify --quiet "$Ref^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $commit) { throw "Cannot find '$Ref' in $RepoPath. Fetch first: git -C $RepoPath fetch origin --tags --force" }
    return ([string]$commit).Trim()
}

function Test-ReleaseTag {
    [OutputType([bool])]
    param([string]$Ref)
    return $Ref -match '^v\d{4}\.\d{2}\.\d{2}-\d+$'
}

function New-WorkDir {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Label)
    $root = if ($env:REPEATO_WORK_DIR) { $env:REPEATO_WORK_DIR } else { Join-Path $script:InfraRoot '.work' }
    $dir = Join-Path $root "$Label-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    if (-not $script:DryRun) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Export-Source {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$WorkDir)
    $source = Join-Path $WorkDir 'src'
    $archive = Join-Path $WorkDir 'source.tar'
    Write-Step "Exporting a clean copy of $($Commit.Substring(0, 7)) (git archive, no working-copy files)"
    if ($script:DryRun) {
        Write-Host "[dry-run] git -C $RepoPath archive --format=tar -o $archive $Commit; tar -xf $archive -C $source" -ForegroundColor DarkGray
        return $source
    }
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    & git -C $RepoPath archive --format=tar -o $archive $Commit
    if ($LASTEXITCODE -ne 0) { throw "git archive failed for $Commit" }
    & tar -xf $archive -C $source
    if ($LASTEXITCODE -ne 0) { throw 'Unpacking the source failed' }
    Remove-Item -LiteralPath $archive -Force
    return $source
}

function Remove-WorkDir {
    param([string]$WorkDir, [switch]$Keep)
    if (-not $WorkDir -or $script:DryRun -or -not (Test-Path -LiteralPath $WorkDir)) { return }
    if ($Keep) { Write-Warning "Kept $WorkDir (it can hold rendered settings: delete it when done)"; return }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-TcpPort {
    [OutputType([bool])]
    param([string]$HostName, [int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Add-BunToPath {
    if (Get-Command bun -ErrorAction SilentlyContinue) { return }
    $bunDir = if ($IsWindows) { Join-Path $env:USERPROFILE '.bun/bin' } else { Join-Path $HOME '.bun/bin' }
    if (Test-Path $bunDir) { $env:PATH = "$bunDir$([IO.Path]::PathSeparator)$env:PATH" }
}

function Wait-HttpOk {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Url, [int]$Attempts = 10, [int]$DelaySeconds = 6, [int[]]$Accept = @(200))
    if ($script:DryRun) { Write-Host "[dry-run] GET $Url (expect $($Accept -join '/'))" -ForegroundColor DarkGray; return $true }
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 30 -UseBasicParsing -SkipHttpErrorCheck
            if ($Accept -contains [int]$response.StatusCode) { Write-Host "Health: $Url answered $($response.StatusCode)"; return $true }
            Write-Host "Health: $Url answered $($response.StatusCode) ($i/$Attempts)"
        } catch {
            Write-Host "Health: $Url not reachable yet ($i/$Attempts): $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

function Write-DeployResult {
    param([Parameter(Mandatory)][string]$App, [Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][string]$Commit, [string]$Detail)
    $line = "DEPLOY-RESULT app=$App env=$Env commit=$Commit $Detail".Trim()
    Write-Host ''
    Write-Host $line -ForegroundColor Green
    if ($env:GITHUB_STEP_SUMMARY -and -not $script:DryRun) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "| $App | $Env | ``$($Commit.Substring(0, 7))`` | $Detail |"
    }
}

function Invoke-Isolated {
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][hashtable]$Bound)
    $childArgs = @('-NoProfile', '-File', $ScriptPath)
    foreach ($key in $Bound.Keys) {
        $value = $Bound[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $childArgs += "-$key" }
        } elseif ($value -is [array]) {
            $childArgs += @("-$key", ($value -join ','))
        } else {
            $childArgs += @("-$key", [string]$value)
        }
    }
    $start = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in $childArgs) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.Environment['REPEATO_ISOLATED'] = '1'
    $process = [System.Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-ReleaseName {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][string]$Ref, [string]$PlannedTag)
    $name = $Ref
    if ($PlannedTag) {
        if (-not $script:DryRun) { throw '-PlannedTag is only for dry runs (the tag does not exist yet).' }
        $name = $PlannedTag
    }
    if ($Env -eq 'prod' -and -not (Test-ReleaseTag $name)) { throw "Production deploys a release tag (vYYYY.MM.DD-N), not '$name'." }
    return $name
}

Export-ModuleMember -Function *
