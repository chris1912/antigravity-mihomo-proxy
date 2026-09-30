# Antigravity 独立 Mihomo 直接启动器（Codex，2026-09-04）
# 供旧桌面快捷方式调用：只使用项目保存的节点和独立代理端口，不读取或写入 Clash 专用端口。
param(
    [string]$Target
)

$ErrorActionPreference = 'Stop'

$toolRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($toolRoot)) {
    $toolRoot = [Environment]::GetEnvironmentVariable('ANTIGRAVITY_MIHOMO_TOOL_ROOT', 'Process')
}
if ([string]::IsNullOrWhiteSpace($toolRoot)) {
    throw '无法确定独立 Mihomo 项目目录。'
}
$mainPath = Join-Path -Path $toolRoot -ChildPath 'AntigravityProxy.ps1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
    $target = [string]$Target
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = [string]$env:ANTIGRAVITY_MIHOMO_TARGET
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = 'ide'
    }
    if ($target -notin @('ide', 'v2')) {
        throw '不支持的 Antigravity 启动目标。'
    }

    $source = [System.IO.File]::ReadAllText($mainPath, $utf8NoBom)
    $sourceLines = $source -split "`r?`n"
    $mainLine = 0
    for ($index = 0; $index -lt $sourceLines.Count; $index++) {
        if ($sourceLines[$index] -match '^\$toolRoot = \$PSScriptRoot') {
            $mainLine = $index + 1
            break
        }
    }
    if ($mainLine -le 1) {
        throw '无法加载 Antigravity 专用代理函数。'
    }
    $definitions = $sourceLines[0..($mainLine - 2)] -join [Environment]::NewLine
    . ([scriptblock]::Create($definitions))

    $null = Ensure-ToolDirectories -ToolRoot $toolRoot
    $settingsPath = Join-Path -Path $toolRoot -ChildPath 'config\settings.json'
    $controllerSecretPath = Join-Path -Path $toolRoot -ChildPath 'runtime\controller.secret'
    $controllerSecret = Get-ControllerSecret -Path $controllerSecretPath
    $settings = Read-Settings -Path $settingsPath
    $subscriptionUrl = ConvertTo-ValidatedSubscriptionUrl -Text ([string]$settings.subscriptionUrl)
    $proxyPort = ConvertTo-ValidatedPort -Text ([string]$settings.proxyPort) -FieldName 'Antigravity 代理端口'
    $controllerPort = ConvertTo-ValidatedPort -Text ([string]$settings.controllerPort) -FieldName 'Mihomo 控制端口'
    $rootPortMappings = @()
    if ($settings.ContainsKey('portMappings') -and $null -ne $settings.portMappings) {
        foreach ($m in @($settings.portMappings)) {
            $rootPortMappings += @{
                port = [int]$m.port
                node = [string]$m.node
            }
        }
    }
    $hasPrimaryPort = @($rootPortMappings | Where-Object { [int]$_.port -eq $proxyPort }).Count -gt 0
    if (-not $hasPrimaryPort) {
        $rootPortMappings = @( @{ port = $proxyPort; node = [string]$settings.selectedNode } ) + $rootPortMappings
    }
    $rootSelectedPort = if ($settings.ContainsKey('selectedPort') -and [int]$settings.selectedPort -gt 0) { [int]$settings.selectedPort } else { $proxyPort }

    $state = @{
        ToolRoot = $toolRoot
        SettingsPath = $settingsPath
        ConfigPath = (Join-Path -Path $toolRoot -ChildPath 'runtime\mihomo.yaml')
        ControllerSecret = $controllerSecret
        SubscriptionUrl = $subscriptionUrl
        ProxyPort = $proxyPort
        ControllerPort = $controllerPort
        SelectedNode = [string]$settings.selectedNode
        PortMappings = $rootPortMappings
        SelectedPort = $rootSelectedPort
        Nodes = @()
        ManagedProcess = $null
        Refreshing = $false
        Busy = $false
        Settings = $settings
    }

    $null = Write-MihomoConfig -State $state -SubscriptionUrl $subscriptionUrl -ProxyPort $proxyPort -ControllerPort $controllerPort -PortMappings $rootPortMappings
    $null = Start-OrReuseMihomo -State $state -SubscriptionUrl $subscriptionUrl
    $null = Update-MihomoProvider -State $state
    $state.Nodes = @(Wait-MihomoNodes -State $state)
    $selectedNode = [string]$settings.selectedNode
    $selectedNodeExists = @($state.Nodes | Where-Object { [string]$_.Name -eq $selectedNode }).Count -gt 0
    if (-not $selectedNodeExists) {
        throw '没有已保存的有效节点，请先打开独立 Mihomo 工具加载订阅并手动选择节点。'
    }

    $null = Set-MihomoSelection -State $state -NodeName $selectedNode

    # 自动恢复额外监听端口指派的节点
    foreach ($m in $rootPortMappings) {
        $mPort = [int]$m.port
        $mNode = [string]$m.node
        if ($mPort -ne $proxyPort -and -not [string]::IsNullOrWhiteSpace($mNode)) {
            $mNodeExists = @($state.Nodes | Where-Object { [string]$_.Name -eq $mNode }).Count -gt 0
            if ($mNodeExists) {
                try {
                    $null = Set-MihomoSelection -State $state -NodeName $mNode -GroupName ('GROUP_' + $mPort)
                }
                catch {
                }
            }
        }
    }

    $settings.subscriptionUrl = $subscriptionUrl
    $settings.selectedNode = $selectedNode
    $settings.proxyPort = $proxyPort
    $settings.controllerPort = $controllerPort
    $settings.portMappings = $rootPortMappings
    $settings.selectedPort = $rootSelectedPort
    $requestedIdePath = [string]$settings.antigravityPath
    if ($target -eq 'v2') {
        $v2Candidates = @()
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $v2Candidates += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\antigravity\Antigravity.exe'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $v2Candidates += Join-Path -Path $env:ProgramFiles -ChildPath 'Antigravity\Antigravity.exe'
        }
        $requestedIdePath = @($v2Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
        if ([string]::IsNullOrWhiteSpace($requestedIdePath)) {
            throw '找不到 Antigravity 2.0 的 Antigravity.exe。'
        }
    }

    $idePath = Resolve-AntigravityPath -RequestedPath $requestedIdePath -ToolRoot $toolRoot
    if ([string]::IsNullOrWhiteSpace($idePath)) {
        throw '找不到 Antigravity，请先在独立 Mihomo 工具中填写可执行文件路径。'
    }
    if ($target -eq 'ide') {
        $settings.antigravityPath = $idePath
    }
    $null = Save-Settings -Settings $settings -Path $settingsPath
    $process = Start-AntigravityWithProxy -IdePath $idePath -ProxyPort $proxyPort
    Write-Output ('Antigravity 已启动，独立 Mihomo 代理端口为 ' + $proxyPort + '。')
    return $process.Id
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'Antigravity 独立代理启动失败',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
