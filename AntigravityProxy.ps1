Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-DefaultSettings {
    <# 创建首次启动时使用的本地设置。 #>
    $settings = @{
        subscriptionUrl = ''
        selectedNode = ''
        antigravityPath = ''
        proxyPort = 7899
        controllerPort = 19090
        customInstances = @()
    }

    return $settings
}

function Get-JsonValue {
    <# 安全读取 JSON 属性，兼容缺少字段的旧设置文件。 #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-PortFromMapping {
    <# 安全读取端口映射项中的端口号，严防 StrictMode 下标与类型异常。 #>
    param(
        [Parameter(Mandatory = $false)]
        $Mapping
    )

    if ($null -eq $Mapping) {
        return 0
    }
    if ($Mapping -is [int]) {
        return [int]$Mapping
    }
    if ($Mapping -is [hashtable]) {
        if ($Mapping.ContainsKey('port')) {
            return [int]$Mapping['port']
        }
        return 0
    }
    try {
        if ($Mapping.PSObject.Properties['port']) {
            return [int]$Mapping.port
        }
    }
    catch {
    }
    return 0
}

function Get-FirstPortFromMappings {
    <# 安全读取端口映射列表中的首个有效端口号。 #>
    param(
        [Parameter(Mandatory = $false)]
        $Mappings
    )

    if ($null -eq $Mappings) {
        return 0
    }
    if ($Mappings -is [hashtable]) {
        return (Get-PortFromMapping -Mapping $Mappings)
    }
    $arr = @($Mappings)
    if ($arr.Count -gt 0) {
        return (Get-PortFromMapping -Mapping $arr[0])
    }
    return 0
}

function Read-Settings {
    <# 从 config/settings.json 读取设置，损坏时回退到安全默认值。支持限制重试深度的防递归自愈。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [int]$RecoveryAttempt = 0
    )

    $settings = New-DefaultSettings
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $settings
    }

    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $jsonText = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        $source = $jsonText | ConvertFrom-Json
        $settings.subscriptionUrl = [string](Get-JsonValue -Object $source -Name 'subscriptionUrl' -DefaultValue '')
        $settings.selectedNode = [string](Get-JsonValue -Object $source -Name 'selectedNode' -DefaultValue '')
        $settings.antigravityPath = [string](Get-JsonValue -Object $source -Name 'antigravityPath' -DefaultValue '')

        $proxyPortText = [string](Get-JsonValue -Object $source -Name 'proxyPort' -DefaultValue 7899)
        $controllerPortText = [string](Get-JsonValue -Object $source -Name 'controllerPort' -DefaultValue 19090)
        $proxyPort = 0
        $controllerPort = 0
        if ([int]::TryParse($proxyPortText, [ref]$proxyPort) -and $proxyPort -ge 1 -and $proxyPort -le 65535) {
            $settings.proxyPort = $proxyPort
        }
        if ([int]::TryParse($controllerPortText, [ref]$controllerPort) -and $controllerPort -ge 1 -and $controllerPort -le 65535) {
            $settings.controllerPort = $controllerPort
        }

        $portMappings = @()
        $rawMappings = Get-JsonValue -Object $source -Name 'portMappings' -DefaultValue @()
        if ($null -ne $rawMappings) {
            foreach ($m in @($rawMappings)) {
                $mPort = [int](Get-JsonValue -Object $m -Name 'port' -DefaultValue 0)
                $mNode = [string](Get-JsonValue -Object $m -Name 'node' -DefaultValue '')
                if ($mPort -ge 1 -and $mPort -le 65535) {
                    $portMappings += @{
                        port = $mPort
                        node = $mNode
                    }
                }
            }
        }
        $hasPrimary = @($portMappings | Where-Object { [int]$_.port -eq [int]$settings.proxyPort }).Count -gt 0
        if (-not $hasPrimary) {
            $portMappings = @( @{ port = [int]$settings.proxyPort; node = [string]$settings.selectedNode } ) + $portMappings
        }
        $settings.portMappings = $portMappings

        $selectedPort = [int](Get-JsonValue -Object $source -Name 'selectedPort' -DefaultValue $settings.proxyPort)
        if ($selectedPort -le 0 -or @($portMappings | Where-Object { [int]$_.port -eq $selectedPort }).Count -eq 0) {
            $selectedPort = [int]$settings.proxyPort
        }
        $settings.selectedPort = $selectedPort

        $instances = @()
        $seenInstanceIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $rawInstances = Get-JsonValue -Object $source -Name 'customInstances' -DefaultValue @()
        if ($null -ne $rawInstances) {
            foreach ($item in @($rawInstances)) {
                $instId = [string](Get-JsonValue -Object $item -Name 'id' -DefaultValue '')
                if ([string]::IsNullOrWhiteSpace($instId) -or $instId -notmatch '^[a-zA-Z0-9_\-]+$') {
                    continue
                }
                # 大小写不敏感排重：Windows 文件系统不区分大小写，避免仅大小写不同的 ID 映射同一目录引发冲突
                if (-not $seenInstanceIds.Add($instId)) {
                    Write-Warning ("检测到重复或大小写冲突的实例 ID: '$instId'，已自动跳过该冲突项。")
                    continue
                }
                $instName = [string](Get-JsonValue -Object $item -Name 'name' -DefaultValue '应用代理')
                $instSubUrl = [string](Get-JsonValue -Object $item -Name 'subscriptionUrl' -DefaultValue '')
                $instCtrlPort = [int](Get-JsonValue -Object $item -Name 'controllerPort' -DefaultValue 19091)
                $instSelectedPort = [int](Get-JsonValue -Object $item -Name 'selectedPort' -DefaultValue 0)

                $portMappings = @()
                $rawMappings = Get-JsonValue -Object $item -Name 'portMappings' -DefaultValue @()
                if ($null -ne $rawMappings) {
                    foreach ($m in @($rawMappings)) {
                        $mPort = [int](Get-JsonValue -Object $m -Name 'port' -DefaultValue 0)
                        $mNode = [string](Get-JsonValue -Object $m -Name 'node' -DefaultValue '')
                        if ($mPort -ge 1 -and $mPort -le 65535) {
                            $portMappings += @{
                                port = $mPort
                                node = $mNode
                            }
                        }
                    }
                }
                if ($portMappings.Count -eq 0) {
                    $portMappings += @{
                        port = 7880
                        node = ''
                    }
                }
                if ($instSelectedPort -le 0 -or @($portMappings | Where-Object { $_.port -eq $instSelectedPort }).Count -eq 0) {
                    $instSelectedPort = Get-FirstPortFromMappings -Mappings $portMappings
                }

                $instances += @{
                    id = $instId
                    name = $instName
                    subscriptionUrl = $instSubUrl
                    controllerPort = $instCtrlPort
                    portMappings = $portMappings
                    selectedPort = $instSelectedPort
                }
            }
        }
        $settings.customInstances = $instances

        return $settings
    }
    catch {
        # 自愈探测模式下（RecoveryAttempt > 0），若文件依然损坏或无效，立即抛出异常，绝不回退默认配置伪造成功
        if ($RecoveryAttempt -gt 0) {
            throw
        }

        $corruptTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $corruptPath = $Path + '.corrupt-' + $corruptTimestamp
        try {
            Copy-Item -LiteralPath $Path -Destination $corruptPath -Force -ErrorAction SilentlyContinue
        } catch {}

        # 尝试从 .backup 文件自愈恢复，严格限制仅允许尝试 1 次，杜绝递归恢复循环
        $backupPath = $Path + '.backup'
        if ($RecoveryAttempt -eq 0 -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                # 尝试用 Read-Settings 完整解析校验 backup 文件的内容合规性（RecoveryAttempt = 1，若失败会直接 throw）
                $backupSettings = Read-Settings -Path $backupPath -RecoveryAttempt 1
                if ($null -ne $backupSettings) {
                    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                    $backupText = [System.IO.File]::ReadAllText($backupPath, $utf8NoBom)
                    $repairTmp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
                    [System.IO.File]::WriteAllText($repairTmp, $backupText, $utf8NoBom)
                    Move-Item -LiteralPath $repairTmp -Destination $Path -Force
                    Write-Warning ("主设置文件损坏，已成功验证并从备份自愈恢复，同时修复磁盘文件: $backupPath。损坏的原文件已备份至: $corruptPath")
                    return $backupSettings
                }
            } catch {
                Write-Warning ("备份文件 $backupPath 内容亦无效或损坏，放弃自愈恢复: $($_.Exception.Message)")
            }
        }

        Write-Warning ("读取设置文件失败: $($_.Exception.Message)。已将损坏文件备份至: $corruptPath，回退默认设置。")
        return (New-DefaultSettings)
    }
}

function Save-Settings {
    <# 以 UTF-8 无 BOM 安全原子保存订阅、节点、端口、Antigravity 路径和自定义应用实例。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Settings,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $customInstancesData = @()
    $savedInstanceIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Settings.ContainsKey('customInstances') -and $null -ne $Settings.customInstances) {
        foreach ($inst in @($Settings.customInstances)) {
            $idStr = [string]$inst.id
            if ([string]::IsNullOrWhiteSpace($idStr) -or $idStr -notmatch '^[a-zA-Z0-9_\-]+$' -or (-not $savedInstanceIds.Add($idStr))) {
                continue
            }
            $mappingsData = @()
            if ($inst.ContainsKey('portMappings') -and $null -ne $inst.portMappings) {
                foreach ($m in @($inst.portMappings)) {
                    $mappingsData += [ordered]@{
                        port = [int]$m.port
                        node = [string]$m.node
                    }
                }
            }
            $instName = if ($inst.ContainsKey('name') -and $null -ne $inst.name) { [string]$inst.name } else { '应用代理' }
            $instSub = if ($inst.ContainsKey('subscriptionUrl') -and $null -ne $inst.subscriptionUrl) { [string]$inst.subscriptionUrl } else { '' }
            $instCtrl = if ($inst.ContainsKey('controllerPort') -and $null -ne $inst.controllerPort) { [int]$inst.controllerPort } else { 19091 }
            $instSelPort = if ($inst.ContainsKey('selectedPort') -and $null -ne $inst.selectedPort) { [int]$inst.selectedPort } else { 0 }

            $customInstancesData += [ordered]@{
                id = [string]$inst.id
                name = $instName
                subscriptionUrl = $instSub
                controllerPort = $instCtrl
                portMappings = $mappingsData
                selectedPort = $instSelPort
            }
        }
    }

    $rootMappingsData = @()
    if ($Settings.ContainsKey('portMappings') -and $null -ne $Settings.portMappings) {
        foreach ($m in @($Settings.portMappings)) {
            $rootMappingsData += [ordered]@{
                port = [int]$m.port
                node = [string]$m.node
            }
        }
    }

    $rootProxyPort = if ($Settings.ContainsKey('proxyPort') -and $null -ne $Settings.proxyPort) { [int]$Settings.proxyPort } else { 7899 }
    $rootCtrlPort = if ($Settings.ContainsKey('controllerPort') -and $null -ne $Settings.controllerPort) { [int]$Settings.controllerPort } else { 19090 }

    $rootSelectedPort = if ($Settings.ContainsKey('selectedPort') -and [int]$Settings.selectedPort -gt 0) {
        [int]$Settings.selectedPort
    } else {
        $rootProxyPort
    }

    $data = [ordered]@{
        subscriptionUrl = if ($Settings.ContainsKey('subscriptionUrl') -and $null -ne $Settings.subscriptionUrl) { [string]$Settings.subscriptionUrl } else { '' }
        selectedNode = if ($Settings.ContainsKey('selectedNode') -and $null -ne $Settings.selectedNode) { [string]$Settings.selectedNode } else { '' }
        antigravityPath = if ($Settings.ContainsKey('antigravityPath') -and $null -ne $Settings.antigravityPath) { [string]$Settings.antigravityPath } else { '' }
        proxyPort = $rootProxyPort
        controllerPort = $rootCtrlPort
        portMappings = $rootMappingsData
        selectedPort = $rootSelectedPort
        customInstances = $customInstancesData
    }
    $jsonText = $data | ConvertTo-Json -Depth 6
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $null = Ensure-FileDirectoryExists -Path $Path

    # 原子写入流程：使用唯一 GUID 临时文件，更新 .backup 备份，再原子替换原文件
    $tmpPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $Path + '.backup'
    [System.IO.File]::WriteAllText($tmpPath, $jsonText, $utf8NoBom)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force

    return $Path
}

function Ensure-FileDirectoryExists {
    <# 确保指定文件所在的父目录存在，若不存在则递归创建。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }

    return $Path
}

function Ensure-ToolDirectories {
    <# 创建工具自己的 config、providers、runtime、runtime/instances 和 logs 目录。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    foreach ($child in @('config', 'providers', 'runtime', 'runtime\instances', 'logs')) {
        $childPath = Join-Path -Path $ToolRoot -ChildPath $child
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
            New-Item -ItemType Directory -Path $childPath -Force -ErrorAction Stop | Out-Null
        }
    }

    return $ToolRoot
}

function Ensure-InstanceDirectories {
    <# 创建指定自定义实例的专属运行时目录。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot,

        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    if ($InstanceId -notmatch '^[a-zA-Z0-9_\-]+$') {
        throw ("非法实例标识符: '$InstanceId'。实例 ID 仅允许字母、数字、下划线和连字符。")
    }

    $instancesRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $ToolRoot -ChildPath 'runtime\instances'))
    if (-not (Test-Path -LiteralPath $instancesRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $instancesRoot -Force -ErrorAction Stop | Out-Null
    }

    $instanceDir = [System.IO.Path]::GetFullPath((Join-Path -Path $instancesRoot -ChildPath $InstanceId))
    if (-not $instanceDir.StartsWith($instancesRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("非法实例路径越界: '$instanceDir'")
    }

    if (-not (Test-Path -LiteralPath $instanceDir -PathType Container)) {
        New-Item -ItemType Directory -Path $instanceDir -Force -ErrorAction Stop | Out-Null
    }

    return $instanceDir
}

function Get-ControllerSecret {
    <# 读取或创建仅保存在工具 runtime 目录中的随机控制器密钥。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $existing = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $existing = ([System.IO.File]::ReadAllText($Path, $utf8NoBom)).Trim()
            if ($existing.Length -ge 16) {
                return $existing
            }
        }
        catch {
            $existing = ''
        }
    }

    $secret = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $null = Ensure-FileDirectoryExists -Path $Path
    [System.IO.File]::WriteAllText($Path, $secret, $utf8NoBom)

    return $secret
}

function ConvertTo-YamlScalar {
    <# 将 URL 等外部文本安全转换成 YAML 双引号标量。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '')
    $escaped = $escaped.Replace("`n", '\n')

    return '"' + $escaped + '"'
}

function Get-SubscriptionHash {
    <# 生成订阅地址的不可逆摘要，用于判断是否可以复用已有 Mihomo。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionUrl
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($SubscriptionUrl)
        $digest = $sha256.ComputeHash($bytes)
        return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-ValidatedPort {
    <# 校验 GUI 输入的 TCP 端口。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    $parsed = 0
    if (-not [int]::TryParse($Text.Trim(), [ref]$parsed)) {
        throw "$FieldName 必须是 1 到 65535 之间的整数。"
    }
    if ($parsed -lt 1 -or $parsed -gt 65535) {
        throw "$FieldName 必须是 1 到 65535 之间的整数。"
    }

    return $parsed
}

function ConvertTo-ValidatedSubscriptionUrl {
    <# 校验订阅地址，只允许 HTTP 或 HTTPS，避免把任意协议写进核心配置。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $trimmed = $Text.Trim()
    $uri = $null
    if (-not [System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref]$uri)) {
        throw '订阅地址不是有效的绝对 URL。'
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw '订阅地址只支持 http 或 https。'
    }

    return $trimmed
}

function Get-MihomoCorePath {
    <# 返回工具目录内独立 Mihomo 核心的路径。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    return (Join-Path -Path $ToolRoot -ChildPath 'mihomo.exe')
}

