# Antigravity 切回 Clash 7898（Codex，2026-09-04）
# 完全结束 Antigravity 进程树，备份并改写桌面/开始菜单快捷方式，之后统一从 Clash 7898 启动。
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# 不修改用户级代理环境变量，其他应用继续保留原有代理端口。
$toolRoot = $PSScriptRoot
$clashPort = 7898
$launcherPath = Join-Path -Path $toolRoot -ChildPath 'launch-clash-antigravity.ps1'
$agyLauncherPath = Join-Path -Path $toolRoot -ChildPath 'run-agy-with-clash.ps1'
$backupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\clash-shortcuts-backup.json'
$agyWrapperPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy\bin\agy-proxy.cmd'
$agyWrapperBackupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\agy-proxy.cmd.backup'
$projectAgyWrapperPath = Join-Path -Path $toolRoot -ChildPath 'agy-proxy.cmd'
$projectAgyWrapperBackupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\agy-proxy-project.cmd.backup'
$installedIdeCliPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\bin\antigravity-ide.cmd'
$installedIdeCliBackupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\antigravity-ide.cmd.backup'
$legacyLauncherRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Antigravity\launchers'
$legacyV2LauncherPath = Join-Path -Path $legacyLauncherRoot -ChildPath 'launch-antigravity-7898.ps1'
$legacyIdeLauncherPath = Join-Path -Path $legacyLauncherRoot -ChildPath 'launch-antigravity-ide-7898.ps1'
$legacyV2BackupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\launch-antigravity-7898.ps1.backup'
$legacyIdeBackupPath = Join-Path -Path $toolRoot -ChildPath 'runtime\launch-antigravity-ide-7898.ps1.backup'

function Get-NormalizedPath {
    <# 将 Windows 路径规范化，供进程和快捷方式匹配使用。 #>
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\').ToLowerInvariant()
    }
    catch {
        return $Path.TrimEnd('\').ToLowerInvariant()
    }
}

function Test-ClashPort {
    <# 检查 Clash 7898 是否监听，未启动时只给出警告而不阻止快捷方式切换。 #>
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

function Get-AntigravityProcessRecords {
    <# 只收集已知 Antigravity、language service 和 agy CLI 进程，避免误杀其他程序。 #>
    $knownPaths = @()
    $knownRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $knownPaths += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\antigravity\Antigravity.exe'
        $knownPaths += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\antigravity\resources\bin\language_server.exe'
        $knownPaths += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\Antigravity IDE.exe'
        $knownPaths += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE\resources\app\extensions\antigravity\bin\language_server_windows_x64.exe'
        $knownPaths += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy\bin\agy.exe'
        $knownRoots += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\antigravity'
        $knownRoots += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Antigravity IDE'
        $knownRoots += Join-Path -Path $env:LOCALAPPDATA -ChildPath 'agy'
    }
    # 读取 GUI 保存的自定义安装路径，避免在公开源码中固化个人目录。Codex，2026-09-23。
    $settingsPath = Join-Path -Path $toolRoot -ChildPath 'config\settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedPath = [string]$settings.antigravityPath
            if (-not [string]::IsNullOrWhiteSpace($savedPath)) {
                $knownPaths += $savedPath
                $knownRoots += Split-Path -Path $savedPath -Parent
            }
        }
        catch {
            Write-Verbose ('无法读取已保存的 Antigravity 路径：' + $_.Exception.Message)
        }
    }

    $normalizedPaths = @($knownPaths | ForEach-Object { Get-NormalizedPath -Path $_ })
    $normalizedRoots = @($knownRoots | ForEach-Object { Get-NormalizedPath -Path $_ })
    $knownNames = @('Antigravity.exe', 'Antigravity IDE.exe', 'language_server.exe', 'language_server_windows_x64.exe', 'agy.exe')
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        throw ('无法读取进程列表，未执行退出操作：' + $_.Exception.Message)
    }

    $matches = @()
    foreach ($process in $processes) {
        $executablePath = Get-NormalizedPath -Path ([string]$process.ExecutablePath)
        $commandLine = [string]$process.CommandLine
        $pathMatch = $normalizedPaths -contains $executablePath
        $nameMatch = $knownNames -contains ([string]$process.Name)
        $rootMatch = $false
        foreach ($root in $normalizedRoots) {
            if (-not [string]::IsNullOrWhiteSpace($root) -and $commandLine.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $rootMatch = $true
                break
            }
        }
        if ($pathMatch -or ($nameMatch -and $rootMatch)) {
            $matches += $process
        }
    }

    return @($matches | Sort-Object -Property ProcessId -Unique)
}

