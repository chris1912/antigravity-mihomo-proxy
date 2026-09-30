# agy CLI Clash 7898 启动器（Codex，2026-09-04）
# 只给本次 agy CLI 进程注入 Clash 代理，不读取独立 Mihomo 设置。
$ErrorActionPreference = 'Stop'
$clashPort = 7898
$agyPath = ''
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $localAgyPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $localAgyPath -PathType Leaf) {
        $agyPath = $localAgyPath
    }
}

function Test-ClashPort {
    <# 检查 Clash 7898 是否监听，避免 agy CLI 无代理运行。 #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            return $true
        }
    }
    catch {
        Write-Verbose ('无法读取 TCP 监听列表，将使用连接探测：' + $_.Exception.Message)
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($agyPath)) {
    $agyCommand = Get-Command -Name 'agy.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $agyCommand) {
        throw '找不到 agy.exe，请先确认 agy CLI 已安装。'
    }
    $agyPath = $agyCommand.Source
}
if (-not (Test-ClashPort -Port $clashPort)) {
    throw 'Clash 代理端口 7898 没有监听，请先启动 Clash 并确认端口。'
}

$proxyValues = @(
    [pscustomobject]@{ Name = 'HTTP_PROXY'; Value = 'http://127.0.0.1:' + $clashPort }
    [pscustomobject]@{ Name = 'HTTPS_PROXY'; Value = 'http://127.0.0.1:' + $clashPort }
    [pscustomobject]@{ Name = 'ALL_PROXY'; Value = 'socks5://127.0.0.1:' + $clashPort }
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
