# Parses every PowerShell file of this repository and, when PSScriptAnalyzer is installed, runs it with tools/PSScriptAnalyzerSettings.psd1; exits non-zero on any parse error or analyzer error.
#Requires -Version 7.4
[CmdletBinding()]
param([switch]$SkipAnalyzer)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notlike '*[\/].work[\/]*' }
$failures = 0

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
    if ($errors.Count -gt 0) {
        $failures++
        foreach ($parseError in $errors) { Write-Host "PARSE ERROR $($relative):$($parseError.Extent.StartLineNumber) $($parseError.Message)" -ForegroundColor Red }
    } else {
        Write-Host "parsed $relative"
    }
}

if (-not $SkipAnalyzer) {
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $findings = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings })
        foreach ($finding in $findings) {
            Write-Host "$($finding.Severity) $([IO.Path]::GetRelativePath($root, $finding.ScriptPath)):$($finding.Line) $($finding.RuleName) $($finding.Message)"
        }
        $failures += @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
    } else {
        Write-Warning 'PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser): only parse checks ran.'
    }
}

if ($failures -gt 0) { Write-Host "$failures problem(s)" -ForegroundColor Red; exit 1 }
Write-Host "All $($files.Count) PowerShell files are fine." -ForegroundColor Green
