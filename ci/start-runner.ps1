param(
    [string]$RunnerDirectory = (Join-Path $env:USERPROFILE 'actions-runner-cfe-ka-test')
)

$ErrorActionPreference = 'Stop'
$runFile = Join-Path $RunnerDirectory 'run.cmd'
if (-not (Test-Path -LiteralPath $runFile -PathType Leaf)) {
    throw "Runner не установлен в $RunnerDirectory"
}
$listenerPath = Join-Path $RunnerDirectory 'bin\Runner.Listener.exe'
$listener = Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $listenerPath }
if ($listener) {
    Write-Host 'Runner уже запущен'
    return
}
# Официальный run.cmd обрабатывает перезапуск runner после обновления.
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', ('"' + $runFile + '"')) -WorkingDirectory $RunnerDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $RunnerDirectory 'runner-console.log') -RedirectStandardError (Join-Path $RunnerDirectory 'runner-errors.log') -PassThru
Write-Host "Runner запущен в фоне, процесс $($process.Id)"
