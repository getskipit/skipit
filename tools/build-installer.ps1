# Собирает установщик из уже собранной программы. -Preview — только интерфейс,
# без вложенного установщика, запроса UAC и возможности установить программу.
param([string]$Version, [switch]$Preview, [string]$OutputDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) {
    $match = Select-String -Path (Join-Path $root 'lib\version.dart') -Pattern "defaultValue: '([^']+)'" | Select-Object -First 1
    $Version = $match.Matches[0].Groups[1].Value
}
$Version = $Version -replace '^v', ''
if (-not $OutputDir) { $OutputDir = Join-Path $root $(if ($Preview) { 'build\installer-shell-preview' } else { 'build\installer' }) }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $OutputDir | Out-Null

$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $cmake = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' | Select-Object -First 1
    }
}
if (-not $cmake) { throw 'Не найден CMake из комплекта Visual Studio.' }

$payloadArgument = @()
if (-not $Preview) {
    $iscc = @(
        (Get-Command iscc -ErrorAction SilentlyContinue).Source,
        'D:\tools\InnoSetup\ISCC.exe',
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe", "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Не найден Inno Setup (ISCC.exe).' }
    $payloadDir = Join-Path $root 'build\installer-payload'
    & $iscc "/DAppVersion=$Version" "/O$payloadDir" (Join-Path $root 'installer\skipit.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать вложенный установщик.' }
    $payloadArgument = @("-DINSTALLER_PAYLOAD=$payloadDir\SkipIt-Setup-Windows-$Version.exe")
}
$buildDir = Join-Path $root $(if ($Preview) { 'build\installer-shell-preview-cmake' } else { 'build\installer-shell-cmake' })
& $cmake -S (Join-Path $root 'installer\shell') -B $buildDir -A x64 "-DAPP_VERSION=$Version" "-DSKIPIT_PREVIEW=$($Preview.IsPresent.ToString().ToUpper())" @payloadArgument
if ($LASTEXITCODE -ne 0) { throw 'Не удалось настроить сборку оболочки установщика.' }
& $cmake --build $buildDir --config Release
if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать оболочку установщика.' }
$name = if ($Preview) { 'SkipIt-Setup-Preview.exe' } else { "SkipIt-Setup-Windows-$Version.exe" }
$destination = Join-Path $OutputDir $name
Copy-Item -LiteralPath (Join-Path $buildDir 'Release\SkipItSetup.exe') -Destination $destination -Force
if (-not $Preview) {
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLower()
    [IO.File]::WriteAllText("$destination.sha256", "$hash  $name`n")
}
Write-Host "Готово: $destination" -ForegroundColor Green
