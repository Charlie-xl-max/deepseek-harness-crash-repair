[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$DshHome,
    [switch]$DryRun,
    [switch]$NoLaunch,
    [ValidateRange(5, 120)]
    [int]$LaunchWaitSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppContainerSid = 'S-1-15-2-1'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Section {
    param([string]$Message)

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)

    Write-Host "    $Message"
}

function Get-PropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-HarnessExecutable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -ne 'DeepSeek Harness') {
        return $false
    }

    try {
        return (Get-Item -LiteralPath $Path).VersionInfo.FileDescription -eq 'DeepSeek Harness'
    } catch {
        return $false
    }
}

function Resolve-HarnessExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim().Trim('"'))
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            if (Test-HarnessExecutable -Path $expanded) {
                return (Resolve-Path -LiteralPath $expanded).Path
            }
            throw "指定路径不是 DeepSeek Harness 主程序：$expanded"
        }

        if (Test-Path -LiteralPath $expanded -PathType Container) {
            $candidate = Join-Path $expanded 'DeepSeek Harness.exe'
            if (Test-HarnessExecutable -Path $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }

        throw "没有在指定位置找到 DeepSeek Harness：$expanded"
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    @(
        'D:\deepseek harness',
        (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness' } else { $null }),
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $candidates.Add((Join-Path $_ 'DeepSeek Harness.exe'))
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($registryRoot in $uninstallRoots) {
        if (-not (Test-Path $registryRoot)) {
            continue
        }

        try {
            Get-ChildItem $registryRoot -ErrorAction Stop | ForEach-Object {
                $entry = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $displayName = Get-PropertyValue -InputObject $entry -Name 'DisplayName'
                if ($displayName -notlike '*DeepSeek*Harness*') {
                    return
                }

                $location = Get-PropertyValue -InputObject $entry -Name 'InstallLocation'
                if (-not [string]::IsNullOrWhiteSpace($location)) {
                    $candidates.Add((Join-Path $location.Trim('"') 'DeepSeek Harness.exe'))
                }

                $uninstall = Get-PropertyValue -InputObject $entry -Name 'DisplayIcon'
                if (-not [string]::IsNullOrWhiteSpace($uninstall)) {
                    $iconPath = ([string]$uninstall -split ',')[0].Trim().Trim('"')
                    if ($iconPath -like '*.exe') {
                        $candidates.Add($iconPath)
                    }
                }
            }
        } catch {
            # A locked registry hive should not stop discovery through the other paths.
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-HarnessExecutable -Path $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw '没有找到 DeepSeek Harness。请用 -InstallDir 指定安装目录。'
}

function Resolve-DshHome {
    param([string]$RequestedHome)

    if (-not [string]::IsNullOrWhiteSpace($RequestedHome)) {
        return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($RequestedHome.Trim().Trim('"')))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:DSH_HOME.Trim().Trim('"')))
    }

    return Join-Path $env:USERPROFILE '.dsh'
}

function Test-AppContainerReadAce {
    param([string]$Path)

    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($rule in $acl.Access) {
            $identity = [string]$rule.IdentityReference.Value
            if ($identity -match 'ALL APPLICATION PACKAGES' -or $identity -match 'S-1-15-2-1') {
                if (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0) {
                    return $true
                }
            }
        }

        # Windows may expose this well-known package SID through the SDDL alias AC.
        if ([string]$acl.Sddl -match '(?i)(?:;;;AC\)|S-1-15-2-1)') {
            return $true
        }
    } catch {
        return $false
    }

    return $false
}

function Repair-AppContainerAcl {
    param(
        [string]$InstallRoot,
        [string]$ExecutablePath,
        [switch]$PreviewOnly
    )

    $before = Test-AppContainerReadAce -Path $InstallRoot
    if ($before) {
        Write-Info '安装目录权限已正确，无需重复授权。'
        return
    }

    if ($PreviewOnly) {
        Write-Info "将为安装目录补上沙盒读取权限：$InstallRoot"
        return
    }

    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $targets = @($InstallRoot, $ExecutablePath)
    $resources = Join-Path $InstallRoot 'resources'
    if (Test-Path -LiteralPath $resources -PathType Container) {
        $targets += $resources
    }

    foreach ($target in $targets | Select-Object -Unique) {
        $output = & $icacls $target /grant "*${AppContainerSid}:(OI)(CI)(RX)" /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "修复目录权限失败：$target`n$($output -join [Environment]::NewLine)"
        }
    }

    if (-not (Test-AppContainerReadAce -Path $InstallRoot)) {
        throw "安装目录权限写入后仍未验证成功：$InstallRoot"
    }

    Write-Info '已补上 Windows 沙盒读取权限。'
}