function Install-MihomoCore {
    <# 从 Mihomo 官方 GitHub 最新发布下载 Windows amd64 核心。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    $headers = @{ 'User-Agent' = 'Antigravity-Mihomo-Proxy' }
    $pinnedTag = 'v1.19.30'
    $release = $null
    try {
        $tagUrl = 'https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/' + $pinnedTag
        $release = Invoke-RestMethod -Uri $tagUrl -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        throw ("获取固定版本 Mihomo ($pinnedTag) 发布信息失败: $($_.Exception.Message)。已禁止未经验证下载不可控版本。")
    }
    $assets = @($release.assets | Where-Object {
        $_.name -match '(?i)windows-amd64' -and $_.name -match '(?i)\.(zip|gz)$'
    })
    if ($assets.Count -eq 0) {
        throw '官方发布中没有找到 Windows amd64 Mihomo 核心。'
    }
    $asset = $assets |
        Sort-Object -Property @{ Expression = {
                if ($_.name -match '(?i)windows-amd64-compatible') {
                    return 0
                }
                if ($_.name -match '(?i)windows-amd64-v3') {
                    return 1
                }
                return 2
            }
        } |
        Select-Object -First 1
    if ($null -eq $asset) {
        throw '无法选择兼容当前 Windows amd64 的 Mihomo 下载包。'
    }

    $downloadDirectory = Join-Path -Path $ToolRoot -ChildPath 'runtime\mihomo-download'
    if (-not (Test-Path -LiteralPath $downloadDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $downloadDirectory -ErrorAction Stop | Out-Null
    }
    $archivePath = Join-Path -Path $downloadDirectory -ChildPath ([string]$asset.name)
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $archivePath -ErrorAction Stop

    $digestText = [string](Get-JsonValue -Object $asset -Name 'digest' -DefaultValue '')
    if ($digestText -match '(?i)^sha256:(?<hash>[0-9a-f]{64})$') {
        $expectedHash = $matches['hash'].ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw ("Mihomo 下载包 SHA-256 校验失败：期望 $expectedHash，实际 $actualHash。")
        }
    } else {
        throw ("官方发布未提供下载包 $($asset.name) 的有效 SHA-256 摘要，已拒绝安装未经验证的二进制。")
    }

    $corePath = Get-MihomoCorePath -ToolRoot $ToolRoot
    if ([string]$asset.name -match '(?i)\.zip$') {
        $extractDirectory = Join-Path -Path $downloadDirectory -ChildPath 'extracted'
        if (-not (Test-Path -LiteralPath $extractDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $extractDirectory -ErrorAction Stop | Out-Null
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory -Force
        $candidate = Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Name -match '(?i)^mihomo.*\.exe$' } |
            Select-Object -First 1
        if ($null -eq $candidate) {
            throw '下载包中没有找到 mihomo.exe。'
        }
        Copy-Item -LiteralPath $candidate.FullName -Destination $corePath -Force -ErrorAction Stop
    }
    else {
        $sourceStream = [System.IO.File]::OpenRead($archivePath)
        $gzipStream = [System.IO.Compression.GZipStream]::new($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
        $targetStream = [System.IO.File]::Create($corePath)
        try {
            $gzipStream.CopyTo($targetStream)
        }
        finally {
            $targetStream.Dispose()
            $gzipStream.Dispose()
            $sourceStream.Dispose()
        }
    }

    $extractedVersion = & $corePath -v 2>&1 | Select-Object -First 1
    if ($extractedVersion -notmatch '(?i)Mihomo.*v1\.19\.30') {
        throw ("安装的 Mihomo 核心版本与预期固定版本 (v1.19.30) 不一致: $extractedVersion")
    }

    return $corePath
}

function Ensure-MihomoCore {
    <# 检查独立核心，不存在或版本不符时经用户确认后从官方发布下载。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $corePath = Get-MihomoCorePath -ToolRoot $State.ToolRoot
    if (Test-Path -LiteralPath $corePath -PathType Leaf) {
        $extractedVersion = & $corePath -v 2>&1 | Select-Object -First 1
        if ($extractedVersion -match '(?i)Mihomo.*v1\.19\.30') {
            return $corePath
        }
        Write-Warning ("本地现有 Mihomo 核心不可用或版本不符合固定要求 (v1.19.30): $extractedVersion")
    }

    $choice = [System.Windows.Forms.MessageBox]::Show(
        '未发现独立 Mihomo 核心。是否从 Mihomo 官方 GitHub 发布页下载 Windows amd64 版本？',
        '需要 Mihomo 核心',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        throw '未安装独立 Mihomo 核心。'
    }

    return (Install-MihomoCore -ToolRoot $State.ToolRoot)
}

function Write-MihomoConfig {
    <# 写入工具私有的 Mihomo 配置，订阅仅作为本工具的 proxy-provider。
       支持单端口模式（Antigravity）与多端口监听模式（listeners + 独立 proxy-groups）。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionUrl,

        [Parameter(Mandatory = $false)]
        [int]$ProxyPort = 0,

        [Parameter(Mandatory = $true)]
        [int]$ControllerPort,

        [Parameter(Mandatory = $false)]
        [array]$PortMappings = @()
    )

    $urlScalar = ConvertTo-YamlScalar -Value $SubscriptionUrl
    $providerFileName = 'subscription-' + (Get-SubscriptionHash -SubscriptionUrl $SubscriptionUrl).Substring(0, 16) + '.yaml'
    $providerPath = './providers/' + $providerFileName
    $secret = [string]$State.ControllerSecret

    $effectiveMappings = @(
        if ($PortMappings -and $PortMappings.Count -gt 0) {
            $PortMappings
        } elseif ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
            $State.PortMappings
        } else {
            @()
        }
    )

    $isAntigravity = ($ProxyPort -gt 0 -or [string]$State.ConfigPath -match '(?i)runtime\\mihomo\.yaml$')
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($isAntigravity) {
        $mainPort = if ($ProxyPort -gt 0) { $ProxyPort } elseif ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) { [int]$State.ProxyPort } else { 7899 }
        $lines.Add('mixed-port: ' + $mainPort)
        $lines.Add('allow-lan: false')
        $lines.Add('bind-address: 127.0.0.1')
        $lines.Add('mode: rule')
        $lines.Add('log-level: info')
        $lines.Add('ipv6: false')
        $lines.Add('external-controller: 127.0.0.1:' + $ControllerPort)
        $lines.Add('secret: ' + (ConvertTo-YamlScalar -Value $secret))
        $lines.Add('profile:')
        $lines.Add('  store-selected: true')

        $extraPorts = @($effectiveMappings | Where-Object {
            $p = if ($_ -is [hashtable] -and $_.ContainsKey('port')) { [int]$_['port'] } else { [int]$_.port }
            $p -ne $mainPort
        })
        if ($extraPorts.Count -gt 0) {
            $lines.Add('listeners:')
            foreach ($mapping in $extraPorts) {
                $mPort = if ($mapping -is [hashtable] -and $mapping.ContainsKey('port')) { [int]$mapping['port'] } else { [int]$mapping.port }
                $lines.Add('  - name: listener-' + $mPort)
                $lines.Add('    type: mixed')
                $lines.Add('    port: ' + $mPort)
                $lines.Add('    proxy: GROUP_' + $mPort)
            }
        }

        $lines.Add('proxy-providers:')
        $lines.Add('  subscription:')
        $lines.Add('    type: http')
        $lines.Add('    url: ' + $urlScalar)
        $lines.Add('    path: ' + $providerPath)
        $lines.Add('    interval: 86400')
        $lines.Add('    exclude-filter: ' + (ConvertTo-YamlScalar -Value '(?i)(剩余流量|到期时间|下次重置|套餐|官网|公告|提示|官方群|交流群|加入群|说明|重置|通知|频道|更新|客服|维护|traffic|expire|reset)'))
        $lines.Add('    health-check:')
        $lines.Add('      enable: false')

        $lines.Add('proxy-groups:')
        $lines.Add('  - name: ANTIGRAVITY')
        $lines.Add('    type: select')
        $lines.Add('    use:')
        $lines.Add('      - subscription')
        $lines.Add('    proxies:')
        $lines.Add('      - DIRECT')

        foreach ($mapping in $extraPorts) {
            $mPort = if ($mapping -is [hashtable] -and $mapping.ContainsKey('port')) { [int]$mapping['port'] } else { [int]$mapping.port }
            $lines.Add('  - name: GROUP_' + $mPort)
            $lines.Add('    type: select')
            $lines.Add('    use:')
            $lines.Add('      - subscription')
            $lines.Add('    proxies:')
            $lines.Add('      - DIRECT')
        }

        $lines.Add('rules:')
        $lines.Add('  - MATCH,ANTIGRAVITY')
    }
    else {
        # 通用应用实例 (listeners 模式)
        $lines.Add('allow-lan: false')
        $lines.Add('bind-address: 127.0.0.1')
        $lines.Add('mode: rule')
        $lines.Add('log-level: info')
        $lines.Add('ipv6: false')
        $lines.Add('external-controller: 127.0.0.1:' + $ControllerPort)
        $lines.Add('secret: ' + (ConvertTo-YamlScalar -Value $secret))
        $lines.Add('profile:')
        $lines.Add('  store-selected: true')

        if ($effectiveMappings.Count -gt 0) {
            $lines.Add('listeners:')
            foreach ($mapping in $effectiveMappings) {
                $mPort = if ($mapping -is [hashtable] -and $mapping.ContainsKey('port')) { [int]$mapping['port'] } else { [int]$mapping.port }
                $lines.Add('  - name: listener-' + $mPort)
                $lines.Add('    type: mixed')
                $lines.Add('    port: ' + $mPort)
                $lines.Add('    proxy: GROUP_' + $mPort)
            }
        }

        $lines.Add('proxy-providers:')
        $lines.Add('  subscription:')
        $lines.Add('    type: http')
        $lines.Add('    url: ' + $urlScalar)
        $lines.Add('    path: ' + $providerPath)
        $lines.Add('    interval: 86400')
        $lines.Add('    exclude-filter: ' + (ConvertTo-YamlScalar -Value '(?i)(剩余流量|到期时间|下次重置|套餐|官网|公告|提示|官方群|交流群|加入群|说明|重置|通知|频道|更新|客服|维护|traffic|expire|reset)'))
        $lines.Add('    health-check:')
        $lines.Add('      enable: false')

        $lines.Add('proxy-groups:')
        if ($effectiveMappings.Count -gt 0) {
            foreach ($mapping in $effectiveMappings) {
                $mPort = if ($mapping -is [hashtable] -and $mapping.ContainsKey('port')) { [int]$mapping['port'] } else { [int]$mapping.port }
                $lines.Add('  - name: GROUP_' + $mPort)
                $lines.Add('    type: select')
                $lines.Add('    use:')
                $lines.Add('      - subscription')
                $lines.Add('    proxies:')
                $lines.Add('      - DIRECT')
            }
            $firstPort = Get-FirstPortFromMappings -Mappings $effectiveMappings
            $lines.Add('rules:')
            $lines.Add('  - MATCH,GROUP_' + $firstPort)
        }
        else {
            $lines.Add('  - name: DEFAULT')
            $lines.Add('    type: select')
            $lines.Add('    use:')
            $lines.Add('      - subscription')
            $lines.Add('    proxies:')
            $lines.Add('      - DIRECT')
            $lines.Add('rules:')
            $lines.Add('  - MATCH,DEFAULT')
        }
    }

    $configText = [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $null = Ensure-FileDirectoryExists -Path $State.ConfigPath
    [System.IO.File]::WriteAllText($State.ConfigPath, $configText, $utf8NoBom)

    return $State.ConfigPath
}

function Invoke-MihomoApi {
    <# 调用本工具私有 Mihomo 控制 API，强制使用 UTF-8 编码读取与写入，防止中文与国旗 Emoji 乱码。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body = $null
    )

    $url = 'http://127.0.0.1:' + $State.ControllerPort + $Path
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = $Method
    $request.Headers.Add('Authorization', 'Bearer ' + $State.ControllerSecret)
    $request.Timeout = 10000

    if ($null -ne $Body) {
        $request.ContentType = 'application/json; charset=utf-8'
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
        $request.ContentLength = $bodyBytes.Length
        $reqStream = $request.GetRequestStream()
        $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $reqStream.Dispose()
    }

    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $respStream = $response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($respStream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $respStream.Dispose()
        $response.Dispose()

        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return ($text | ConvertFrom-Json)
    }
    catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response) {
            $errStream = $ex.Response.GetResponseStream()
            $errReader = [System.IO.StreamReader]::new($errStream, [System.Text.Encoding]::UTF8)
            $errText = $errReader.ReadToEnd()
            $errReader.Dispose()
            $errStream.Dispose()
            $ex.Response.Dispose()
            throw ('Mihomo API 错误: ' + $errText)
        }
        throw
    }
}

function Wait-MihomoController {
    <# 等待独立 Mihomo 控制 API 就绪，避免 GUI 过早读取空配置。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $null = Invoke-MihomoApi -State $State -Method 'GET' -Path '/version'
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw '独立 Mihomo 控制 API 在 30 秒内没有就绪，请查看 logs。'
}

function Get-MihomoMetadataPath {
    <# 返回独立 Mihomo PID 元数据文件路径。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    if ($State.ContainsKey('MetadataPath') -and -not [string]::IsNullOrWhiteSpace($State.MetadataPath)) {
        return $State.MetadataPath
    }

    return (Join-Path -Path $State.ToolRoot -ChildPath 'runtime\mihomo-process.json')
}

function Get-ManagedMihomoProcess {
    <# 仅识别本工具记录且命令行指向本工具配置的 Mihomo 进程。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $metadataPath = Get-MihomoMetadataPath -State $State
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $metadataText = [System.IO.File]::ReadAllText($metadataPath, $utf8NoBom)
        $metadata = $metadataText | ConvertFrom-Json
        $pidText = [string](Get-JsonValue -Object $metadata -Name 'pid' -DefaultValue 0)
        $managedPid = 0
        if (-not [int]::TryParse($pidText, [ref]$managedPid) -or $managedPid -le 0) {
            return $null
        }

        $process = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -notmatch '(?i)^mihomo$') {
            return $null
        }
        $actualExecutablePath = [string](Get-JsonValue -Object $process -Name 'Path' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($actualExecutablePath)) {
            $normalizedActualPath = $actualExecutablePath.ToLowerInvariant().Replace('/', '\')
            $normalizedCorePath = (Get-MihomoCorePath -ToolRoot $State.ToolRoot).ToLowerInvariant().Replace('/', '\')
            if ($normalizedActualPath -ne $normalizedCorePath) {
                return $null
            }
        }

        $storedStartText = [string](Get-JsonValue -Object $metadata -Name 'startTimeUtc' -DefaultValue '')
        $actualStart = $process.StartTime.ToUniversalTime()
        $storedStart = [DateTime]::Parse(
            $storedStartText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $startDifference = [Single][Math]::Abs(($actualStart - $storedStart).TotalSeconds)
        if ($startDifference -gt [Single]10) {
            return $null
        }

        $cimProcess = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $managedPid) -ErrorAction SilentlyContinue
        if ($null -eq $cimProcess) {
            return $null
        }
        $commandLine = [string](Get-JsonValue -Object $cimProcess -Name 'CommandLine' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            return $null
        }
        $configPath = [string]$State.ConfigPath
        $normalizedCommandLine = $commandLine.ToLowerInvariant().Replace('/', '\')
        $normalizedConfigPath = $configPath.ToLowerInvariant().Replace('/', '\')
        if (-not $normalizedCommandLine.Contains($normalizedConfigPath)) {
            return $null
        }

        return [pscustomobject]@{
            Process = $process
            Metadata = $metadata
        }
    }
    catch {
        return $null
    }
}

function Save-MihomoMetadata {
    <# 保存本工具启动的 Mihomo PID、启动时间和配置摘要。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionHash
    )

    $actualProcess = Get-Process -Id $Process.Id -ErrorAction Stop
    $portMappingsData = @()
    if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
        $portMappingsData = $State.PortMappings
    }
    $proxyPortVal = if ($State.ContainsKey('ProxyPort')) { [int]$State.ProxyPort } else { 0 }
    $metadata = [ordered]@{
        pid = [int]$actualProcess.Id
        startTimeUtc = $actualProcess.StartTime.ToUniversalTime().ToString('o')
        configPath = [string]$State.ConfigPath
        subscriptionHash = $SubscriptionHash
        proxyPort = $proxyPortVal
        controllerPort = [int]$State.ControllerPort
        portMappings = $portMappingsData
    }
    $jsonText = $metadata | ConvertTo-Json -Depth 4
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $metaPath = (Get-MihomoMetadataPath -State $State)
    $null = Ensure-FileDirectoryExists -Path $metaPath
    [System.IO.File]::WriteAllText($metaPath, $jsonText, $utf8NoBom)

    return $metadata
}

function Remove-MihomoMetadata {
    <# 删除本工具自己的过期 PID 元数据，不触碰任何 Mihomo 进程。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $metadataPath = Get-MihomoMetadataPath -State $State
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
    }

    return $metadataPath
}

function Stop-ManagedMihomo {
    <# 只停止 PID 元数据验证通过的本工具 Mihomo，绝不按进程名批量结束。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $managed = Get-ManagedMihomoProcess -State $State
    if ($null -eq $managed) {
        $null = Remove-MihomoMetadata -State $State
        $State.Nodes = @()
        $State.ManagedProcess = $null
        return $false
    }

    Stop-Process -Id $managed.Process.Id -Force -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ($null -eq (Get-Process -Id $managed.Process.Id -ErrorAction SilentlyContinue)) {
            $null = Remove-MihomoMetadata -State $State
            $State.Nodes = @()
            $State.ManagedProcess = $null
            return $true
        }
        Start-Sleep -Milliseconds 200
    }

    throw '独立 Mihomo 进程没有在预期时间内停止。'
}

function Test-LocalPortInUse {
    <# 检查本地端口是否已被其他进程监听，可忽略指定的本工具 PID。 #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$IgnoredProcessId = 0
    )

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
        if ($IgnoredProcessId -gt 0 -and [int]$connection.OwningProcess -eq $IgnoredProcessId) {
            continue
        }
        return $true
    }

    return $false
}

function Stop-OrphanedMihomoOnPort {
    <# 仅在端口被本工具核心且属于当前配置旧进程或已废弃孤儿进程占用时回收，严防误杀其他合法运行中的实例。 #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$ToolRoot,

        [Parameter(Mandatory = $false)]
        [hashtable]$State = $null
    )

    $corePath = Get-MihomoCorePath -ToolRoot $ToolRoot
    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($conn in $connections) {
        $pidToKill = [int]$conn.OwningProcess
        if ($pidToKill -gt 0) {
            try {
                $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
                if ($null -ne $proc -and $null -ne $proc.Path) {
                    if ([string]::Equals($proc.Path, $corePath, [StringComparison]::OrdinalIgnoreCase)) {
                        # 查询该进程的启动命令行与配置路径
                        $cim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $pidToKill) -ErrorAction SilentlyContinue
                        $cmdLine = if ($null -ne $cim) { [string]$cim.CommandLine } else { '' }
                        $currentConfigPath = if ($null -ne $State -and $State.ContainsKey('ConfigPath')) { [string]$State.ConfigPath } else { '' }

                        # 若无法提取命令行，禁止盲目强杀同路径 Mihomo 进程
                        if ([string]::IsNullOrWhiteSpace($cmdLine)) {
                            throw ('端口 ' + $Port + ' 正被 Mihomo 进程 (PID ' + $pidToKill + ') 占用，但无法读取其启动命令行确认归属，安全起见已终止回收。请手动检查该进程。')
                        }

                        # 精确解析 Mihomo 命令行中的 -f <configPath> 参数
                        $extractedConfig = $null
                        if ($cmdLine -match '(?i)(?:^|\s)-f\s+["'']?([^"''\r\n]+?)["'']?(?:\s|$)') {
                            $extractedConfig = $matches[1].Trim()
                        }
                        if ([string]::IsNullOrWhiteSpace($extractedConfig)) {
                            throw ('端口 ' + $Port + ' 正被 Mihomo 进程 (PID ' + $pidToKill + ') 占用，但其命令行中未找到明确的 -f 配置文件参数，安全起见已跳过回收。')
                        }

                        $extractedConfigNorm = $null
                        try {
                            $extractedConfigNorm = [System.IO.Path]::GetFullPath($extractedConfig)
                        } catch {
                            throw ('端口 ' + $Port + ' 正被核心 (PID ' + $pidToKill + ') 占用，其配置路径非法: ' + $extractedConfig)
                        }

                        # 检查是否属于 settings 中其他已配置的活跃实例
                        $isOtherActiveInstance = $false
                        $otherInstanceName = ''
                        if ($null -ne $State -and $State.ContainsKey('Settings') -and $null -ne $State.Settings) {
                            $settingsObj = $State.Settings
                            $agConfigPathNorm = [System.IO.Path]::GetFullPath((Join-Path -Path $ToolRoot -ChildPath 'runtime\mihomo.yaml'))
                            $currentConfigNorm = if (-not [string]::IsNullOrWhiteSpace($currentConfigPath)) { [System.IO.Path]::GetFullPath($currentConfigPath) } else { '' }
                            $isCurrentAg = [string]::Equals($currentConfigNorm, $agConfigPathNorm, [StringComparison]::OrdinalIgnoreCase)

                            if (-not $isCurrentAg -and [string]::Equals($extractedConfigNorm, $agConfigPathNorm, [StringComparison]::OrdinalIgnoreCase)) {
                                $isOtherActiveInstance = $true
                                $otherInstanceName = 'Antigravity 专用'
                            }

                            if (-not $isOtherActiveInstance -and $settingsObj.ContainsKey('customInstances') -and $null -ne $settingsObj.customInstances) {
                                foreach ($ci in @($settingsObj.customInstances)) {
                                    $ciId = [string]$ci.id
                                    if ([string]::IsNullOrWhiteSpace($ciId)) { continue }
                                    $ciConfigPathNorm = [System.IO.Path]::GetFullPath((Join-Path -Path $ToolRoot -ChildPath ('runtime\instances\' + $ciId + '\mihomo.yaml')))
                                    if (-not [string]::Equals($ciConfigPathNorm, $currentConfigNorm, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($extractedConfigNorm, $ciConfigPathNorm, [StringComparison]::OrdinalIgnoreCase)) {
                                        $isOtherActiveInstance = $true
                                        $otherInstanceName = [string]$ci.name
                                        break
                                    }
                                }
                            }
                        }

                        if ($isOtherActiveInstance) {
                            throw ('端口 ' + $Port + ' 正被合法运行的【' + $otherInstanceName + '】核心占用，请更换端口避免冲突。')
                        }

                        # 严格核对配置归属：要么是当前实例的历史残留，要么是位于本项目 runtime/ 目录下的孤儿配置
                        $currentConfigNorm = if (-not [string]::IsNullOrWhiteSpace($currentConfigPath)) { [System.IO.Path]::GetFullPath($currentConfigPath) } else { '' }
                        $isCurrentInstance = (-not [string]::IsNullOrWhiteSpace($currentConfigNorm) -and [string]::Equals($extractedConfigNorm, $currentConfigNorm, [StringComparison]::OrdinalIgnoreCase))
                        $isKnownRuntimeOrphan = $false
                        if (-not $isCurrentInstance) {
                            $runtimeRootNorm = [System.IO.Path]::GetFullPath((Join-Path -Path $ToolRoot -ChildPath 'runtime'))
                            $runtimePrefix = $runtimeRootNorm.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                            if ($extractedConfigNorm.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -and $extractedConfigNorm.EndsWith('.yaml', [StringComparison]::OrdinalIgnoreCase)) {
                                $isKnownRuntimeOrphan = $true
                            } else {
                                throw ('端口 ' + $Port + ' 正被非本项目 runtime 管理的外部 Mihomo 核心 (PID ' + $pidToKill + ') 占用 (配置: ' + $extractedConfigNorm + ')，安全起见已跳过回收。请手动排查或更换端口。')
                            }
                        }

                        # 仅在确认是当前实例历史残留或已废弃的孤儿进程时，才执行安全回收
                        Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
                        for ($i = 0; $i -lt 15; $i++) {
                            Start-Sleep -Milliseconds 200
                            if (-not (Test-LocalPortInUse -Port $Port)) {
                                break
                            }
                        }
                    }
                }
            }
            catch {
                if ($_.Exception.Message -match '正被') {
                    throw
                }
            }
        }
    }
}

function Ensure-MihomoPortsAvailable {
    <# 确保专用代理端口和控制端口不会覆盖其他本地服务。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $portsToCheck = @()
    if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
        foreach ($mapping in $State.PortMappings) {
            $portsToCheck += [int]$mapping.port
        }
    } elseif ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) {
        $portsToCheck += [int]$State.ProxyPort
    }

    if ($portsToCheck.Count -eq 0) {
        throw '未配置任何代理监听端口。'
    }

    $uniquePorts = @($portsToCheck | Select-Object -Unique)
    if ($uniquePorts.Count -ne $portsToCheck.Count) {
        throw '配置中存在重复的代理监听端口。'
    }

    foreach ($port in $portsToCheck) {
        if ($port -eq $State.ControllerPort) {
            throw ('代理端口 ' + $port + ' 与控制端口不能相同。')
        }
        if (Test-LocalPortInUse -Port $port) {
            Stop-OrphanedMihomoOnPort -Port $port -ToolRoot $State.ToolRoot -State $State
            if (Test-LocalPortInUse -Port $port) {
                throw ('代理端口 ' + $port + ' 已被其他进程占用。')
            }
        }
    }

    if (Test-LocalPortInUse -Port $State.ControllerPort) {
        Stop-OrphanedMihomoOnPort -Port $State.ControllerPort -ToolRoot $State.ToolRoot -State $State
        if (Test-LocalPortInUse -Port $State.ControllerPort) {
            throw ('控制端口 ' + $State.ControllerPort + ' 已被其他进程占用。')
        }
    }

    return $true
}

