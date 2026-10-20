param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Test-Requirement([bool]$Condition, [string]$Label) {
    $script:checks++
    if (-not $Condition) { $script:failures.Add($Label) }
}

$requiredFiles = @(
    'AGENTS.md', 'README.md', 'pubspec.yaml', 'analysis_options.yaml',
    '.github/workflows/build_apk.yml', 'tool/configure_android.mjs',
    'android/app/src/main/AndroidManifest.xml',
    'android/app/src/main/kotlin/com/anggit/mula/mula/MainActivity.kt',
    'android/app/src/main/res/drawable/ic_stat_mula.xml',
    'lib/main.dart', 'lib/data/local/app_database.dart'
)
foreach ($relative in $requiredFiles) {
    Test-Requirement (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "Missing file: $relative"
}

$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
foreach ($package in @('flutter_riverpod', 'sqflite', 'path', 'shared_preferences', 'flutter_local_notifications', 'android_alarm_manager_plus', 'timezone', 'local_auth', 'intl', 'flutter_test', 'sqflite_common_ffi', 'flutter_lints')) {
    Test-Requirement ($pubspec -match "(?m)^  ${package}:") "Missing dependency: $package"
}
Test-Requirement ($pubspec -notmatch '(?m)^\s*(riverpod_generator|freezed|build_runner):') 'Code generation dependency is forbidden'

$workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/build_apk.yml') -Raw
foreach ($entry in @('actions/checkout@v4', 'actions/setup-java@v4', 'subosito/flutter-action@v2', 'actions/upload-artifact@v4', 'MULA-Android-APK', 'workflow_dispatch:', 'branches: [main, master]', 'java-version: ''17''', 'channel: stable', 'flutter create --org com.anggit.mula --project-name mula --platforms android --no-pub .', 'flutter pub get', 'flutter analyze --no-fatal-infos --no-fatal-warnings', 'flutter test', 'flutter build apk --release --no-tree-shake-icons', 'cp -r lib', 'cp -r "$backup_dir/lib/." lib/')) {
    Test-Requirement ($workflow.Contains($entry)) "Missing cloud builder step: $entry"
}
Test-Requirement (-not $workflow.Contains("`t")) 'YAML indentation contains tabs'

$manifestPath = Join-Path $root 'android/app/src/main/AndroidManifest.xml'
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$namespace = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$namespace.AddNamespace('android', 'http://schemas.android.com/apk/res/android')
foreach ($permission in @('POST_NOTIFICATIONS', 'SCHEDULE_EXACT_ALARM', 'USE_EXACT_ALARM', 'FOREGROUND_SERVICE', 'WAKE_LOCK', 'VIBRATE', 'RECEIVE_BOOT_COMPLETED', 'USE_BIOMETRIC')) {
    $node = $manifest.SelectSingleNode("/manifest/uses-permission[@android:name='android.permission.$permission']", $namespace)
    Test-Requirement ($null -ne $node) "Missing Android permission: $permission"
}
foreach ($component in @('com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver', 'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver', 'dev.fluttercommunity.plus.androidalarmmanager.AlarmService', 'dev.fluttercommunity.plus.androidalarmmanager.AlarmBroadcastReceiver', 'dev.fluttercommunity.plus.androidalarmmanager.RebootBroadcastReceiver')) {
    $node = $manifest.SelectSingleNode("/manifest/application/*[@android:name='$component']", $namespace)
    Test-Requirement ($null -ne $node) "Missing native alarm component: $component"
}
foreach ($xmlFile in Get-ChildItem -LiteralPath (Join-Path $root 'android/app/src/main/res') -Recurse -File -Filter '*.xml') {
    try { [xml]$null = Get-Content -LiteralPath $xmlFile.FullName -Raw; $checks++ }
    catch { $failures.Add("Invalid XML: $($xmlFile.FullName)") }
}
$activity = Get-Content -LiteralPath (Join-Path $root 'android/app/src/main/kotlin/com/anggit/mula/mula/MainActivity.kt') -Raw
Test-Requirement ($activity -match 'class MainActivity\s*:\s*FlutterFragmentActivity\(\)') 'local_auth requires FlutterFragmentActivity'

if (Test-Path -LiteralPath (Join-Path $root 'lib')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Recurse -File -Filter '*.dart') {
        $source = Get-Content -LiteralPath $file.FullName -Raw
        Test-Requirement ($source -notmatch '//\s*TODO\b|onPressed\s*:\s*\(\)\s*\{\s*\}') "Forbidden placeholder in $($file.FullName)"
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Error $failure -ErrorAction Continue }
    throw "$($failures.Count) source check(s) failed."
}
Write-Output "$checks source checks passed. Flutter analysis, tests, and APK compilation run in GitHub Actions."
