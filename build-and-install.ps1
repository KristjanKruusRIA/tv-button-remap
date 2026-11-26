param(
    [string]$TvHost = $env:TV_HOST,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

if (-not $BuildOnly -and -not $TvHost) {
    throw 'Pass -TvHost <ip>:<port> or set $env:TV_HOST (or pass -BuildOnly to compile without installing).'
}

# 1. Locate JDK (javac)
function Resolve-JavaHome {
    if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\javac.exe")) {
        return $env:JAVA_HOME
    }
    $javacCmd = Get-Command javac.exe -ErrorAction SilentlyContinue
    if ($javacCmd) {
        return Split-Path (Split-Path $javacCmd.Source -Parent) -Parent
    }
    $searchDirs = @(
        'C:\Program Files\Java',
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Microsoft',
        'C:\Program Files\Android\Android Studio\jbr'
    )
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        if (Test-Path "$dir\bin\javac.exe") { return $dir }
        $sub = Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') } |
            Select-Object -First 1
        if ($sub) { return $sub.FullName }
    }
    throw 'JDK (javac.exe) not found. Install JDK 17+ or set JAVA_HOME.'
}

$env:JAVA_HOME = Resolve-JavaHome
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# 2. Ensure Android SDK build-tools 34 and platform android-34
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$btDir = Join-Path $sdkRoot 'build-tools\34.0.0'
$platDir = Join-Path $sdkRoot 'platforms\android-34'

