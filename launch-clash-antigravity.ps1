# Antigravity Clash 7898 启动器（Codex，2026-09-04）
# 只给本次 Antigravity 进程树注入 Clash 代理，不改系统代理和永久环境变量。
[CmdletBinding()]
param(
    [ValidateSet('ide', 'v2')]
    [string]$Target = 'v2'
)

$ErrorActionPreference = 'Stop'
$clashPort = 7898

function Test-ClashPort {
    <# 检查 Clash 的 7898 端口是否正在监听，避免启动后才发现代理不可用。 #>
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

function Resolve-ClashTargetPath {
    <# 根据桌面快捷方式类型定位 Antigravity IDE 或 Antigravity 2.0。 #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ide', 'v2')]
        [string]$LaunchTarget
    )

    $candidates = @()
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath 'config\settings.json'
    if ($LaunchTarget -eq 'ide' -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$settings.antigravityPath)) {
                $candidates += [string]$settings.antigravityPath
            }
        }
        catch {
            Write-Verbose ('无法读取已保存的 Antigravity 路径：' + $_.Exception.Message)
        }
    }
    if ($LaunchTarget -eq 'ide') {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $candidates += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\Antigravity IDE.exe'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $candidates += Join-Path -Path $env:ProgramFiles -ChildPath 'Antigravity IDE\Antigravity IDE.exe'
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $candidates += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\antigravity\Antigravity.exe'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $candidates += Join-Path -Path $env:ProgramFiles -ChildPath 'Antigravity\Antigravity.exe'
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw ('找不到 Antigravity ' + $LaunchTarget + ' 可执行文件。')
}

function Get-ProcessRecords {
    <# 读取当前进程快照，供启动前判断是否会复用旧的 Antigravity 实例。 #>
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        throw ('无法读取 Antigravity 进程列表：' + $_.Exception.Message)
    }
}

function Test-TargetProcessRunning {
    <# 判断指定路径的 Antigravity 主进程或语言服务是否仍在运行。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdePath
    )

    $normalizedPath = $IdePath.ToLowerInvariant().Replace('/', '\')
    $processes = Get-ProcessRecords
    foreach ($process in $processes) {
        $executablePath = [string]$process.ExecutablePath
        if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
            $normalizedExecutablePath = $executablePath.ToLowerInvariant().Replace('/', '\')
            if ($normalizedExecutablePath -eq $normalizedPath) {
                return $true
            }
        }
    }

    return $false
}

function Start-ClashAntigravity {
    <# 用进程级代理变量和 Electron 参数启动 Antigravity 及其语言服务。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdePath,

        [Parameter(Mandatory = $true)]
        [int]$ProxyPort
    )

    if (-not (Test-ClashPort -Port $ProxyPort)) {
        throw ('Clash 代理端口 ' + $ProxyPort + ' 没有监听，请先启动 Clash 并确认端口。')
    }
    if (Test-TargetProcessRunning -IdePath $IdePath) {
        throw '检测到同路径 Antigravity 仍在运行，请先在“Antigravity 专用代理”中点击“切换到 Clash 7898”完全退出后再启动。'
    }

    $proxyUrl = 'http://127.0.0.1:' + $ProxyPort
    $socksUrl = 'socks5://127.0.0.1:' + $ProxyPort
    $proxyValues = @(
        [pscustomobject]@{ Name = 'HTTP_PROXY'; Value = $proxyUrl }
        [pscustomobject]@{ Name = 'HTTPS_PROXY'; Value = $proxyUrl }
        [pscustomobject]@{ Name = 'ALL_PROXY'; Value = $socksUrl }
    )
    $previousValues = @{}
    foreach ($entry in $proxyValues) {
        $name = [string]$entry.Name
        $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, 'Process')
    }

    $oldElectronRunAsNode = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')
    $oldVscodeVariables = @{}
    Get-ChildItem Env: | Where-Object { $_.Name -like 'VSCODE_*' } | ForEach-Object {
        $oldVscodeVariables[$_.Name] = $_.Value
    }

    try {
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process')
        foreach ($name in $oldVscodeVariables.Keys) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        $ideDirectory = Split-Path -Parent $IdePath
        $argumentList = @('--proxy-server=' + $proxyUrl)
        $process = Start-Process -FilePath $IdePath -ArgumentList $argumentList -WorkingDirectory $ideDirectory -PassThru -ErrorAction Stop
    }
    finally {
        foreach ($entry in $proxyValues) {
            $name = [string]$entry.Name
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
        }
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $oldElectronRunAsNode, 'Process')
        foreach ($entry in $oldVscodeVariables.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }

    return $process.Id
}

try {
    $idePath = Resolve-ClashTargetPath -LaunchTarget $Target
    $processId = Start-ClashAntigravity -IdePath $idePath -ProxyPort $clashPort
    Write-Output ('Antigravity ' + $Target + ' 已启动，使用 Clash 代理端口 ' + $clashPort + '，PID=' + $processId + '。')
    exit 0
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'Antigravity Clash 7898 启动失败',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
