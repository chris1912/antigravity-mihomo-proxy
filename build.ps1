<#
.SYNOPSIS
    Antigravity & 通用应用独立多核心代理 - 项目构建与便携打包脚本
.DESCRIPTION
    1. 语法与 AST 合规性校验（确保 Windows PowerShell 5.1 / PowerShell 7 零报错）
    2. 仅在指定 -Clean 或 -CleanOnly 时清理日志与运行期缓存
    3. 校验并确保 mihomo.exe 核心就绪
    4. 生成可直接移植到其他电脑运行的便携发行包 (Portable ZIP)
.PARAMETER Package
    是否生成发布压缩包（默认 $true）
.PARAMETER Validate
    仅执行代码语法、回归脚本与环境合规性检查
.PARAMETER Clean
    在打包前深度清理本地运行期实例数据与日志
.PARAMETER CleanOnly
    仅执行项目临时文件清理，不打包
.PARAMETER OutputDir
    打包输出目录（默认为项目上一级的 dist 目录）
#>

[CmdletBinding()]
param(
    [switch]$Package = $true,
    [switch]$Validate = $false,
    [switch]$Clean = $false,
    [switch]$CleanOnly = $false,
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Antigravity & 通用应用代理 - 项目构建与打包工具" -ForegroundColor Cyan
Write-Host "  工程目录: $projectRoot" -ForegroundColor Gray
Write-Host "==================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. 代码质量与 AST 语法解析检查
# -----------------------------------------------------------------------------
Write-Host "`n[1/4] 正在执行 PowerShell 语法与 AST 解析检查..." -ForegroundColor Yellow

$scriptFiles = Get-ChildItem -Path $projectRoot -Filter '*.ps1' -File
$testsDir = Join-Path -Path $projectRoot -ChildPath 'tests'
if (Test-Path -LiteralPath $testsDir -PathType Container) {
    $scriptFiles += @(Get-ChildItem -Path $testsDir -Filter '*.ps1' -File)
}
$hasSyntaxErrors = $false

foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "  [FAIL] $($file.Name): 发现 $($errors.Count) 处语法错误!" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "    Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Red
        }
        $hasSyntaxErrors = $true
    }
    else {
        Write-Host "  [OK] $($file.Name) - AST 语法有效 (0 错误)" -ForegroundColor Green
    }
}

if ($hasSyntaxErrors) {
    throw "构建中断：代码存在语法错误，请修复后再打包。"
}

# -----------------------------------------------------------------------------
# 验证模式分支 (-Validate)
# -----------------------------------------------------------------------------
if ($Validate) {
    Write-Host "`n[验证模式] 正在执行自动化测试套件与运行环境检查..." -ForegroundColor Cyan

    $testScript = Join-Path -Path $projectRoot -ChildPath 'tests\Test-ProxyCore.ps1'
    if (Test-Path -LiteralPath $testScript -PathType Leaf) {
        Write-Host "  运行单元与集成测试: tests/Test-ProxyCore.ps1" -ForegroundColor Yellow
        $testOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testScript
        Write-Host ($testOutput -join "`n")
        if ($LASTEXITCODE -ne 0) {
            throw "自动化测试套件执行失败，退出代码: $LASTEXITCODE"
        }
    }
    else {
        throw "验证失败：未找到核心回归测试脚本 tests/Test-ProxyCore.ps1！"
    }

    # 校验核心状态
    $corePath = Join-Path -Path $projectRoot -ChildPath 'mihomo.exe'
    if (Test-Path -LiteralPath $corePath -PathType Leaf) {
        $coreInfo = & $corePath -v 2>$null | Select-Object -First 1
        Write-Host "  [OK] Mihomo 核心就绪: $coreInfo" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] 根目录下未找到 mihomo.exe 核心文件" -ForegroundColor Yellow
    }

    Write-Host "`n[OK] 代码合规性与验证检查全部通过 (0 错误)！" -ForegroundColor Green
    return
}

