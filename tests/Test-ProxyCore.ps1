<#
.SYNOPSIS
    Antigravity & 通用应用代理 - 核心逻辑自动化回归测试套件
.DESCRIPTION
    覆盖配置读写、原子持久化与损坏自愈、Mihomo 配置与多监听器生成、端口冲突与孤儿隔离防护。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Path $testRoot -Parent

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  正在运行核心功能自动化回归测试套件" -ForegroundColor Cyan
Write-Host "  工程目录: $projectRoot" -ForegroundColor Gray
Write-Host "==================================================" -ForegroundColor Cyan

# 提取 AntigravityProxy.ps1 中的函数定义（不启动 GUI）
$mainScript = Join-Path -Path $projectRoot -ChildPath 'AntigravityProxy.ps1'
$code = Get-Content -LiteralPath $mainScript -Raw -Encoding UTF8
$marker = '$toolRoot = $PSScriptRoot'
$idx = $code.IndexOf($marker)
if ($idx -le 0) {
    throw "未在 AntigravityProxy.ps1 中找到函数切分标记 '$marker'"
}
$fnCode = $code.Substring(0, $idx)
. ([scriptblock]::Create($fnCode))

$totalTests = 0
$passedTests = 0
$failedTests = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$FailureMessage = ''
    )
    $script:totalTests++
    if ($Condition) {
        $script:passedTests++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:failedTests++
        Write-Host "  [FAIL] $Name - $FailureMessage" -ForegroundColor Red
    }
}

$tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("ag-core-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # -------------------------------------------------------------------------
    # 测试组 1: 设置读写、原子替换与损坏自愈
    # -------------------------------------------------------------------------
    Write-Host "`n[测试组 1] 设置读写、原子写入与损坏自愈测试..." -ForegroundColor Yellow

    $settingsPath = Join-Path -Path $tempDir -ChildPath 'config\settings.json'
    $testSettings = @{
        subscriptionUrl = 'https://example.com/sub'
        selectedNode = 'TW-Node-01'
        antigravityPath = 'C:\Test\antigravity.exe'
        proxyPort = 7899
        controllerPort = 19090
        portMappings = @(
            @{ port = 7899; node = 'TW-Node-01' }
            @{ port = 7896; node = 'US-Node-02' }
        )
        selectedPort = 7896
        customInstances = @(
            @{
                id = 'app-test-1'
                name = '测试应用 1'
                subscriptionUrl = 'https://example.com/sub2'
                controllerPort = 19091
                portMappings = @(
                    @{ port = 7880; node = 'HK-Node-01' }
                )
                selectedPort = 7880
            }
        )
    }

    # 1.1 保存测试
    $savedPath = Save-Settings -Settings $testSettings -Path $settingsPath
    Assert-Test -Name "设置保存文件生成" -Condition (Test-Path -LiteralPath $settingsPath -PathType Leaf) -FailureMessage "未生成 settings.json 文件"

    # 1.2 读取测试
    $loadedSettings = Read-Settings -Path $settingsPath
    Assert-Test -Name "设置反序列化完整性 (ProxyPort)" -Condition ($loadedSettings.proxyPort -eq 7899) -FailureMessage "读取的 proxyPort 不匹配"
    Assert-Test -Name "设置反序列化完整性 (PortMappings 数量)" -Condition ($loadedSettings.portMappings.Count -eq 2) -FailureMessage "portMappings 数量不为 2"
    Assert-Test -Name "设置反序列化完整性 (自定义实例)" -Condition ($loadedSettings.customInstances.Count -eq 1 -and $loadedSettings.customInstances[0].id -eq 'app-test-1') -FailureMessage "自定义实例数据不完整"

    # 1.3 备份生成测试
    $testSettings.selectedNode = 'TW-Node-Modified'
    $null = Save-Settings -Settings $testSettings -Path $settingsPath
    $null = Save-Settings -Settings $testSettings -Path $settingsPath
    $backupPath = $settingsPath + '.backup'
    Assert-Test -Name "二次保存自动生成 .backup" -Condition (Test-Path -LiteralPath $backupPath -PathType Leaf) -FailureMessage "未生成 settings.json.backup"

    # 1.4 损坏自愈测试
    [System.IO.File]::WriteAllText($settingsPath, "{ invalid json content ...")
    $recoveredSettings = Read-Settings -Path $settingsPath
    Assert-Test -Name "主配置损坏时自愈读取备份非默认字段" -Condition ($recoveredSettings.selectedNode -eq 'TW-Node-Modified') -FailureMessage "未能从备份自愈恢复非默认值 selectedNode"
    $corruptFiles = @(Get-ChildItem -Path (Split-Path -Parent $settingsPath) -Filter 'settings.json.corrupt-*')
    Assert-Test -Name "主配置损坏时生成 .corrupt 镜像" -Condition ($corruptFiles.Count -gt 0) -FailureMessage "未保留损坏配置文件"
    $diskRepaired = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "主配置损坏时自愈并在磁盘重写修复主配置" -Condition ($null -ne $diskRepaired -and $diskRepaired.selectedNode -eq 'TW-Node-Modified') -FailureMessage "未在磁盘上重写修复损坏的主配置文件"

    # 1.5 自愈后二次保存测试（确保不会将已损坏内容当作旧备份复制）
    $testSettings.selectedNode = 'TW-Node-Subsequent'
    $null = Save-Settings -Settings $testSettings -Path $settingsPath
    $backupAfterSave = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test -Name "自愈后保存新配置其备份内容为有效配置" -Condition ($null -ne $backupAfterSave -and $backupAfterSave.selectedNode -eq 'TW-Node-Modified') -FailureMessage "自愈后二次保存使备份被损坏内容污染"

    # 1.6 实例 ID 大小写不敏感排重测试
    $testSettingsWithDupes = @{
        subscriptionUrl = 'https://example.com/sub'
        selectedNode = 'TW-Node-01'
        antigravityPath = 'C:\Test\antigravity.exe'
        proxyPort = 7899
        controllerPort = 19090
        customInstances = @(
            @{ id = 'my-app'; name = 'App 1'; controllerPort = 19091 }
            @{ id = 'MY-APP'; name = 'App 1 Dup'; controllerPort = 19092 }
            @{ id = 'my-app-2'; name = 'App 2'; controllerPort = 19093 }
        )
    }
    $dupeSettingsPath = Join-Path -Path $tempDir -ChildPath 'config\dupe-settings.json'
    $null = Save-Settings -Settings $testSettingsWithDupes -Path $dupeSettingsPath
    $dupeLoaded = Read-Settings -Path $dupeSettingsPath
    Assert-Test -Name "实例 ID 大小写不敏感排重 (剔除冲突项)" -Condition ($dupeLoaded.customInstances.Count -eq 2) -FailureMessage "未正确剔除大小写冲突的重复实例 ID"

    # 1.7 备份本身损坏时的防递归与绝不覆盖主配置测试
    $recurseSettingsPath = Join-Path -Path $tempDir -ChildPath 'config\recurse-test.json'
    $recurseBackupPath = $recurseSettingsPath + '.backup'
    [System.IO.File]::WriteAllText($recurseSettingsPath, "{ bad main json")
    [System.IO.File]::WriteAllText($recurseBackupPath, "{ bad backup json")
    $recoveredFromBadBackup = Read-Settings -Path $recurseSettingsPath
    Assert-Test -Name "备份亦损坏时安全回退默认设置 (防递归)" -Condition ($recoveredFromBadBackup.proxyPort -eq 7899) -FailureMessage "备份损坏时未能安全回退默认设置"
    $mainDiskContent = [System.IO.File]::ReadAllText($recurseSettingsPath, [System.Text.Encoding]::UTF8)
    Assert-Test -Name "备份损坏时绝不将坏备份写回覆盖主配置" -Condition (-not $mainDiskContent.Contains('bad backup json')) -FailureMessage "坏备份内容被错误写回覆盖了主配置文件"

    # -------------------------------------------------------------------------
    # 测试组 2: Mihomo 配置与多监听器 (Listeners) 生成
    # -------------------------------------------------------------------------
    Write-Host "`n[测试组 2] Mihomo 配置文件生成与规则校验..." -ForegroundColor Yellow

    # 2.1 Antigravity 模块 (多端口) 配置
    $agConfigPath = Join-Path -Path $tempDir -ChildPath 'runtime\mihomo.yaml'
    $stateAg = @{
        ToolRoot = $projectRoot
        ConfigPath = $agConfigPath
        ControllerSecret = 'test-secret-123'
        PortMappings = @(
            @{ port = 7899; node = 'TW-Node-01' }
            @{ port = 7895; node = '' }
            @{ port = 7896; node = 'US-Node-02' }
        )
    }

    $null = Write-MihomoConfig -State $stateAg -SubscriptionUrl 'https://sub.example.com/test' -ProxyPort 7899 -ControllerPort 19090 -PortMappings $stateAg.PortMappings
    Assert-Test -Name "Antigravity 配置生成" -Condition (Test-Path -LiteralPath $agConfigPath) -FailureMessage "未生成 mihomo.yaml"

    $agContent = Get-Content -LiteralPath $agConfigPath -Raw -Encoding UTF8
    Assert-Test -Name "包含主 mixed-port 7899" -Condition ($agContent.Contains('mixed-port: 7899')) -FailureMessage "缺少 mixed-port: 7899"
    Assert-Test -Name "包含额外 listener 7895" -Condition ($agContent.Contains('port: 7895') -and $agContent.Contains('proxy: GROUP_7895')) -FailureMessage "缺少 listener 7895"
    Assert-Test -Name "包含额外 listener 7896" -Condition ($agContent.Contains('port: 7896') -and $agContent.Contains('proxy: GROUP_7896')) -FailureMessage "缺少 listener 7896"
    Assert-Test -Name "包含 ANTIGRAVITY 主策略组" -Condition ($agContent.Contains('name: ANTIGRAVITY')) -FailureMessage "缺少 ANTIGRAVITY 组"
    Assert-Test -Name "包含 GROUP_7895 策略组" -Condition ($agContent.Contains('name: GROUP_7895')) -FailureMessage "缺少 GROUP_7895 组"
    Assert-Test -Name "包含 MATCH,ANTIGRAVITY 默认规则" -Condition ($agContent.Contains('MATCH,ANTIGRAVITY')) -FailureMessage "缺少 MATCH,ANTIGRAVITY 规则"

    # 2.2 通用应用实例配置
    $instConfigPath = Join-Path -Path $tempDir -ChildPath 'runtime\instances\app-test-1\mihomo.yaml'
    $stateInst = @{
        ToolRoot = $projectRoot
        ConfigPath = $instConfigPath
        ControllerSecret = 'inst-secret-456'
        PortMappings = @(
            @{ port = 7880; node = 'HK-Node-01' }
            @{ port = 7881; node = 'JP-Node-02' }
        )
    }
    $null = Write-MihomoConfig -State $stateInst -SubscriptionUrl 'https://sub.example.com/test2' -ControllerPort 19091 -PortMappings $stateInst.PortMappings
    Assert-Test -Name "自定义实例配置生成" -Condition (Test-Path -LiteralPath $instConfigPath) -FailureMessage "未生成实例配置文件"

    $instContent = Get-Content -LiteralPath $instConfigPath -Raw -Encoding UTF8
    Assert-Test -Name "实例包含 listener 7880 与 7881" -Condition ($instContent.Contains('port: 7880') -and $instContent.Contains('port: 7881')) -FailureMessage "缺少实例端口 listeners"
    Assert-Test -Name "实例包含 GROUP_7880 与 GROUP_7881" -Condition ($instContent.Contains('name: GROUP_7880') -and $instContent.Contains('name: GROUP_7881')) -FailureMessage "缺少实例策略组"
    Assert-Test -Name "实例包含首端口 MATCH 规则" -Condition ($instContent.Contains('MATCH,GROUP_7880')) -FailureMessage "缺少 MATCH,GROUP_7880"

    # -------------------------------------------------------------------------
    # 测试组 3: 辅助函数容错与边界测试
    # -------------------------------------------------------------------------
    Write-Host "`n[测试组 3] 辅助函数容错与边界测试..." -ForegroundColor Yellow

    # 3.1 Get-PortFromMapping 容错测试
    $pFromHash = Get-PortFromMapping -Mapping @{ port = 8080 }
    $pFromObj = Get-PortFromMapping -Mapping ([pscustomobject]@{ port = 8081 })
    $pFromInt = Get-PortFromMapping -Mapping 8082
    $pFromNull = Get-PortFromMapping -Mapping $null
    Assert-Test -Name "Get-PortFromMapping 兼容 Hashtable" -Condition ($pFromHash -eq 8080) -FailureMessage "Hashtable 解析错误"
    Assert-Test -Name "Get-PortFromMapping 兼容 PSCustomObject" -Condition ($pFromObj -eq 8081) -FailureMessage "PSCustomObject 解析错误"
    Assert-Test -Name "Get-PortFromMapping 兼容 Integer" -Condition ($pFromInt -eq 8082) -FailureMessage "Integer 解析错误"
    Assert-Test -Name "Get-PortFromMapping 兼容 Null" -Condition ($pFromNull -eq 0) -FailureMessage "Null 应安全返回 0"

    # 3.2 节点可选手过滤测试
    $validNode = Test-SelectableNode -Name '香港 01' -Type 'ss'
    $systemNode = Test-SelectableNode -Name 'DIRECT' -Type 'Direct'
    $trafficNode = Test-SelectableNode -Name '剩余流量: 50GB' -Type 'ss'
    Assert-Test -Name "Test-SelectableNode 识别正常节点" -Condition ($validNode -eq $true) -FailureMessage "未正确识别正常节点"
    Assert-Test -Name "Test-SelectableNode 过滤系统保留节点" -Condition ($systemNode -eq $false) -FailureMessage "未过滤 DIRECT 节点"
    Assert-Test -Name "Test-SelectableNode 过滤流量公告信息" -Condition ($trafficNode -eq $false) -FailureMessage "未过滤流量信息"

    # -------------------------------------------------------------------------
    # 测试组 4: 脚本静态语法分析与快捷启动器配置装配
    # -------------------------------------------------------------------------
    Write-Host "`n[测试组 4] 脚本静态语法分析与快捷启动器校验..." -ForegroundColor Yellow

    # 4.1 核心脚本 AST 静态语法解析（确保 0 语法错误、无编码乱码破坏）
    $scriptsToParse = @(
        'AntigravityProxy.ps1',
        'build.ps1',
        'start.ps1',
        'launch-saved-antigravity.ps1',
        'launch-clash-antigravity.ps1',
        'switch-antigravity-to-clash.ps1',
        'run-agy-with-proxy.ps1',
        'run-agy-with-clash.ps1'
    )
    foreach ($scriptName in $scriptsToParse) {
        $scriptFilePath = Join-Path -Path $projectRoot -ChildPath $scriptName
        if (Test-Path -LiteralPath $scriptFilePath -PathType Leaf) {
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFilePath, [ref]$null, [ref]$parseErrors)
            $errMessage = ''
            if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
                $errList = @()
                foreach ($e in $parseErrors) { $errList += [string]$e.Message }
                $errMessage = [string]::Join('; ', $errList)
            }
            Assert-Test -Name "AST 语法解析: $scriptName (0 错误)" -Condition ($null -eq $parseErrors -or $parseErrors.Count -eq 0) -FailureMessage $errMessage
        }
    }

    # 4.2 launch-saved-antigravity.ps1 配置装配断言
    $launcherPath = Join-Path -Path $projectRoot -ChildPath 'launch-saved-antigravity.ps1'
    $launcherContent = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
    Assert-Test -Name "快捷启动器已校验并赋值 `$controllerPort" -Condition ($launcherContent -match '\$controllerPort\s*=\s*ConvertTo-ValidatedPort') -FailureMessage "快捷启动器未正确定义 `$controllerPort 赋值"
    Assert-Test -Name "快捷启动器已将 `$controllerPort 传入 Write-MihomoConfig" -Condition ($launcherContent -match '-ControllerPort\s+\$controllerPort') -FailureMessage "快捷启动器未将 `$controllerPort 传给 Write-MihomoConfig"
    Assert-Test -Name "快捷启动器已在 `$state 哈希表中包含 ControllerPort" -Condition ($launcherContent -match 'ControllerPort\s*=\s*\$controllerPort') -FailureMessage "快捷启动器 `$state 未包含 ControllerPort"

    # 4.3 Ensure-MihomoCore 校验本地已有二进制版本 (v1.19.30)
    $mainScriptText = Get-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'AntigravityProxy.ps1') -Raw -Encoding UTF8
    Assert-Test -Name "Ensure-MihomoCore 校验现有核心版本" -Condition ($mainScriptText -match '(?i)Ensure-MihomoCore[\s\S]*?Mihomo.*v1\.19\.30') -FailureMessage "Ensure-MihomoCore 未校验现有核心版本"

    # 4.4 Stop-OrphanedMihomoOnPort 精确匹配 -f 参数与边界校验
    Assert-Test -Name "孤儿回收精确解析 -f 参数并作边界校验" -Condition ($mainScriptText.Contains('$extractedConfigNorm') -and $mainScriptText.Contains('$runtimePrefix') -and $mainScriptText.Contains('$runtimeRootNorm')) -FailureMessage "孤儿回收未精确解析 -f 路径或缺少 runtimePrefix 边界校验"

    # 4.5 build.ps1 实例目录重建 ID 正则与路径越界防护
    $buildScriptText = Get-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'build.ps1') -Raw -Encoding UTF8
    Assert-Test -Name "build.ps1 校验实例 ID 正则与路径越界" -Condition ($buildScriptText.Contains('$instId -match') -and $buildScriptText.Contains('$instancesParent') -and $buildScriptText.Contains('StartsWith($instancesParent')) -FailureMessage "build.ps1 缺少实例 ID 正则校验或路径越界检查"
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "  测试结果汇总: 全部 $totalTests 项, 通过: $passedTests, 失败: $failedTests" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })
Write-Host "==================================================" -ForegroundColor Cyan

if ($failedTests -gt 0) {
    exit 1
}
else {
    exit 0
}
