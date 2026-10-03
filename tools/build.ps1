# Сборка SkipIt: программа + установщик SkipIt-Setup-Windows-<версия>.exe.
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 [-Version 1.0.7]
# Без -Version берётся версия по умолчанию из lib\version.dart.
# Результат: build\installer\SkipIt-Setup-Windows-<версия>.exe и файл .sha256 с его контрольной суммой

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

    $iscc = @(
        (Get-Command iscc -ErrorAction SilentlyContinue).Source,
        'D:\tools\InnoSetup\ISCC.exe',
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Не найден Inno Setup (ISCC.exe). Установите его: https://jrsoftware.org/isdl.php' }

    & $iscc "/DAppVersion=$Version" 'installer\skipit.iss'
    if ($LASTEXITCODE -ne 0) { throw 'Сборка установщика завершилась с ошибкой' }
    # Контрольная сумма рядом с установщиком: по ней программа проверяет скачанное обновление.
    $installer = "build\installer\SkipIt-Setup-Windows-$Version.exe"
    $hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
    [IO.File]::WriteAllText((Join-Path $root "$installer.sha256"), "$hash  SkipIt-Setup-Windows-$Version.exe`n")
    Write-Host "Готово: $installer" -ForegroundColor Green
} finally {
    Pop-Location
}