function Find-Tool([string]$root, [string]$fileName) {
    if (-not (Test-Path $root)) { return $null }
    $hit = Get-ChildItem -Path $root -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Install-SdkArchive([string]$url, [string]$targetDir, [string]$markerFile) {
    if (Find-Tool $targetDir $markerFile) { return }
    Write-Host "Downloading $url ..."
    $tmpRoot = Join-Path $env:TEMP ("sdk-" + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tmpRoot 'archive.zip'
    $extractDir = Join-Path $tmpRoot 'extract'
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $found = Get-ChildItem -Path $extractDir -Filter $markerFile -Recurse -File | Select-Object -First 1
        if (-not $found) { throw "Archive from $url did not contain $markerFile" }
        $sourceRoot = $found.DirectoryName
        New-Item -ItemType Directory -Force -Path (Split-Path $targetDir -Parent) | Out-Null
        if (Test-Path $targetDir) { Remove-Item -Recurse -Force $targetDir }
        Move-Item -Path $sourceRoot -Destination $targetDir
    } finally {
        if (Test-Path $tmpRoot) { Remove-Item -Recurse -Force $tmpRoot }
    }
}

Install-SdkArchive 'https://dl.google.com/android/repository/build-tools_r34-windows.zip' $btDir 'aapt2.exe'
Install-SdkArchive 'https://dl.google.com/android/repository/platform-34-ext7_r03.zip' $platDir 'android.jar'

$aapt2 = Find-Tool $btDir 'aapt2.exe'
$d8 = Find-Tool $btDir 'd8.bat'
$zipalign = Find-Tool $btDir 'zipalign.exe'
$apksigner = Find-Tool $btDir 'apksigner.bat'
$androidJar = Find-Tool $platDir 'android.jar'

if (-not $aapt2 -or -not $d8 -or -not $zipalign -or -not $apksigner -or -not $androidJar) {
    throw "Missing required Android SDK tools under $sdkRoot"
}

# 3. Clean build directory
$buildDir = Join-Path $PSScriptRoot 'build'
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
New-Item -ItemType Directory -Force -Path "$buildDir\gen", "$buildDir\classes", "$buildDir\dex" | Out-Null

# 4. Compile & link resources
Write-Host 'Compiling resources with aapt2...'
& $aapt2 compile --dir res -o "$buildDir\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile failed' }

& $aapt2 link -o "$buildDir\unaligned.apk" `
    -I $androidJar `
    --manifest AndroidManifest.xml `
    --java "$buildDir\gen" `
    --min-sdk-version 26 `
    --target-sdk-version 34 `
    --version-code 1 `
    --version-name 1.0 `
    "$buildDir\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

# 5. Compile Java sources (including generated R.java)
Write-Host 'Compiling Java sources...'
$javaSources = @(Get-ChildItem -Path 'src' -Filter '*.java' -Recurse -File | ForEach-Object { $_.FullName })
$genSources = @(Get-ChildItem -Path "$buildDir\gen" -Filter '*.java' -Recurse -File | ForEach-Object { $_.FullName })
$allSources = $javaSources + $genSources
& javac -source 11 -target 11 -classpath $androidJar -d "$buildDir\classes" @allSources
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

# 6. Dex with d8
Write-Host 'Dexing classes with d8...'
$classFiles = @(Get-ChildItem -Path "$buildDir\classes" -Filter '*.class' -Recurse -File | ForEach-Object { $_.FullName })
& $d8 --min-api 26 --lib $androidJar --output "$buildDir\dex" @classFiles
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

# 7. Package classes.dex at root of APK
Write-Host 'Packaging classes.dex into APK...'
& jar uf "$buildDir\unaligned.apk" -C "$buildDir\dex" classes.dex
if ($LASTEXITCODE -ne 0) { throw 'jar uf failed' }

# 8. Align APK
& $zipalign -f -p 4 "$buildDir\unaligned.apk" "$buildDir\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }

# 9. Generate local keystore if needed and sign APK
$keystore = Join-Path $PSScriptRoot 'local-remap.jks'
if (-not (Test-Path $keystore)) {
    Write-Host 'Generating local signing keystore...'
    & keytool -genkeypair -v -keystore $keystore -alias remap -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass android -keypass android -dname 'CN=LocalRemap,O=Local,C=US'
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
}

$apkOut = Join-Path $buildDir 'button-remap.apk'
Write-Host 'Signing APK...'
& $apksigner sign --ks $keystore --ks-pass pass:android --key-pass pass:android `
    --out $apkOut "$buildDir\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'apksigner sign failed' }

& $apksigner verify $apkOut
if ($LASTEXITCODE -ne 0) { throw 'apksigner verify failed' }

if ($BuildOnly) {
    Write-Host "Built and verified: $apkOut"
    exit 0
}

# 10. Connect ADB, install, allow restricted settings, enable accessibility service
Write-Host "Connecting to $TvHost ..."
& adb connect $TvHost
& adb -s $TvHost wait-for-device

Write-Host 'Installing APK...'
& adb -s $TvHost install -r $apkOut
if ($LASTEXITCODE -ne 0) { throw 'adb install failed' }

Write-Host 'Granting ACCESS_RESTRICTED_SETTINGS and enabling accessibility service...'
& adb -s $TvHost shell "appops set com.local.buttonremap ACCESS_RESTRICTED_SETTINGS allow"

$svc = 'com.local.buttonremap/.ButtonRemapService'
$fullSvc = 'com.local.buttonremap/com.local.buttonremap.ButtonRemapService'
$existing = (& adb -s $TvHost shell "settings get secure enabled_accessibility_services").Trim()
$parts = @()
if ($existing -and $existing -ne 'null') {
    $parts = @($existing -split ':' | Where-Object { $_ -and $_ -ne $svc -and $_ -ne $fullSvc })
}
$parts += $svc
$newVal = $parts -join ':'

& adb -s $TvHost shell "settings put secure enabled_accessibility_services '$newVal'"
& adb -s $TvHost shell "settings put secure accessibility_enabled 1"

Write-Host "Enabled services: $(& adb -s $TvHost shell 'settings get secure enabled_accessibility_services')"
Write-Host "Accessibility enabled: $(& adb -s $TvHost shell 'settings get secure accessibility_enabled')"
Write-Host 'Done.'
