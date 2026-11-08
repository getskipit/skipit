# Упаковывает уже собранную Windows-версию без установки и без запуска программы.
param([string]$Version, [string]$ReleaseDir, [string]$OutputDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) {
    $m = Select-String -LiteralPath (Join-Path $root 'lib\version.dart') -Pattern "defaultValue: '([^']+)'" | Select-Object -First 1
    $Version = $m.Matches[0].Groups[1].Value
}
$Version = $Version -replace '^v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+([A-Za-z](-\d+)?)?$') { throw 'Некорректная версия' }
if (-not $ReleaseDir) { $ReleaseDir = Join-Path $root 'build\windows\x64\runner\Release' }
if (-not $OutputDir) { $OutputDir = Join-Path $root 'build\portable' }
foreach ($file in @('SkipIt.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir $file) -PathType Leaf)) { throw "Не найдена сборка: $file" }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stageRoot = [IO.Path]::GetFullPath((Join-Path $root 'build\portable-staging'))
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
$stage = Join-Path $stageRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    # Только файлы сборки: userdata, журналы, дампы и конфиги в архив не попадают.
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'SkipIt.exe') -Destination $stage
    Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.dll' -File | Copy-Item -Destination $stage
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'data') -Destination $stage -Recurse
    $core = Join-Path $stage 'core'
    New-Item -ItemType Directory -Path $core | Out-Null
    foreach ($name in @('skipit-xray.exe', 'skipit-sing-box.exe', 'wintun.dll', 'LICENSE-Xray.txt', 'LICENSE-sing-box.txt')) {
        Copy-Item -LiteralPath (Join-Path $root "core\$name") -Destination $core
    }
    foreach ($name in @('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage
    }
    Copy-Item -LiteralPath (Join-Path $root 'docs\PORTABLE.md') -Destination (Join-Path $stage 'PORTABLE.txt')
    [IO.File]::WriteAllText((Join-Path $stage 'portable'), 'SkipIt portable mode')
    $archive = Join-Path $OutputDir "SkipIt-Portable-Windows-$Version.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$hash  $([IO.Path]::GetFileName($archive))`n")
    Write-Output "Готово: $archive"
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if (-not $resolved.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Небезопасный путь временной папки' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