function Test-RuntimeVersionMatches {
    param(
        [string]$VersionSpec,
        [string]$AppVersion
    )

    if ([string]::IsNullOrWhiteSpace($VersionSpec)) {
        return $true
    }

    $normalized = $VersionSpec.Trim()
    if ($normalized.StartsWith('=')) {
        $normalized = $normalized.Substring(1).Trim()
    }

    return $normalized -eq $AppVersion
}

function Get-MismatchedRuntimeDependencies {
    param(
        [object]$Manifest,
        [string]$AppVersion
    )

    $result = [System.Collections.Generic.List[object]]::new()
    $dependencies = Get-PropertyValue -InputObject $Manifest -Name 'dependencies'
    if ($null -eq $dependencies) {
        return @()
    }

    foreach ($property in $dependencies.PSObject.Properties) {
        $name = [string]$property.Name
        if ($name -notmatch '^@deepseek-ai/dsh(?:-|$)') {
            continue
        }

        $version = [string]$property.Value
        if (-not (Test-RuntimeVersionMatches -VersionSpec $version -AppVersion $AppVersion)) {
            $result.Add([pscustomobject]@{
                Name = $name
                Version = $version
            })
        }
    }

    return @($result)
}

function Get-InstalledRuntimeMismatches {
    param(
        [string[]]$ModuleRoots,
        [string]$AppVersion
    )

    $mismatches = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($moduleRoot in $ModuleRoots) {
        $scopeRoot = Join-Path $moduleRoot '@deepseek-ai'
        if (-not (Test-Path -LiteralPath $scopeRoot -PathType Container)) {
            continue
        }

        foreach ($directory in Get-ChildItem -LiteralPath $scopeRoot -Directory -ErrorAction SilentlyContinue) {
            if ($directory.Name -notmatch '^dsh(?:-|$)') {
                continue
            }

            $manifestPath = Join-Path $directory.FullName 'package.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                continue
            }

            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $name = [string](Get-PropertyValue -InputObject $manifest -Name 'name')
                $version = [string](Get-PropertyValue -InputObject $manifest -Name 'version')
                if (-not [string]::IsNullOrWhiteSpace($name) -and
                    -not [string]::IsNullOrWhiteSpace($version) -and
                    -not (Test-RuntimeVersionMatches -VersionSpec $version -AppVersion $AppVersion)) {
                    [void]$mismatches.Add("$name@$version")
                }
            } catch {
                # An unreadable package is handled by the profile's next plugin operation.
            }
        }
    }

    return @($mismatches)
}

function Find-DependencyManifest {
    param(
        [string]$DependencyName,
        [string[]]$ModuleRoots
    )

    foreach ($moduleRoot in $ModuleRoots) {
        $candidate = Join-Path $moduleRoot $DependencyName
        $manifestPath = Join-Path $candidate 'package.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            return $manifestPath
        }
    }

    return $null
}

function Get-ProfileRuntimeAnalysis {
    param(
        [string]$ProfilePath,
        [string]$AppVersion
    )

    $packagePath = Join-Path $ProfilePath 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        return [pscustomobject]@{
            PackagePath = $packagePath
            Package = $null
            ProblemDependencies = @()
            CurrentRuntimeMismatches = @()
            AllRuntimeMismatches = @()
            ModuleRoots = @()
            CurrentNodeModules = Join-Path $ProfilePath 'node_modules'
        }
    }

    try {
        $package = Get-Content -LiteralPath $packagePath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "无法读取 profile 配置：$packagePath`n$($_.Exception.Message)"
    }

    $currentNodeModules = Join-Path $ProfilePath 'node_modules'
    $staleRoots = @(
        Get-ChildItem -LiteralPath $ProfilePath -Directory -Filter 'node_modules.stale-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3 |
            ForEach-Object { $_.FullName }
    )
    $moduleRoots = @()
    if (Test-Path -LiteralPath $currentNodeModules -PathType Container) {
        $moduleRoots += $currentNodeModules
    }
    $moduleRoots += $staleRoots

    $currentMismatches = if (Test-Path -LiteralPath $currentNodeModules -PathType Container) {
        @(Get-InstalledRuntimeMismatches -ModuleRoots @($currentNodeModules) -AppVersion $AppVersion)
    } else {
        @()
    }
    $allMismatches = @(Get-InstalledRuntimeMismatches -ModuleRoots $moduleRoots -AppVersion $AppVersion)

    $problemDependencies = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dependencies = Get-PropertyValue -InputObject $package -Name 'dependencies'
    if ($null -ne $dependencies) {
        foreach ($property in $dependencies.PSObject.Properties) {
            $dependencyName = [string]$property.Name
            $dependencyVersion = [string]$property.Value

            if ($dependencyName -match '^@deepseek-ai/dsh(?:-|$)' -and
                -not (Test-RuntimeVersionMatches -VersionSpec $dependencyVersion -AppVersion $AppVersion)) {
                [void]$problemDependencies.Add($dependencyName)
            }

            $manifestPath = Find-DependencyManifest -DependencyName $dependencyName -ModuleRoots $moduleRoots
            if ($null -eq $manifestPath) {
                continue
            }

            try {
                $dependencyManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $runtimeMismatches = @(Get-MismatchedRuntimeDependencies -Manifest $dependencyManifest -AppVersion $AppVersion)
                if ($runtimeMismatches.Count -gt 0) {
                    [void]$problemDependencies.Add($dependencyName)
                }
            } catch {
                # Leave a package untouched if its manifest cannot be trusted.
            }
        }
    }

    return [pscustomobject]@{
        PackagePath = $packagePath
        Package = $package
        ProblemDependencies = @($problemDependencies)
        CurrentRuntimeMismatches = $currentMismatches
        AllRuntimeMismatches = $allMismatches
        ModuleRoots = $moduleRoots
        CurrentNodeModules = $currentNodeModules
    }
}

