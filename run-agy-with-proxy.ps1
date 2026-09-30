# agy CLI 独立 Mihomo 启动器（Codex，2026-09-04）
# 读取项目端口，只给本次 agy CLI 进程设置代理，不写入永久环境变量。

$ErrorActionPreference = 'Stop'
$toolRoot = $PSScriptRoot
$settingsPath = Join-Path -Path $toolRoot -ChildPath 'config\settings.json'
$secretPath = Join-Path -Path $toolRoot -ChildPath 'runtime\controller.secret'
$agyPath = ''
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $localAgyPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $localAgyPath -PathType Leaf) {
        $agyPath = $localAgyPath
    }
}

if ([string]::IsNullOrWhiteSpace($agyPath)) {
    $agyCommand = Get-Command -Name 'agy.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $agyCommand) {
        throw 'agy.exe was not found; install agy CLI first.'
    }
    $agyPath = $agyCommand.Source
}

$proxyPort = 7899
$controllerPort = 19090
$selectedNode = ''
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $parsedPort = 0
        $portText = [string]$settings.proxyPort
        if ([int]::TryParse($portText, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
            $proxyPort = $parsedPort
        }
        $parsedControllerPort = 0
        $controllerText = [string]$settings.controllerPort
        if ([int]::TryParse($controllerText, [ref]$parsedControllerPort) -and $parsedControllerPort -ge 1 -and $parsedControllerPort -le 65535) {
            $controllerPort = $parsedControllerPort
        }
        $selectedNode = [string]$settings.selectedNode
    }
    catch {
        $proxyPort = 7899
        $controllerPort = 19090
        $selectedNode = ''
    }
}

$listener = Get-NetTCPConnection -State Listen -LocalPort $proxyPort -ErrorAction SilentlyContinue
if ($null -eq $listener) {
    throw ('Standalone Mihomo proxy port ' + $proxyPort + ' is not listening; start the proxy tool first.')
}

if ([string]::IsNullOrWhiteSpace($selectedNode) -or -not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
    throw 'No saved Antigravity node is configured; select a node in the standalone proxy tool first.'
}
$controllerSecret = (Get-Content -LiteralPath $secretPath -Raw -Encoding UTF8).Trim()
$controllerHeaders = @{ Authorization = 'Bearer ' + $controllerSecret }
$selectionBody = @{ name = $selectedNode } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri ('http://127.0.0.1:' + $controllerPort + '/proxies/ANTIGRAVITY') -Headers $controllerHeaders -Method Put -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($selectionBody)) -TimeoutSec 5 -ErrorAction Stop | Out-Null

$proxyValues = @(
    [pscustomobject]@{ Name = 'HTTP_PROXY'; Value = 'http://127.0.0.1:' + $proxyPort }
    [pscustomobject]@{ Name = 'HTTPS_PROXY'; Value = 'http://127.0.0.1:' + $proxyPort }
    [pscustomobject]@{ Name = 'ALL_PROXY'; Value = 'socks5://127.0.0.1:' + $proxyPort }
)
$previousValues = @{}
foreach ($entry in $proxyValues) {
    $name = [string]$entry.Name
    $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, 'Process')
}

$exitCode = 1
try {
    $cliArguments = @($args)
    & $agyPath @cliArguments
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($entry in $proxyValues) {
        $name = [string]$entry.Name
        [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
    }
}

exit $exitCode
