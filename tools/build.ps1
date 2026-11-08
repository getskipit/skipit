# Сборка SkipIt: программа + установщик SkipIt-Setup-Windows-<версия>.exe.
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 [-Version 1.1.6]
# Без -Version берётся версия по умолчанию из lib\version.dart.
# Результат: установщик в build\installer, переносной ZIP в build\portable и их файлы .sha256.

param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not $Version) {
        $m = Select-String -Path 'lib\version.dart' -Pattern "defaultValue: '([^']+)'" | Select-Object -First 1
        $Version = $m.Matches[0].Groups[1].Value
    }
    $Version = $Version -replace '^v', ''
    # Flutter принимает только числовую версию (1.0.2) — буква идёт в APP_VERSION для программы и установщика.
    $numeric = ([regex]::Match($Version, '^\d+(\.\d+){0,2}')).Value
    if (-not $numeric) { throw "Не удалось разобрать версию '$Version'" }
    Write-Host "Версия: $Version (числовая $numeric)" -ForegroundColor Cyan

    # Ядра нужных версий (tools\cores.json); если они уже скачаны, скрипт ничего не качает.
    & (Join-Path $PSScriptRoot 'setup.ps1')

    flutter build windows --release --no-tree-shake-icons --build-name $numeric --dart-define "APP_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build завершился с ошибкой' }

    & (Join-Path $PSScriptRoot 'build-installer.ps1') -Version $Version
    & (Join-Path $PSScriptRoot 'build-portable.ps1') -Version $Version
} finally {
    Pop-Location
}