# -----------------------------------------------------------------------------
# 2. 清理运行时中间文件、日志与测试残留 (仅在 -Clean 或 -CleanOnly 时执行)
# -----------------------------------------------------------------------------
if ($Clean -or $CleanOnly) {
    Write-Host "`n[2/4] 正在深度清理本地运行数据 (-Clean)..." -ForegroundColor Yellow

    # 安全检查：严禁在核心仍在后台运行时执行清理
    $corePath = [System.IO.Path]::GetFullPath((Join-Path -Path $projectRoot -ChildPath 'mihomo.exe'))
    $projectRootNorm = [System.IO.Path]::GetFullPath($projectRoot)
    $runningCores = @()
    $candidateProcesses = @(Get-Process -Name mihomo -ErrorAction SilentlyContinue)
    foreach ($proc in $candidateProcesses) {
        $pId = $proc.Id
        $procPath = $null
        try { $procPath = $proc.Path } catch {}
        $cmdLine = $null
        try {
            $cim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $pId) -ErrorAction SilentlyContinue
            if ($null -ne $cim) {
                if ([string]::IsNullOrWhiteSpace($procPath)) { $procPath = [string]$cim.ExecutablePath }
                $cmdLine = [string]$cim.CommandLine
            }
        } catch {}

        # 严格检查进程归属：路径匹配、命令行包含项目路径；若都无法读取则按安全优先策略报错阻断
        $belongsToProject = $false
        if (-not [string]::IsNullOrWhiteSpace($procPath) -and [string]::Equals([System.IO.Path]::GetFullPath($procPath), $corePath, [StringComparison]::OrdinalIgnoreCase)) {
            $belongsToProject = $true
        } elseif (-not [string]::IsNullOrWhiteSpace($cmdLine) -and $cmdLine.ToLowerInvariant().Contains($projectRootNorm.ToLowerInvariant())) {
            $belongsToProject = $true
        } elseif ([string]::IsNullOrWhiteSpace($procPath) -and [string]::IsNullOrWhiteSpace($cmdLine)) {
            throw ("深度清理中止：检测到后台运行中的 Mihomo 进程 (PID: $pId) 权限不足无法确定其归属路径。为防止误删活跃数据，请先手动排查或关闭该进程后再执行 -Clean。")
        }

        if ($belongsToProject) {
            $runningCores += $pId
        }
    }

    if ($runningCores.Count -gt 0) {
        throw ("深度清理中止：检测到仍有 $($runningCores.Count) 个属于本项目的 Mihomo 核心进程正在后台运行 (PID: $($runningCores -join ', '))。请先在管理平台中点击【停止核心】后再执行 -Clean。")
    }

    $cleanErrors = @()

    # 清理 .codex 运行期目录
    $codexDir = Join-Path -Path $projectRoot -ChildPath '.codex'
    if (Test-Path -LiteralPath $codexDir -PathType Container) {
        try {
            Remove-Item -LiteralPath $codexDir -Recurse -Force -ErrorAction Stop
            Write-Host "  已清理: .codex/ 目录" -ForegroundColor Gray
        } catch {
            $cleanErrors += ("清理 .codex/ 失败: $($_.Exception.Message)")
        }
    }

    # 清理 runtime 下的废弃与冗余项
    $runtimeDir = Join-Path -Path $projectRoot -ChildPath 'runtime'
    if (Test-Path -LiteralPath $runtimeDir -PathType Container) {
        # 清理历史异常拼接的目录 runtime/instancesapp-*
        Get-ChildItem -Path $runtimeDir -Directory -Filter 'instancesapp-*' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "  已清理废弃目录: $($_.Name)" -ForegroundColor Gray
            } catch {
                $cleanErrors += ("清理目录 $($_.Name) 失败: $($_.Exception.Message)")
            }
        }

        # 清理探针测试与下载缓存
        $cleanupSubdirs = @('loopback-listener-probe', 'mihomo-download')
        foreach ($d in $cleanupSubdirs) {
            $p = Join-Path -Path $runtimeDir -ChildPath $d
            if (Test-Path -LiteralPath $p) {
                try {
                    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                    Write-Host "  已清理缓存目录: runtime/$d" -ForegroundColor Gray
                } catch {
                    $cleanErrors += ("清理缓存目录 runtime/$d 失败: $($_.Exception.Message)")
                }
            }
        }

        # 清理 backup 备份文件
        Get-ChildItem -Path $runtimeDir -File -Filter '*.backup' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-Host "  已清理备份文件: $($_.Name)" -ForegroundColor Gray
            } catch {
                $cleanErrors += ("清理备份文件 $($_.Name) 失败: $($_.Exception.Message)")
            }
        }

        # 清理临时 cache.db
        $runtimeCache = Join-Path -Path $runtimeDir -ChildPath 'cache.db'
        if (Test-Path -LiteralPath $runtimeCache) {
            try {
                Remove-Item -LiteralPath $runtimeCache -Force -ErrorAction Stop
            } catch {
                $cleanErrors += ("清理 runtime/cache.db 失败: $($_.Exception.Message)")
            }
        }

        # 清理运行时动态生成的实例临时状态（保留 instances 及其配置实例的目录结构）
        $instancesDir = Join-Path -Path $runtimeDir -ChildPath 'instances'
        if (Test-Path -LiteralPath $instancesDir) {
            try {
                $instFiles = @(Get-ChildItem -Path $instancesDir -Recurse -File -ErrorAction Stop | Where-Object { $_.Name -ne '.gitkeep' })
                foreach ($f in $instFiles) {
                    try {
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    } catch {
                        $cleanErrors += ("清理实例文件 $($f.FullName) 失败: $($_.Exception.Message)")
                    }
                }
            } catch {
                $cleanErrors += ("枚举实例目录 $instancesDir 失败: $($_.Exception.Message)")
            }
        }
    }

    # 清理根目录 cache.db
    $rootCache = Join-Path -Path $projectRoot -ChildPath 'cache.db'
    if (Test-Path -LiteralPath $rootCache) {
        try {
            Remove-Item -LiteralPath $rootCache -Force -ErrorAction Stop
            Write-Host "  已清理: 根目录 cache.db" -ForegroundColor Gray
        } catch {
            $cleanErrors += ("清理根目录 cache.db 失败: $($_.Exception.Message)")
        }
    }

    # 清理 logs/ 目录下的日志内容
    $logsDir = Join-Path -Path $projectRoot -ChildPath 'logs'
    if (Test-Path -LiteralPath $logsDir) {
        try {
            $logFiles = @(Get-ChildItem -Path $logsDir -File -ErrorAction Stop)
            foreach ($lf in $logFiles) {
                try {
                    Remove-Item -LiteralPath $lf.FullName -Force -ErrorAction Stop
                } catch {
                    $cleanErrors += ("清理日志文件 $($lf.Name) 失败: $($_.Exception.Message)")
                }
            }
            Write-Host "  已清理: logs/ 历史日志" -ForegroundColor Gray
        } catch {
            $cleanErrors += ("枚举日志目录 $logsDir 失败: $($_.Exception.Message)")
        }
    }

    if ($cleanErrors.Count -gt 0) {
        throw ("深度清理未完全成功，存在以下删除错误：`n  " + ($cleanErrors -join "`n  "))
    }

    Write-Host "  [OK] 本地运行数据清理完毕。" -ForegroundColor Green
    if ($CleanOnly) {
        return
    }
}
else {
    Write-Host "`n[2/4] 跳过运行数据清理（保留本地活跃实例与日志，传入 -Clean 可显式深度清理）" -ForegroundColor Gray
}