function ConvertTo-ProcessArgument {
    <# 为 Start-Process 生成可处理带空格路径的双引号参数。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ('"' + $Value.Replace('"', '\"') + '"')
}

function Start-MihomoProcess {
    <# 清除父进程代理环境后启动独立 Mihomo，避免它继承现有 Clash 代理。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$CorePath
    )

    $proxyEnvironmentNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')
    $previousValues = @{}
    foreach ($name in $proxyEnvironmentNames) {
        $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    try {
        $arguments = @(
            '-d'
            (ConvertTo-ProcessArgument -Value $State.ToolRoot)
            '-f'
            (ConvertTo-ProcessArgument -Value $State.ConfigPath)
        )
        $stdoutPath = if ($State.ContainsKey('StdoutPath') -and -not [string]::IsNullOrWhiteSpace($State.StdoutPath)) {
            $State.StdoutPath
        } else {
            Join-Path -Path $State.ToolRoot -ChildPath 'logs\mihomo.stdout.log'
        }
        $stderrPath = if ($State.ContainsKey('StderrPath') -and -not [string]::IsNullOrWhiteSpace($State.StderrPath)) {
            $State.StderrPath
        } else {
            Join-Path -Path $State.ToolRoot -ChildPath 'logs\mihomo.stderr.log'
        }
        $process = Start-Process -FilePath $CorePath -ArgumentList $arguments -WorkingDirectory $State.ToolRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -ErrorAction Stop
    }
    finally {
        foreach ($name in $proxyEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
        }
    }

    return $process
}

function Test-MihomoProxyListener {
    <#
    检查独立 Mihomo 的代理端口是否还能接受新的本机 TCP 连接。
    控制 API 可响应并不代表 mixed-port/listeners 未卡死；Codex，2026-09-04。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [int]$Port = 0,

        [int]$TimeoutMilliseconds = 1500
    )

    $portsToCheck = @()
    if ($Port -gt 0) {
        $portsToCheck += $Port
    } elseif ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
        foreach ($m in $State.PortMappings) {
            $portsToCheck += [int]$m.port
        }
    } elseif ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) {
        $portsToCheck += [int]$State.ProxyPort
    }

    if ($portsToCheck.Count -eq 0) {
        return $false
    }

    foreach ($targetPort in $portsToCheck) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connectTask = $client.ConnectAsync('127.0.0.1', $targetPort)
            if (-not $connectTask.Wait($TimeoutMilliseconds)) {
                return $false
            }
            if (-not $client.Connected) {
                return $false
            }
        }
        catch {
            return $false
        }
        finally {
            $client.Dispose()
        }
    }

    return $true
}

function Start-OrReuseMihomo {
    <# 配置未变化时复用本工具 Mihomo，变化时只重启本工具记录的进程。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionUrl
    )

    $corePath = Ensure-MihomoCore -State $State
    $subscriptionHash = Get-SubscriptionHash -SubscriptionUrl $SubscriptionUrl
    $managed = Get-ManagedMihomoProcess -State $State
    if ($null -ne $managed) {
        $metadata = $managed.Metadata
        $sameHash = [string](Get-JsonValue -Object $metadata -Name 'subscriptionHash' -DefaultValue '') -eq $subscriptionHash
        $sameControllerPort = [int](Get-JsonValue -Object $metadata -Name 'controllerPort' -DefaultValue 0) -eq [int]$State.ControllerPort
        $sameConfig = $false
        if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
            $savedMappings = @(Get-JsonValue -Object $metadata -Name 'portMappings' -DefaultValue @())
            $savedPorts = @($savedMappings | ForEach-Object { [string](Get-JsonValue -Object $_ -Name 'port' -DefaultValue 0) }) -join ','
            $currentPorts = @($State.PortMappings | ForEach-Object { [string]$_.port }) -join ','
            $sameConfig = ($savedPorts -eq $currentPorts)
        } else {
            $sameProxyPort = [int](Get-JsonValue -Object $metadata -Name 'proxyPort' -DefaultValue 0) -eq [int]$State.ProxyPort
            $sameConfig = $sameProxyPort
        }

        if ($sameHash -and $sameConfig -and $sameControllerPort) {
            $State.ManagedProcess = $managed.Process
            try {
                $null = Wait-MihomoController -State $State
                if (Test-MihomoProxyListener -State $State) {
                    return $managed.Process
                }
                $State.LastMihomoHealthError = '独立 Mihomo 控制端口可用，但代理端口无法接受本机连接。'
            }
            catch {
                $State.LastMihomoHealthError = $_.Exception.Message
            }
            $null = Stop-ManagedMihomo -State $State
        }
        else {
            $null = Stop-ManagedMihomo -State $State
        }
    }

    $null = Ensure-MihomoPortsAvailable -State $State
    $process = Start-MihomoProcess -State $State -CorePath $corePath
    $State.ManagedProcess = $process
    $null = Save-MihomoMetadata -State $State -Process $process -SubscriptionHash $subscriptionHash
    $null = Wait-MihomoController -State $State
    if (-not (Test-MihomoProxyListener -State $State)) {
        $State.LastMihomoHealthError = '独立 Mihomo 已启动，但代理端口无法接受本机连接。请更换端口后重试。'
        $null = Stop-ManagedMihomo -State $State
        throw $State.LastMihomoHealthError
    }

    return $process
}

function Update-MihomoProvider {
    <# 请求独立 Mihomo 立即刷新订阅，失败时交给后续节点等待逻辑重试。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    try {
        $null = Invoke-MihomoApi -State $State -Method 'PUT' -Path '/providers/proxies/subscription' -Body '{}'
        return $true
    }
    catch {
        $State.LastProviderError = $_.Exception.Message
        return $false
    }
}

function Test-SelectableNode {
    <# 判断 API 返回项是否是用户可以手动选择的真实代理节点。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Type
    )

    $groupTypes = @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Smart', 'Compatible', 'Chain', 'PassRule', 'RejectDrop')
    $reservedNames = @('DIRECT', 'REJECT', 'PASS', 'GLOBAL', 'ANTIGRAVITY')
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in $reservedNames) {
        return $false
    }
    if ($Type -in $groupTypes -or $Type -match '(?i)^(Direct|Reject|Pass|Dns)$') {
        return $false
    }

    $metadataPattern = '(?i)(剩余流量|到期时间|下次重置|套餐|官网|公告|提示|官方群|交流群|加入群|说明|重置|通知|频道|更新|客服|维护|traffic|expire|reset)'
    if ($Name -match $metadataPattern) {
        return $false
    }

    return $true
}

function Get-MihomoNodes {
    <# 优先从 subscription provider 读取真实代理节点，再兼容读取全局代理列表。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $nodes = @()
    try {
        $providerResponse = Invoke-MihomoApi -State $State -Method 'GET' -Path '/providers/proxies/subscription'
        $providerProperty = $providerResponse.PSObject.Properties['proxies']
        if ($null -ne $providerProperty) {
            foreach ($proxy in @($providerProperty.Value)) {
                $name = [string](Get-JsonValue -Object $proxy -Name 'name' -DefaultValue '')
                $type = [string](Get-JsonValue -Object $proxy -Name 'type' -DefaultValue '')
                if (-not (Test-SelectableNode -Name $name -Type $type)) {
                    continue
                }
                $nodes += [pscustomobject]@{
                    Name = $name
                    Type = $type
                    Delay = $null
                    DelayText = '未测试'
                    Status = '未测试'
                    AiStatus = '未测试'
                    Error = ''
                }
            }
        }
    }
    catch {
    }

    if ($nodes.Count -eq 0) {
        $response = Invoke-MihomoApi -State $State -Method 'GET' -Path '/proxies'
        $proxiesProperty = $response.PSObject.Properties['proxies']
        if ($null -eq $proxiesProperty) {
            throw 'Mihomo API 返回中没有 proxies。'
        }

        foreach ($property in $proxiesProperty.Value.PSObject.Properties) {
            $name = [string]$property.Name
            $proxy = $property.Value
            $type = [string](Get-JsonValue -Object $proxy -Name 'type' -DefaultValue '')
            if (-not (Test-SelectableNode -Name $name -Type $type)) {
                continue
            }
            $nodes += [pscustomobject]@{
                Name = $name
                Type = $type
                Delay = $null
                DelayText = '未测试'
                Status = '未测试'
                AiStatus = '未测试'
                Error = ''
            }
        }
    }

    return @($nodes | Sort-Object -Property Name -Unique)
}

function Wait-MihomoNodes {
    <# 等待订阅 provider 完成下载并返回至少一个可选择节点。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [int]$Attempts = 40
    )

    $lastError = ''
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $nodes = @(Get-MihomoNodes -State $State)
            if ($nodes.Count -gt 0) {
                return $nodes
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 1000
    }

    $State.LastNodeLoadError = $lastError
    throw '订阅没有加载出可选择节点，请检查订阅地址和 logs。'
}

function Test-MihomoNode {
    <# 通过指定策略组（默认 ANTIGRAVITY）测试 provider 节点，并在结束后恢复原选择。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$NodeName,

        [string]$GroupName = ''
    )

    $isCustomInstance = ($State.ContainsKey('Id') -and -not [string]::IsNullOrWhiteSpace([string]$State.Id))
    $targetGroup = if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        $GroupName
    } elseif ($isCustomInstance) {
        if ($State.ContainsKey('SelectedPort') -and [int]$State.SelectedPort -gt 0) {
            'GROUP_' + [int]$State.SelectedPort
        } elseif ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
            'GROUP_' + (Get-FirstPortFromMappings -Mappings $State.PortMappings)
        } else {
            'DEFAULT'
        }
    } else {
        # Antigravity 专用模块 (Tab 0)：核心主选择组为 ANTIGRAVITY
        'ANTIGRAVITY'
    }

    $encodedUrl = [System.Uri]::EscapeDataString('https://www.gstatic.com/generate_204')
    $encodedGroup = [System.Uri]::EscapeDataString($targetGroup)
    $previousSelection = ''
    $selectionChanged = $false
    $result = $null
    try {
        $group = $null
        try {
            $group = Invoke-MihomoApi -State $State -Method 'GET' -Path ('/proxies/' + $encodedGroup)
        }
        catch {
            # 容错：如果指定策略组不存在，自动查找可用的 Selector 组
            $allProxies = Invoke-MihomoApi -State $State -Method 'GET' -Path '/proxies'
            if ($null -ne $allProxies -and $null -ne $allProxies.proxies) {
                $availableGroups = @($allProxies.proxies.PSObject.Properties | Where-Object { $_.Value.type -eq 'Selector' } | ForEach-Object { $_.Name })
                if ($availableGroups.Count -gt 0) {
                    if ($availableGroups -contains 'ANTIGRAVITY') {
                        $targetGroup = 'ANTIGRAVITY'
                    } else {
                        $targetGroup = $availableGroups[0]
                    }
                    $encodedGroup = [System.Uri]::EscapeDataString($targetGroup)
                    $group = Invoke-MihomoApi -State $State -Method 'GET' -Path ('/proxies/' + $encodedGroup)
                }
            }
            if ($null -eq $group) {
                throw
            }
        }
        $previousSelection = [string](Get-JsonValue -Object $group -Name 'now' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($previousSelection)) {
            throw ($targetGroup + ' 策略组没有当前选择，无法测试节点。')
        }
        if ($previousSelection -ne $NodeName) {
            $null = Set-MihomoSelection -State $State -NodeName $NodeName -GroupName $targetGroup
            $selectionChanged = $true
        }

        $apiPath = '/proxies/' + $encodedGroup + '/delay?url=' + $encodedUrl + '&timeout=5000'
        $response = Invoke-MihomoApi -State $State -Method 'GET' -Path $apiPath
        $delayValue = [Single](Get-JsonValue -Object $response -Name 'delay' -DefaultValue 0)
        $result = [pscustomobject]@{
            Name = $NodeName
            Delay = $delayValue
            DelayText = ('{0:0} ms' -f $delayValue)
            Status = '可用'
            Error = ''
        }
    }
    catch {
        $result = [pscustomobject]@{
            Name = $NodeName
            Delay = $null
            DelayText = 'Timeout'
            Status = '不可用'
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($selectionChanged -and -not [string]::IsNullOrWhiteSpace($previousSelection)) {
            try {
                $null = Set-MihomoSelection -State $State -NodeName $previousSelection -GroupName $targetGroup
            }
            catch {
            }
        }
    }

    return $result
}

function Test-MihomoAiPreflight {
    <# 针对所选节点执行端到端 Google Gemini API 深度业务探活，检测区域限制与连通性。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$NodeName,

        [int]$TimeoutSeconds = 5
    )

    $previousSelection = ''
    $selectionChanged = $false
    $result = $null

    try {
        $group = Invoke-MihomoApi -State $State -Method 'GET' -Path '/proxies/ANTIGRAVITY'
        $previousSelection = [string](Get-JsonValue -Object $group -Name 'now' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($previousSelection)) {
            throw 'ANTIGRAVITY 策略组没有当前选择，无法测试节点。'
        }
        if ($previousSelection -ne $NodeName) {
            $null = Set-MihomoSelection -State $State -NodeName $NodeName
            $selectionChanged = $true
            Start-Sleep -Milliseconds 200
        }

        Add-Type -AssemblyName System.Net.Http
        $proxyUrl = 'http://127.0.0.1:' + [int]$State.ProxyPort
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.Proxy = [System.Net.WebProxy]::new($proxyUrl)
        $handler.UseProxy = $true
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $targetUrl = 'https://generativelanguage.googleapis.com/v1beta/models'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = $client.GetAsync($targetUrl).Result
            $sw.Stop()
            $statusCode = [int]$response.StatusCode
            $body = $response.Content.ReadAsStringAsync().Result

            if ($body -match 'User location is not supported') {
                $result = [pscustomobject]@{
                    Name = $NodeName
                    AiStatus = '区域受限 (GeoBlocked)'
                    AiDetail = 'Google 提示地区不支持 Gemini'
                    Success = $false
                    ElapsedMs = $sw.ElapsedMilliseconds
                }
            }
            elseif ($body -match 'PERMISSION_DENIED' -or $body -match 'API Key' -or $statusCode -eq 403 -or $statusCode -eq 400) {
                $result = [pscustomobject]@{
                    Name = $NodeName
                    AiStatus = ('Gemini可用 ({0:0}ms)' -f $sw.ElapsedMilliseconds)
                    AiDetail = '认证层正常响应，支持Gemini API'
                    Success = $true
                    ElapsedMs = $sw.ElapsedMilliseconds
                }
            }
            elseif ($statusCode -eq 200) {
                $result = [pscustomobject]@{
                    Name = $NodeName
                    AiStatus = ('Gemini可用 ({0:0}ms)' -f $sw.ElapsedMilliseconds)
                    AiDetail = '200 OK'
                    Success = $true
                    ElapsedMs = $sw.ElapsedMilliseconds
                }
            }
            else {
                $result = [pscustomobject]@{
                    Name = $NodeName
                    AiStatus = ('响应异常 (' + $statusCode + ')')
                    AiDetail = $body.Substring(0, [Math]::Min(80, $body.Length))
                    Success = $false
                    ElapsedMs = $sw.ElapsedMilliseconds
                }
            }
        }
        catch {
            $sw.Stop()
            $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            $statusText = if ($msg -match 'timed? out' -or $msg -match 'canceled') { '连接超时' } else { '不可用' }
            $result = [pscustomobject]@{
                Name = $NodeName
                AiStatus = $statusText
                AiDetail = $msg
                Success = $false
                ElapsedMs = $sw.ElapsedMilliseconds
            }
        }
        finally {
            $client.Dispose()
            $handler.Dispose()
        }
    }
    catch {
        $result = [pscustomobject]@{
            Name = $NodeName
            AiStatus = '测试失败'
            AiDetail = $_.Exception.Message
            Success = $false
            ElapsedMs = 0
        }
    }
    finally {
        if ($selectionChanged -and -not [string]::IsNullOrWhiteSpace($previousSelection)) {
            try {
                $null = Set-MihomoSelection -State $State -NodeName $previousSelection
            }
            catch {
            }
        }
    }

    return $result
}

function Set-MihomoSelection {
    <# 通过 Mihomo API 把指定的策略组切换到用户选中的节点。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$NodeName,

        [string]$GroupName = 'ANTIGRAVITY'
    )

    $targetGroup = if (-not [string]::IsNullOrWhiteSpace($GroupName)) { $GroupName } else { 'ANTIGRAVITY' }
    $encodedGroup = [System.Uri]::EscapeDataString($targetGroup)
    $body = @{ name = $NodeName } | ConvertTo-Json -Compress
    $null = Invoke-MihomoApi -State $State -Method 'PUT' -Path ('/proxies/' + $encodedGroup) -Body $body
    return $true
}

