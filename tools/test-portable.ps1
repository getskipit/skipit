# Проверка упаковки на искусственной сборке: без запуска программы и без сети.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$area = Join-Path $root ('build\portable-check-' + [guid]::NewGuid().ToString('N'))
$release = Join-Path $area 'release'
$output = Join-Path $area 'output'
New-Item -ItemType Directory -Path (Join-Path $release 'data'), (Join-Path $release 'userdata'), $output -Force | Out-Null
foreach ($file in @('SkipIt.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat', 'userdata\state.json', 'config.json', 'skipit-service.exe', 'dev-build', 'personal.log')) {
    [IO.File]::WriteAllText((Join-Path $release $file), 'synthetic fixture')
}
try {
    & (Join-Path $PSScriptRoot 'build-portable.ps1') -Version '1.1.6' -ReleaseDir $release -OutputDir $output
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = Join-Path $output 'SkipIt-Portable-Windows-1.1.6.zip'
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($required in @('SkipIt.exe', 'flutter_windows.dll', 'portable', 'data/app.so', 'data/icudtl.dat', 'core/skipit-xray.exe', 'core/skipit-sing-box.exe', 'core/wintun.dll', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'PORTABLE.txt')) {
            if ($required -notin $entries) { throw "Не включён обязательный файл: $required" }
        }
        if ($entries | Where-Object { $_ -match '(^|/)(userdata|state\.json|config\.json|skipit-service\.exe|dev-build|personal\.log)(/|$)' }) {
            throw 'В архив попали личные данные, служба или тестовая метка'
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([IO.File]::ReadAllText("$archive.sha256") -split '\s+')[0]
    if ($hash -ne $expected) { throw 'Неверная контрольная сумма ZIP' }
    Write-Output 'Проверка переносного ZIP пройдена: состав, отсутствие данных и службы, SHA-256.'
} finally {
    $resolved = [IO.Path]::GetFullPath($area)
    $build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + '\'
    if (-not $resolved.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'Небезопасный путь проверки' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