function Stop-AntigravityProcesses {
    <# 先请求 Antigravity 正常退出，再强制清理残留主进程和 language service。 #>
    $records = @(Get-AntigravityProcessRecords)
    if ($records.Count -eq 0) {
        return 0
    }

    $processIds = @($records | ForEach-Object { [int]$_.ProcessId })
    foreach ($processId in $processIds) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $null = $process.CloseMainWindow()
            }
        }
        catch {
            Write-Verbose ('跳过已退出进程 ' + $processId + '：' + $_.Exception.Message)
        }
    }

    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-AntigravityProcessRecords | Where-Object { $processIds -contains [int]$_.ProcessId })
        if ($remaining.Count -eq 0) {
            return $processIds.Count
        }
    }

    foreach ($processId in $processIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        catch {
            Write-Verbose ('强制退出时跳过进程 ' + $processId + '：' + $_.Exception.Message)
        }
    }

    Start-Sleep -Milliseconds 500
    $remaining = @(Get-AntigravityProcessRecords | Where-Object { $processIds -contains [int]$_.ProcessId })
    if ($remaining.Count -gt 0) {
        throw ('仍有 Antigravity 相关进程未退出：' + (($remaining | ForEach-Object { $_.ProcessId }) -join ', '))
    }

    return $processIds.Count
}

function Stop-StandaloneMihomo {
    <# 按项目 PID、启动时间、可执行文件和配置路径校验后停止独立 Mihomo。 #>
    $metadataPath = Join-Path -Path $toolRoot -ChildPath 'runtime\mihomo-process.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $false
    }

    $metadata = $null
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $metadata = [System.IO.File]::ReadAllText($metadataPath, $utf8NoBom) | ConvertFrom-Json
        $managedPid = 0
        if (-not [int]::TryParse([string]$metadata.pid, [ref]$managedPid) -or $managedPid -le 0) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
            return $false
        }

        $process = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
        $corePath = Get-NormalizedPath -Path (Join-Path -Path $toolRoot -ChildPath 'mihomo.exe')
        $actualPath = ''
        if ($null -ne $process) {
            $actualPath = Get-NormalizedPath -Path ([string]$process.Path)
        }
        if ($null -eq $process -or $process.ProcessName -notmatch '(?i)^mihomo$' -or ($actualPath -and $actualPath -ne $corePath)) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
            return $false
        }

        $storedStart = [DateTime]::Parse(
            [string]$metadata.startTimeUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $difference = [Single][Math]::Abs(($process.StartTime.ToUniversalTime() - $storedStart).TotalSeconds)
        if ($difference -gt [Single]10) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
            return $false
        }

        $configPath = Get-NormalizedPath -Path (Join-Path -Path $toolRoot -ChildPath 'runtime\mihomo.yaml')
        $cimProcess = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $managedPid) -ErrorAction Stop
        $commandLine = ([string]$cimProcess.CommandLine).ToLowerInvariant().Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine.IndexOf($configPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
            return $false
        }

        Stop-Process -Id $managedPid -Force -ErrorAction Stop
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if ($null -eq (Get-Process -Id $managedPid -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
                return $true
            }
            Start-Sleep -Milliseconds 200
        }

        throw '独立 Mihomo 进程没有在预期时间内停止。'
    }
    catch {
        throw ('停止独立 Mihomo 失败：' + $_.Exception.Message)
    }
}