function Resolve-AntigravityPath {
    <# 优先显式路径与环境目录定位 Antigravity，找不到时供 GUI 浏览选择；不固化个人路径。Codex，2026-09-30。 #>
    param(
        [string]$RequestedPath,

        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates += $RequestedPath
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\Antigravity IDE.exe'
        $candidates += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity\Antigravity.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path -Path $env:ProgramFiles -ChildPath 'Antigravity IDE\Antigravity IDE.exe'
        $candidates += Join-Path -Path $env:ProgramFiles -ChildPath 'Antigravity\Antigravity.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Antigravity IDE\Antigravity IDE.exe'
        $candidates += Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Antigravity\Antigravity.exe'
    }
    $candidates += Join-Path -Path $ToolRoot -ChildPath 'Antigravity.exe'

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
        }
    }

    return ''
}

function Assert-AntigravityNotRunning {
    <# 防止新启动参数落到第二个壳进程，而实际 IDE 或语言服务继续复用旧实例。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdePath
    )

    $resolvedPath = (Get-Item -LiteralPath $IdePath -ErrorAction Stop).FullName
    $mainProcessNames = @('Antigravity IDE.exe', 'Antigravity.exe')
    $existing = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        if ([int]$_.ProcessId -eq [int]$PID) {
            return $false
        }
        if ([string]::IsNullOrWhiteSpace([string]$_.ExecutablePath)) {
            return $false
        }
        $isMainProcess = $mainProcessNames -contains ([string]$_.Name)
        $isLanguageServer = ([string]$_.Name -match '(?i)^language_server.*\.exe$') -and ([string]$_.ExecutablePath -match '(?i)antigravity')
        if (-not ($isMainProcess -or $isLanguageServer)) {
            return $false
        }
        return $isMainProcess -or $isLanguageServer
    })
    if ($existing.Count -gt 0) {
        throw ('检测到已有 Antigravity 或 language_server 实例正在运行，请先完全退出旧实例后再启动专用代理。')
    }
    return
}

function Start-AntigravityWithProxy {
    <# 只给本次启动的 Antigravity、语言服务和扩展子进程注入代理，不写系统环境变量。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdePath,

        [Parameter(Mandatory = $true)]
        [int]$ProxyPort
    )

    $proxyUrl = 'http://127.0.0.1:' + $ProxyPort
    $socksUrl = 'socks5://127.0.0.1:' + $ProxyPort
    Assert-AntigravityNotRunning -IdePath $IdePath
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
        # 防止从 Codex/VS Code 启动时复用外部 IPC，确保语言服务由本次 IDE 进程树创建并继承代理。
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

    return $process
}

function Set-UiStatus {
    <# 更新 GUI 状态栏颜色和文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [bool]$IsError = $false
    )

    $Label.Text = $Message
    if ($IsError) {
        $Label.ForeColor = [System.Drawing.Color]::Firebrick
    }
    else {
        $Label.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    return
}

function Show-UiError {
    <# 用消息框显示用户可操作的错误信息。 #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Form,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Form,
        $Message,
        'Antigravity 专用代理',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    return
}

function Test-MihomoPortActive {
    <# 检测指定代理端口是否真实处于运行与监听状态（且由本项目管理的 Mihomo 进程监听）。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if ($Port -le 0) {
        return $false
    }

    $managed = Get-ManagedMihomoProcess -State $State
    if ($null -eq $managed) {
        return $false
    }

    $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($conn in $conns) {
        if ([int]$conn.OwningProcess -eq [int]$managed.Process.Id) {
            return $true
        }
    }

    return $false
}

function Refresh-NodeList {
    <# 把 Mihomo 节点对象刷新到 GUI 列表，并恢复仍然存在的上次选择与绑定的端口（工作中显示绿色高亮）。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ListView]$ListView,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$CurrentLabel,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Nodes = @()
    )

    $targetNodes = if ($null -ne $Nodes -and $Nodes.Count -gt 0) {
        $Nodes
    } elseif ($State.ContainsKey('Nodes') -and $null -ne $State.Nodes) {
        @($State.Nodes)
    } else {
        @()
    }

    $State.Refreshing = $true
    try {
        $ListView.Items.Clear()

        # 预先检测各端口的实时工作状态
        $portStatusCache = @{}
        $mainPort = if ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) { [int]$State.ProxyPort } else { 7899 }
        if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
            foreach ($m in $State.PortMappings) {
                $p = Get-PortFromMapping -Mapping $m
                if ($p -gt 0 -and -not $portStatusCache.ContainsKey($p)) {
                    $portStatusCache[$p] = (Test-MihomoPortActive -State $State -Port $p)
                }
            }
        } else {
            $portStatusCache[$mainPort] = (Test-MihomoPortActive -State $State -Port $mainPort)
        }

        # 建立 节点 -> 绑定端口信息的映射
        $nodeToPortInfos = @{}
        if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
            foreach ($m in $State.PortMappings) {
                $nodeName = [string]$m.node
                $p = Get-PortFromMapping -Mapping $m
                if (-not [string]::IsNullOrWhiteSpace($nodeName) -and $p -gt 0) {
                    if (-not $nodeToPortInfos.ContainsKey($nodeName)) {
                        $nodeToPortInfos[$nodeName] = @()
                    }
                    $isWorking = if ($portStatusCache.ContainsKey($p)) { [bool]$portStatusCache[$p] } else { $false }
                    $nodeToPortInfos[$nodeName] += @{
                        Port = $p
                        IsMain = ($p -eq $mainPort)
                        IsWorking = $isWorking
                    }
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$State.SelectedNode)) {
            $isWorking = if ($portStatusCache.ContainsKey($mainPort)) { [bool]$portStatusCache[$mainPort] } else { $false }
            $nodeToPortInfos[[string]$State.SelectedNode] = @(@{
                Port = $mainPort
                IsMain = $true
                IsWorking = $isWorking
            })
        }

        foreach ($node in $targetNodes) {
            $item = New-Object System.Windows.Forms.ListViewItem
            $item.UseItemStyleForSubItems = $false
            $item.Text = [string]$node.Name

            $portSubItem = New-Object System.Windows.Forms.ListViewItem+ListViewSubItem
            if ($nodeToPortInfos.ContainsKey([string]$node.Name)) {
                $portInfos = @($nodeToPortInfos[[string]$node.Name])
                $hasWorking = @($portInfos | Where-Object { $_.IsWorking }).Count -gt 0

                $labels = @()
                foreach ($pi in $portInfos) {
                    $pDesc = if ($pi.IsMain) { "$($pi.Port)(主)" } else { "$($pi.Port)" }
                    if ($pi.IsWorking) {
                        $labels += "● $pDesc (工作中)"
                    } else {
                        $labels += "○ $pDesc (未运行)"
                    }
                }
                $portSubItem.Text = ($labels -join ', ')
                if ($hasWorking) {
                    $portSubItem.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
                    $portSubItem.BackColor = [System.Drawing.Color]::FromArgb(236, 253, 236)
                    $portSubItem.Font = New-Object System.Drawing.Font($ListView.Font.FontFamily, $ListView.Font.Size, [System.Drawing.FontStyle]::Bold)
                } else {
                    $portSubItem.ForeColor = [System.Drawing.Color]::DimGray
                    $portSubItem.Font = New-Object System.Drawing.Font($ListView.Font.FontFamily, $ListView.Font.Size, [System.Drawing.FontStyle]::Regular)
                }
            } else {
                $portSubItem.Text = ''
            }
            $null = $item.SubItems.Add($portSubItem)

            $null = $item.SubItems.Add([string]$node.DelayText)
            $null = $item.SubItems.Add([string]$node.Status)
            $aiStatus = if ($node.PSObject.Properties['AiStatus']) { [string]$node.AiStatus } else { '未测试' }
            $null = $item.SubItems.Add($aiStatus)
            $item.Tag = [string]$node.Name
            $null = $ListView.Items.Add($item)
            if ([string]$node.Name -eq [string]$State.SelectedNode) {
                $item.Selected = $true
            }
        }
    }
    finally {
        $State.Refreshing = $false
    }

    $selectedItem = @($targetNodes | Where-Object { [string]$_.Name -eq [string]$State.SelectedNode })
    if ($selectedItem.Count -gt 0) {
        $CurrentLabel.Text = '当前选择：' + $State.SelectedNode
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$State.SelectedNode)) {
        $CurrentLabel.Text = '当前选择：' + $State.SelectedNode + '（本次订阅未找到）'
    }
    else {
        $CurrentLabel.Text = '当前选择：未选择'
    }

    return
}

function Load-SubscriptionIntoUi {
    <# 加载订阅、启动或复用独立 Mihomo，并把节点显示到 GUI。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [hashtable]$Controls
    )

    $subscriptionUrl = ConvertTo-ValidatedSubscriptionUrl -Text $Controls.SubscriptionBox.Text
    $proxyPort = ConvertTo-ValidatedPort -Text $Controls.ProxyPortBox.Text -FieldName 'Antigravity 代理端口'
    $controllerPort = ConvertTo-ValidatedPort -Text $Controls.ControllerPortBox.Text -FieldName 'Mihomo 控制端口'
    $previousSelection = [string]$State.SelectedNode
    if ([string]::IsNullOrWhiteSpace($previousSelection)) {
        $previousSelection = [string]$State.Settings.selectedNode
    }

    $State.SubscriptionUrl = $subscriptionUrl
    $State.ProxyPort = $proxyPort
    $State.ControllerPort = $controllerPort
    $State.Settings.proxyPort = $proxyPort
    $State.Settings.controllerPort = $controllerPort
    $State.ConfigPath = Join-Path -Path $State.ToolRoot -ChildPath 'runtime\mihomo.yaml'
    $null = Write-MihomoConfig -State $State -SubscriptionUrl $subscriptionUrl -ProxyPort $proxyPort -ControllerPort $controllerPort
    $null = Start-OrReuseMihomo -State $State -SubscriptionUrl $subscriptionUrl
    $null = Update-MihomoProvider -State $State
    $nodes = @(Wait-MihomoNodes -State $State)

    $State.Settings.subscriptionUrl = $subscriptionUrl
    $State.Nodes = $nodes
    $State.SelectedNode = $previousSelection
    $null = Save-Settings -Settings $State.Settings -Path $State.SettingsPath
    Refresh-NodeList -State $State -ListView $Controls.NodeList -CurrentLabel $Controls.CurrentLabel -Nodes $nodes

    return $nodes
}

function Get-AntigravityShortcutRecords {
    <# 扫描桌面和开始菜单中的 Antigravity 快捷方式，供保存按钮统一改写。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    $roots = @(
        [Environment]::GetFolderPath('Desktop')
        (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs')
        (Join-Path -Path $env:ProgramData -ChildPath 'Microsoft\Windows\Start Menu\Programs')
    )
    $records = @()
    foreach ($root in ($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        $shortcuts = @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($file in $shortcuts) {
            try {
                $shortcut = New-Object -ComObject WScript.Shell
                $shortcut = $shortcut.CreateShortcut($file.FullName)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $targetPath = [string]$shortcut.TargetPath
                $arguments = [string]$shortcut.Arguments
                $isNamed = $baseName -in @('Antigravity', 'Antigravity IDE')
                $isLauncher = $arguments -match '(?i)(launch-antigravity|launch-clash-antigravity|launch-saved-antigravity)'
                $isExecutable = $targetPath -match '(?i)\\Antigravity(?: IDE)?\.exe$'
                if ($isNamed -or $isLauncher -or $isExecutable) {
                    $launchTarget = if ($baseName -match '(?i)IDE' -or $targetPath -match '(?i)Antigravity IDE\.exe$' -or $arguments -match '(?i)launch-antigravity-ide') { 'ide' } else { 'v2' }
                    $records += [pscustomobject]@{
                        Path = $file.FullName
                        LaunchTarget = $launchTarget
                    }
                }
            }
            catch {
                Write-Verbose ('跳过无法读取的快捷方式 ' + $file.FullName + '：' + $_.Exception.Message)
            }
        }
    }

    return @($records | Sort-Object -Property Path -Unique)
}

function Set-AntigravityShortcutToDedicated {
    <# 将单个快捷方式改为通过保存节点的独立 Mihomo 启动。 #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,

        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    $shortcut = New-Object -ComObject WScript.Shell
    $shortcut = $shortcut.CreateShortcut([string]$Record.Path)
    $powershellPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        $powershellPath = (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction Stop).Source
    }
    $launcherPath = Join-Path -Path $ToolRoot -ChildPath 'launch-saved-antigravity.ps1'
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $launcherPath + '" -Target ' + [string]$Record.LaunchTarget
    $shortcut.WorkingDirectory = $ToolRoot
    $shortcut.Description = 'Antigravity 通过保存的独立 Mihomo 端口启动'
    $shortcut.Save()
    return
}

function Set-AgyWrapperToDedicated {
    <# 将 agy 包装器改为读取项目保存节点并使用独立 Mihomo 端口。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WrapperPath,

        [Parameter(Mandatory = $true)]
        [string]$LauncherPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    $wrapperDirectory = Split-Path -Parent $WrapperPath
    if (-not (Test-Path -LiteralPath $wrapperDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $wrapperDirectory -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $WrapperPath -PathType Leaf) -and -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $original = [System.IO.File]::ReadAllText($WrapperPath, $utf8NoBom)
        [System.IO.File]::WriteAllText($BackupPath, $original, $utf8NoBom)
    }
    $scriptPathVal = if ((Split-Path -Parent $WrapperPath).ToLowerInvariant().TrimEnd('\') -eq (Split-Path -Parent $LauncherPath).ToLowerInvariant().TrimEnd('\')) {
        '%~dp0' + (Split-Path -Leaf $LauncherPath)
    } else {
        $LauncherPath
    }
    $wrapperText = @"
@echo off
setlocal
set "SCRIPT_PATH=$scriptPathVal"
powershell.exe -NoLogo -NoProfile -NonInteractive -File "%SCRIPT_PATH%" %*
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
"@
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($WrapperPath, $wrapperText, $utf8NoBom)
    return
}

function Set-FilePortLiteral {
    <# 备份并替换指定脚本中的旧端口文本，避免备用入口继续使用旧代理。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [int]$OldPort,

        [Parameter(Mandatory = $true)]
        [int]$NewPort
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $original = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        [System.IO.File]::WriteAllText($BackupPath, $original, $utf8NoBom)
    }
    $text = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
    $updated = $text.Replace([string]$OldPort, [string]$NewPort)
    [System.IO.File]::WriteAllText($Path, $updated, $utf8NoBom)
    return $true
}

