# Deploys repeato.console (admin console) to its Vercel project for staging or prod from a clean export of one commit or release tag.
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

Invoke-VercelDeploy -App 'console' -Env $Env -Ref $Ref -RepoPath $RepoPath -KeyFile $KeyFile -PlannedTag $PlannedTag -KeepWorkDir:$KeepWorkDir
