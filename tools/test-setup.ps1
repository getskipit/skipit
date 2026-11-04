# Проверяет обязательность SHA-256 без сети и запуска ядер.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $root 'build\setup-check'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Синтаксическая ошибка setup.ps1' }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CoreArchive' }, $true)
if (-not $function) { throw 'Не найдена Get-CoreArchive' }
. ([scriptblock]::Create($function.Extent.Text))

$script:downloads = 0
$script:unpacks = 0
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $script:downloads++
    [IO.File]::WriteAllText($OutFile, 'synthetic archive for checksum verification')
}
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    $script:unpacks++
}
foreach ($invalid in @('', 'abc', ('z' * 64))) {
    $rejected = $false
    try { Get-CoreArchive 'example' 'https://core.example/archive.zip' $invalid | Out-Null }
    catch { if ($_.Exception.Message -notmatch 'SHA-256') { throw }; $rejected = $true }
    if (-not $rejected -or $script:downloads -ne 0 -or $script:unpacks -ne 0) { throw 'Некорректный SHA-256 не остановил загрузку' }
}
$rejected = $false
try { Get-CoreArchive 'example' 'https://core.example/archive.zip' ('0' * 64) | Out-Null }
catch { if ($_.Exception.Message -notmatch 'сумма архива не совпала') { throw }; $rejected = $true }
if (-not $rejected -or $script:unpacks -ne 0) { throw 'Архив с неверной суммой был принят' }
$valid = (Get-FileHash -LiteralPath (Join-Path $tmp 'example.zip') -Algorithm SHA256).Hash
Get-CoreArchive 'example' 'https://core.example/archive.zip' $valid | Out-Null
if ($script:downloads -ne 2 -or $script:unpacks -ne 1) { throw 'Архив с правильной суммой не принят' }
Write-Output 'Проверки SHA-256 пройдены: сеть и ядра не использовались.'
