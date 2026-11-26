param(
    [string]$TvHost = $env:TV_HOST
)

$ErrorActionPreference = 'Stop'

if (-not $TvHost) {
    throw 'Pass -TvHost <ip>:<port> or set $env:TV_HOST.'
}

Write-Host "Connecting to $TvHost ..."
& adb connect $TvHost
& adb -s $TvHost wait-for-device

$svc = 'com.local.buttonremap/.ButtonRemapService'
$fullSvc = 'com.local.buttonremap/com.local.buttonremap.ButtonRemapService'
$existing = (& adb -s $TvHost shell "settings get secure enabled_accessibility_services").Trim()
$remaining = @()
if ($existing -and $existing -ne 'null') {
    $remaining = @($existing -split ':' | Where-Object { $_ -and $_ -ne $svc -and $_ -ne $fullSvc })
}

if ($remaining.Count -gt 0) {
    $newVal = $remaining -join ':'
    & adb -s $TvHost shell "settings put secure enabled_accessibility_services '$newVal'"
} else {
    & adb -s $TvHost shell "settings delete secure enabled_accessibility_services"
    & adb -s $TvHost shell "settings put secure accessibility_enabled 0"
}

Write-Host 'Uninstalling com.local.buttonremap...'
& adb -s $TvHost uninstall com.local.buttonremap
Write-Host 'Restored.'