function Get-AntigravityShortcuts {
    <# 扫描桌面和开始菜单中属于 Antigravity 的快捷方式。 #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Shell
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
                $shortcut = $Shell.CreateShortcut($file.FullName)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $targetPath = [string]$shortcut.TargetPath
                $arguments = [string]$shortcut.Arguments
                $isNamed = $baseName -in @('Antigravity', 'Antigravity IDE')
                $isLegacy = $arguments -match '(?i)launch-antigravity(?:-ide)?(?:-7898)?\.ps1'
                $isExecutable = $targetPath -match '(?i)\\Antigravity(?: IDE)?\.exe$'
                if ($isNamed -or $isLegacy -or $isExecutable) {
                    $launchTarget = if ($baseName -match '(?i)IDE' -or $targetPath -match '(?i)Antigravity IDE\.exe$' -or $arguments -match '(?i)launch-antigravity-ide') { 'ide' } else { 'v2' }
                    $records += [pscustomobject]@{
                        Path = $file.FullName
                        LaunchTarget = $launchTarget
                        TargetPath = $targetPath
                        Arguments = $arguments
                        WorkingDirectory = [string]$shortcut.WorkingDirectory
                        Description = [string]$shortcut.Description
                        Hotkey = [string]$shortcut.Hotkey
                        IconLocation = [string]$shortcut.IconLocation
                        WindowStyle = [int]$shortcut.WindowStyle
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

function Save-ShortcutBackup {
    <# 首次切换前保存快捷方式原始信息，避免后续无法恢复专用代理入口。 #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return $false
    }

    $backup = [ordered]@{
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        shortcuts = @($Records | ForEach-Object {
            [ordered]@{
                path = [string]$_.Path
                launchTarget = [string]$_.LaunchTarget
                targetPath = [string]$_.TargetPath
                arguments = [string]$_.Arguments
                workingDirectory = [string]$_.WorkingDirectory
                description = [string]$_.Description
                hotkey = [string]$_.Hotkey
                iconLocation = [string]$_.IconLocation
                windowStyle = [int]$_.WindowStyle
            }
        })
    }
    $json = $backup | ConvertTo-Json -Depth 6
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
    return $true
}

function Set-FilePortLiteral {
    <# 备份并把脚本或命令文件中的旧本地端口统一替换为 Clash 7898。 #>
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
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $original = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        [System.IO.File]::WriteAllText($BackupPath, $original, $utf8NoBom)
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $text = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
    $updated = $text.Replace([string]$OldPort, [string]$NewPort)
    [System.IO.File]::WriteAllText($Path, $updated, $utf8NoBom)
    return $true
}

function Set-ShortcutToClash {
    <# 把快捷方式改为调用 7898 启动器，同时保留原图标和显示属性。 #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Shell,

        [Parameter(Mandatory = $true)]
        [object]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Launcher
    )

    $shortcut = $Shell.CreateShortcut([string]$Record.Path)
    $powershellPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        $powershellPath = (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction Stop).Source
    }
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $Launcher + '" -Target ' + [string]$Record.LaunchTarget
    $shortcut.WorkingDirectory = $toolRoot
    $shortcut.Description = 'Antigravity 通过 Clash 7898 启动'
    $shortcut.Save()
    return
}

function Set-AgyWrapperToClash {
    <# 将 PATH 中的 agy-proxy 命令切换到 Clash 7898，并保留原脚本备份。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WrapperPath,

        [Parameter(Mandatory = $true)]
        [string]$Launcher,

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

    $wrapperText = @"
@echo off
setlocal
set "SCRIPT_PATH=$Launcher"
powershell.exe -NoLogo -NoProfile -NonInteractive -File "%SCRIPT_PATH%" %*
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
"@
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($WrapperPath, $wrapperText, $utf8NoBom)
    return
}

