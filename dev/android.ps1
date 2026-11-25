# Runs the customer app on an Android phone emulator against the local stack of dev/up.ps1: makes sure the Pixel 8 emulator (AVD Pixel_8: 1080 x 2400 at 420 dpi, Pixel 8 frame, GPU on, 4 GB) exists, starts it when no emulator runs, waits for it to boot, then runs `flutter run` in this window (r hot reload, R restart, q quit) with the customer app's env/dev.json (backend at 10.0.2.2:3000, the emulator's address of this laptop). With -Device <serial of a phone on USB> it runs on that phone instead with env/dev-localhost.json, through adb reverse to localhost:3000. Guide: docs/local-dev.md.
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Avd = 'Pixel_8',
    [string]$Device,
    [switch]$Recreate,
    [switch]$EmulatorOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Common.psm1') -Force

$deviceProfile = 'pixel_8'
$systemImage = 'system-images;android-35;google_apis;x86_64'
$skinSource = "https://android.googlesource.com/platform/tools/adt/idea/+archive/refs/heads/mirror-goog-studio-main/artwork/resources/device-art-resources/$deviceProfile.tar.gz"

function Get-AndroidSdk {
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path ([string]$env:LOCALAPPDATA) 'Android\Sdk'))) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'emulator'))) { return $candidate }
    }
    throw 'No Android SDK found. Set ANDROID_HOME to the SDK folder (the one holding emulator, platform-tools and cmdline-tools).'
}

$sdk = Get-AndroidSdk
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$emulator = Join-Path $sdk 'emulator\emulator.exe'
$avdManager = Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
$sdkManager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
$avdHome = if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { Join-Path $HOME '.android\avd' }
$avdDir = Join-Path $avdHome "$Avd.avd"
$skinDir = Join-Path $sdk "skins\$deviceProfile"

function Install-PhoneFrame {
    if (Test-Path (Join-Path $skinDir 'layout')) { return }
    Write-Host "Downloading the Pixel 8 frame into $skinDir"
    New-Item -ItemType Directory -Path $skinDir -Force | Out-Null
    $archive = Join-Path $skinDir 'frame.tar.gz'
    Invoke-WebRequest -Uri $skinSource -OutFile $archive
    & tar -xzf $archive -C $skinDir
    if ($LASTEXITCODE -ne 0) { throw "Could not unpack $archive" }
    Remove-Item -LiteralPath $archive -Force
}

function Set-PhoneSettings {
    $configPath = Join-Path $avdDir 'config.ini'
    $wanted = [ordered]@{
        'hw.gpu.enabled'  = 'yes'
        'hw.gpu.mode'     = 'host'
        'hw.ramSize'      = '4096M'
        'hw.keyboard'     = 'yes'
        'showDeviceFrame' = 'yes'
        'skin.dynamic'    = 'yes'
        'skin.name'       = $deviceProfile
        'skin.path'       = ($skinDir -replace '\\', '/')
    }
    $lines = @(Get-Content -LiteralPath $configPath | Where-Object { $key = ($_ -split '=', 2)[0]; -not $wanted.Contains($key) })
    $lines += @($wanted.Keys | ForEach-Object { "$_=$($wanted[$_])" })
    Set-Content -LiteralPath $configPath -Value $lines -Encoding utf8NoBOM
}

function New-PhoneAvd {
    if (-not (Test-Path (Join-Path $sdk ($systemImage -replace ';', '\')))) {
        Write-Host "Installing $systemImage"
        & $sdkManager $systemImage
        if ($LASTEXITCODE -ne 0) { throw "sdkmanager could not install $systemImage" }
    }
    Write-Host "Creating AVD $Avd ($deviceProfile, $systemImage)"
    'no' | & $avdManager create avd --force -n $Avd -d $deviceProfile -k $systemImage 2>&1 | Out-Null
    if (-not (Test-Path (Join-Path $avdDir 'config.ini'))) { throw "avdmanager did not create $avdDir" }
}

function Get-RunningEmulators {
    @(& $adb devices | Select-String '^(emulator-\d+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
}

if ($Recreate -or -not (Test-Path (Join-Path $avdDir 'config.ini'))) { New-PhoneAvd }
Install-PhoneFrame
Set-PhoneSettings

& $adb start-server | Out-Null
function Find-AvdEmulator {
    Get-RunningEmulators | Where-Object { ([string]((& $adb -s $_ emu avd name 2>$null) | Select-Object -First 1)).Trim() -eq $Avd } | Select-Object -First 1
}

$serial = $Device
if (-not $serial) {
    $serial = Find-AvdEmulator
}
if (-not $serial) {
    Write-Step "Starting the $Avd emulator"
    Start-Process -FilePath $emulator -ArgumentList @('-avd', $Avd) -WindowStyle Normal | Out-Null
    for ($i = 1; $i -le 60 -and -not $serial; $i++) {
        Start-Sleep -Seconds 4
        $serial = Find-AvdEmulator
    }
    if (-not $serial) { throw "The $Avd emulator did not appear in adb devices within four minutes (see the emulator window)." }
}

Write-Step "Waiting for $serial to finish booting"
$booted = $false
for ($i = 1; $i -le 90; $i++) {
    if (((& $adb -s $serial shell getprop sys.boot_completed 2>$null) -join '').Trim() -eq '1') { $booted = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $booted) { throw "$serial did not finish booting within three minutes." }
Write-Host "$serial is ready ($((& $adb -s $serial shell wm size) -join ' '))"
if ($EmulatorOnly) { return }

if (-not (Wait-HttpOk -Url 'http://localhost:3000/api/health' -Attempts 1 -DelaySeconds 1)) {
    Write-Warning 'The local backend does not answer on http://localhost:3000. Start it first: pwsh dev/up.ps1 -Apps backend'
}

$envFile = 'env/dev.json'
if ($serial -notlike 'emulator-*') {
    & $adb -s $serial reverse tcp:3000 tcp:3000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb reverse failed on $serial" }
    $envFile = 'env/dev-localhost.json'
    Write-Host "$serial is a phone on USB: its port 3000 now leads to this laptop's backend (adb reverse)"
}
$defines = @("--dart-define-from-file=$envFile")

Write-Step "Customer app on $serial with $envFile (r hot reload, R hot restart, q quit)"
Push-Location (Get-RepeatoApp 'customer').Path
try {
    & flutter run -d $serial @defines
} finally {
    Pop-Location
}
