param(
    [string]$BaselineFile = $env:ONEC_BASELINE_CF,
    [string]$BaselineSha256 = $env:ONEC_BASELINE_SHA256
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runName = if ($env:GITHUB_RUN_ID) {
    "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
} else {
    'local-' + [guid]::NewGuid().ToString('N')
}
$runRoot = Join-Path $projectRoot "build\$runName"
$basePath = Join-Path $runRoot 'ib'
$artifactPath = Join-Path $runRoot 'artifacts'
$logPath = Join-Path $runRoot 'logs'
$manifestPath = Join-Path $runRoot 'build-result.json'
New-Item -ItemType Directory -Path $artifactPath, $logPath -Force | Out-Null

$result = [ordered]@{
    status = 'failed'
    commit = $env:GITHUB_SHA
    branch = $env:GITHUB_REF_NAME
    run = $runName
    startedAt = [DateTime]::UtcNow.ToString('o')
    testsExecuted = $false
}

function Invoke-VRunner {
    param([string]$Step, [string[]]$Arguments)

    Write-Host "Операция: $Step"
    $stepLog = Join-Path $logPath "$Step.log"
    # Сохраняем исходный вывод 1С, затем проверяем код завершения команды.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $script:runnerCommand @Arguments 2>&1 | Tee-Object -FilePath $stepLog
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        throw "Операция '$Step' завершилась с кодом $exitCode. Полный вывод: $stepLog"
    }
}

Start-Transcript -Path (Join-Path $logPath 'build.log') -Force | Out-Null
try {
    $settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $settings.extensionSource))
    if (-not $sourcePath.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Исходники расширения должны находиться внутри репозитория'
    }
    $extensionXml = [xml](Get-Content -LiteralPath (Join-Path $sourcePath 'Configuration.xml') -Raw -Encoding UTF8)
    if ($extensionXml.MetaDataObject.Configuration.Properties.Name -ne $settings.extensionName) {
        throw 'Имя расширения в build-settings.json не совпадает с именем в XML'
    }
    if ($settings.extensionName -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') {
        throw 'Недопустимое имя расширения'
    }
    if (-not $BaselineFile -or -not (Test-Path -LiteralPath $BaselineFile -PathType Leaf)) {
        throw 'Укажите существующий эталон .cf в переменной ONEC_BASELINE_CF'
    }
    if ($BaselineSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Укажите SHA256 эталона в переменной ONEC_BASELINE_SHA256'
    }
    $baselineHash = (Get-FileHash -LiteralPath $BaselineFile -Algorithm SHA256).Hash
    if ($baselineHash -ne $BaselineSha256) {
        throw 'Контрольная сумма эталона не совпала с ONEC_BASELINE_SHA256'
    }

    $script:runnerCommand = (Get-Command vrunner -ErrorAction Stop).Source
    $runnerVersion = (& $script:runnerCommand --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $runnerVersion -ne $settings.vanessaRunnerVersion) {
        throw "Ожидается Vanessa Runner $($settings.vanessaRunnerVersion), установлен: $runnerVersion"
    }
    $oscriptVersion = (& oscript -version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось определить версию OneScript' }
    $result.platformVersion = $settings.platformVersion
    $result.vanessaRunnerVersion = $runnerVersion
    $result.oneScriptVersion = $oscriptVersion
    $result.extensionName = $settings.extensionName
    $result.baselineSha256 = $baselineHash
    if (-not $result.commit) { $result.commit = (& git -C $projectRoot rev-parse HEAD | Out-String).Trim() }

    # Каждая сборка создаёт собственную базу и передаёт подключение явно.
    $connection = '/F' + $basePath
    $common = @('--ibconnection', $connection, '--v8version', $settings.platformVersion, '--src-format', 'xml')
    Invoke-VRunner 'initialize-base' (@('infobase', 'init', '--src', $BaselineFile) + $common)

    $cfeFile = Join-Path $artifactPath ($settings.extensionName + '.cfe')
    Invoke-VRunner 'compile-extension' (@('cfe', 'compile', '--src', $sourcePath, '--extension-name', $settings.extensionName) + $common + @($cfeFile))
    Invoke-VRunner 'update-extension-db' @('infobase', 'update', '--target', $settings.extensionName, '--ibconnection', $connection, '--v8version', $settings.platformVersion)

    if (-not (Test-Path -LiteralPath $cfeFile -PathType Leaf) -or (Get-Item -LiteralPath $cfeFile).Length -eq 0) {
        throw 'Файл поставки расширения не создан или пуст'
    }
    $result.artifact = [ordered]@{
        name = [IO.Path]::GetFileName($cfeFile)
        size = (Get-Item -LiteralPath $cfeFile).Length
        sha256 = (Get-FileHash -LiteralPath $cfeFile -Algorithm SHA256).Hash
    }
    $result.status = 'success'
    Write-Host "Расширение собрано: $cfeFile"
} catch {
    $result.error = $_.Exception.Message
    Write-Host $_.Exception.Message
    throw
} finally {
    # Удаляем только служебную базу этого запуска; исходники и логи сохраняем.
    if (Test-Path -LiteralPath $basePath) {
        $resolvedBase = (Resolve-Path -LiteralPath $basePath).Path
        $expectedBase = [IO.Path]::GetFullPath((Join-Path $runRoot 'ib'))
        if ($resolvedBase -eq $expectedBase -and $resolvedBase.StartsWith($runRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            try {
                Remove-Item -LiteralPath $resolvedBase -Recurse -Force
            } catch {
                Write-Warning "Не удалось удалить служебную базу: $($_.Exception.Message)"
            }
        }
    }
    $result.finishedAt = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Stop-Transcript | Out-Null
}