function Set-LegacyLauncherToClash {
    <# 将旧桌面桥接脚本改为直接调用 Clash 启动器，避免任何旧入口回到独立代理。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ide', 'v2')]
        [string]$LaunchTarget,

        [Parameter(Mandatory = $true)]
        [string]$Launcher
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $original = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        [System.IO.File]::WriteAllText($BackupPath, $original, $utf8NoBom)
    }
    $powershellPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lines = @(
        '# Legacy Antigravity launcher redirected to Clash 7898 (Codex, 2026-09-04).'
        '$ErrorActionPreference = ''Stop'''
        ('$launcherPath = ''' + $Launcher + '''')
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

try {
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $agyLauncherPath -PathType Leaf)) {
        throw '找不到 Clash 启动器文件，请确认项目目录完整。'
    }

    $stoppedApps = Stop-AntigravityProcesses
    $stoppedMihomo = Stop-StandaloneMihomo
    $installedIdeChanged = Set-FilePortLiteral -Path $installedIdeCliPath -BackupPath $installedIdeCliBackupPath -OldPort 17890 -NewPort $clashPort
    $installedIdeChanged = (Set-FilePortLiteral -Path $installedIdeCliPath -BackupPath $installedIdeCliBackupPath -OldPort 7899 -NewPort $clashPort) -or $installedIdeChanged
    $legacyV2Changed = Set-LegacyLauncherToClash -Path $legacyV2LauncherPath -BackupPath $legacyV2BackupPath -LaunchTarget 'v2' -Launcher $launcherPath
    $legacyIdeChanged = Set-LegacyLauncherToClash -Path $legacyIdeLauncherPath -BackupPath $legacyIdeBackupPath -LaunchTarget 'ide' -Launcher $launcherPath
    $shell = New-Object -ComObject WScript.Shell
    $shortcutRecords = @(Get-AntigravityShortcuts -Shell $shell)
    if ($shortcutRecords.Count -eq 0) {
        throw '没有找到桌面或开始菜单中的 Antigravity 快捷方式。'
    }
    $backupCreated = Save-ShortcutBackup -Records $shortcutRecords -Path $backupPath
    foreach ($record in $shortcutRecords) {
        Set-ShortcutToClash -Shell $shell -Record $record -Launcher $launcherPath
    }
    Set-AgyWrapperToClash -WrapperPath $agyWrapperPath -Launcher $agyLauncherPath -BackupPath $agyWrapperBackupPath
    Set-AgyWrapperToClash -WrapperPath $projectAgyWrapperPath -Launcher $agyLauncherPath -BackupPath $projectAgyWrapperBackupPath

    if (Test-ClashPort -Port $clashPort) {
        Write-Output ('Clash 7898 当前正在监听。')
    }
    else {
        Write-Warning ('Clash 7898 当前没有监听；快捷方式已切换，启动前请先打开 Clash。')
    }
    Write-Output ('已退出 Antigravity 相关进程 ' + $stoppedApps + ' 个。')
    if ($stoppedMihomo) {
        Write-Output '已停止本项目独立 Mihomo。'
    }
    else {
        Write-Output '没有找到需要停止的本项目独立 Mihomo。'
    }
    Write-Output ('已切换 ' + $shortcutRecords.Count + ' 个 Antigravity 快捷方式到 Clash 7898。')
    Write-Output ('agy-proxy 已切换到 Clash 7898：' + $agyWrapperPath)
    Write-Output '未修改用户级代理环境变量，其他应用继续使用原有 7897。'
    Write-Output '全局和项目内 agy-proxy 包装器已切换到 Clash 7898。'
    if ($installedIdeChanged) {
        Write-Output 'Antigravity IDE 直接 CLI 已切换到 Clash 7898。'
    }
    if ($legacyV2Changed -or $legacyIdeChanged) {
        Write-Output '旧 Antigravity 桥接入口已切换到 Clash 7898。'
    }
    if ($backupCreated) {
        Write-Output ('原快捷方式信息已备份到：' + $backupPath)
    }
    else {
        Write-Output ('快捷方式备份已存在，未覆盖：' + $backupPath)
    }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