function Remove-IncompatibleProfileDependencies {
    param(
        [object]$Analysis,
        [string]$Timestamp,
        [switch]$PreviewOnly
    )

    $problemDependencies = @($Analysis.ProblemDependencies)
    if ($problemDependencies.Count -eq 0) {
        return $null
    }

    $package = $Analysis.Package
    $dependencies = Get-PropertyValue -InputObject $package -Name 'dependencies'
    if ($null -eq $dependencies) {
        return $null
    }

    foreach ($dependencyName in $problemDependencies) {
        if ($PreviewOnly) {
            Write-Info "将停用不兼容插件依赖：$dependencyName"
            continue
        }

        $dependencies.PSObject.Properties.Remove($dependencyName)
        Write-Info "已停用不兼容插件依赖：$dependencyName"
    }

    $backupPath = "$($Analysis.PackagePath).bak-$Timestamp"
    if ($PreviewOnly) {
        Write-Info "将备份原配置：$backupPath"
        return $backupPath
    }

    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = "$($Analysis.PackagePath).bak-$Timestamp-$(Get-Random -Minimum 1000 -Maximum 9999)"
    }
    Copy-Item -LiteralPath $Analysis.PackagePath -Destination $backupPath -Force

    $json = $package | ConvertTo-Json -Depth 100
    $temporaryPath = "$($Analysis.PackagePath).tmp-$Timestamp"
    [IO.File]::WriteAllText(
        $temporaryPath,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Analysis.PackagePath -Force

    return $backupPath
}

function Move-ConflictingNodeModules {
    param(
        [object]$Analysis,
        [string]$Timestamp,
        [switch]$PreviewOnly
    )

    $currentMismatches = @($Analysis.CurrentRuntimeMismatches)
    if ($currentMismatches.Count -eq 0) {
        return $null
    }

    $backupPath = "$($Analysis.CurrentNodeModules).stale-$Timestamp"
    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = "$($Analysis.CurrentNodeModules).stale-$Timestamp-$(Get-Random -Minimum 1000 -Maximum 9999)"
    }

    Write-Info "发现旧运行时：$($currentMismatches -join ', ')"
    if ($PreviewOnly) {
        Write-Info "将隔离旧依赖目录：$($Analysis.CurrentNodeModules)"
        Write-Info "隔离后的保留位置：$backupPath"
        return $backupPath
    }

    Rename-Item -LiteralPath $Analysis.CurrentNodeModules -NewName ([IO.Path]::GetFileName($backupPath))
    Write-Info "旧依赖已保留到：$backupPath"
    return $backupPath
}

function Stop-HarnessProcesses {
    param(
        [string]$ExecutablePath,
        [switch]$PreviewOnly
    )

    $processes = @(
        Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $ExecutablePath
                } catch {
                    $false
                }
            }
    )

    if ($processes.Count -eq 0) {
        return
    }

    if ($PreviewOnly) {
        Write-Info "将关闭正在运行的 Harness 进程：$($processes.Id -join ', ')"
        return
    }

    Write-Info "正在关闭 Harness：$($processes.Id -join ', ')"
    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        try {
            Wait-Process -Id $process.Id -Timeout 8 -ErrorAction Stop
        } catch {
            # Stop-Process already requested termination; continue after the bounded wait.
        }
    }
}

