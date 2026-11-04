# Скачивает ядра Xray-core и sing-box в папку core\ и, если нужно, создаёт Windows-обвязку Flutter-проекта.
#   powershell -ExecutionPolicy Bypass -File tools\setup.ps1
#
# Версии ядер задаёт разработчик в tools\cores.json — программа у пользователей ядра сама не обновляет.
# Чтобы обновить ядро: поменяйте там "version" (тег релиза) и "sha256" (контрольная сумма zip-архива
# для Windows x64 со страницы релиза), затем запустите этот скрипт. SHA-256 обязателен.
# Уже скачанное ядро нужной версии повторно не качается.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'core'
$tmp = Join-Path $env:TEMP 'skipit-setup'
New-Item -ItemType Directory -Force $core, $tmp | Out-Null
$cores = Get-Content (Join-Path $PSScriptRoot 'cores.json') -Raw | ConvertFrom-Json
foreach ($name in @('xray', 'sing-box')) {
    if ($cores.$name.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "$name`: в tools/cores.json нужен полный SHA-256 архива (64 шестнадцатеричных знака)"
    }
}

# Версия уже лежащего в core\ ядра (пустая строка — ядра нет или оно не запускается).
function Get-InstalledVersion($exe, $pattern) {
    if (-not (Test-Path $exe)) { return '' }
    try {
        $out = (& $exe version 2>$null | Out-String)
        if ($out -match $pattern) { return $Matches[1] }
    } catch {}
    return ''
}

# Скачивает архив релиза по прямой ссылке (без API GitHub и его лимитов) и сверяет контрольную сумму.
function Get-CoreArchive($name, $url, $sha256) {
    if ($sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "$name`: некорректный SHA-256 архива" }
    $zip = Join-Path $tmp "$name.zip"
    Write-Host "  $url"
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $sha256.ToLower()) { throw "$name`: контрольная сумма архива не совпала ($actual)" }
    $dir = Join-Path $tmp $name
    Expand-Archive $zip -DestinationPath $dir -Force
    return $dir
}

$xrayVersion = $cores.xray.version -replace '^v', ''
$xrayExe = Join-Path $core 'skipit-xray.exe'
$wintun = Join-Path $core 'wintun.dll'
if ((Get-InstalledVersion $xrayExe 'Xray ([\d.]+)') -eq $xrayVersion -and (Test-Path (Join-Path $core 'LICENSE-Xray.txt')) -and (Test-Path $wintun)) {
    Write-Host "Xray-core $xrayVersion уже на месте"
} else {
    Write-Host "Xray-core $xrayVersion..."
    $dir = Get-CoreArchive 'xray' "https://github.com/XTLS/Xray-core/releases/download/$($cores.xray.version)/Xray-windows-64.zip" $cores.xray.sha256
    # Свои имена ядер — чтобы другие VPN-клиенты не закрывали их как «чужие» xray.exe.
    Copy-Item (Join-Path $dir 'xray.exe') $xrayExe -Force
    # Текст лицензии (MPL-2.0) кладём рядом с ядром.
    Copy-Item (Join-Path $dir 'LICENSE') (Join-Path $core 'LICENSE-Xray.txt') -Force
    # Драйвер адаптера из того же архива: нужен Xray, когда он сам поднимает TUN (в sing-box драйвер встроен).
    Copy-Item (Join-Path $dir 'wintun.dll') $wintun -Force
}

$sbVersion = $cores.'sing-box'.version -replace '^v', ''
$sbExe = Join-Path $core 'skipit-sing-box.exe'
$sbLicense = Join-Path $core 'LICENSE-sing-box.txt'
if ((Get-InstalledVersion $sbExe 'sing-box version ([\d.]+)') -eq $sbVersion) {
    Write-Host "sing-box $sbVersion уже на месте"
    # Ядро скачано раньше, чем скрипт начал сохранять лицензию, — докачиваем только её текст.
    if (-not (Test-Path $sbLicense)) {
        Invoke-WebRequest "https://raw.githubusercontent.com/SagerNet/sing-box/$($cores.'sing-box'.version)/LICENSE" -OutFile $sbLicense -UseBasicParsing
    }
} else {
    Write-Host "sing-box $sbVersion..."
    $dir = Get-CoreArchive 'sing-box' "https://github.com/SagerNet/sing-box/releases/download/$($cores.'sing-box'.version)/sing-box-$sbVersion-windows-amd64.zip" $cores.'sing-box'.sha256
    $sb = Get-ChildItem $dir -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
    Copy-Item $sb.FullName $sbExe -Force
    # GPL-3.0 требует передавать текст лицензии вместе с программой.
    $license = Get-ChildItem $dir -Recurse -Filter 'LICENSE' | Select-Object -First 1
    Copy-Item $license.FullName $sbLicense -Force
}

Remove-Item $tmp -Recurse -Force
Write-Host "Ядра лежат в $core" -ForegroundColor Green

if (-not (Test-Path (Join-Path $root 'windows'))) {
    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        Write-Host 'Создаю Windows-обвязку Flutter...'
        Push-Location $root
        flutter create --platforms=windows --project-name skipit --org app.skipit .
        Pop-Location
        # Заголовок окна «SkipIt» вместо имени пакета.
        $mainCpp = Join-Path $root 'windows\runner\main.cpp'
        (Get-Content $mainCpp -Raw) -replace 'L"skipit"', 'L"SkipIt"' | Set-Content $mainCpp -NoNewline
    } else {
        Write-Host 'Flutter не найден в PATH — установите его и выполните: flutter create --platforms=windows --project-name skipit .' -ForegroundColor Yellow
    }
}