# 确保核心基础目录结构完整
foreach ($folder in @('config', 'logs', 'providers', 'runtime', 'runtime\instances')) {
    $dirPath = Join-Path -Path $projectRoot -ChildPath $folder
    if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) {
        New-Item -ItemType Directory -Path $dirPath -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $keepFile = Join-Path -Path $dirPath -ChildPath '.gitkeep'
    if (-not (Test-Path -LiteralPath $keepFile) -and $folder -in @('logs', 'providers', 'runtime\instances')) {
        [System.IO.File]::WriteAllText($keepFile, '')
    }
}

# 确保 settings.json 中配置的所有自定义实例目录均已重建（校验 ID 正则并防御路径越界）
$settingsFile = Join-Path -Path $projectRoot -ChildPath 'config\settings.json'
if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
    try {
        $settingsObj = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $settingsObj.customInstances) {
            $instancesParent = [System.IO.Path]::GetFullPath((Join-Path -Path $projectRoot -ChildPath 'runtime\instances'))
            foreach ($inst in $settingsObj.customInstances) {
                $instId = [string]$inst.id
                if (-not [string]::IsNullOrWhiteSpace($instId) -and $instId -match '^[a-zA-Z0-9_\-]+$') {
                    $instSubDir = [System.IO.Path]::GetFullPath((Join-Path -Path $instancesParent -ChildPath $instId))
                    if ($instSubDir.StartsWith($instancesParent, [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not (Test-Path -LiteralPath $instSubDir -PathType Container)) {
                            New-Item -ItemType Directory -Path $instSubDir -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }
            }
        }
    }
    catch {
    }
}

# 确保 config/settings.example.json 存在
$exampleConfigPath = Join-Path -Path $projectRoot -ChildPath 'config\settings.example.json'
if (-not (Test-Path -LiteralPath $exampleConfigPath)) {
    $defaultJson = @'
{
  "subscriptionUrl": "",
  "selectedNode": "",
  "antigravityPath": "",
  "proxyPort": 7899,
  "controllerPort": 19090,
  "portMappings": [
    {
      "port": 7899,
      "node": ""
    }
  ],
  "selectedPort": 7899,
  "customInstances": []
}
'@
    [System.IO.File]::WriteAllText($exampleConfigPath, $defaultJson, [System.Text.Encoding]::UTF8)
    Write-Host "  已创建: config/settings.example.json" -ForegroundColor Green
}

Write-Host "  [OK] 临时文件清理完毕，目录结构规范化完成。" -ForegroundColor Green

if ($CleanOnly) {
    Write-Host "`n清理完成（已指定 -CleanOnly，跳过打包）。" -ForegroundColor Green
    return
}

# -----------------------------------------------------------------------------
# 3. 检查 Mihomo 核心文件
# -----------------------------------------------------------------------------
Write-Host "`n[3/4] 正在检查 Mihomo 核心程序..." -ForegroundColor Yellow

$corePath = Join-Path -Path $projectRoot -ChildPath 'mihomo.exe'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    Write-Host "  [WARN] 根目录下未检测到 mihomo.exe!" -ForegroundColor Yellow
    Write-Host "  提示: 部署到其他电脑时，请将 mihomo.exe 放入工程根目录，或通过启动器自动下载。" -ForegroundColor Yellow
}
else {
    $coreVersion = & $corePath -v 2>&1 | Select-Object -First 1
    Write-Host "  [OK] 检测到核心: $coreVersion" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 4. 生成可移植的便携发行包 (Portable ZIP)
# -----------------------------------------------------------------------------
if ($Package) {
    Write-Host "`n[4/4] 正在打包便携发行版本..." -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $parentDir = Split-Path -Path $projectRoot -Parent
        $distDir = Join-Path -Path $parentDir -ChildPath 'dist'
    }
    else {
        $distDir = $OutputDir
    }

    if (-not (Test-Path -LiteralPath $distDir -PathType Container)) {
        New-Item -ItemType Directory -Path $distDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $archiveName = "antigravity-mihomo-proxy-portable-v2.0.0.zip"
    $archivePath = Join-Path -Path $distDir -ChildPath $archiveName
    $archiveTimestampedPath = Join-Path -Path $distDir -ChildPath "antigravity-mihomo-proxy-portable-v2.0.0_$timestamp.zip"

    # 准备临时打包暂存区，严格过滤敏感文件（如用户的 settings.json 和订阅缓存）
    $stagingDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("ag-staging-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingDir -Force -ErrorAction Stop | Out-Null

    try {
        # 复制所有源码与启动脚本
        $includeFiles = @(
            'AntigravityProxy.ps1',
            'start.ps1',
            'start.cmd',
            'build.ps1',
            'build.cmd',
            'agy-proxy.cmd',
            'run-agy-with-proxy.ps1',
            'run-agy-with-clash.ps1',
            'launch-saved-antigravity.ps1',
            'launch-clash-antigravity.ps1',
            'switch-antigravity-to-clash.ps1',
            'README.md',
            'MEMORY.md',
            'CONTRIBUTING.md',
            'SECURITY.md',
            'LICENSE',
            '.gitignore'
        )

        foreach ($f in $includeFiles) {
            $src = Join-Path -Path $projectRoot -ChildPath $f
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                Copy-Item -LiteralPath $src -Destination $stagingDir -Force
            }
        }

        # 包含 mihomo.exe（便携即用）
        if (Test-Path -LiteralPath $corePath -PathType Leaf) {
            Copy-Item -LiteralPath $corePath -Destination $stagingDir -Force
        }

        # 复制干净的目录骨架
        $dirsToCreate = @('config', 'logs', 'providers', 'runtime', 'runtime\instances')
        foreach ($d in $dirsToCreate) {
            $destD = Join-Path -Path $stagingDir -ChildPath $d
            if (-not (Test-Path -LiteralPath $destD -PathType Container)) {
                New-Item -ItemType Directory -Path $destD -Force | Out-Null
            }
        }

        # 仅打包 settings.example.json，不打包用户私有订阅 settings.json
        $exampleConfigSrc = Join-Path -Path $projectRoot -ChildPath 'config\settings.example.json'
        if (Test-Path -LiteralPath $exampleConfigSrc) {
            Copy-Item -LiteralPath $exampleConfigSrc -Destination (Join-Path -Path $stagingDir -ChildPath 'config\settings.example.json') -Force
            # 同时也放一份作为默认 settings.json，确保开箱即用
            Copy-Item -LiteralPath $exampleConfigSrc -Destination (Join-Path -Path $stagingDir -ChildPath 'config\settings.json') -Force
        }

        # 复制自动化回归测试套件，确保便携包具备开箱即用自检能力
        $testsSrc = Join-Path -Path $projectRoot -ChildPath 'tests'
        if (Test-Path -LiteralPath $testsSrc -PathType Container) {
            Copy-Item -LiteralPath $testsSrc -Destination (Join-Path -Path $stagingDir -ChildPath 'tests') -Recurse -Force
        }

        # 添加 .gitkeep 保持目录存在
        foreach ($d in @('logs', 'providers', 'runtime\instances')) {
            $keep = Join-Path -Path $stagingDir -ChildPath ($d + '\.gitkeep')
            [System.IO.File]::WriteAllText($keep, '')
        }

        # 压缩打包
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $archivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Copy-Item -LiteralPath $archivePath -Destination $archiveTimestampedPath -Force

        $fileSizeMB = [math]::Round(((Get-Item $archivePath).Length / 1MB), 2)
        Write-Host "`n==================================================" -ForegroundColor Green
        Write-Host "  打包成功！" -ForegroundColor Green
        Write-Host "  便携版本发行包: $archivePath" -ForegroundColor Cyan
        Write-Host "  文件大小: $fileSizeMB MB" -ForegroundColor Cyan
        Write-Host "  带时间戳备份: $archiveTimestampedPath" -ForegroundColor Gray
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "`n移植到其他电脑使用指南:" -ForegroundColor Yellow
        Write-Host "  1. 将 zip 包解压到任意目标目录" -ForegroundColor Gray
        Write-Host "  2. 双击 start.cmd 即可启动管理平台" -ForegroundColor Gray
        Write-Host "  3. 也可运行 build.ps1 -Validate 随时自检代码合规性" -ForegroundColor Gray
    }
    finally {
        if (Test-Path -LiteralPath $stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
