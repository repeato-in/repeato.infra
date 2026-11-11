# Stops what dev/up.ps1 started: the app processes it recorded in dev/.run/pids.json and the repeato-mysql-dev container. -KeepDb leaves the database running; -Reset also deletes the local database volume. Never touches the test containers.
#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$KeepDb,
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'
$runDir = Join-Path $PSScriptRoot '.run'
$pidFile = Join-Path $runDir 'pids.json'

if (Test-Path $pidFile) {
    $saved = Get-Content -Raw $pidFile | ConvertFrom-Json -AsHashtable
    foreach ($name in $saved.Keys) {
        $id = [int]$saved[$name]
        if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { Write-Host "$name (pid $id) already stopped"; continue }
        if ($IsWindows) {
            & taskkill /PID $id /T /F | Out-Null
        } else {
            & pkill -TERM -P $id 2>$null
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
        Write-Host "$name (pid $id) stopped"
    }
    Remove-Item -LiteralPath $pidFile -Force
} else {
    Write-Host 'No app processes recorded.'
}

if ($KeepDb) { Write-Host 'repeato-mysql-dev keeps running.'; return }
$compose = Join-Path $PSScriptRoot 'compose.yaml'
if ($Reset) {
    & docker compose -f $compose rm --stop --force --volumes mysql-dev
    & docker volume rm repeato-mysql-dev-data 2>$null | Out-Null
    Write-Host 'repeato-mysql-dev and its data are removed. The next up.ps1 builds the database again.'
} else {
    & docker compose -f $compose stop mysql-dev
    Write-Host 'repeato-mysql-dev stopped (data kept).'
}
