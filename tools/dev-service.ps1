# Служба для тестовой сборки (SkipItDev): ставит или снимает её. Нужны права администратора —
# скрипт сам попросит их окном UAC.
#   powershell -ExecutionPolicy Bypass -File tools\dev-service.ps1            # поставить или обновить
#   powershell -ExecutionPolicy Bypass -File tools\dev-service.ps1 -Uninstall # снять
#
# Файл службы копируется в Program Files: служба работает с правами системы, и её exe не должен
# лежать в папке, куда может писать кто угодно (build\dev). Команды она принимает только от
# build\dev\SkipIt.exe — эта папка открыта на запись, поэтому такая служба годится только на машине
# разработчика. После правок в windows\service — собрать тестовую копию (tools\dev.ps1) и запустить
# этот скрипт снова.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$name = 'SkipItDev'
$dest = Join-Path $env:ProgramFiles 'SkipIt Dev Service'
$exe = Join-Path $dest 'skipit-service.exe'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    $p = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

if (Test-Path $exe) {
    & $exe --stop --name $name | Out-Null
}
if ($Uninstall) {
    if (Test-Path $exe) { & $exe --uninstall --name $name | Out-Null }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Write-Host "Служба $name снята"
    exit 0
}

$source = Join-Path $root 'build\dev\skipit-service.exe'
$client = Join-Path $root 'build\dev\SkipIt.exe'
if (-not (Test-Path $source)) { throw "Нет $source — сначала соберите тестовую копию (tools\dev.ps1)" }
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item $source $exe -Force
& $exe --install --name $name --client $client
if ($LASTEXITCODE -ne 0) { throw "Служба не поставилась (код $LASTEXITCODE)" }
Write-Host "Служба $name работает и слушается только $client"
