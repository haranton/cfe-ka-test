param(
    [string]$ConfigFile = $env:ONEC_CI_CONFIG,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.json' }
$config = Get-Content -LiteralPath $ConfigFile -Encoding UTF8 -Raw | ConvertFrom-Json
$connection = [Environment]::ExpandEnvironmentVariables([string]$config.database.connection).Trim()
if ($connection -notmatch '^/[FS].+') {
    throw 'Укажите постоянную тестовую базу в database.connection: /F<каталог> или /S<сервер>\<база>'
}
if ($connection -match '^/F') {
    $basePath = $connection.Substring(2).Trim().Trim('"')
    if (-not [IO.Path]::IsPathRooted($basePath)) { $basePath = Join-Path $projectRoot $basePath }
    $basePath = [IO.Path]::GetFullPath($basePath)
    if (-not (Test-Path -LiteralPath (Join-Path $basePath '1Cv8.1CD') -PathType Leaf)) {
        throw "Существующая файловая база не найдена: $basePath"
    }
    $connection = '/F' + $basePath
}
$extensionName = [string]$config.extension.name
if ($extensionName -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') { throw 'Укажите корректное имя в extension.name' }
if (-not $config.platformVersion) { throw 'Укажите версию платформы в platformVersion' }
$source = [IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$config.extension.source)))
if (-not $source.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $source)) {
    throw 'extension.source должен указывать на XML-каталог или CFE-файл внутри проекта'
}
$sourceIsDirectory = Test-Path -LiteralPath $source -PathType Container
if ($sourceIsDirectory) {
    $xml = [xml](Get-Content -LiteralPath (Join-Path $source 'Configuration.xml') -Encoding UTF8 -Raw)
    if ($xml.MetaDataObject.Configuration.Properties.Name -ne $extensionName) { throw 'Имя расширения в конфиге не совпадает с XML' }
} elseif ([IO.Path]::GetExtension($source) -ne '.cfe') {
    throw 'Файлом источника может быть только .cfe'
}
$runner = (Get-Command vrunner -ErrorAction Stop).Source
if ($config.tests.enabled -isnot [bool]) { throw 'tests.enabled должен быть true или false' }
if ($config.tests.enabled) {
    if (-not $config.tests.command -or $config.tests.arguments -isnot [array] -or $config.tests.arguments.Count -eq 0) { throw 'Укажите tests.command и массив tests.arguments' }
    $testCommandInfo = Get-Command ([string]$config.tests.command) -ErrorAction Stop
    if ($testCommandInfo.CommandType -ne 'Application') { throw 'tests.command должен быть исполняемым файлом: vrunner, oscript или powershell.exe' }
    $testCommand = $testCommandInfo.Source
}
if ($ValidateOnly) { Write-Host 'Конфиг проверен. Операции с базой не выполнялись.'; return }

$runName = if ($env:GITHUB_RUN_ID) { "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)" } else { 'local-' + [guid]::NewGuid().ToString('N') }
$runRoot = Join-Path $projectRoot "build\$runName"
$logs = Join-Path $runRoot 'logs'
$artifacts = Join-Path $runRoot 'artifacts'
$reports = Join-Path $runRoot 'reports'
New-Item -ItemType Directory -Path $logs, $artifacts, $reports -Force | Out-Null
$result = [ordered]@{ status = 'failed'; commit = $env:GITHUB_SHA; branch = $env:GITHUB_REF_NAME; run = $runName; testsExecuted = $false; startedAt = [DateTime]::UtcNow.ToString('o') }

function Invoke-Step {
    param([string]$Name, [string]$Command, [string[]]$Arguments)
    Write-Host "Операция: $Name"
    # Сохраняем исходный вывод команды и проверяем её код завершения.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $logs "$Name.log")
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { throw "Операция '$Name' завершилась с кодом $code. См. $Name.log" }
}

$environmentNames = @('VRUNNER_IBCONNECTION', 'VRUNNER_V8VERSION', 'VRUNNER_EXTENSION_NAME', 'VRUNNER_DBUSER', 'ONEC_CI_REPORTS')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $projectRoot
Start-Transcript -Path (Join-Path $logs 'build.log') -Force | Out-Null
try {
    # Тестовая команда наследует то же подключение и версию платформы.
    $env:VRUNNER_IBCONNECTION = $connection
    $env:VRUNNER_V8VERSION = [string]$config.platformVersion
    $env:VRUNNER_EXTENSION_NAME = $extensionName
    if ($config.database.user) { $env:VRUNNER_DBUSER = [string]$config.database.user }
    $env:ONEC_CI_REPORTS = $reports
    $result.platformVersion = $config.platformVersion
    $result.extensionName = $extensionName
    if (-not $result.commit) { $result.commit = (& git rev-parse HEAD | Out-String).Trim() }

    # При загрузке XML 1С обновляет ConfigDumpInfo.xml, поэтому передаём копию.
    $loadSource = $source
    if ($sourceIsDirectory) {
        $loadSource = Join-Path $runRoot 'source'
        Copy-Item -LiteralPath $source -Destination $loadSource -Recurse
    }
    $common = @('--extension-name', $extensionName, '--ibconnection', $connection, '--v8version', [string]$config.platformVersion)
    Invoke-Step 'load-extension' $runner (@('cfe', 'load') + $common + @('--src-format', 'xml', $loadSource))
    $cfeFile = Join-Path $artifacts ($extensionName + '.cfe')
    Invoke-Step 'export-cfe' $runner (@('cfe', 'unload') + $common + @($cfeFile))
    if (-not (Test-Path -LiteralPath $cfeFile -PathType Leaf) -or (Get-Item -LiteralPath $cfeFile).Length -eq 0) { throw 'Файл CFE не создан или пуст' }
    $result.artifact = @{ name = [IO.Path]::GetFileName($cfeFile); sha256 = (Get-FileHash -LiteralPath $cfeFile -Algorithm SHA256).Hash }
    if ($config.tests.enabled) {
        $result.testsExecuted = $true
        $testArguments = @($config.tests.arguments | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
        Invoke-Step 'tests' $testCommand $testArguments
    } else { Write-Host 'Тесты выключены в конфиге' }
    $result.status = 'success'
} catch {
    $result.error = $_.Exception.Message
    throw
} finally {
    # Постоянную базу сохраняем. Результат и логи остаются в папке build.
    $result.finishedAt = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runRoot 'build-result.json') -Encoding UTF8
    Stop-Transcript | Out-Null
    Pop-Location
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