function Set-LegacyAntigravityLauncherToDedicated {
    <# 将旧桌面桥接脚本改为直接调用保存节点的独立启动器。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ide', 'v2')]
        [string]$LaunchTarget,

        [Parameter(Mandatory = $true)]
        [string]$ToolRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $original = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        [System.IO.File]::WriteAllText($BackupPath, $original, $utf8NoBom)
    }
    $powershellPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcherPath = Join-Path -Path $ToolRoot -ChildPath 'launch-saved-antigravity.ps1'
    $lines = @(
        '# Legacy Antigravity launcher redirected to the saved standalone Mihomo port (Codex, 2026-09-04).'
        '$ErrorActionPreference = ''Stop'''
        ('$launcherPath = ''' + $launcherPath + '''')
        ('$powershellPath = ''' + $powershellPath + '''')
        ('$arguments = @(''-NoLogo'', ''-NoProfile'', ''-NonInteractive'', ''-File'', $launcherPath, ''-Target'', ''' + $LaunchTarget + ''')')
        '& $powershellPath @arguments'
        '$exitCode = $LASTEXITCODE'
        'exit $exitCode'
    )
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($Path, ($lines -join [Environment]::NewLine), $utf8Bom)
    return $true
}

function Configure-AntigravityLaunchers {
    <# 只配置 Antigravity 相关入口，不启动 IDE、2.0 或 agy 应用。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $shortcutRecords = @(Get-AntigravityShortcutRecords -ToolRoot $State.ToolRoot)
    if ($shortcutRecords.Count -eq 0) {
        throw '没有找到桌面或开始菜单中的 Antigravity 快捷方式。'
    }
    foreach ($record in $shortcutRecords) {
        Set-AntigravityShortcutToDedicated -Record $record -ToolRoot $State.ToolRoot
    }

    $runtimeRoot = Join-Path -Path $State.ToolRoot -ChildPath 'runtime'
    $agyLauncherPath = Join-Path -Path $State.ToolRoot -ChildPath 'run-agy-with-proxy.ps1'
    $projectAgyWrapperPath = Join-Path -Path $State.ToolRoot -ChildPath 'agy-proxy.cmd'
    $globalAgyWrapperPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy\bin\agy-proxy.cmd'
    $null = Set-AgyWrapperToDedicated -WrapperPath $projectAgyWrapperPath -LauncherPath $agyLauncherPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'agy-proxy-project-clash.backup')
    $null = Set-AgyWrapperToDedicated -WrapperPath $globalAgyWrapperPath -LauncherPath $agyLauncherPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'agy-proxy-global-clash.backup')

    $null = Set-FilePortLiteral -Path $agyLauncherPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'run-agy-with-proxy-clash.backup') -OldPort 7898 -NewPort ([int]$State.ProxyPort)
    $null = Set-FilePortLiteral -Path $agyLauncherPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'run-agy-with-proxy-original.backup') -OldPort 17890 -NewPort ([int]$State.ProxyPort)
    $null = Set-FilePortLiteral -Path $agyLauncherPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'run-agy-with-proxy-7899.backup') -OldPort 7899 -NewPort ([int]$State.ProxyPort)

    $ideCliPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\bin\antigravity-ide.cmd'
    $ideCliChanged = Set-FilePortLiteral -Path $ideCliPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'antigravity-ide-clash.backup') -OldPort 7898 -NewPort ([int]$State.ProxyPort)
    $ideCliChanged = (Set-FilePortLiteral -Path $ideCliPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'antigravity-ide-original.backup') -OldPort 17890 -NewPort ([int]$State.ProxyPort)) -or $ideCliChanged
    $ideCliChanged = (Set-FilePortLiteral -Path $ideCliPath -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'antigravity-ide-7899.backup') -OldPort 7899 -NewPort ([int]$State.ProxyPort)) -or $ideCliChanged
    $legacyRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Antigravity\launchers'
    $legacyV2Changed = Set-LegacyAntigravityLauncherToDedicated -Path (Join-Path -Path $legacyRoot -ChildPath 'launch-antigravity-7898.ps1') -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'launch-antigravity-7898-clash.backup') -LaunchTarget 'v2' -ToolRoot $State.ToolRoot
    $legacyIdeChanged = Set-LegacyAntigravityLauncherToDedicated -Path (Join-Path -Path $legacyRoot -ChildPath 'launch-antigravity-ide-7898.ps1') -BackupPath (Join-Path -Path $runtimeRoot -ChildPath 'launch-antigravity-ide-7898-clash.backup') -LaunchTarget 'ide' -ToolRoot $State.ToolRoot

    $legacyCount = 0
    if ($legacyV2Changed) {
        $legacyCount++
    }
    if ($legacyIdeChanged) {
        $legacyCount++
    }
    return [pscustomobject]@{
        ShortcutCount = $shortcutRecords.Count
        IdeCliChanged = $ideCliChanged
        LegacyLauncherCount = $legacyCount
    }
}

function Invoke-SwitchAntigravityToClash {
    <#
    调用既有切换脚本，将 Antigravity 相关入口切至 Clash 7898。
    该操作会退出 Antigravity、语言服务和 agy，并停止独立 Mihomo；Codex，2026-09-05。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $switchPath = Join-Path -Path $State.ToolRoot -ChildPath 'switch-antigravity-to-clash.ps1'
    if (-not (Test-Path -LiteralPath $switchPath -PathType Leaf)) {
        throw '找不到切换到 Clash 的脚本。'
    }
    $powershellPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        $powershellPath = (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction Stop).Source
    }
    $runtimeRoot = Join-Path -Path $State.ToolRoot -ChildPath 'runtime'
    $stdoutPath = Join-Path -Path $runtimeRoot -ChildPath 'switch-to-clash.stdout.log'
    $stderrPath = Join-Path -Path $runtimeRoot -ChildPath 'switch-to-clash.stderr.log'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (ConvertTo-ProcessArgument -Value $switchPath))
    $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WorkingDirectory $State.ToolRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
    if ($process.ExitCode -ne 0) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $detail = ''
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $detail = [System.IO.File]::ReadAllText($stderrPath, $utf8NoBom).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = '切换脚本退出码为 ' + $process.ExitCode + '。'
        }
        throw $detail
    }
    return $true
}

function Save-SelectedAntigravitySettings {
    <# 保存订阅、节点和端口配置，但不启动任何 Antigravity 应用。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [hashtable]$Controls
    )

    $subscriptionUrl = ConvertTo-ValidatedSubscriptionUrl -Text $Controls.SubscriptionBox.Text
    $proxyPort = ConvertTo-ValidatedPort -Text $Controls.ProxyPortBox.Text -FieldName 'Antigravity 代理端口'
    $controllerPort = ConvertTo-ValidatedPort -Text $Controls.ControllerPortBox.Text -FieldName 'Mihomo 控制端口'
    if ($State.Nodes.Count -eq 0 -or [string]$State.SubscriptionUrl -ne $subscriptionUrl -or [int]$State.ProxyPort -ne $proxyPort -or [int]$State.ControllerPort -ne $controllerPort) {
        $null = Load-SubscriptionIntoUi -State $State -Controls $Controls
    }

    $selectedNode = [string]$State.SelectedNode
    if ([string]::IsNullOrWhiteSpace($selectedNode) -and $Controls.NodeList.SelectedItems.Count -gt 0) {
        $selectedNode = [string]$Controls.NodeList.SelectedItems[0].Tag
        $State.SelectedNode = $selectedNode
    }
    if ([string]::IsNullOrWhiteSpace($selectedNode)) {
        throw '请先在节点列表中单击选择一个节点。'
    }
    $selectedNodeExists = @($State.Nodes | Where-Object { [string]$_.Name -eq $selectedNode }).Count -gt 0
    if (-not $selectedNodeExists) {
        throw '当前选择的节点不在本次订阅列表中，请重新选择。'
    }

    $State.ProxyPort = $proxyPort
    $State.ControllerPort = $controllerPort
    $State.Settings.subscriptionUrl = $subscriptionUrl
    $State.Settings.selectedNode = $selectedNode
    $State.Settings.proxyPort = $proxyPort
    $State.Settings.controllerPort = $controllerPort
    $State.Settings.antigravityPath = [string]$Controls.IdePathBox.Text.Trim()

    # 保证 portMappings 中主端口 7899 的 node 保持最新
    if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
        $found = $false
        foreach ($m in $State.PortMappings) {
            if ([int]$m.port -eq $proxyPort) {
                $m.node = $selectedNode
                $found = $true
                break
            }
        }
        if (-not $found) {
            $State.PortMappings = @( @{ port = $proxyPort; node = $selectedNode } ) + $State.PortMappings
        }
    } else {
        $State.PortMappings = @( @{ port = $proxyPort; node = $selectedNode } )
    }
    $State.Settings.portMappings = $State.PortMappings

    # 确保独立 Mihomo 配置写入最新端口监听，并在必要时重启核心
    $State.ConfigPath = Join-Path -Path $State.ToolRoot -ChildPath 'runtime\mihomo.yaml'
    $null = Write-MihomoConfig -State $State -SubscriptionUrl $subscriptionUrl -ProxyPort $proxyPort -ControllerPort $controllerPort -PortMappings $State.PortMappings
    $null = Start-OrReuseMihomo -State $State -SubscriptionUrl $subscriptionUrl

    # 设置主端口在 ANTIGRAVITY 策略组中的选择
    $null = Set-MihomoSelection -State $State -NodeName $selectedNode -GroupName 'ANTIGRAVITY'

    # 设置额外端口在各自策略组中的选择
    foreach ($m in $State.PortMappings) {
        $mPort = [int]$m.port
        if ($mPort -ne $proxyPort -and -not [string]::IsNullOrWhiteSpace($m.node)) {
            $mNode = [string]$m.node
            $matched = @($State.Nodes | Where-Object { [string]$_.Name -eq $mNode })
            if ($matched.Count -gt 0) {
                try {
                    $null = Set-MihomoSelection -State $State -NodeName $mNode -GroupName ('GROUP_' + $mPort)
                }
                catch {
                }
            }
        }
    }

    $null = Save-Settings -Settings $State.Settings -Path $State.SettingsPath

    $idePath = Resolve-AntigravityPath -RequestedPath $State.Settings.antigravityPath -ToolRoot $State.ToolRoot
    if ([string]::IsNullOrWhiteSpace($idePath)) {
        throw '找不到 Antigravity，请填写可执行文件路径或点击“浏览”。'
    }
    $Controls.IdePathBox.Text = $idePath
    $State.Settings.antigravityPath = $idePath
    $null = Save-Settings -Settings $State.Settings -Path $State.SettingsPath

    return [pscustomobject]@{
        SelectedNode = $selectedNode
        ProxyPort = $proxyPort
        ControllerPort = $controllerPort
        IdePath = $idePath
    }
}


function New-InstanceState {
    <# 为指定的自定义实例构建独立的 State 运行时数据字典。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory = $true)]
        [hashtable]$Settings,

        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    $instanceId = [string]$InstanceConfig.id
    $instanceDir = Ensure-InstanceDirectories -ToolRoot $ToolRoot -InstanceId $instanceId
    $configPath = Join-Path -Path $instanceDir -ChildPath 'mihomo.yaml'
    $metadataPath = Join-Path -Path $instanceDir -ChildPath 'mihomo-process.json'
    $secretPath = Join-Path -Path $instanceDir -ChildPath 'controller.secret'
    $controllerSecret = Get-ControllerSecret -Path $secretPath

    $stdoutPath = Join-Path -Path $ToolRoot -ChildPath ('logs\mihomo-' + $instanceId + '.stdout.log')
    $stderrPath = Join-Path -Path $ToolRoot -ChildPath ('logs\mihomo-' + $instanceId + '.stderr.log')

    $portMappings = @()
    if ($InstanceConfig.ContainsKey('portMappings') -and $null -ne $InstanceConfig.portMappings) {
        foreach ($m in $InstanceConfig.portMappings) {
            $portMappings += @{
                port = [int]$m.port
                node = [string]$m.node
            }
        }
    }
    if ($portMappings.Count -eq 0) {
        $portMappings += @{
            port = 7880
            node = ''
        }
    }

    $selectedPort = [int]$InstanceConfig.selectedPort
    if ($selectedPort -le 0 -or @($portMappings | Where-Object { [int]$_.port -eq $selectedPort }).Count -eq 0) {
        $selectedPort = Get-FirstPortFromMappings -Mappings $portMappings
    }

    $state = @{
        Id = $instanceId
        Name = [string]$InstanceConfig.name
        ToolRoot = $ToolRoot
        SettingsPath = $SettingsPath
        ConfigPath = $configPath
        MetadataPath = $metadataPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        ControllerSecret = $controllerSecret
        SubscriptionUrl = [string]$InstanceConfig.subscriptionUrl
        ControllerPort = [int]$InstanceConfig.controllerPort
        PortMappings = $portMappings
        SelectedPort = $selectedPort
        SelectedNode = ''
        Nodes = @()
        ManagedProcess = $null
        Refreshing = $false
        Busy = $false
        Settings = $Settings
        InstanceConfig = $InstanceConfig
    }

    return $state
}

function Sync-InstanceStateToSettings {
    <# 把实例运行时的名称、端口与节点映射同步回 settings.json。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $inst = $State.InstanceConfig
    $inst.name = [string]$State.Name
    $inst.subscriptionUrl = [string]$State.SubscriptionUrl
    $inst.controllerPort = [int]$State.ControllerPort
    $inst.selectedPort = [int]$State.SelectedPort
    $inst.portMappings = $State.PortMappings

    $null = Save-Settings -Settings $State.Settings -Path $State.SettingsPath
}

function Refresh-InstanceNodeList {
    <# 刷新自定义实例的 ListView，显示绑定的端口与延迟状态（工作中显示绿色高亮，无 Gemini 列）。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ListView]$ListView,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$CurrentLabel,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Nodes = @()
    )

    $targetNodes = if ($null -ne $Nodes -and $Nodes.Count -gt 0) {
        $Nodes
    } elseif ($State.ContainsKey('Nodes') -and $null -ne $State.Nodes) {
        @($State.Nodes)
    } else {
        @()
    }

    $State.Refreshing = $true
    try {
        $ListView.Items.Clear()

        # 预先检测各端口的实时工作状态
        $portStatusCache = @{}
        if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
            foreach ($m in $State.PortMappings) {
                $p = Get-PortFromMapping -Mapping $m
                if ($p -gt 0 -and -not $portStatusCache.ContainsKey($p)) {
                    $portStatusCache[$p] = (Test-MihomoPortActive -State $State -Port $p)
                }
            }
        }

        # 建立 节点 -> 绑定端口信息的映射
        $nodeToPortInfos = @{}
        if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
            foreach ($m in $State.PortMappings) {
                $nodeName = [string]$m.node
                $p = Get-PortFromMapping -Mapping $m
                if (-not [string]::IsNullOrWhiteSpace($nodeName) -and $p -gt 0) {
                    if (-not $nodeToPortInfos.ContainsKey($nodeName)) {
                        $nodeToPortInfos[$nodeName] = @()
                    }
                    $isWorking = if ($portStatusCache.ContainsKey($p)) { [bool]$portStatusCache[$p] } else { $false }
                    $nodeToPortInfos[$nodeName] += @{
                        Port = $p
                        IsWorking = $isWorking
                    }
                }
            }
        }

        foreach ($node in $targetNodes) {
            $item = New-Object System.Windows.Forms.ListViewItem
            $item.UseItemStyleForSubItems = $false
            $item.Text = [string]$node.Name

            $portSubItem = New-Object System.Windows.Forms.ListViewItem+ListViewSubItem
            if ($nodeToPortInfos.ContainsKey([string]$node.Name)) {
                $portInfos = @($nodeToPortInfos[[string]$node.Name])
                $hasWorking = @($portInfos | Where-Object { $_.IsWorking }).Count -gt 0

                $labels = @()
                foreach ($pi in $portInfos) {
                    if ($pi.IsWorking) {
                        $labels += "● $($pi.Port) (工作中)"
                    } else {
                        $labels += "○ $($pi.Port) (未运行)"
                    }
                }
                $portSubItem.Text = ($labels -join ', ')
                if ($hasWorking) {
                    $portSubItem.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
                    $portSubItem.BackColor = [System.Drawing.Color]::FromArgb(236, 253, 236)
                    $portSubItem.Font = New-Object System.Drawing.Font($ListView.Font.FontFamily, $ListView.Font.Size, [System.Drawing.FontStyle]::Bold)
                } else {
                    $portSubItem.ForeColor = [System.Drawing.Color]::DimGray
                    $portSubItem.Font = New-Object System.Drawing.Font($ListView.Font.FontFamily, $ListView.Font.Size, [System.Drawing.FontStyle]::Regular)
                }
            } else {
                $portSubItem.Text = ''
            }
            $null = $item.SubItems.Add($portSubItem)

            $null = $item.SubItems.Add([string]$node.DelayText)
            $null = $item.SubItems.Add([string]$node.Status)
            $item.Tag = [string]$node.Name
            $null = $ListView.Items.Add($item)

            if (-not [string]::IsNullOrWhiteSpace($State.SelectedNode) -and [string]$node.Name -eq [string]$State.SelectedNode) {
                $item.Selected = $true
            }
        }
    }
    finally {
        $State.Refreshing = $false
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$State.SelectedNode)) {
        $CurrentLabel.Text = '当前选中：' + $State.SelectedNode
    }
    else {
        $CurrentLabel.Text = '当前选中：未选择'
    }

    return
}

function Update-AntigravityTabTitle {
    <# 根据 Antigravity 状态更新 Tab 0 的标题文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TabPage]$TabPage
    )

    $allPorts = @()
    if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings -and $State.PortMappings.Count -gt 0) {
        $allPorts = @($State.PortMappings | ForEach-Object { [string]$_.port })
    } elseif ($State.ContainsKey('ProxyPort')) {
        $allPorts = @([string]$State.ProxyPort)
    }
    $TabPage.Text = 'Antigravity 专用 (' + ($allPorts -join ', ') + ')'
}

function Refresh-AntigravityPortCombo {
    <# 刷新 Antigravity 模块的端口下拉框。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ComboBox]$PortCombo
    )

    $PortCombo.Items.Clear()
    $mainPort = if ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) { [int]$State.ProxyPort } else { 7899 }
    $null = $PortCombo.Items.Add([string]$mainPort + ' (主)')

    if ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
        foreach ($m in $State.PortMappings) {
            $mPort = [int]$m.port
            if ($mPort -ne $mainPort) {
                $null = $PortCombo.Items.Add([string]$mPort)
            }
        }
    }

    $curSelected = if ($State.ContainsKey('SelectedPort') -and [int]$State.SelectedPort -gt 0) { [int]$State.SelectedPort } else { $mainPort }
    $targetItem = if ($curSelected -eq $mainPort) { [string]$mainPort + ' (主)' } else { [string]$curSelected }
    if ($PortCombo.Items.Contains($targetItem)) {
        $PortCombo.SelectedItem = $targetItem
    } elseif ($PortCombo.Items.Count -gt 0) {
        $PortCombo.SelectedIndex = 0
    }
}

function Update-AntigravityPortInfo {
    <# 根据当前选中端口更新绑定提示、实际工作状态与指派按钮文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$PortInfoLabel,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$AssignBtn
    )

    $mainPort = if ($State.ContainsKey('ProxyPort') -and [int]$State.ProxyPort -gt 0) { [int]$State.ProxyPort } else { 7899 }
    $curPort = if ($State.ContainsKey('SelectedPort') -and [int]$State.SelectedPort -gt 0) { [int]$State.SelectedPort } else { $mainPort }

    $boundNode = ''
    if ($curPort -eq $mainPort) {
        $boundNode = [string]$State.SelectedNode
    } elseif ($State.ContainsKey('PortMappings') -and $null -ne $State.PortMappings) {
        foreach ($m in $State.PortMappings) {
            if ([int]$m.port -eq $curPort) {
                $boundNode = [string]$m.node
                break
            }
        }
    }

    $portDesc = if ($curPort -eq $mainPort) { [string]$curPort + ' (主)' } else { [string]$curPort }
    $isActive = Test-MihomoPortActive -State $State -Port $curPort
    $statusText = if ($isActive) { '【工作中 ●】' } else { '【未工作 ○】' }

    if ([string]::IsNullOrWhiteSpace($boundNode)) {
        $PortInfoLabel.Text = ('当前端口 ' + $portDesc + ' ' + $statusText + ' 绑定：(未指派)')
    } else {
        $PortInfoLabel.Text = ('当前端口 ' + $portDesc + ' ' + $statusText + ' 绑定节点：' + $boundNode)
    }

    if ($isActive) {
        $PortInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
    } else {
        $PortInfoLabel.ForeColor = [System.Drawing.Color]::DimGray
    }

    $AssignBtn.Text = ('将选中节点指派给端口 ' + $portDesc)
}

function Update-InstanceTabTitle {
    <# 根据实例状态更新对应 TabPage 的标题文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $portsList = @($State.PortMappings | ForEach-Object { [string]$_.port }) -join ', '
    if ($State.ContainsKey('TabPage') -and $null -ne $State.TabPage) {
        $State.TabPage.Text = [string]$State.Name + ' (' + $portsList + ')'
    }
}

function Refresh-InstancePortCombo {
    <# 刷新端口下拉框项并保持当前选中端口同步。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ComboBox]$PortCombo
    )

    $PortCombo.Items.Clear()
    foreach ($m in $State.PortMappings) {
        $null = $PortCombo.Items.Add([string]$m.port)
    }
    $targetPortStr = [string]$State.SelectedPort
    if ($PortCombo.Items.Contains($targetPortStr)) {
        $PortCombo.SelectedItem = $targetPortStr
    } elseif ($PortCombo.Items.Count -gt 0) {
        $PortCombo.SelectedIndex = 0
        $State.SelectedPort = [int]$PortCombo.SelectedItem
    }
}

function Update-InstancePortInfo {
    <# 根据当前选中端口更新绑定节点提示文本、实际工作状态与指派按钮文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$PortInfoLabel,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$AssignBtn
    )

    $curPort = [int]$State.SelectedPort
    $boundNode = ''
    foreach ($m in $State.PortMappings) {
        if ([int]$m.port -eq $curPort) {
            $boundNode = [string]$m.node
            break
        }
    }

    $isActive = Test-MihomoPortActive -State $State -Port $curPort
    $statusText = if ($isActive) { '【工作中 ●】' } else { '【未工作 ○】' }

    if ([string]::IsNullOrWhiteSpace($boundNode)) {
        $PortInfoLabel.Text = ('当前端口 ' + $curPort + ' ' + $statusText + ' 绑定节点：(未指派)')
    } else {
        $PortInfoLabel.Text = ('当前端口 ' + $curPort + ' ' + $statusText + ' 绑定节点：' + $boundNode)
    }

    if ($isActive) {
        $PortInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
    } else {
        $PortInfoLabel.ForeColor = [System.Drawing.Color]::DimGray
    }

    $AssignBtn.Text = ('将选中节点指派给端口 ' + $curPort)
}

function Restore-ActiveProxiesFromRunningCore {
    <# 检查核心是否在后台运行，若在运行则秒级恢复节点列表并在界面呈现真实的端口工作状态（绿色高亮）。 #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ListView]$ListView,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$CurrentLabel,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$PortInfoLabel,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$AssignBtn,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$StatusLabel,

        [bool]$IsAntigravity = $false
    )

    $managed = Get-ManagedMihomoProcess -State $State
    if ($null -ne $managed) {
        $State.ManagedProcess = $managed.Process
        try {
            $nodes = @(Get-MihomoNodes -State $State)
            if ($nodes.Count -gt 0) {
                $State.Nodes = $nodes
                if ($IsAntigravity) {
                    Refresh-NodeList -State $State -ListView $ListView -CurrentLabel $CurrentLabel -Nodes $nodes
                    Update-AntigravityPortInfo -State $State -PortInfoLabel $PortInfoLabel -AssignBtn $AssignBtn
                } else {
                    Refresh-InstanceNodeList -State $State -ListView $ListView -CurrentLabel $CurrentLabel -Nodes $nodes
                    Update-InstancePortInfo -State $State -PortInfoLabel $PortInfoLabel -AssignBtn $AssignBtn
                }
                Set-UiStatus -Label $StatusLabel -Message ('状态：已连接后台运行的核心 (PID ' + $managed.Process.Id + ')，端口正常工作中（见绿色标记）。')
                return $true
            }
        }
        catch {
        }
    }

    if ($IsAntigravity) {
        Update-AntigravityPortInfo -State $State -PortInfoLabel $PortInfoLabel -AssignBtn $AssignBtn
    } else {
        Update-InstancePortInfo -State $State -PortInfoLabel $PortInfoLabel -AssignBtn $AssignBtn
    }
    return $false
}

function Show-AddPortDialog {
    <# 弹出添加代理端口对话框，返回有效的未占用端口号。 #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner,

        [int]$DefaultPort = 7882
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '添加代理监听端口'
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.ClientSize = [System.Drawing.Size]::new(340, 150)
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '请输入要新增的本地代理端口 (1024-65535)：'
    $lbl.Location = [System.Drawing.Point]::new(20, 20)
    $lbl.AutoSize = $true
    $dlg.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum = 1024
    $num.Maximum = 65535
    $num.Value = [decimal]$DefaultPort
    $num.Location = [System.Drawing.Point]::new(20, 50)
    $num.Size = [System.Drawing.Size]::new(150, 25)
    $dlg.Controls.Add($num)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = [System.Drawing.Point]::new(140, 95)
    $btnOk.Size = [System.Drawing.Size]::new(80, 30)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = [System.Drawing.Point]::new(235, 95)
    $btnCancel.Size = [System.Drawing.Size]::new(80, 30)
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $result = $dlg.ShowDialog($Owner)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return [int]$num.Value
    }
    return 0
}

$toolRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($toolRoot)) {
    $toolRoot = [Environment]::GetEnvironmentVariable('ANTIGRAVITY_MIHOMO_TOOL_ROOT', 'Process')
}
if ([string]::IsNullOrWhiteSpace($toolRoot)) {
    throw '无法确定工具目录。'
}

$null = Ensure-ToolDirectories -ToolRoot $toolRoot
$settingsPath = Join-Path -Path $toolRoot -ChildPath 'config\settings.json'
$controllerSecretPath = Join-Path -Path $toolRoot -ChildPath 'runtime\controller.secret'
$controllerSecret = Get-ControllerSecret -Path $controllerSecretPath
$settings = Read-Settings -Path $settingsPath

# 确保至少存在一个默认应用代理实例
if ($settings.customInstances.Count -eq 0) {
    $defaultInstance = @{
        id = 'app-1'
        name = '应用代理 1'
        subscriptionUrl = ''
        controllerPort = 19091
        portMappings = @(
            @{ port = 7880; node = '' }
        )
        selectedPort = 7880
    }
    $settings.customInstances = @($defaultInstance)
    $null = Save-Settings -Settings $settings -Path $settingsPath
}

# 确保所有已配置实例的专属目录均已创建
foreach ($inst in @($settings.customInstances)) {
    if ($null -ne $inst -and $inst.ContainsKey('id') -and -not [string]::IsNullOrWhiteSpace($inst.id)) {
        $null = Ensure-InstanceDirectories -ToolRoot $toolRoot -InstanceId ([string]$inst.id)
    }
}

$rootPortMappings = @()
if ($settings.ContainsKey('portMappings') -and $null -ne $settings.portMappings) {
    foreach ($m in @($settings.portMappings)) {
        $rootPortMappings += @{
            port = [int]$m.port
            node = [string]$m.node
        }
    }
}
$hasPrimaryPort = @($rootPortMappings | Where-Object { [int]$_.port -eq [int]$settings.proxyPort }).Count -gt 0
if (-not $hasPrimaryPort) {
    $rootPortMappings = @( @{ port = [int]$settings.proxyPort; node = [string]$settings.selectedNode } ) + $rootPortMappings
}
$rootSelectedPort = if ($settings.ContainsKey('selectedPort') -and [int]$settings.selectedPort -gt 0) { [int]$settings.selectedPort } else { [int]$settings.proxyPort }

$state = @{
    ToolRoot = $toolRoot
    SettingsPath = $settingsPath
    ConfigPath = (Join-Path -Path $toolRoot -ChildPath 'runtime\mihomo.yaml')
    ControllerSecret = $controllerSecret
    SubscriptionUrl = [string]$settings.subscriptionUrl
    ProxyPort = [int]$settings.proxyPort
    ControllerPort = [int]$settings.controllerPort
    SelectedNode = [string]$settings.selectedNode
    PortMappings = $rootPortMappings
    SelectedPort = $rootSelectedPort
    Nodes = @()
    ManagedProcess = $null
    Refreshing = $false
    Busy = $false
    Settings = $settings
}

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Mihomo 独立代理多核心管理平台 (Antigravity & 通用应用)'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = [System.Drawing.Size]::new(940, 680)
$form.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
$form.MinimizeBox = $true
$form.MaximizeBox = $false

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = [System.Drawing.Point]::new(10, 10)
$tabControl.Size = [System.Drawing.Size]::new(920, 660)
$tabControl.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabControl.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
$form.Controls.Add($tabControl)

# -------------------------------------------------------------
# TAB 0: Antigravity 专用 (7899)
# -------------------------------------------------------------
$antigravityTab = New-Object System.Windows.Forms.TabPage
$antigravityTab.Text = 'Antigravity 专用 (7899)'
$antigravityTab.UseVisualStyleBackColor = $true
$tabControl.TabPages.Add($antigravityTab)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Antigravity 专用代理 (Mihomo 独立核心)'
$titleLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = [System.Drawing.Point]::new(15, 12)
$antigravityTab.Controls.Add($titleLabel)

$subscriptionLabel = New-Object System.Windows.Forms.Label
$subscriptionLabel.Text = '订阅地址：'
$subscriptionLabel.AutoSize = $true
$subscriptionLabel.Location = [System.Drawing.Point]::new(15, 52)
$antigravityTab.Controls.Add($subscriptionLabel)

$subscriptionBox = New-Object System.Windows.Forms.TextBox
$subscriptionBox.Location = [System.Drawing.Point]::new(95, 48)
$subscriptionBox.Size = [System.Drawing.Size]::new(685, 25)
$subscriptionBox.Text = [string]$settings.subscriptionUrl
$antigravityTab.Controls.Add($subscriptionBox)

$loadButton = New-Object System.Windows.Forms.Button
$loadButton.Text = '加载订阅'
$loadButton.Location = [System.Drawing.Point]::new(795, 46)
$loadButton.Size = [System.Drawing.Size]::new(100, 30)
$antigravityTab.Controls.Add($loadButton)

$ideLabel = New-Object System.Windows.Forms.Label
$ideLabel.Text = 'Antigravity 路径：'
$ideLabel.AutoSize = $true
$ideLabel.Location = [System.Drawing.Point]::new(15, 90)
$antigravityTab.Controls.Add($ideLabel)

$idePathBox = New-Object System.Windows.Forms.TextBox
$idePathBox.Location = [System.Drawing.Point]::new(130, 86)
$idePathBox.Size = [System.Drawing.Size]::new(650, 25)
$resolvedIdePath = Resolve-AntigravityPath -RequestedPath ([string]$settings.antigravityPath) -ToolRoot $toolRoot
$idePathBox.Text = if ([string]::IsNullOrWhiteSpace($settings.antigravityPath)) { $resolvedIdePath } else { [string]$settings.antigravityPath }
$antigravityTab.Controls.Add($idePathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = '浏览…'
$browseButton.Location = [System.Drawing.Point]::new(795, 84)
$browseButton.Size = [System.Drawing.Size]::new(100, 30)
$antigravityTab.Controls.Add($browseButton)

$proxyPortLabel = New-Object System.Windows.Forms.Label
$proxyPortLabel.Text = 'Antigravity 端口：'
$proxyPortLabel.AutoSize = $true
$proxyPortLabel.Location = [System.Drawing.Point]::new(15, 126)
$antigravityTab.Controls.Add($proxyPortLabel)

$proxyPortBox = New-Object System.Windows.Forms.TextBox
$proxyPortBox.Location = [System.Drawing.Point]::new(130, 122)
$proxyPortBox.Size = [System.Drawing.Size]::new(65, 25)
$proxyPortBox.Text = [string]$settings.proxyPort
$antigravityTab.Controls.Add($proxyPortBox)

$controllerPortLabel = New-Object System.Windows.Forms.Label
$controllerPortLabel.Text = '控制端口：'
$controllerPortLabel.AutoSize = $true
$controllerPortLabel.Location = [System.Drawing.Point]::new(205, 126)
$antigravityTab.Controls.Add($controllerPortLabel)

$controllerPortBox = New-Object System.Windows.Forms.TextBox
$controllerPortBox.Location = [System.Drawing.Point]::new(270, 122)
$controllerPortBox.Size = [System.Drawing.Size]::new(65, 25)
$controllerPortBox.Text = [string]$settings.controllerPort
$antigravityTab.Controls.Add($controllerPortBox)

$portSectionLabel = New-Object System.Windows.Forms.Label
$portSectionLabel.Text = '分配端口：'
$portSectionLabel.AutoSize = $true
$portSectionLabel.Location = [System.Drawing.Point]::new(350, 126)
$antigravityTab.Controls.Add($portSectionLabel)

$agPortCombo = New-Object System.Windows.Forms.ComboBox
$agPortCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$agPortCombo.Location = [System.Drawing.Point]::new(415, 122)
$agPortCombo.Size = [System.Drawing.Size]::new(110, 25)
$antigravityTab.Controls.Add($agPortCombo)

$agAddPortBtn = New-Object System.Windows.Forms.Button
$agAddPortBtn.Text = '+ 添加端口'
$agAddPortBtn.Location = [System.Drawing.Point]::new(535, 120)
$agAddPortBtn.Size = [System.Drawing.Size]::new(95, 28)
$antigravityTab.Controls.Add($agAddPortBtn)

$agDelPortBtn = New-Object System.Windows.Forms.Button
$agDelPortBtn.Text = '- 删除端口'
$agDelPortBtn.Location = [System.Drawing.Point]::new(635, 120)
$agDelPortBtn.Size = [System.Drawing.Size]::new(90, 28)
$antigravityTab.Controls.Add($agDelPortBtn)

$agPortInfoLabel = New-Object System.Windows.Forms.Label
$agPortInfoLabel.Text = '当前端口绑定：(未指派)'
$agPortInfoLabel.AutoSize = $true
$agPortInfoLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$agPortInfoLabel.Location = [System.Drawing.Point]::new(735, 126)
$antigravityTab.Controls.Add($agPortInfoLabel)

$nodeLabel = New-Object System.Windows.Forms.Label
$nodeLabel.Text = '节点列表 (单击选择出口节点，Ctrl/Shift 可多选测试)：'
$nodeLabel.AutoSize = $true
$nodeLabel.Location = [System.Drawing.Point]::new(15, 165)
$antigravityTab.Controls.Add($nodeLabel)

$nodeList = New-Object System.Windows.Forms.ListView
$nodeList.View = [System.Windows.Forms.View]::Details
$nodeList.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
$nodeList.FullRowSelect = $true
$nodeList.GridLines = $true
$nodeList.HideSelection = $false
$nodeList.MultiSelect = $true
$nodeList.Location = [System.Drawing.Point]::new(15, 188)
$nodeList.Size = [System.Drawing.Size]::new(880, 290)
$null = $nodeList.Columns.Add('节点名称', 360)
$null = $nodeList.Columns.Add('绑定端口', 150)
$null = $nodeList.Columns.Add('基础延迟', 90)
$null = $nodeList.Columns.Add('网络状态', 90)
$null = $nodeList.Columns.Add('Gemini深度可用性', 200)
$antigravityTab.Controls.Add($nodeList)

$currentLabel = New-Object System.Windows.Forms.Label
$currentLabel.Text = '当前选择：未选择'
$currentLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
$currentLabel.AutoSize = $true
$currentLabel.Location = [System.Drawing.Point]::new(15, 492)
$antigravityTab.Controls.Add($currentLabel)

$agAssignBtn = New-Object System.Windows.Forms.Button
$agAssignBtn.Text = '将选中节点指派给端口'
$agAssignBtn.Location = [System.Drawing.Point]::new(320, 486)
$agAssignBtn.Size = [System.Drawing.Size]::new(230, 32)
$antigravityTab.Controls.Add($agAssignBtn)

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = '测基础延迟'
$testButton.Location = [System.Drawing.Point]::new(560, 486)
$testButton.Size = [System.Drawing.Size]::new(140, 32)
$antigravityTab.Controls.Add($testButton)

$testAiButton = New-Object System.Windows.Forms.Button
$testAiButton.Text = '深度测Gemini'
$testAiButton.Location = [System.Drawing.Point]::new(710, 486)
$testAiButton.Size = [System.Drawing.Size]::new(185, 32)
$antigravityTab.Controls.Add($testAiButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = if ([string]::IsNullOrWhiteSpace($settings.subscriptionUrl)) { '状态：请输入订阅地址。' } else { '状态：已读取上次设置，可点击加载订阅。' }
$statusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$statusLabel.AutoEllipsis = $true
$statusLabel.Location = [System.Drawing.Point]::new(15, 535)
$statusLabel.Size = [System.Drawing.Size]::new(340, 36)
$antigravityTab.Controls.Add($statusLabel)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = '停止独立核心'
$stopButton.Location = [System.Drawing.Point]::new(370, 535)
$stopButton.Size = [System.Drawing.Size]::new(125, 36)
$antigravityTab.Controls.Add($stopButton)

$clashButton = New-Object System.Windows.Forms.Button
$clashButton.Text = '切换到 Clash 7898'
$clashButton.Location = [System.Drawing.Point]::new(510, 535)
$clashButton.Size = [System.Drawing.Size]::new(165, 36)
$antigravityTab.Controls.Add($clashButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = '保存并切到7899端口'
$startButton.Location = [System.Drawing.Point]::new(690, 535)
$startButton.Size = [System.Drawing.Size]::new(205, 36)
$antigravityTab.Controls.Add($startButton)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($testButton, '测试选中节点的 TCP/Google 204 延迟。')
$toolTip.SetToolTip($testAiButton, '端到端深度测试选中节点是否被 Google Gemini API 区域阻断。')
$toolTip.SetToolTip($stopButton, '停止本工具的独立 Mihomo 核心，不修改快捷方式。')
$toolTip.SetToolTip($clashButton, '安全退出 Antigravity，并将桌面快捷方式切回 Clash 7898。')
$toolTip.SetToolTip($startButton, '保存当前选中的节点并启动 Antigravity 专用 7899 独立代理核心。')

$controls = @{
    SubscriptionBox = $subscriptionBox
    IdePathBox = $idePathBox
    ProxyPortBox = $proxyPortBox
    ControllerPortBox = $controllerPortBox
    NodeList = $nodeList
    CurrentLabel = $currentLabel
    StatusLabel = $statusLabel
    TestButton = $testButton
    TestAiButton = $testAiButton
}
$state.Form = $form

# 初始化 Tab 0 标题与端口控件状态
Update-AntigravityTabTitle -State $state -TabPage $antigravityTab
Refresh-AntigravityPortCombo -State $state -PortCombo $agPortCombo
Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn

# 启动时检测后台是否已有正在运行的核心，若有则秒级恢复节点并在列表中标绿已工作的端口
$null = Restore-ActiveProxiesFromRunningCore -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn -StatusLabel $controls.StatusLabel -IsAntigravity $true

$agPortCombo.Add_SelectedIndexChanged({
    if ($agPortCombo.SelectedIndex -ge 0) {
        $selectedText = [string]$agPortCombo.SelectedItem
        if ($selectedText -match '^(\d+)') {
            $state.SelectedPort = [int]$matches[1]
            $state.Settings.selectedPort = [int]$matches[1]
        }
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
    }
}.GetNewClosure())

$agAssignBtn.Add_Click({
    $selectedItems = @($controls.NodeList.SelectedItems)
    if ($selectedItems.Count -eq 0) {
        Show-UiError -Form $form -Message '请先在列表中选中一个节点。'
        return
    }
    $chosenNode = [string]$selectedItems[0].Tag
    $curPort = [int]$state.SelectedPort
    $mainPort = [int]$state.ProxyPort

    if ($curPort -eq $mainPort) {
        $state.SelectedNode = $chosenNode
        $state.Settings.selectedNode = $chosenNode
        foreach ($m in $state.PortMappings) {
            if ([int]$m.port -eq $mainPort) {
                $m.node = $chosenNode
                break
            }
        }
        try {
            $null = Set-MihomoSelection -State $state -NodeName $chosenNode -GroupName 'ANTIGRAVITY'
        }
        catch {
        }
    } else {
        foreach ($m in $state.PortMappings) {
            if ([int]$m.port -eq $curPort) {
                $m.node = $chosenNode
                break
            }
        }
        try {
            $null = Set-MihomoSelection -State $state -NodeName $chosenNode -GroupName ('GROUP_' + $curPort)
        }
        catch {
        }
    }

    $state.Settings.portMappings = $state.PortMappings
    $null = Save-Settings -Settings $state.Settings -Path $state.SettingsPath
    Refresh-NodeList -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -Nodes $state.Nodes
    Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
    Set-UiStatus -Label $controls.StatusLabel -Message ('已将端口 ' + $curPort + ' 的出口节点设置为：' + $chosenNode)
}.GetNewClosure())

$agAddPortBtn.Add_Click({
    $existingPorts = @()
    if ($state.ContainsKey('PortMappings') -and $null -ne $state.PortMappings) {
        $existingPorts = @($state.PortMappings | ForEach-Object { [int]$_.port })
    } else {
        $existingPorts = @([int]$state.ProxyPort)
    }
    foreach ($c in $settings.customInstances) {
        if ($null -ne $c.portMappings) {
            foreach ($pm in $c.portMappings) {
                $existingPorts += [int]$pm.port
            }
        }
    }

    $candidatePort = 7891
    while ($candidatePort -in $existingPorts -or (Test-LocalPortInUse -Port $candidatePort)) {
        $candidatePort++
    }

    $newPort = Show-AddPortDialog -Owner $form -DefaultPort $candidatePort
    if ($newPort -gt 0) {
        if ($newPort -in $existingPorts) {
            Show-UiError -Form $form -Message ('端口 ' + $newPort + ' 已在配置列表中。')
            return
        }
        if (Test-LocalPortInUse -Port $newPort) {
            Show-UiError -Form $form -Message ('本地端口 ' + $newPort + ' 已被其他进程占用。')
            return
        }
        $state.PortMappings += @{
            port = $newPort
            node = ''
        }
        $state.SelectedPort = $newPort
        $state.Settings.portMappings = $state.PortMappings
        $null = Save-Settings -Settings $state.Settings -Path $state.SettingsPath

        Refresh-AntigravityPortCombo -State $state -PortCombo $agPortCombo
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        Update-AntigravityTabTitle -State $state -TabPage $antigravityTab
        Refresh-NodeList -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -Nodes $state.Nodes
        Set-UiStatus -Label $controls.StatusLabel -Message ('已为 Antigravity 模块添加端口 ' + $newPort + '。请点击【保存并切到7899端口】启动新端口监听。')
    }
}.GetNewClosure())

$agDelPortBtn.Add_Click({
    $curPort = [int]$state.SelectedPort
    $mainPort = [int]$state.ProxyPort
    if ($curPort -eq $mainPort) {
        Show-UiError -Form $form -Message ('Antigravity 主代理端口 (' + $mainPort + ') 为系统核心端口，不可删除。')
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $form,
        ('确定要删除代理端口 ' + $curPort + ' 吗？'),
        '删除端口确认',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        $state.PortMappings = @($state.PortMappings | Where-Object { [int]$_.port -ne $curPort })
        $state.SelectedPort = $mainPort
        $state.Settings.portMappings = $state.PortMappings
        $null = Save-Settings -Settings $state.Settings -Path $state.SettingsPath

        Refresh-AntigravityPortCombo -State $state -PortCombo $agPortCombo
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        Update-AntigravityTabTitle -State $state -TabPage $antigravityTab
        Refresh-NodeList -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -Nodes $state.Nodes
        Set-UiStatus -Label $controls.StatusLabel -Message ('已删除端口 ' + $curPort + '。请点击【保存并切到7899端口】更新监听。')
    }
}.GetNewClosure())

$nodeSelectionHandler = {
    if (-not $state.Refreshing -and $controls.NodeList.SelectedItems.Count -gt 0) {
        $chosenNode = [string]$controls.NodeList.SelectedItems[0].Tag
        $state.SelectedNode = $chosenNode
        $controls.CurrentLabel.Text = '当前选择：' + $chosenNode
        if ([int]$state.SelectedPort -eq [int]$state.ProxyPort) {
            foreach ($m in $state.PortMappings) {
                if ([int]$m.port -eq [int]$state.ProxyPort) {
                    $m.node = $chosenNode
                    break
                }
            }
            Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        }
    }
    return
}.GetNewClosure()
$nodeList.Add_SelectedIndexChanged($nodeSelectionHandler)

$browseHandler = {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择 Antigravity 可执行文件'
    $dialog.Filter = 'Antigravity 可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    try {
        if (-not [string]::IsNullOrWhiteSpace($controls.IdePathBox.Text) -and (Test-Path -LiteralPath $controls.IdePathBox.Text -PathType Leaf)) {
            $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($controls.IdePathBox.Text)
            $dialog.FileName = [System.IO.Path]::GetFileName($controls.IdePathBox.Text)
        }
    }
    catch {
    }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $controls.IdePathBox.Text = $dialog.FileName
    }
    return
}.GetNewClosure()
$browseButton.Add_Click($browseHandler)

$loadHandler = {
    if ($state.Busy) {
        return
    }
    $state.Busy = $true
    $loadButton.Enabled = $false
    $testButton.Enabled = $false
    $testAiButton.Enabled = $false
    $clashButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Set-UiStatus -Label $controls.StatusLabel -Message '状态：正在启动独立 Mihomo 并加载订阅节点……'
        $nodes = Load-SubscriptionIntoUi -State $state -Controls $controls
        Refresh-AntigravityPortCombo -State $state -PortCombo $agPortCombo
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        Update-AntigravityTabTitle -State $state -TabPage $antigravityTab
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：订阅加载成功，共发现 ' + $nodes.Count + ' 个可用节点。')
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    finally {
        $state.Busy = $false
        $loadButton.Enabled = $true
        $testButton.Enabled = $true
        $testAiButton.Enabled = $true
        $clashButton.Enabled = $true
        $startButton.Enabled = $true
    }
    return
}.GetNewClosure()
$loadButton.Add_Click($loadHandler)

$testHandler = {
    if ($state.Busy) {
        return
    }
    if ($state.Nodes.Count -eq 0 -or $controls.NodeList.Items.Count -eq 0) {
        Show-UiError -Form $form -Message '请先点击“加载订阅”。'
        return
    }
    $selectedItems = @($controls.NodeList.SelectedItems)
    if ($selectedItems.Count -eq 0) {
        Show-UiError -Form $form -Message '请先框选一个或多个节点，再点击“测基础延迟”。'
        return
    }
    $selectedCount = $selectedItems.Count
    $state.Busy = $true
    $loadButton.Enabled = $false
    $testButton.Enabled = $false
    $testAiButton.Enabled = $false
    $clashButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：正在测试已选的 ' + $selectedCount + ' 个节点延迟……')
        foreach ($item in $selectedItems) {
            $nodeName = [string]$item.Tag
            $item.SubItems[2].Text = '测试中…'
            $item.SubItems[3].Text = '测试中'
            [System.Windows.Forms.Application]::DoEvents()
            $result = Test-MihomoNode -State $state -NodeName $nodeName
            $item.SubItems[2].Text = [string]$result.DelayText
            $item.SubItems[3].Text = [string]$result.Status
            [System.Windows.Forms.Application]::DoEvents()
        }
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：已完成 ' + $selectedCount + ' 个选中节点延迟测试。')
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    finally {
        $state.Busy = $false
        $loadButton.Enabled = $true
        $testButton.Enabled = $true
        $testAiButton.Enabled = $true
        $clashButton.Enabled = $true
        $startButton.Enabled = $true
    }
    return
}.GetNewClosure()
$testButton.Add_Click($testHandler)

$testAiHandler = {
    if ($state.Busy) {
        return
    }
    if ($state.Nodes.Count -eq 0 -or $controls.NodeList.Items.Count -eq 0) {
        Show-UiError -Form $form -Message '请先点击“加载订阅”。'
        return
    }
    $selectedItems = @($controls.NodeList.SelectedItems)
    if ($selectedItems.Count -eq 0) {
        Show-UiError -Form $form -Message '请先框选一个或多个节点，再点击“深度测Gemini”。'
        return
    }
    $selectedCount = $selectedItems.Count
    $state.Busy = $true
    $loadButton.Enabled = $false
    $testButton.Enabled = $false
    $testAiButton.Enabled = $false
    $clashButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：正在对已选的 ' + $selectedCount + ' 个节点进行 Gemini 业务探活……')
        foreach ($item in $selectedItems) {
            $nodeName = [string]$item.Tag
            $item.SubItems[4].Text = '探活中…'
            [System.Windows.Forms.Application]::DoEvents()
            $result = Test-MihomoAiPreflight -State $state -NodeName $nodeName
            $item.SubItems[4].Text = [string]$result.AiStatus
            if ($result.Success -and $item.SubItems[3].Text -eq '未测试') {
                $item.SubItems[3].Text = '可用'
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：已完成 ' + $selectedCount + ' 个选中节点的 Gemini 业务探活。')
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    finally {
        $state.Busy = $false
        $loadButton.Enabled = $true
        $testButton.Enabled = $true
        $testAiButton.Enabled = $true
        $clashButton.Enabled = $true
        $startButton.Enabled = $true
    }
    return
}.GetNewClosure()
$testAiButton.Add_Click($testAiHandler)

$startHandler = {
    if ($state.Busy) {
        return
    }
    $state.Busy = $true
    $loadButton.Enabled = $false
    $testButton.Enabled = $false
    $testAiButton.Enabled = $false
    $clashButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Set-UiStatus -Label $controls.StatusLabel -Message '状态：正在保存 B 节点并切换 Antigravity 启动入口……'
        $null = Save-SelectedAntigravitySettings -State $state -Controls $controls
        $launcherResult = Configure-AntigravityLaunchers -State $state
        $aiProbe = Test-MihomoAiPreflight -State $state -NodeName $state.SelectedNode -TimeoutSeconds 4
        $portsSummary = @($state.PortMappings | ForEach-Object { [string]$_.port }) -join ', '
        Refresh-NodeList -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -Nodes $state.Nodes
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        if ($aiProbe.Success) {
            Set-UiStatus -Label $controls.StatusLabel -Message ('状态：已切到独立核心，监听端口: ' + $portsSummary + '，已配置 ' + $launcherResult.ShortcutCount + ' 个快捷方式；所选节点 Gemini 探活正常（' + $aiProbe.ElapsedMs + 'ms）。')
        }
        else {
            Set-UiStatus -Label $controls.StatusLabel -Message ('警告：已切到独立核心，监听端口: ' + $portsSummary + '，但所选节点 Gemini 探活异常：' + $aiProbe.AiStatus + '。建议选择其他节点。') -IsError $true
        }
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    finally {
        $state.Busy = $false
        $loadButton.Enabled = $true
        $testButton.Enabled = $true
        $testAiButton.Enabled = $true
        $clashButton.Enabled = $true
        $startButton.Enabled = $true
    }
    return
}.GetNewClosure()
$startButton.Add_Click($startHandler)

$clashHandler = {
    if ($state.Busy) {
        return
    }
    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        $form,
        '将完全退出 Antigravity 2.0、IDE、language service 和 agy，并停止独立 Mihomo。' + [Environment]::NewLine + '之后桌面快捷方式和 agy-proxy 将改走 Clash 7898；其他应用仍保持 7897。' + [Environment]::NewLine + '是否继续？',
        '切换 Antigravity 到 Clash 7898',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }
    $state.Busy = $true
    $loadButton.Enabled = $false
    $testButton.Enabled = $false
    $testAiButton.Enabled = $false
    $stopButton.Enabled = $false
    $clashButton.Enabled = $false
    $startButton.Enabled = $false
    try {
        Set-UiStatus -Label $controls.StatusLabel -Message '状态：正在退出 Antigravity 并切换到 Clash 7898……'
        $null = Invoke-SwitchAntigravityToClash -State $state
        Set-UiStatus -Label $controls.StatusLabel -Message '状态：已切到 Clash 7898；独立 B 配置仍已保存，点击右侧按钮可切回。'
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：切换失败：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    finally {
        $state.Busy = $false
        $loadButton.Enabled = $true
        $testButton.Enabled = $true
        $testAiButton.Enabled = $true
        $stopButton.Enabled = $true
        $clashButton.Enabled = $true
        $startButton.Enabled = $true
    }
    return
}.GetNewClosure()
$clashButton.Add_Click($clashHandler)

$stopHandler = {
    if ($state.Busy) {
        return
    }
    try {
        $stopped = Stop-ManagedMihomo -State $state
        Refresh-NodeList -State $state -ListView $controls.NodeList -CurrentLabel $controls.CurrentLabel -Nodes $state.Nodes
        Update-AntigravityPortInfo -State $state -PortInfoLabel $agPortInfoLabel -AssignBtn $agAssignBtn
        if ($stopped) {
            Set-UiStatus -Label $controls.StatusLabel -Message '状态：已停止 Antigravity 专属 Mihomo 核心（端口已停止工作）。'
        }
        else {
            Set-UiStatus -Label $controls.StatusLabel -Message '状态：没有找到本工具仍在运行的 Antigravity 专属核心。'
        }
    }
    catch {
        Set-UiStatus -Label $controls.StatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
        Show-UiError -Form $form -Message $_.Exception.Message
    }
    return
}.GetNewClosure()
$stopButton.Add_Click($stopHandler)


# -------------------------------------------------------------
# 自定义应用代理 Tab 构造函数与逻辑
# -------------------------------------------------------------
function Add-CustomInstanceTabPage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TabControl]$TabControl,

        [Parameter(Mandatory = $true)]
        [string]$ToolRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory = $true)]
        [hashtable]$Settings,

        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Form,

        [int]$InsertIndex = -1
    )

    $instState = New-InstanceState -ToolRoot $ToolRoot -InstanceConfig $InstanceConfig -Settings $Settings -SettingsPath $SettingsPath
    $instTab = New-Object System.Windows.Forms.TabPage
    $instState.TabPage = $instTab
    $instState.Form = $Form

    Update-InstanceTabTitle -State $instState

    $instTab.UseVisualStyleBackColor = $true

    # 1. 顶部实例名称与控制端口行
    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = '实例名称：'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = [System.Drawing.Point]::new(15, 15)
    $instTab.Controls.Add($nameLabel)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = [System.Drawing.Point]::new(85, 12)
    $nameBox.Size = [System.Drawing.Size]::new(180, 25)
    $nameBox.Text = $instState.Name
    $instTab.Controls.Add($nameBox)

    $renameBtn = New-Object System.Windows.Forms.Button
    $renameBtn.Text = '保存名称'
    $renameBtn.Location = [System.Drawing.Point]::new(275, 10)
    $renameBtn.Size = [System.Drawing.Size]::new(85, 28)
    $instTab.Controls.Add($renameBtn)

    $ctrlPortLabel = New-Object System.Windows.Forms.Label
    $ctrlPortLabel.Text = '控制端口：'
    $ctrlPortLabel.AutoSize = $true
    $ctrlPortLabel.Location = [System.Drawing.Point]::new(380, 15)
    $instTab.Controls.Add($ctrlPortLabel)

    $ctrlPortBox = New-Object System.Windows.Forms.TextBox
    $ctrlPortBox.Location = [System.Drawing.Point]::new(450, 12)
    $ctrlPortBox.Size = [System.Drawing.Size]::new(75, 25)
    $ctrlPortBox.Text = [string]$instState.ControllerPort
    $instTab.Controls.Add($ctrlPortBox)

    # 2. 订阅地址行
    $subLabel = New-Object System.Windows.Forms.Label
    $subLabel.Text = '订阅地址：'
    $subLabel.AutoSize = $true
    $subLabel.Location = [System.Drawing.Point]::new(15, 52)
    $instTab.Controls.Add($subLabel)

    $subBox = New-Object System.Windows.Forms.TextBox
    $subBox.Location = [System.Drawing.Point]::new(85, 48)
    $subBox.Size = [System.Drawing.Size]::new(695, 25)
    $subBox.Text = [string]$instState.SubscriptionUrl
    $instTab.Controls.Add($subBox)

    $loadSubBtn = New-Object System.Windows.Forms.Button
    $loadSubBtn.Text = '加载订阅'
    $loadSubBtn.Location = [System.Drawing.Point]::new(795, 46)
    $loadSubBtn.Size = [System.Drawing.Size]::new(100, 30)
    $instTab.Controls.Add($loadSubBtn)

    # 3. 端口管理与映射配置行
    $portSectionLabel = New-Object System.Windows.Forms.Label
    $portSectionLabel.Text = '代理监听端口：'
    $portSectionLabel.AutoSize = $true
    $portSectionLabel.Location = [System.Drawing.Point]::new(15, 90)
    $instTab.Controls.Add($portSectionLabel)

    $portCombo = New-Object System.Windows.Forms.ComboBox
    $portCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $portCombo.Location = [System.Drawing.Point]::new(115, 86)
    $portCombo.Size = [System.Drawing.Size]::new(100, 25)
    $instTab.Controls.Add($portCombo)

    $addPortBtn = New-Object System.Windows.Forms.Button
    $addPortBtn.Text = '+ 添加端口'
    $addPortBtn.Location = [System.Drawing.Point]::new(225, 84)
    $addPortBtn.Size = [System.Drawing.Size]::new(95, 28)
    $instTab.Controls.Add($addPortBtn)

    $delPortBtn = New-Object System.Windows.Forms.Button
    $delPortBtn.Text = '- 删除当前端口'
    $delPortBtn.Location = [System.Drawing.Point]::new(330, 84)
    $delPortBtn.Size = [System.Drawing.Size]::new(115, 28)
    $instTab.Controls.Add($delPortBtn)

    $portInfoLabel = New-Object System.Windows.Forms.Label
    $portInfoLabel.Text = '当前配置端口绑定的出口节点：(未指派)'
    $portInfoLabel.AutoSize = $true
    $portInfoLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $portInfoLabel.Location = [System.Drawing.Point]::new(460, 90)
    $instTab.Controls.Add($portInfoLabel)

    # 4. 节点列表 (无 Gemini 列)
    $nodeSectionLabel = New-Object System.Windows.Forms.Label
    $nodeSectionLabel.Text = '订阅节点列表 (在下方选择节点，点击指派给指定端口)：'
    $nodeSectionLabel.AutoSize = $true
    $nodeSectionLabel.Location = [System.Drawing.Point]::new(15, 126)
    $instTab.Controls.Add($nodeSectionLabel)

    $instNodeList = New-Object System.Windows.Forms.ListView
    $instNodeList.View = [System.Windows.Forms.View]::Details
    $instNodeList.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
    $instNodeList.FullRowSelect = $true
    $instNodeList.GridLines = $true
    $instNodeList.HideSelection = $false
    $instNodeList.MultiSelect = $true
    $instNodeList.Location = [System.Drawing.Point]::new(15, 150)
    $instNodeList.Size = [System.Drawing.Size]::new(880, 328)
    $null = $instNodeList.Columns.Add('节点名称', 480)
    $null = $instNodeList.Columns.Add('绑定端口', 150)
    $null = $instNodeList.Columns.Add('基础延迟', 120)
    $null = $instNodeList.Columns.Add('网络状态', 110)
    $instTab.Controls.Add($instNodeList)

    # 5. 节点列表下方控制条
    $instCurrentLabel = New-Object System.Windows.Forms.Label
    $instCurrentLabel.Text = '当前选中：未选择'
    $instCurrentLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
    $instCurrentLabel.AutoSize = $true
    $instCurrentLabel.Location = [System.Drawing.Point]::new(15, 492)
    $instTab.Controls.Add($instCurrentLabel)

    $instTestBtn = New-Object System.Windows.Forms.Button
    $instTestBtn.Text = '测基础延迟'
    $instTestBtn.Location = [System.Drawing.Point]::new(525, 486)
    $instTestBtn.Size = [System.Drawing.Size]::new(115, 32)
    $instTab.Controls.Add($instTestBtn)

    $assignBtn = New-Object System.Windows.Forms.Button
    $assignBtn.Text = '设为当前端口出口节点'
    $assignBtn.Location = [System.Drawing.Point]::new(650, 486)
    $assignBtn.Size = [System.Drawing.Size]::new(245, 32)
    $instTab.Controls.Add($assignBtn)

    # 6. 底部状态与操作按钮
    $instStatusLabel = New-Object System.Windows.Forms.Label
    $instStatusLabel.Text = if ([string]::IsNullOrWhiteSpace($instState.SubscriptionUrl)) { '状态：请输入订阅地址并加载。' } else { '状态：已读取设置，点击【保存并启动】开启代理。' }
    $instStatusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $instStatusLabel.AutoEllipsis = $true
    $instStatusLabel.Location = [System.Drawing.Point]::new(15, 535)
    $instStatusLabel.Size = [System.Drawing.Size]::new(370, 36)
    $instTab.Controls.Add($instStatusLabel)

    $instStopBtn = New-Object System.Windows.Forms.Button
    $instStopBtn.Text = '停止本实例核心'
    $instStopBtn.Location = [System.Drawing.Point]::new(400, 535)
    $instStopBtn.Size = [System.Drawing.Size]::new(135, 36)
    $instTab.Controls.Add($instStopBtn)

    $instDelBtn = New-Object System.Windows.Forms.Button
    $instDelBtn.Text = '删除此实例'
    $instDelBtn.Location = [System.Drawing.Point]::new(545, 535)
    $instDelBtn.Size = [System.Drawing.Size]::new(110, 36)
    $instTab.Controls.Add($instDelBtn)

    $instStartBtn = New-Object System.Windows.Forms.Button
    $instStartBtn.Text = '保存并启动本实例 (多端口)'
    $instStartBtn.Location = [System.Drawing.Point]::new(665, 535)
    $instStartBtn.Size = [System.Drawing.Size]::new(230, 36)
    $instTab.Controls.Add($instStartBtn)

    Refresh-InstancePortCombo -State $instState -PortCombo $portCombo
    Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn

    # ---------------- 事件绑定 ----------------
    $renameBtn.Add_Click({
        $newName = $nameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newName)) {
            Show-UiError -Form $Form -Message '实例名称不能为空。'
            return
        }
        $instState.Name = $newName
        Update-InstanceTabTitle -State $instState
        Sync-InstanceStateToSettings -State $instState
        Set-UiStatus -Label $instStatusLabel -Message ('已更新实例名称为：' + $newName)
    }.GetNewClosure())

    $portCombo.Add_SelectedIndexChanged({
        if ($portCombo.SelectedIndex -ge 0) {
            $instState.SelectedPort = [int]$portCombo.SelectedItem
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
        }
    }.GetNewClosure())

    $instNodeList.Add_SelectedIndexChanged({
        if (-not $instState.Refreshing -and $instNodeList.SelectedItems.Count -gt 0) {
            $instState.SelectedNode = [string]$instNodeList.SelectedItems[0].Tag
            $instCurrentLabel.Text = '当前选中：' + $instState.SelectedNode
        }
    }.GetNewClosure())

    $assignBtn.Add_Click({
        $curPort = [int]$instState.SelectedPort
        $selectedItems = @($instNodeList.SelectedItems)
        if ($selectedItems.Count -eq 0) {
            Show-UiError -Form $Form -Message '请先在列表中选中一个节点。'
            return
        }
        $chosenNode = [string]$selectedItems[0].Tag
        foreach ($m in $instState.PortMappings) {
            if ([int]$m.port -eq $curPort) {
                $m.node = $chosenNode
                break
            }
        }
        # 如果当前核心已在运行，尝试即时调用 API 切换
        try {
            $null = Set-MihomoSelection -State $instState -NodeName $chosenNode -GroupName ('GROUP_' + $curPort)
        }
        catch {
        }
        Sync-InstanceStateToSettings -State $instState
        Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $instState.Nodes
        Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
        Set-UiStatus -Label $instStatusLabel -Message ('已将端口 ' + $curPort + ' 的出口节点设置为：' + $chosenNode)
    }.GetNewClosure())

    $addPortBtn.Add_Click({
        # 寻找下一个可用端口号（全局排除主模块与所有实例已用端口）
        $existingPorts = @($instState.PortMappings | ForEach-Object { (Get-PortFromMapping $_) })
        if ($Settings.ContainsKey('proxyPort') -and [int]$Settings.proxyPort -gt 0) {
            $existingPorts += [int]$Settings.proxyPort
        }
        if ($Settings.ContainsKey('portMappings') -and $null -ne $Settings.portMappings) {
            foreach ($pm in $Settings.portMappings) {
                $existingPorts += (Get-PortFromMapping $pm)
            }
        }
        if ($Settings.ContainsKey('customInstances') -and $null -ne $Settings.customInstances) {
            foreach ($c in $Settings.customInstances) {
                if ($null -ne $c.portMappings) {
                    foreach ($pm in $c.portMappings) {
                        $existingPorts += (Get-PortFromMapping $pm)
                    }
                }
            }
        }
        $existingPorts = @($existingPorts | Select-Object -Unique)

        $candidatePort = 7880
        while ($candidatePort -in $existingPorts -or (Test-LocalPortInUse -Port $candidatePort)) {
            $candidatePort++
        }
        $newPort = Show-AddPortDialog -Owner $Form -DefaultPort $candidatePort
        if ($newPort -gt 0) {
            if ($newPort -in $existingPorts) {
                Show-UiError -Form $Form -Message ('端口 ' + $newPort + ' 已在配置列表中（可能已被主模块或其他实例占用）。')
                return
            }
            if (Test-LocalPortInUse -Port $newPort) {
                Show-UiError -Form $Form -Message ('本地端口 ' + $newPort + ' 已被其他进程占用。')
                return
            }
            $instState.PortMappings += @{
                port = $newPort
                node = ''
            }
            $instState.SelectedPort = $newPort
            Refresh-InstancePortCombo -State $instState -PortCombo $portCombo
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
            Update-InstanceTabTitle -State $instState
            Sync-InstanceStateToSettings -State $instState
            Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $instState.Nodes
            Set-UiStatus -Label $instStatusLabel -Message ('已添加端口 ' + $newPort + '。请点击【保存并启动】使其生效。')
        }
    }.GetNewClosure())

    $delPortBtn.Add_Click({
        if ($instState.PortMappings.Count -le 1) {
            Show-UiError -Form $Form -Message '每个代理实例至少需要保留一个监听端口。'
            return
        }
        $curPort = [int]$instState.SelectedPort
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $Form,
            ('确定要删除代理端口 ' + $curPort + ' 吗？'),
            '删除端口确认',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $instState.PortMappings = @($instState.PortMappings | Where-Object { [int]$_.port -ne $curPort })
            $instState.SelectedPort = Get-FirstPortFromMappings -Mappings $instState.PortMappings
            Refresh-InstancePortCombo -State $instState -PortCombo $portCombo
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
            Update-InstanceTabTitle -State $instState
            Sync-InstanceStateToSettings -State $instState
            Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $instState.Nodes
            Set-UiStatus -Label $instStatusLabel -Message ('已删除端口 ' + $curPort + '。请点击【保存并启动】更新监听。')
        }
    }.GetNewClosure())

    $loadSubBtn.Add_Click({
        if ($instState.Busy) {
            return
        }
        $instState.Busy = $true
        $loadSubBtn.Enabled = $false
        $instTestBtn.Enabled = $false
        $instStartBtn.Enabled = $false
        try {
            $instSubUrl = ConvertTo-ValidatedSubscriptionUrl -Text $subBox.Text
            $instCtrlPort = ConvertTo-ValidatedPort -Text $ctrlPortBox.Text -FieldName 'Mihomo 控制端口'
            $instState.SubscriptionUrl = $instSubUrl
            $instState.ControllerPort = $instCtrlPort

            Set-UiStatus -Label $instStatusLabel -Message '状态：正在启动专属核心并加载订阅节点……'
            $null = Write-MihomoConfig -State $instState -SubscriptionUrl $instSubUrl -ControllerPort $instCtrlPort -PortMappings $instState.PortMappings
            $null = Start-OrReuseMihomo -State $instState -SubscriptionUrl $instSubUrl
            $null = Update-MihomoProvider -State $instState
            $nodes = @(Wait-MihomoNodes -State $instState)
            $instState.Nodes = $nodes
            Sync-InstanceStateToSettings -State $instState
            Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $nodes
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
            Set-UiStatus -Label $instStatusLabel -Message ('状态：订阅加载成功，发现 ' + $nodes.Count + ' 个可用节点。')
        }
        catch {
            Set-UiStatus -Label $instStatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
            Show-UiError -Form $Form -Message $_.Exception.Message
        }
        finally {
            $instState.Busy = $false
            $loadSubBtn.Enabled = $true
            $instTestBtn.Enabled = $true
            $instStartBtn.Enabled = $true
        }
    }.GetNewClosure())

    $instTestBtn.Add_Click({
        if ($instState.Busy) {
            return
        }
        if ($instState.Nodes.Count -eq 0 -or $instNodeList.Items.Count -eq 0) {
            Show-UiError -Form $Form -Message '请先点击“加载订阅”。'
            return
        }
        $selectedItems = @($instNodeList.SelectedItems)
        if ($selectedItems.Count -eq 0) {
            Show-UiError -Form $Form -Message '请先框选一个或多个节点，再点击“测基础延迟”。'
            return
        }
        $selectedCount = $selectedItems.Count
        $instState.Busy = $true
        $loadSubBtn.Enabled = $false
        $instTestBtn.Enabled = $false
        $instStartBtn.Enabled = $false
        try {
            Set-UiStatus -Label $instStatusLabel -Message ('状态：正在测试已选的 ' + $selectedCount + ' 个节点延迟……')
            foreach ($item in $selectedItems) {
                $nodeName = [string]$item.Tag
                $item.SubItems[2].Text = '测试中…'
                $item.SubItems[3].Text = '测试中'
                [System.Windows.Forms.Application]::DoEvents()
                $result = Test-MihomoNode -State $instState -NodeName $nodeName
                $item.SubItems[2].Text = [string]$result.DelayText
                $item.SubItems[3].Text = [string]$result.Status
                [System.Windows.Forms.Application]::DoEvents()
            }
            Set-UiStatus -Label $instStatusLabel -Message ('状态：已完成 ' + $selectedCount + ' 个选中节点延迟测试。')
        }
        catch {
            Set-UiStatus -Label $instStatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
            Show-UiError -Form $Form -Message $_.Exception.Message
        }
        finally {
            $instState.Busy = $false
            $loadSubBtn.Enabled = $true
            $instTestBtn.Enabled = $true
            $instStartBtn.Enabled = $true
        }
    }.GetNewClosure())

    $instStartBtn.Add_Click({
        if ($instState.Busy) {
            return
        }
        $instState.Busy = $true
        $loadSubBtn.Enabled = $false
        $instTestBtn.Enabled = $false
        $instStartBtn.Enabled = $false
        try {
            $instSubUrl = ConvertTo-ValidatedSubscriptionUrl -Text $subBox.Text
            $instCtrlPort = ConvertTo-ValidatedPort -Text $ctrlPortBox.Text -FieldName 'Mihomo 控制端口'
            $instState.SubscriptionUrl = $instSubUrl
            $instState.ControllerPort = $instCtrlPort

            if ($instState.PortMappings.Count -eq 0) {
                throw '本实例未配置任何代理监听端口。'
            }

            Set-UiStatus -Label $instStatusLabel -Message '状态：正在写入配置并启动实例专属核心……'
            $null = Write-MihomoConfig -State $instState -SubscriptionUrl $instSubUrl -ControllerPort $instCtrlPort -PortMappings $instState.PortMappings
            $null = Start-OrReuseMihomo -State $instState -SubscriptionUrl $instSubUrl
            $null = Update-MihomoProvider -State $instState
            $nodes = @(Wait-MihomoNodes -State $instState)
            $instState.Nodes = $nodes

            # 遍历端口，切到已分配的节点
            $assignedCount = 0
            foreach ($m in $instState.PortMappings) {
                $port = Get-PortFromMapping -Mapping $m
                $nodeName = [string]$m.node
                $groupName = 'GROUP_' + $port
                if (-not [string]::IsNullOrWhiteSpace($nodeName)) {
                    $matched = @($nodes | Where-Object { [string]$_.Name -eq $nodeName })
                    if ($matched.Count -gt 0) {
                        try {
                            $null = Set-MihomoSelection -State $instState -NodeName $nodeName -GroupName $groupName
                            $assignedCount++
                        }
                        catch {
                        }
                    }
                }
            }

            Sync-InstanceStateToSettings -State $instState
            Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $nodes
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
            $allPorts = @($instState.PortMappings | ForEach-Object { [string]$_.port }) -join ', '
            Set-UiStatus -Label $instStatusLabel -Message ('状态：实例运行中！监听端口: ' + $allPorts + '；控制端口: ' + $instCtrlPort + '。已绑定 ' + $assignedCount + ' 个端口出口节点。')
        }
        catch {
            Set-UiStatus -Label $instStatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
            Show-UiError -Form $Form -Message $_.Exception.Message
        }
        finally {
            $instState.Busy = $false
            $loadSubBtn.Enabled = $true
            $instTestBtn.Enabled = $true
            $instStartBtn.Enabled = $true
        }
    }.GetNewClosure())

    $instStopBtn.Add_Click({
        if ($instState.Busy) {
            return
        }
        try {
            $stopped = Stop-ManagedMihomo -State $instState
            Refresh-InstanceNodeList -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -Nodes $instState.Nodes
            Update-InstancePortInfo -State $instState -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn
            if ($stopped) {
                Set-UiStatus -Label $instStatusLabel -Message '状态：已停止本实例专属 Mihomo 核心（端口已停止工作）。'
            }
            else {
                Set-UiStatus -Label $instStatusLabel -Message '状态：没有找到本实例仍在运行的核心进程。'
            }
        }
        catch {
            Set-UiStatus -Label $instStatusLabel -Message ('状态：' + $_.Exception.Message) -IsError $true
            Show-UiError -Form $Form -Message $_.Exception.Message
        }
    }.GetNewClosure())

    $instDelBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $Form,
            ('确定要删除代理实例【' + $instState.Name + '】吗？' + [Environment]::NewLine + '这会停止其核心并清理配置文件。'),
            '删除实例确认',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        try {
            $null = Stop-ManagedMihomo -State $instState
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $Form,
                ('停止实例核心时发生错误：' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + '已中止删除操作，以防留下不可控的孤儿进程。'),
                '删除实例中止',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        # 严格验证核心是否已彻底停止，防止残留未控孤儿进程（即使元数据损坏也能根据端口与命令行精准识别）
        $managed = Get-ManagedMihomoProcess -State $instState
        $activePid = if ($null -ne $managed) { [int]$managed.Process.Id } else { 0 }

        if ($activePid -eq 0) {
            $portsToCheck = @([int]$instState.ControllerPort)
            if ($instState.ContainsKey('PortMappings') -and $null -ne $instState.PortMappings) {
                foreach ($m in $instState.PortMappings) {
                    $portsToCheck += (Get-PortFromMapping -Mapping $m)
                }
            }
            $portsToCheck = @($portsToCheck | Where-Object { $_ -gt 0 } | Select-Object -Unique)
            foreach ($p in $portsToCheck) {
                $conns = @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
                foreach ($conn in $conns) {
                    $owningPid = [int]$conn.OwningProcess
                    if ($owningPid -gt 0) {
                        $proc = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
                        if ($null -ne $proc -and $proc.ProcessName -match '(?i)^mihomo$') {
                            $cim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $owningPid) -ErrorAction SilentlyContinue
                            $cmd = if ($null -ne $cim) { [string]$cim.CommandLine } else { '' }
                            if ($cmd.ToLowerInvariant().Contains($instState.ConfigPath.ToLowerInvariant())) {
                                $activePid = $owningPid
                                break
                            }
                        }
                    }
                }
                if ($activePid -gt 0) { break }
            }
        }

        if ($activePid -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                $Form,
                ('无法完全停止该实例的核心进程 (PID ' + $activePid + ')。' + [Environment]::NewLine + '已中止删除操作，以防产生不可控的后台孤儿进程。请先手动结束该进程后重试。'),
                '删除实例中止',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        # 校验实例 ID 与目录越界
        if ($instState.Id -notmatch '^[a-zA-Z0-9_\-]+$') {
            throw ('非法实例标识符: ' + $instState.Id)
        }
        $instancesParent = [System.IO.Path]::GetFullPath((Join-Path -Path $ToolRoot -ChildPath 'runtime\instances'))
        $instDir = [System.IO.Path]::GetFullPath((Join-Path -Path $instancesParent -ChildPath $instState.Id))
        if (-not $instDir.StartsWith($instancesParent, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('非法实例路径越界: ' + $instDir)
        }

        if (Test-Path -LiteralPath $instDir -PathType Container) {
            try {
                Remove-Item -LiteralPath $instDir -Recurse -Force -ErrorAction Stop
            }
            catch {
            }

            if (Test-Path -LiteralPath $instDir -PathType Container) {
                [System.Windows.Forms.MessageBox]::Show(
                    $Form,
                    ('无法删除实例目录（文件可能被占用或权限不足）：' + [Environment]::NewLine + $instDir + [Environment]::NewLine + '已中止删除操作并保留配置，防止丢失管理入口。'),
                    '删除实例失败',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                return
            }
        }

        # 从 settings 中移除
        $Settings.customInstances = @($Settings.customInstances | Where-Object { -not [string]::Equals([string]$_.id, [string]$instState.Id, [StringComparison]::OrdinalIgnoreCase) })
        $null = Save-Settings -Settings $Settings -Path $SettingsPath

        $TabControl.TabPages.Remove($instTab)
        if ($TabControl.TabPages.Count -gt 1) {
            $TabControl.SelectedIndex = 0
        }
    }.GetNewClosure())

    # 启动时检测后台是否已有正在运行的核心，若有则秒级恢复节点并在列表中标绿已工作的端口
    $null = Restore-ActiveProxiesFromRunningCore -State $instState -ListView $instNodeList -CurrentLabel $instCurrentLabel -PortInfoLabel $portInfoLabel -AssignBtn $assignBtn -StatusLabel $instStatusLabel -IsAntigravity $false

    if ($InsertIndex -ge 0 -and $InsertIndex -lt $TabControl.TabPages.Count) {
        $TabControl.TabPages.Insert($InsertIndex, $instTab)
    }
    else {
        $null = $TabControl.TabPages.Add($instTab)
    }

    return $instTab
}

# 依次渲染所有自定义实例 Tab
foreach ($instConfig in @($settings.customInstances)) {
    $null = Add-CustomInstanceTabPage -TabControl $tabControl -ToolRoot $toolRoot -InstanceConfig $instConfig -Settings $settings -SettingsPath $settingsPath -Form $form
}

# -------------------------------------------------------------
# 添加 "+ 添加新代理实例" Tab
# -------------------------------------------------------------
$addTab = New-Object System.Windows.Forms.TabPage
$addTab.Text = '+ 添加新代理实例'
$tabControl.TabPages.Add($addTab)

$tabControl.Add_SelectedIndexChanged({
    if ($tabControl.SelectedTab -eq $addTab) {
        # 计算新实例序号、端口与ID
        $existingCount = $settings.customInstances.Count
        $newIndex = $existingCount + 1
        $newName = '应用代理 ' + $newIndex
        $existingIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $settings.customInstances) {
            if ($null -ne $c.id) { $null = $existingIds.Add([string]$c.id) }
        }
        do {
            $newId = 'app-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
        } while ($existingIds.Contains($newId))

        # 查找未占用的控制端口 (>= 19091)
        $usedCtrlPorts = @(19090)
        if ($settings.ContainsKey('controllerPort') -and [int]$settings.controllerPort -gt 0) {
            $usedCtrlPorts += [int]$settings.controllerPort
        }
        foreach ($c in $settings.customInstances) {
            $usedCtrlPorts += [int]$c.controllerPort
        }
        $candCtrlPort = 19091
        while ($candCtrlPort -in $usedCtrlPorts -or (Test-LocalPortInUse -Port $candCtrlPort)) {
            $candCtrlPort++
        }

        # 查找未占用的代理端口 (>= 7880，全局排除主模块与所有实例)
        $usedProxyPorts = @(7899)
        if ($settings.ContainsKey('proxyPort') -and [int]$settings.proxyPort -gt 0) {
            $usedProxyPorts += [int]$settings.proxyPort
        }
        if ($settings.ContainsKey('portMappings') -and $null -ne $settings.portMappings) {
            foreach ($pm in $settings.portMappings) {
                $usedProxyPorts += (Get-PortFromMapping $pm)
            }
        }
        foreach ($c in $settings.customInstances) {
            if ($null -ne $c.portMappings) {
                foreach ($pm in $c.portMappings) {
                    $usedProxyPorts += (Get-PortFromMapping $pm)
                }
            }
        }
        $usedProxyPorts = @($usedProxyPorts | Select-Object -Unique)

        $candProxyPort = 7880
        while ($candProxyPort -in $usedProxyPorts -or (Test-LocalPortInUse -Port $candProxyPort)) {
            $candProxyPort++
        }

        $newInstanceConfig = @{
            id = $newId
            name = $newName
            subscriptionUrl = ''
            controllerPort = $candCtrlPort
            portMappings = @(
                @{ port = $candProxyPort; node = '' }
            )
            selectedPort = $candProxyPort
        }

        $settings.customInstances += $newInstanceConfig
        $null = Save-Settings -Settings $settings -Path $settingsPath

        # 插入在 "+" Tab 之前
        $insertIdx = $tabControl.TabPages.IndexOf($addTab)
        $newTab = Add-CustomInstanceTabPage -TabControl $tabControl -ToolRoot $toolRoot -InstanceConfig $newInstanceConfig -Settings $settings -SettingsPath $settingsPath -Form $form -InsertIndex $insertIdx
        $tabControl.SelectedTab = $newTab
    }
}.GetNewClosure())

$form.Add_Shown({
    $form.Activate()
    return
}.GetNewClosure())

[System.Windows.Forms.Application]::Run($form)
return