function Start-HarnessAndCheck {
    param(
        [string]$ExecutablePath,
        [int]$WaitSeconds
    )

    $startedAt = Get-Date
    $process = Start-Process -FilePath $ExecutablePath -PassThru
    Write-Info "正在等待应用启动（最多 $WaitSeconds 秒）..."
    Start-Sleep -Seconds $WaitSeconds
    $process.Refresh()

    if ($process.HasExited) {
        throw "Harness 启动后提前退出，退出码：$($process.ExitCode)。请打开应用日志查看详情。"
    }

    $children = @(
        Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $ExecutablePath
                } catch {
                    $false
                }
            }
    )
    if ($children.Count -eq 0) {
        throw 'Harness 主进程没有保持运行。'
    }

    $candidateLogs = @(
        Get-ChildItem -LiteralPath (Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs') -Filter 'crash-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-2) } |
            Sort-Object LastWriteTime -Descending
    )
    if ($candidateLogs.Count -gt 0) {
        $latestLog = Get-Content -LiteralPath $candidateLogs[0].FullName -Raw -ErrorAction SilentlyContinue
        if ($latestLog -match 'startup failed|required plugins did not activate|Sandboxed processes cannot read') {
            throw "应用已保持运行，但新日志仍包含启动错误：$($candidateLogs[0].FullName)"
        }
    }

    Write-Info "应用已启动并保持运行，进程号：$($process.Id)"
}

try {
    Write-Host ''
    Write-Host 'DeepSeek Harness 修复工具' -ForegroundColor Green
    Write-Host '只修复旧插件运行时冲突和安装目录权限，不改账号、会话或聊天记录。'

    Write-Section '查找安装'
    $executablePath = Resolve-HarnessExecutable -RequestedPath $InstallDir
    $installRoot = Split-Path -Parent $executablePath
    $appVersion = (Get-Item -LiteralPath $executablePath).VersionInfo.FileVersion
    if ([string]::IsNullOrWhiteSpace($appVersion)) {
        throw '无法读取 Harness 版本。'
    }
    Write-Info "程序：$executablePath"
    Write-Info "版本：$appVersion"

    $resolvedDshHome = Resolve-DshHome -RequestedHome $DshHome
    $profilePath = Join-Path $resolvedDshHome 'profiles\desktop'
    Write-Info "配置：$profilePath"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        Write-Info '桌面配置尚未生成，本次只检查权限。'
    }

    Write-Section '检查运行状态'
    Stop-HarnessProcesses -ExecutablePath $executablePath -PreviewOnly:$DryRun

    Write-Section '检查安装目录权限'
    Repair-AppContainerAcl -InstallRoot $installRoot -ExecutablePath $executablePath -PreviewOnly:$DryRun

    Write-Section '检查插件运行时'
    $backupPackagePath = $null
    $backupModulesPath = $null
    if (Test-Path -LiteralPath $profilePath -PathType Container) {
        $analysis = Get-ProfileRuntimeAnalysis -ProfilePath $profilePath -AppVersion $appVersion
        if (@($analysis.AllRuntimeMismatches).Count -eq 0 -and @($analysis.ProblemDependencies).Count -eq 0) {
            Write-Info '没有发现与当前 Harness 冲突的旧运行时。'
        } else {
            if (@($analysis.CurrentRuntimeMismatches).Count -gt 0) {
                Write-Info "检测到旧运行时：$(@($analysis.AllRuntimeMismatches) -join ', ')"
            }

            $backupPackagePath = Remove-IncompatibleProfileDependencies `
                -Analysis $analysis `
                -Timestamp $Timestamp `
                -PreviewOnly:$DryRun
            $backupModulesPath = Move-ConflictingNodeModules `
                -Analysis $analysis `
                -Timestamp $Timestamp `
                -PreviewOnly:$DryRun

            if ($null -eq $backupPackagePath -and $null -eq $backupModulesPath) {
                Write-Info '历史备份中仍保留旧运行时；当前 profile 已隔离，无需再次修改。'
            }
        }
    }

    Write-Section '启动应用'
    if ($DryRun) {
        Write-Info '预览模式未做任何修改，也未启动应用。'
    } elseif ($NoLaunch) {
        Write-Info '修复已完成；已按参数要求跳过启动。'
    } else {
        Start-HarnessAndCheck -ExecutablePath $executablePath -WaitSeconds $LaunchWaitSeconds
    }

    Write-Host ''
    if ($DryRun) {
        Write-Host '预览完成。去掉 -DryRun 后再次运行即可执行修复。' -ForegroundColor Yellow
    } else {
        Write-Host '修复完成。' -ForegroundColor Green
    }
    if ($backupPackagePath -and -not $DryRun) {
        Write-Info "原插件配置备份：$backupPackagePath"
    }
    if ($backupModulesPath -and -not $DryRun) {
        Write-Info "原插件依赖备份：$backupModulesPath"
    }

    exit 0
} catch {
    Write-Host ''
    Write-Host "修复失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
