#requires -Version 5.1
<#
  冰点还原 (Faronics Deep Freeze) 强制卸载 / 彻底清理工具
  ============================================================================
  文件名 : DFRemover.ps1
  运行环境: Windows 10/11 x64，必须以管理员身份运行
  用  途 : 在没有密码（或密码遗忘）的情况下，把冰点还原从系统中连根清除。

  四种工作模式（-Mode）：
    Menu            交互菜单（默认，双击 Start.cmd 即是此模式）
    Scan            只读扫描，只看不改，给出处置建议
    Auto            扫描 + 自动生成 PE 离线卸载包（不改动本机任何东西）
    PrepareOffline  只生成 PE 离线卸载包
    Remove          在线强制卸载（仅限"已解冻/未被保护"的系统）
    Verify          卸载后复查残留
    Doctor          环境自检（换一台电脑先跑这个，确认能正常干活）
    WinRE           不用 U 盘：用系统自带的 Windows RE 做离线清理
    BootMenu        一键重启到恢复环境（无键盘可用）
    PeScan          在 PE 里检测目标系统的冰点（只读）
    PeRemove        在 PE 里强制卸载（自动识别系统盘）
    PeVerify        在 PE 里复查残留
    Inventory       导出配置清单（不含密码，供重装对照）
    Guide           打开《多种卸载思路对比》教程
    BootEntry       设置“下次启动进 U 盘/PE”（UEFI 一次性启动）
    BootEntryClear  清除一次性启动项（恢复原顺序）

  关键原理（务必理解，否则会白做）：
    冰点 = 磁盘过滤驱动(DFFilter/DeepFrz/FarDisk...) + 内核服务 + 设备类过滤器
           (UpperFilters) + 安装目录 + 注册表 + 卷根目录 persi0.sys。
    处于"冻结"状态时，所有写入都被驱动重定向，重启后全部丢弃。
    => 因此冻结状态下不可能在本机内部卸载成功，必须离线（PE / 另一套系统）清理。
    离线清理的顺序必须是：先卸掉"注册表里的加载点"，再删文件。
    顺序反了（先删文件、留着服务/过滤器登记）会导致开机 0x7B 蓝屏。
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Scan', 'Auto', 'Remove', 'PrepareOffline', 'Verify', 'Doctor', 'WinRE', 'BootMenu', 'PeScan', 'PeRemove', 'PeVerify', 'Inventory', 'Guide', 'BootEntry', 'BootEntryClear')]
    [string]$Mode = 'Menu',

    # 在线卸载时，即使检测到过滤驱动仍在运行也继续（不推荐；冻结状态下做了也白做）
    [switch]$Force,

    # 只显示将要执行的动作，不真正改动
    [switch]$DryRun,

    # -Mode PrepareOffline 的输出目录
    [string]$KitDir,

    # -Mode WinRE 时，把清理脚本放到哪个卷（例如 D:\）。不填则自动挑
    [string]$StageVolume,

    # -Mode WinRE 时只放脚本、不改 Windows RE 设置
    [switch]$StageOnly,

    # 注册表备份目录（默认自动挑一个可写位置；U 盘部署时可指定到 U 盘）
    [string]$BackupDir,

    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# 从压缩包/网络拷来的文件会带"来自其他计算机"标记（MOTW），可能被 SmartScreen 或
# 执行策略拦住。能解就顺手解开，解不了也不影响运行。
try {
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
        Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.ps1', '.cmd', '.exe', '.dll' } |
            ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
} catch { }

# ============================================================================
# 组件清单（三个脚本保持一致：DFRemover.ps1 / DF-Offline-Clean.ps1 / DF-Offline-Clean.cmd）
# ============================================================================
$script:DfServiceNames = @(
    'DFServ', 'DFFilter', 'DeepFrz', 'DfDiskLo', 'FarDisk', 'FarSpace', 'DFInstall'
)
$script:DfDriverFiles = @(
    'DFFilter.sys', 'DeepFrz.sys', 'FarDisk.sys', 'FarSpace.sys', 'DfDiskLo.sys'
)
# 用于匹配"名字/显示名/路径"里的冰点特征
$script:DfNameRegex = '(?i)(DFServ|DFFilter|DFInstall|Deep\s*-\s*Freeze|DeepFreeze|Deep\s*Freeze|DeepFrz|FarDisk|FarSpace|DfDiskLo|Faronics|冰点)'
# 用于匹配服务的 ImagePath（更严格，避免误伤 Microsoft 的 dfs*/Dfsc）
$script:DfPathRegex = '(?i)(Faronics|\\DFFilter\.sys|\\DeepFrz\.sys|\\FarDisk\.sys|\\FarSpace\.sys|\\DfDiskLo\.sys|\\DFServ(\.exe)?(\s|$|"))'

$script:IsAdmin = $false

# ============================================================================
# 日志
# ============================================================================
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:LogPath = $null

function Initialize-Log {
    # 日志优先写脚本目录；只读介质（写保护 U 盘/光盘/只读共享）时自动改到别处
    $candidates = New-Object System.Collections.ArrayList
    if ($PSScriptRoot) { [void]$candidates.Add($PSScriptRoot) }
    $alt = Get-PortableWritableDir
    if ($alt) { [void]$candidates.Add($alt) }
    if ($env:TEMP) { [void]$candidates.Add($env:TEMP) }

    foreach ($d in $candidates) {
        $c = Join-Path $d 'DFRemover.log'
        try {
            Add-Content -LiteralPath $c -Value '' -ErrorAction Stop
            $script:LogPath = $c
            return
        } catch { }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
    $script:LogLines.Add($line)
    switch ($Level) {
        'OK'    { Write-Host $Message -ForegroundColor Green }
        'WARN'  { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'HEAD'  { Write-Host $Message -ForegroundColor Cyan }
        'DIM'   { Write-Host $Message -ForegroundColor DarkGray }
        default { Write-Host $Message }
    }
}

function Save-Log {
    if (-not $script:LogPath) { return }
    try {
        Add-Content -LiteralPath $script:LogPath -Value ("`r`n===== {0} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Add-Content -LiteralPath $script:LogPath -Value $script:LogLines
    } catch { }
}

function Test-AdminRights {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Rule {
    param([string]$Title)
    Write-Host ''
    Write-Host ('─' * 74) -ForegroundColor DarkCyan
    if ($Title) { Write-Host ("  " + $Title) -ForegroundColor Cyan }
    Write-Host ('─' * 74) -ForegroundColor DarkCyan
}

function Write-Check {
    param([string]$Name, [ValidateSet('OK', 'WARN', 'BAD', 'INFO')][string]$State, [string]$Detail = '')
    $tag = switch ($State) { 'OK' { '[ OK ]' } 'WARN' { '[注意]' } 'BAD' { '[失败]' } default { '[信息]' } }
    $color = switch ($State) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'BAD' { 'Red' } default { 'Gray' } }
    Write-Host ("  {0} {1}" -f $tag, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("         " + $Detail) -ForegroundColor DarkGray }
}

# ============================================================================
# 环境自检（换电脑 / 出问题先跑这个）
# ============================================================================
function Test-PathWritable {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Dir ('.dfprobe_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Test-IsWinPE {
    try { return (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') } catch { return $false }
}

function Get-PortableWritableDir {
    # 找一个真正可写的落脚点：脚本目录 → 脚本所在盘 → TEMP → 用户配置目录
    $cands = New-Object System.Collections.ArrayList
    if ($PSScriptRoot) {
        [void]$cands.Add($PSScriptRoot)
        $q = Split-Path -Qualifier $PSScriptRoot
        if ($q) { [void]$cands.Add($q + '\') }
    }
    if ($env:TEMP) { [void]$cands.Add($env:TEMP) }
    if ($env:LOCALAPPDATA) { [void]$cands.Add($env:LOCALAPPDATA) }
    foreach ($c in $cands) { if (Test-PathWritable -Dir $c) { return $c } }
    return $null
}

function Get-RemovableDrives {
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($v in (Get-Volume -ErrorAction Stop)) {
            if ($v.DriveType -eq 'Removable' -and $v.DriveLetter) {
                [void]$out.Add(($v.DriveLetter + ':\'))
            }
        }
    } catch { }
    if ($out.Count -eq 0) {
        # 老系统退化方案
        try {
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction Stop)) {
                if ($d.Root -match '^[A-Za-z]:\\$' -and $d.Free -gt 64MB) {
                    $di = New-Object System.IO.DriveInfo($d.Root)
                    if ($di.DriveType -eq 'Removable') { [void]$out.Add($d.Root) }
                }
            }
        } catch { }
    }
    return @($out | Select-Object -Unique)
}

function Show-Doctor {
    Write-Rule '环境自检（换电脑 / 出问题先跑这个）'
    $bad = 0
    $warn = 0

    # 1 管理员
    if (Test-AdminRights) {
        Write-Check '管理员权限' 'OK'
    } else {
        Write-Check '管理员权限' 'BAD' '没有管理员权限，扫描会漏项、卸载必然失败。请右键"以管理员身份运行"。'
        $bad++
    }

    # 2 64 位进程（32 位进程看 HKLM\SOFTWARE 会被重定向到 WOW6432Node）
    $os64 = [Environment]::Is64BitOperatingSystem
    $proc64 = [Environment]::Is64BitProcess
    if (-not $os64) {
        Write-Check '系统位数' 'OK' '32 位系统（冰点仅支持 32 位时代版本，仍可尝试）'
    } elseif ($proc64) {
        Write-Check 'PowerShell 位数' 'OK' '64 位进程，注册表视图正确'
    } else {
        Write-Check 'PowerShell 位数' 'BAD' '当前是 32 位 PowerShell，访问 HKLM\SOFTWARE 会被重定向到 WOW6432Node，可能漏掉 64 位的冰点键。请改用 64 位 PowerShell（Start.cmd 已自动处理）。'
        $bad++
    }

    # 3 PowerShell 版本
    $pv = $PSVersionTable.PSVersion
    if ($pv.Major -ge 5) {
        Write-Check ('PowerShell ' + $pv.ToString()) 'OK'
    } else {
        Write-Check ('PowerShell ' + $pv.ToString()) 'WARN' '建议 PowerShell 5.1；更老版本可能有兼容问题。'
        $warn++
    }

    # 4 是不是在 PE 里
    if (Test-IsWinPE) {
        Write-Check '运行环境' 'WARN' '当前在 WinPE / Windows RE 中。这里请直接运行 Offline\DF-Offline-Clean.cmd，不要用本脚本的在线卸载。'
        $warn++
    } else {
        Write-Check '运行环境' 'OK' '正常 Windows 系统'
    }

    # 5 脚本目录可写（日志、注册表备份、离线包都写这里）
    if (Test-PathWritable -Dir $PSScriptRoot) {
        Write-Check '脚本所在目录可写' 'OK' $PSScriptRoot
    } else {
        $alt = Get-PortableWritableDir
        if ($alt) {
            Write-Check '脚本所在目录可写' 'WARN' ('只读介质（U 盘写保护 / 光盘 / 只读共享）。日志与备份会改写到：' + $alt)
            $warn++
        } else {
            Write-Check '脚本所在目录可写' 'BAD' '找不到任何可写目录，备份和日志都写不出来。请把工具复制到硬盘再运行。'
            $bad++
        }
    }

    # 6 reg.exe
    $reg = Get-Command reg.exe -ErrorAction SilentlyContinue
    if ($reg) {
        Write-Check 'reg.exe 可用' 'OK' $reg.Source
    } else {
        Write-Check 'reg.exe 可用' 'BAD' '系统缺少 reg.exe，注册表清理无法进行。'
        $bad++
    }

    # 7 代码页 / 语言（只影响显示，不影响功能）
    $cp = 0
    try { $cp = [Console]::OutputEncoding.CodePage } catch { }
    $cult = (Get-Culture).Name
    if ($cp -in 936, 54936, 65001) {
        Write-Check ('控制台代码页 ' + $cp + ' / ' + $cult) 'OK' '中文可正常显示'
    } else {
        Write-Check ('控制台代码页 ' + $cp + ' / ' + $cult) 'WARN' '非中文代码页，中文可能显示成方块；功能不受影响，PE 清理器的状态标签带英文（[完成 OK]）可对照阅读。'
        $warn++
    }

    # 8 执行策略（Start.cmd 已用 -ExecutionPolicy Bypass 绕过）
    try {
        $ep = Get-ExecutionPolicy
        Write-Check ('执行策略 ' + $ep) 'OK' '（Start.cmd 会用 Bypass 启动，无需改系统设置）'
    } catch { }

    # 9 系统盘 BitLocker（离线清理读不到加密盘）
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl.ProtectionStatus -eq 'On') {
            Write-Check '系统盘 BitLocker' 'WARN' '已开启加密。PE 离线清理前需要先暂停保护（manage-bde -protectors -disable C:）或准备好恢复密钥。'
            $warn++
        } else {
            Write-Check '系统盘 BitLocker' 'OK' '未加密'
        }
    } catch {
        Write-Check '系统盘 BitLocker' 'INFO' '系统不支持或查不到（家庭版常见），一般不影响。'
    }

    # 10 hiberfil.sys（快速启动会让离线改的注册表失效）
    $hib = Join-Path $env:SystemDrive 'hiberfil.sys'
    if (Test-Path -LiteralPath $hib) {
        Write-Check '休眠/快速启动文件' 'WARN' '检测到 hiberfil.sys。离线清理时它会用旧快照覆盖注册表改动，清理器会让你删掉它（选 Y）。'
        $warn++
    } else {
        Write-Check '休眠/快速启动文件' 'OK' '没有 hiberfil.sys'
    }

    # 11 本机是否真的装了冰点（快速判断，不做全量扫描）
    $svcHit = @()
    foreach ($n in $script:DfServiceNames) {
        if (Test-Path ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $n)) { $svcHit += $n }
    }
    if ($svcHit.Count -or (Test-Path 'HKLM:\SOFTWARE\Faronics')) {
        Write-Check '冰点安装情况' 'OK' ('发现组件：' + (($svcHit + @('HKLM\SOFTWARE\Faronics')) -join ', '))
    } else {
        Write-Check '冰点安装情况' 'INFO' '本机没发现冰点（可以直接把工具拿到出问题的那台电脑上用）'
    }

    # 11.5 Windows RE（不用 U 盘方案的可行性）
    $re = Get-WinREStatus
    if ($re.Enabled) {
        Write-Check 'Windows RE（恢复环境）' 'OK' '可用 → 菜单 6 可以走"不用 U 盘"的路线'
    } elseif ($re.Known) {
        Write-Check 'Windows RE（恢复环境）' 'WARN' '当前被禁用；菜单 6 会尝试启用（若系统正冻结，启用可能被还原）'
        $warn++
    } else {
        Write-Check 'Windows RE（恢复环境）' 'INFO' '查不到状态，可能没有恢复分区；这类机器建议用 U 盘方案'
    }

    # 12 可移动磁盘（离线包要放这里）
    $rem = Get-RemovableDrives
    if ($rem.Count) {
        Write-Check ('可移动磁盘 ' + ($rem -join ' ')) 'OK' '生成离线包时可以直接选它'
    } else {
        Write-Check '可移动磁盘' 'INFO' '没检测到 U 盘。离线卸载必须借助 U 盘或 PE，请插一个。'
    }

    Write-Rule '自检结论'
    if ($bad -eq 0 -and $warn -eq 0) {
        Write-Log '  ✅ 环境完好，可以直接使用。' 'OK'
    } elseif ($bad -eq 0) {
        Write-Log ("  ✅ 可以使用，有 {0} 项提醒（不影响主要功能）。" -f $warn) 'OK'
    } else {
        Write-Log ("  ⚠ 有 {0} 项必须先解决，否则会失败或卸不干净。" -f $bad) 'ERROR'
    }
    return $bad
}

# ============================================================================
# 不用 U 盘 / PE 的路线（利用系统自带的 Windows RE）
# ============================================================================
function Get-WinREStatus {
    $st = [pscustomobject]@{ Enabled = $false; Known = $false; Raw = '' }
    try {
        $out = (& reagentc.exe /info 2>&1) -join "`n"
        $st.Raw = $out
        if ($out -match '(?i)status:\s*enabled' -or $out -match '已启用') {
            $st.Enabled = $true; $st.Known = $true
        } elseif ($out -match '(?i)status:\s*disabled' -or $out -match '已禁用|未启用') {
            $st.Enabled = $false; $st.Known = $true
        }
    } catch { }

    # 兜底：直接看 winre.wim 在不在（有些系统 reagentc 输出被裁剪）
    if (-not $st.Known) {
        $wim = Join-Path $env:SystemDrive 'Recovery\WindowsRE\winre.wim'
        if (Test-Path -LiteralPath $wim) { $st.Enabled = $true; $st.Known = $true }
    }
    return $st
}

function Get-OtherWindowsInstalls {
    # 找"另一块盘 / 另一个分区上的 Windows"——双系统时可以直接在那边跑离线清理
    $out = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root -or $d.Root -notmatch '^[A-Za-z]:\\$') { continue }
        if ($d.Root -eq ($env:SystemDrive + '\')) { continue }
        $sys = Join-Path $d.Root 'Windows\System32\config\SYSTEM'
        if (Test-Path -LiteralPath $sys) { [void]$out.Add((Join-Path $d.Root 'Windows')) }
    }
    return @($out)
}

function Get-StagingVolumes {
    # 可用来暂存清理脚本的卷：必须不是系统盘、可写、有点空间
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($v in (Get-Volume -ErrorAction Stop)) {
            if (-not $v.DriveLetter) { continue }
            if ($v.DriveType -ne 'Fixed') { continue }
            $root = $v.DriveLetter + ':\'
            if ($root -eq ($env:SystemDrive + '\')) { continue }
            if ($v.SizeRemaining -lt 16MB) { continue }
            if (Test-PathWritable -Dir $root) {
                [void]$out.Add([pscustomobject]@{
                    Root = $root
                    Label = $v.FileSystemLabel
                    FreeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
                })
            }
        }
    } catch {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $d.Root -or $d.Root -notmatch '^[A-Za-z]:\\$') { continue }
            if ($d.Root -eq ($env:SystemDrive + '\')) { continue }
            if ($d.Free -lt 16MB) { continue }
            if (Test-PathWritable -Dir $d.Root) {
                [void]$out.Add([pscustomobject]@{ Root = $d.Root; Label = ''; FreeGB = [math]::Round($d.Free / 1GB, 1) })
            }
        }
    }
    return @($out)
}

function Show-NoUsbOptions {
    Write-Rule '不用 U 盘 / 不用 PE 的几种办法'
    Write-Host ''
    Write-Host '  先讲清一件事：冰点冻结的是"系统盘上的写入"，不是"必须用 PE"。' -ForegroundColor White
    Write-Host '  只要在"驱动没加载"的环境里改硬盘，效果完全一样。所以下面这几条都能用：' -ForegroundColor Gray
    Write-Host ''

    # 1) 系统自带恢复环境
    $re = Get-WinREStatus
    Write-Host '  【1】系统自带的 Windows 恢复环境（推荐，完全不用 U 盘）' -ForegroundColor Green
    if ($re.Enabled) {
        Write-Host '        当前状态：可用 ✅' -ForegroundColor Green
    } elseif ($re.Known) {
        Write-Host '        当前状态：被禁用（需要先启用；如果系统正冻结，启用可能被回滚）' -ForegroundColor Yellow
    } else {
        Write-Host '        当前状态：查不到（系统可能没有恢复分区）' -ForegroundColor Yellow
    }
    Write-Host '        做法：把清理脚本放到非系统盘 → 重启进"高级启动 → 命令提示符"→ 在那里清理。' -ForegroundColor Gray
    Write-Host '        按 6 可以一键准备（自动放脚本 / 启用 WinRE / 提示重启操作）。' -ForegroundColor Gray
    Write-Host '        ⚠ 但没有实体键盘时，RE 里的命令提示符没法输入 —— 那种情况请按 7 走 U 盘自动模式。' -ForegroundColor Yellow
    Write-Host ''

    # 2) 另一套 Windows
    $others = Get-OtherWindowsInstalls
    if ($others.Count -gt 0) {
        Write-Host '  【2】本机另一套 Windows（检测到了 ✅）' -ForegroundColor Green
        foreach ($w in $others) {
            Write-Host ('        ' + $w) -ForegroundColor Gray
        }
        Write-Host '        做法：重启进那套系统，在那边运行：' -ForegroundColor Gray
        Write-Host ('        Offline\DF-Offline-Clean.ps1 -TargetWindows "' + $env:SystemDrive + '\Windows"') -ForegroundColor DarkGray
        Write-Host '        （注意：在那套系统里，本系统的盘符可能不是 C:）' -ForegroundColor Gray
    } else {
        Write-Host '  【2】本机另一套 Windows：没检测到' -ForegroundColor DarkGray
        Write-Host '        如果这台机器是双系统，重启进另一个系统跑离线清理器即可。' -ForegroundColor DarkGray
    }
    Write-Host ''

    # 3) 解冻窗口
    Write-Host '  【3】解冻窗口（企业版常见）' -ForegroundColor White
    Write-Host '        如果管理员配过"定时解冻"，在解冻时段内系统不受保护，' -ForegroundColor Gray
    Write-Host '        这时直接按 3 在线卸载就行，完全不需要任何介质。' -ForegroundColor Gray
    Write-Host ''

    # 4) 官方途径
    Write-Host '  【4】官方途径（不折腾，最稳）' -ForegroundColor White
    Write-Host '        · 企业版有控制台 → 用"一次性密码 OTP"登录后正常卸载' -ForegroundColor Gray
    Write-Host '        · 未输序列号的试用版 → BIOS 里把时间往后调 60 天，保护失效后正常卸载' -ForegroundColor Gray
    Write-Host ''
    Write-Rule '提醒'
    Write-Log '  除上面这些，"在冻结的系统里直接删冰点"是不成立的：' 'WARN'
    Write-Log '  驱动会把你的写入重定向，重启后原样还原。这是冰点的设计目的，不是工具的限制。' 'DIM'
    return
}

function Invoke-WinREPrep {
    param([string]$Volume, [switch]$DryRun, [switch]$StageOnly)

    Write-Rule '无 U 盘方案：用系统自带的 Windows RE 清理'

    if (Test-IsWinPE) {
        Write-Log '  当前已经在 PE/RE 里了，直接运行 Offline\DF-Offline-Clean.cmd 即可。' 'WARN'
        return $false
    }

    # ---- 1. 目标卷 ----
    $vols = Get-StagingVolumes
    if ($vols.Count -eq 0) {
        Write-Log '  ✗ 没有可用的非系统盘来暂存脚本。' 'ERROR'
        Write-Log '    这个方案的前提是：有一个不被冻结的卷（通常是 D: 数据盘）。' 'DIM'
        Write-Log '    如果你只有 C: 一个盘，请改用 U 盘方案（菜单 2）。' 'DIM'
        return $false
    }

    $pick = $null
    if ($Volume) {
        $v = $Volume.TrimEnd('\') + '\'
        $pick = $vols | Where-Object { $_.Root -eq $v } | Select-Object -First 1
        if (-not $pick) {
            Write-Log ("  ✗ 指定的卷 {0} 不可用（不存在 / 是系统盘 / 只读）。" -f $Volume) 'ERROR'
            return $false
        }
    } elseif ($vols.Count -eq 1) {
        $pick = $vols[0]
    } else {
        Write-Log '  可用的暂存卷：'
        for ($i = 0; $i -lt $vols.Count; $i++) {
            Write-Host ("    [{0}] {1}  {2}  剩余 {3} GB" -f ($i + 1), $vols[$i].Root, $vols[$i].Label, $vols[$i].FreeGB) -ForegroundColor White
        }
        if ($DryRun) { $pick = $vols[0] }
        else {
            $s = Read-Host '  选择卷序号（回车用第一个）'
            $n = 1
            if ([int]::TryParse($s, [ref]$n) -and $n -ge 1 -and $n -le $vols.Count) { $pick = $vols[$n - 1] } else { $pick = $vols[0] }
        }
    }

    $stage = Join-Path $pick.Root 'DFRemover'
    Write-Log ("  脚本将放到：{0}" -f $stage) 'OK'
    Write-Log '  （放在非系统盘的原因：C: 冻结时重启会还原，脚本会消失）' 'DIM'

    if ($DryRun) {
        Write-Log '  [演练] 到此为止，不复制文件、不改 WinRE、不重启。' 'WARN'
        return $true
    }

    # ---- 2. 复制脚本 ----
    try {
        New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop | Out-Null
        $srcDir = Join-Path $PSScriptRoot 'Offline'
        foreach ($n in @('DF-Offline-Clean.cmd', 'DF-Offline-Clean.ps1')) {
            $s = Join-Path $srcDir $n
            if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $stage -Force }
        }
        Write-Log '  清理脚本已复制。' 'OK'
    } catch {
        Write-Log ("  ✗ 复制失败：{0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }

    # ---- 3. WinRE 状态 / 启用 ----
    $re = Get-WinREStatus
    if ($StageOnly) {
        Write-Log '  -StageOnly：只放脚本，不改 Windows RE 设置。' 'WARN'
    } elseif ($re.Enabled) {
        Write-Log '  Windows RE 已可用，无需改动。' 'OK'
    } else {
        Write-Log '  Windows RE 当前不可用，尝试启用...' 'WARN'
        $out = (& reagentc.exe /enable 2>&1) -join "`n"
        $re2 = Get-WinREStatus
        if ($re2.Enabled) {
            Write-Log '  已启用 Windows RE。' 'OK'
        } else {
            Write-Log '  ✗ 启用失败。可能原因：没有恢复分区 / 恢复镜像损坏 / 系统正冻结导致写入被还原。' 'ERROR'
            Write-Log ('    reagentc 输出：' + ($out -replace "`r?`n", ' ')) 'DIM'
            Write-Log '    → 这条路走不通，请改用 U 盘方案（菜单 2）。' 'WARN'
            return $false
        }
    }

    # ---- 4. 操作卡片 ----
    $card = @()
    $card += '冰点还原 · 用系统自带恢复环境卸载（不需要 U 盘）'
    $card += '=' * 64
    $card += ''
    $card += ('清理脚本位置：' + $stage)
    $card += ''
    $card += '【步骤】'
    $card += '  1. 保存工作，重启电脑。'
    $card += '  2. 开机时：设置 → 系统 → 恢复 → 高级启动 → 立即重新启动；'
    $card += '     或者按住 Shift 点"重启"。'
    $card += '  3. 进入蓝色菜单后：疑难解答 → 高级选项 → 命令提示符。'
    $card += '  4. 在命令提示符里先确认盘符（恢复环境里的盘符可能和平时不同）：'
    $card += '        dir C:\Windows\System32\config\SYSTEM'
    $card += ('        dir ' + $pick.Root + 'DFRemover')
    $card += '     如果上面那条不对，把 C: 换成 D:/E: 逐个试。'
    $card += '  5. 找到后执行：'
    $card += ('        ' + $pick.Root + 'DFRemover\DF-Offline-Clean.cmd')
    $card += '     按提示确认，看到"清理完成"后重启。'
    $card += ''
    $card += '【如果重启后发现脚本不见了】'
    $card += '  说明这个卷也被冰点冻结了。换一个数据盘重试，或改用 U 盘方案。'
    $card += ''
    $card += '【回滚】'
    $card += '  清理器会把注册表备份到目标盘 DFBackup_* 目录，里面有回滚说明。'
    Set-Content -LiteralPath (Join-Path $stage 'WinRE操作步骤.txt') -Value $card -Encoding UTF8 -ErrorAction SilentlyContinue

    Write-Rule '准备完成，按下面操作'
    foreach ($l in $card) { Write-Host ('  ' + $l) -ForegroundColor Gray }

    # ---- 5. 重启（必须人工确认，绝不自动） ----
    if (-not $NoPause) {
        $a = Read-Host '  现在重启进入恢复环境吗？输入 REBOOT 立即重启，直接回车稍后自己重启'
        if ($a -eq 'REBOOT') {
            Write-Log '  5 秒后重启进入高级启动...' 'WARN'
            & shutdown.exe /r /o /t 5
        }
    }
    return $true
}

# ============================================================================
# 一键重启到恢复环境（专为“没有实体键盘”设计：全程只用点）
# ============================================================================
function Invoke-RebootToRecovery {
    param([switch]$DryRun)

    Write-Rule '一键重启到恢复环境（不需要键盘）'

    $re = Get-WinREStatus
    $rem = Get-RemovableDrives

    Write-Host '  这条路的每一步都只需要“点”，不需要任何按键：' -ForegroundColor White
    Write-Host '    1) 这里确认 → 电脑自动重启，进蓝色“高级启动”界面' -ForegroundColor Gray
    Write-Host '    2) 点【使用设备】→ 选你的 U 盘' -ForegroundColor Gray
    Write-Host '    3) 进 PE 后双击 U 盘里的「一键卸载-触摸.cmd」' -ForegroundColor Gray
    Write-Host '       —— 它会全自动清理，然后自动重启回 Windows' -ForegroundColor Gray
    Write-Host '    4) 回到 Windows 后，本工具按 [4] 复查' -ForegroundColor Gray
    Write-Host ''

    if ($re.Enabled) {
        Write-Log '  本机 Windows RE 可用（但 RE 里的命令提示符没屏幕键盘，别走那条）' 'OK'
    } else {
        Write-Log '  本机 Windows RE 不可用；不影响“使用设备 → U 盘”这条路。' 'DIM'
    }

    if ($rem.Count -eq 0) {
        Write-Log '  没检测到 U 盘。这条路需要一个 U 盘，请先插上。' 'WARN'
    } else {
        Write-Log ("  检测到 U 盘：{0}" -f ($rem -join ' ')) 'OK'
        if (-not $DryRun) {
            $ans = Read-Host '  把「触摸版自动卸载」写到 U 盘吗？输入 Y 继续'
            if ($ans -match '^(y|yes|是)$') {
                $dst = Join-Path $rem[0] 'DF-Auto'
                try {
                    New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
                    $srcDir = Join-Path $PSScriptRoot 'Offline'
                    foreach ($n in @('一键卸载-触摸.cmd', 'DF-Offline-Clean.cmd', 'DF-Offline-Clean.ps1')) {
                        $s = Join-Path $srcDir $n
                        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination $dst -Force }
                    }
                    Write-Log ("  已写到 {0}（进 PE 后双击里面的「一键卸载-触摸.cmd」）" -f $dst) 'OK'
                } catch {
                    Write-Log ("  写入 U 盘失败：{0}" -f $_.Exception.Message) 'ERROR'
                }
            }
        }
    }

    Write-Host ''
    Write-Log '  ⚠ 没有键盘时，绝对不要用 PE 的“命令提示符”——那里没有屏幕键盘。' 'WARN'
    Write-Log '    只走第 3 步的“双击自动跑”，这是唯一不需要输入的路。' 'WARN'
    Write-Log '  ⚠ 也别把 U 盘设成第一启动项：用“使用设备”是一次性的，重启会自动回 Windows；' 'WARN'
    Write-Log '    改 BIOS 启动顺序的话，没键盘就改不回来了。' 'WARN'

    if ($DryRun) { Write-Log '  [演练] 不会重启。' 'WARN'; return $true }

    $a = Read-Host '  现在重启进入恢复环境吗？输入 REBOOT 立即重启，回车取消'
    if ($a -ne 'REBOOT') { Write-Log '  已取消，未重启。' 'DIM'; return $false }
    Write-Log '  5 秒后重启进入高级启动...' 'WARN'
    & shutdown.exe /r /o /t 5
    return $true
}
# ============================================================================
# 检测
# ============================================================================
function Get-DfSnapshot {
    $snap = [pscustomobject]@{
        Services      = @()
        DriverFiles   = @()
        Dirs          = @()
        FaronicsKeys  = @()
        OtherDfKeys   = @()
        FilterRefs    = @()
        Uninstall     = @()
        Tasks         = @()
        Shortcuts     = @()
        Firewall      = @()
        DataFiles     = @()
        RunValues     = @()
        Installed     = $false
        DriverRunning = $false
        OtherRtr      = @()
    }

    # ---------- 1. 服务 / 驱动 ----------
    $svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $services = New-Object System.Collections.ArrayList
    foreach ($k in (Get-ChildItem -LiteralPath $svcRoot -ErrorAction SilentlyContinue)) {
        $name = $k.PSChildName
        if ($name -in @('Dfsc', 'Dfsd', 'dfssvc')) { continue }   # Microsoft DFS，绝不误伤
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $img = [string]$p.ImagePath
        $disp = [string]$p.DisplayName
        $hit = $false
        if ($script:DfServiceNames -contains $name) { $hit = $true }
        elseif ($img -match $script:DfPathRegex) { $hit = $true }
        elseif ($disp -match $script:DfNameRegex) { $hit = $true }
        if (-not $hit) { continue }

        $type = 0
        try { $type = [int]$p.Type } catch { }
        $status = 'Unknown'
        try { $status = (Get-Service -Name $name -ErrorAction Stop).Status.ToString() } catch { }
        $isKernel = ($type -band 0x7) -in 1, 2   # 1=内核驱动 2=文件系统驱动

        [void]$services.Add([pscustomobject]@{
            Name      = $name
            Display   = $disp
            ImagePath = $img
            Type      = $type
            IsKernel  = $isKernel
            Status    = $status
            KeyPath   = ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $name)
        })
    }
    $snap.Services = @($services)
    $snap.DriverRunning = [bool](@($services | Where-Object { $_.IsKernel -and $_.Status -eq 'Running' }).Count)

    # ---------- 2. 驱动文件 ----------
    $drvDir = Join-Path $env:SystemRoot 'System32\drivers'
    $files = New-Object System.Collections.ArrayList
    foreach ($k in (Get-ChildItem -LiteralPath $drvDir -Filter '*.sys' -ErrorAction SilentlyContinue)) {
        if ($k.Name -in $script:DfDriverFiles) {
            [void]$files.Add([pscustomobject]@{ Path = $k.FullName; Size = $k.Length; Time = $k.LastWriteTime })
        }
    }
    # System32 下冰点自己的可执行文件（不含 dfs* 微软文件）
    foreach ($n in @('DFServ.exe', 'DFServMain.exe', 'DFInstall.exe', 'DeepFrz.exe')) {
        $p = Join-Path $env:SystemRoot ('System32\' + $n)
        if (Test-Path -LiteralPath $p) {
            $i = Get-Item -LiteralPath $p
            [void]$files.Add([pscustomobject]@{ Path = $i.FullName; Size = $i.Length; Time = $i.LastWriteTime })
        }
    }
    $snap.DriverFiles = @($files)

    # ---------- 3. 安装目录 ----------
    $dirs = New-Object System.Collections.ArrayList
    foreach ($d in @(
            (Join-Path $env:ProgramFiles 'Faronics'),
            (Join-Path ${env:ProgramFiles(x86)} 'Faronics'),
            (Join-Path $env:ProgramData 'Faronics'),
            (Join-Path $env:APPDATA 'Faronics'),
            (Join-Path $env:LOCALAPPDATA 'Faronics')
        )) {
        if ($d -and (Test-Path -LiteralPath $d)) { [void]$dirs.Add($d) }
    }
    $snap.Dirs = @($dirs)

    # ---------- 4. 注册表：Faronics 主键 ----------
    # 策略：若 Faronics 下只有冰点自己的子键 → 整个 Faronics 一起删（彻底）；
    #       若还装着 Faronics 的其他产品（Anti-Executable / Insight 等）→ 只删冰点子键。
    $farKeys = New-Object System.Collections.ArrayList
    $keepKeys = New-Object System.Collections.ArrayList
    foreach ($root in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
        $fk = Join-Path $root 'Faronics'
        if (-not (Test-Path -LiteralPath $fk)) { continue }
        $subs = @(Get-ChildItem -LiteralPath $fk -ErrorAction SilentlyContinue)
        $dfSubs = @($subs | Where-Object { $_.PSChildName -match $script:DfNameRegex })
        $keepSubs = @($subs | Where-Object { $_.PSChildName -notmatch $script:DfNameRegex })
        if ($keepSubs.Count -eq 0) {
            [void]$farKeys.Add($fk)               # 只有冰点 → 整键删除
        } else {
            foreach ($s in $dfSubs) { [void]$farKeys.Add($s.PSPath) }
            foreach ($s in $keepSubs) { [void]$keepKeys.Add($s.PSPath) }
        }
    }
    $snap.FaronicsKeys = @($farKeys | Select-Object -Unique)
    $snap.OtherDfKeys = @($keepKeys | Select-Object -Unique)

    # ---------- 5. 注册表：设备类过滤器 UpperFilters / LowerFilters ----------
    $refs = New-Object System.Collections.ArrayList
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class'
    foreach ($cls in (Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
        foreach ($vn in @('UpperFilters', 'LowerFilters')) {
            $v = $null
            $p = Get-ItemProperty -LiteralPath $cls.PSPath -Name $vn -ErrorAction SilentlyContinue
            if ($p) { $v = $p.$vn }
            if ($null -eq $v) { continue }
            $items = @($v)
            $hits = @($items | Where-Object { $_ -and ($_ -match $script:DfNameRegex) })
            if ($hits.Count -gt 0) {
                [void]$refs.Add([pscustomobject]@{
                    Key       = $cls.PSPath
                    KeyName   = $cls.PSChildName
                    ValueName = $vn
                    Full      = ($items -join ' / ')
                    Hits      = ($hits -join ', ')
                })
            }
        }
    }
    $snap.FilterRefs = @($refs)

    # ---------- 6. 卸载登记项 ----------
    $un = New-Object System.Collections.ArrayList
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $dn = [string]$p.DisplayName
            $pub = [string]$p.Publisher
            if ($dn -match $script:DfNameRegex -or $pub -match 'Faronics') {
                [void]$un.Add([pscustomobject]@{
                    Path    = $k.PSPath
                    Name    = $dn
                    Version = [string]$p.DisplayVersion
                    Publisher = $pub
                    Uninstall = [string]$p.UninstallString
                })
            }
        }
    }
    $snap.Uninstall = @($un)

    # ---------- 7. 启动项 ----------
    $run = New-Object System.Collections.ArrayList
    foreach ($rk in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        )) {
        $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if (([string]$prop.Value) -match $script:DfPathRegex -or $prop.Name -match $script:DfNameRegex) {
                [void]$run.Add([pscustomobject]@{ Key = $rk; Name = $prop.Name; Value = [string]$prop.Value })
            }
        }
    }
    $snap.RunValues = @($run)

    # ---------- 8. 计划任务 ----------
    $tasks = New-Object System.Collections.ArrayList
    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
            if ($t.TaskName -match $script:DfNameRegex -or $t.TaskPath -match '(?i)Faronics') {
                [void]$tasks.Add([pscustomobject]@{ Path = $t.TaskPath; Name = $t.TaskName })
            }
        }
    } catch { }
    $snap.Tasks = @($tasks)

    # ---------- 9. 快捷方式 ----------
    $sc = New-Object System.Collections.ArrayList
    foreach ($d in @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            ([Environment]::GetFolderPath('Desktop')),
            ([Environment]::GetFolderPath('CommonDesktopDirectory'))
        )) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            if ($f.BaseName -match $script:DfNameRegex) { [void]$sc.Add($f.FullName) }
        }
    }
    $snap.Shortcuts = @($sc)

    # ---------- 10. 防火墙规则 ----------
    $fw = New-Object System.Collections.ArrayList
    try {
        foreach ($r in (Get-NetFirewallRule -ErrorAction Stop)) {
            if ($r.DisplayName -match $script:DfNameRegex) { [void]$fw.Add($r.DisplayName) }
        }
    } catch { }
    $snap.Firewall = @($fw)

    # ---------- 11. 卷根目录的数据文件 persi0.sys ----------
    $data = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root -or $d.Root -notmatch '^[A-Za-z]:\\$') { continue }
        foreach ($n in @('persi0.sys', 'persi1.sys', 'persi2.sys')) {
            $p = Join-Path $d.Root $n
            if (Test-Path -LiteralPath $p) {
                $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                [void]$data.Add([pscustomobject]@{ Path = $p; Size = $i.Length })
            }
        }
    }
    $snap.DataFiles = @($data)

    $snap.Installed = [bool](
        $snap.Services.Count -or $snap.DriverFiles.Count -or $snap.Dirs.Count -or
        $snap.FaronicsKeys.Count -or $snap.FilterRefs.Count -or $snap.Uninstall.Count -or
        $snap.DataFiles.Count
    )
    $snap.OtherRtr = @(Get-OtherRtrFindings)
    return $snap
}

# ============================================================================
# 其它"重启还原"类软件（只识别，不处理）
#   —— 受 DeepThaw 支持范围启发：机器上可能装的不是冰点，而是这些
# ============================================================================
function Get-OtherRtrFindings {
    $hits = New-Object System.Collections.ArrayList
    $pat = '(?i)(Reboot\s*Restore|RebootRestore|Rollback\s*Rx|RollbackRx|Shadow\s*Defender|ShadowDefender|Horizon\s*Data\s*Sys|Drive\s*Cloner)'

    # 服务 / 驱动（看显示名与镜像路径）
    foreach ($k in (Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $disp = [string]$p.DisplayName
        $img = [string]$p.ImagePath
        if (($disp -and ($disp -match $pat)) -or ($img -and ($img -match $pat))) {
            [void]$hits.Add([pscustomobject]@{
                    Product = $(if ($disp) { $disp.Trim() } else { $k.PSChildName })
                    Where   = ('服务 ' + $k.PSChildName)
                })
        }
    }

    # 安装目录
    foreach ($d in @(
            (Join-Path $env:ProgramFiles 'Horizon DataSys'),
            (Join-Path ${env:ProgramFiles(x86)} 'Horizon DataSys'),
            (Join-Path $env:ProgramFiles 'Shadow Defender'),
            (Join-Path ${env:ProgramFiles(x86)} 'Shadow Defender')
        )) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            [void]$hits.Add([pscustomobject]@{ Product = '安装目录'; Where = $d })
        }
    }

    # 控制面板卸载项
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $dn = [string]$p.DisplayName
            if ($dn -and ($dn -match $pat)) {
                [void]$hits.Add([pscustomobject]@{ Product = $dn.Trim(); Where = '卸载项' })
            }
        }
    }

    return @($hits | Sort-Object Product, Where -Unique)
}

# ============================================================================
# 报告
# ============================================================================
function Show-DfReport {
    param($Snap)

    Write-Rule '检测结果'

    if (-not $Snap.Installed) {
        Write-Log '  未在本机发现 冰点还原 (Deep Freeze) 的任何痕迹。' 'OK'
        if ($Snap.OtherRtr -and $Snap.OtherRtr.Count) {
            Write-Log '  但发现了其它"重启还原"类软件（本工具不处理）：' 'WARN'
            foreach ($r in $Snap.OtherRtr) { Write-Host ("      {0,-28} ← {1}" -f $r.Product, $r.Where) -ForegroundColor Gray }
            Write-Log '    这类（Rollback Rx / Reboot Restore Rx / Shadow Defender）要用别的工具；' 'DIM'
            Write-Log '    思路可参考 docs\DeepThaw-技术评估.md。' 'DIM'
        } else {
            Write-Log '  如果冰点确实装过、且你现在就在这台机器上，请确认没有看错机器。' 'DIM'
        }
        return
    }

    Write-Log '  发现 冰点还原 组件：' 'WARN'

    if ($Snap.Services.Count) {
        Write-Log '  ● 服务 / 驱动：'
        foreach ($s in $Snap.Services) {
            $kind = if ($s.IsKernel) { '驱动' } else { '服务' }
            $state = $s.Status
            Write-Host ("      {0,-12} [{1}] 状态={2}" -f $s.Name, $kind, $state) -ForegroundColor Gray
            if ($s.ImagePath) { Write-Host ("                    {0}" -f $s.ImagePath) -ForegroundColor DarkGray }
        }
    }
    if ($Snap.FilterRefs.Count) {
        Write-Log '  ● 设备类过滤器（开机最先加载的东西）：'
        foreach ($r in $Snap.FilterRefs) {
            Write-Host ("      {0}  {1} = {2}" -f $r.KeyName, $r.ValueName, $r.Full) -ForegroundColor Gray
        }
    }
    if ($Snap.DriverFiles.Count) {
        Write-Log '  ● 驱动/程序文件：'
        foreach ($f in $Snap.DriverFiles) {
            Write-Host ("      {0}  ({1:N0} 字节)" -f $f.Path, $f.Size) -ForegroundColor Gray
        }
    }
    if ($Snap.Dirs.Count) {
        Write-Log '  ● 安装目录：'
        foreach ($d in $Snap.Dirs) { Write-Host ("      {0}" -f $d) -ForegroundColor Gray }
    }
    if ($Snap.FaronicsKeys.Count) {
        Write-Log '  ● 注册表（Faronics）：'
        foreach ($k in $Snap.FaronicsKeys) { Write-Host ("      {0}" -f $k) -ForegroundColor Gray }
    }
    if ($Snap.Uninstall.Count) {
        Write-Log '  ● 控制面板卸载项：'
        foreach ($u in $Snap.Uninstall) {
            Write-Host ("      {0} {1}" -f $u.Name, $u.Version) -ForegroundColor Gray
        }
    }
    if ($Snap.DataFiles.Count) {
        Write-Log '  ● 卷根目录数据文件（冰点的持久化数据）：'
        foreach ($f in $Snap.DataFiles) { Write-Host ("      {0}  ({1:N0} 字节)" -f $f.Path, $f.Size) -ForegroundColor Gray }
    }
    if ($Snap.Tasks.Count) {
        Write-Log '  ● 计划任务：'
        foreach ($t in $Snap.Tasks) { Write-Host ("      {0}{1}" -f $t.Path, $t.Name) -ForegroundColor Gray }
    }
    if ($Snap.RunValues.Count) {
        Write-Log '  ● 开机启动项：'
        foreach ($r in $Snap.RunValues) { Write-Host ("      {0} = {1}" -f $r.Name, $r.Value) -ForegroundColor Gray }
    }
    if ($Snap.Shortcuts.Count) {
        Write-Log '  ● 快捷方式：'
        foreach ($s in $Snap.Shortcuts) { Write-Host ("      {0}" -f $s) -ForegroundColor Gray }
    }
    if ($Snap.Firewall.Count) {
        Write-Log '  ● 防火墙规则：'
        foreach ($f in $Snap.Firewall) { Write-Host ("      {0}" -f $f) -ForegroundColor Gray }
    }

    if ($Snap.OtherRtr -and $Snap.OtherRtr.Count) {
        Write-Log '  ● 另外还发现其它"重启还原"类软件（本工具不处理，仅提醒）：'
        foreach ($r in $Snap.OtherRtr) { Write-Host ("      {0,-28} ← {1}" -f $r.Product, $r.Where) -ForegroundColor Gray }
    }

    Write-Rule '状态判断与建议'
    if ($Snap.DriverRunning) {
        Write-Log '  判断：过滤驱动正在运行 → 系统极可能处于【冻结/受保护】状态。' 'WARN'
        Write-Log '  在这种状态下，即使现在删文件、改注册表，重启后也会被驱动原样还原，等于白做。' 'WARN'
        Write-Log ''
        Write-Log '  ✅ 正确做法：【离线卸载】' 'OK'
        Write-Log '     1) 选菜单 [2] 生成"PE 离线卸载包"，把它拷到 U 盘；'
        Write-Log '     2) 用 U 盘启动进 PE（微PE / 优启通 / Windows 安装盘都行）；'
        Write-Log '     3) 在 PE 里运行 U 盘上的 DF-Offline-Clean.cmd，按提示确认即可。'
    } else {
        Write-Log '  判断：过滤驱动没有运行 → 系统当前未被冻结，可以直接在线卸载。' 'OK'
        Write-Log '  ✅ 建议：选菜单 [3] 执行在线强制卸载，完成后选 [4] 复查。'
        Write-Log '     （注意：如果刚改过"下次启动解冻"，必须先重启一次再卸载，否则同样会被还原。）' 'DIM'
    }
    Write-Log ''
    Write-Log '  提示：本工具不破解、也不读取密码。它做的是"绕过密码、直接把组件从系统里摘除"。' 'DIM'
}

# ============================================================================
# 备份
# ============================================================================
function New-DfBackup {
    param($Snap, [string]$PreferredDir)

    # 备份目录不再是"写死一个位置就失败即中止"，而是按可写性逐个尝试。
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $name = 'DFBackup_' + $stamp
    $cands = New-Object System.Collections.ArrayList
    if ($PreferredDir) { [void]$cands.Add($PreferredDir) }
    if ($PSScriptRoot) {
        [void]$cands.Add((Join-Path $PSScriptRoot $name))
        try {
            $q = Split-Path -Qualifier $PSScriptRoot
            if ($q) { [void]$cands.Add(($q + '\' + $name)) }
        } catch { }
    }
    if ($env:TEMP) { [void]$cands.Add((Join-Path $env:TEMP $name)) }
    if ($env:LOCALAPPDATA) { [void]$cands.Add((Join-Path $env:LOCALAPPDATA $name)) }

    $bk = $null
    $lastErr = ''
    foreach ($c in $cands) {
        try {
            New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null
            if (Test-PathWritable -Dir $c) { $bk = $c; break }
        } catch { $lastErr = $_.Exception.Message }
    }

    if (-not $bk) {
        Write-Log '  ✗ 注册表备份失败：所有候选目录都不可写。' 'ERROR'
        Write-Log ("    最后错误：{0}" -f $lastErr) 'DIM'
        Write-Log '    常见原因：U 盘写保护 / 光盘 / 只读共享 / 磁盘已满 / 安全软件拦截写入。' 'DIM'
        Write-Log '    处理办法：加 -BackupDir 指定一个可写目录（例如 -BackupDir D:\dfbk），或把工具复制到硬盘再运行。' 'DIM'
        Write-Log '    本次仍会继续卸载，但**没有回滚能力**。' 'WARN'
        return [pscustomobject]@{ Dir = $null; Count = 0; Total = 0; Failed = $true }
    }

    $n = 0
    $okCount = 0
    $restore = New-Object System.Collections.Generic.List[string]
    $restore.Add('@echo off')
    $restore.Add('rem 冰点卸载前注册表备份的还原脚本（右键"以管理员身份运行"）')
    $restore.Add('chcp 936 >nul')
    $restore.Add('cd /d "%~dp0"')
    $restore.Add('echo 正在还原注册表备份...')

    $keys = @()
    $keys += @($Snap.FaronicsKeys)
    $keys += @($Snap.Services | ForEach-Object { $_.KeyPath })
    $keys += @($Snap.FilterRefs | ForEach-Object { $_.Key })
    $keys = @($keys | Where-Object { $_ } | Select-Object -Unique)

    foreach ($k in $keys) {
        $n++
        $file = Join-Path $bk ("{0:D2}.reg" -f $n)
        $regPath = $k -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
        & reg.exe export $regPath $file /y 2>$null | Out-Null

        # 导出成功还不够，要确认文件真的是一个完整 .reg（防"写了个空文件"）
        $good = $false
        if (Test-Path -LiteralPath $file) {
            $fi = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 100) {
                $head = Get-Content -LiteralPath $file -TotalCount 3 -ErrorAction SilentlyContinue
                if (($head -join ' ') -match 'Windows Registry Editor') { $good = $true }
            }
        }
        if ($good) {
            $okCount++
            $restore.Add(('reg import "{0}" >nul 2>&1' -f (Split-Path -Leaf $file)))
        } else {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            $n--
            Write-Log ("  未能导出（跳过）：{0}" -f $regPath) 'DIM'
        }
    }

    # 文件清单（便于事后确认；驱动文件本身不做物理备份）
    $lines = @()
    $lines += '== 驱动/程序文件 =='
    $lines += @($Snap.DriverFiles | ForEach-Object { $_.Path })
    $lines += '== 安装目录 =='
    $lines += @($Snap.Dirs)
    $lines += '== 数据文件 =='
    $lines += @($Snap.DataFiles | ForEach-Object { $_.Path })
    $lines += '== 服务/过滤器 =='
    $lines += @($Snap.Services | ForEach-Object { $_.Name + '  ' + $_.ImagePath })
    Set-Content -LiteralPath (Join-Path $bk 'files_before.txt') -Value $lines -Encoding UTF8

    if ($okCount -gt 0) {
        $restore.Add('echo 完成。建议立即重启。')
        $restore.Add('pause')
        $restore | Set-Content -LiteralPath (Join-Path $bk 'restore.cmd') -Encoding OEM
        Write-Log ("  已备份 {0} 个注册表键 → {1}（还原：restore.cmd）" -f $okCount, $bk) 'OK'
    } else {
        $msg = @(
            '本次未能导出任何注册表键。',
            '可能原因：安全软件拦截 reg export、目标目录权限不足、磁盘空间不足。',
            '如果需要回滚能力，请换一个可写目录重来：-BackupDir D:\dfbk',
            '（本次卸载仍会继续执行。）'
        )
        Set-Content -LiteralPath (Join-Path $bk '备份失败说明.txt') -Value $msg -Encoding UTF8
        Write-Log '  ⚠ 一个注册表键都没备份成功，本次卸载没有回滚能力。' 'WARN'
        Write-Log ("    目录：{0}" -f $bk) 'DIM'
    }

    return [pscustomobject]@{
        Dir    = $bk
        Count  = $okCount
        Total  = $keys.Count
        Failed = ($okCount -eq 0)
    }
}

# ============================================================================
# 底层操作助手
# ============================================================================
function Remove-RegKeySafe {
    param([string]$Path, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }   # 已经不在了，算成功
    if ($DryRun) { Write-Log ("  [演练] 删除注册表键 {0}" -f $Path) 'DIM'; return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
        & reg.exe delete $regPath /f 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
}

function Get-FilterListItems {
    param([string]$KeyPath, [string]$ValueName)
    $p = Get-ItemProperty -LiteralPath $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $v = $p.$ValueName
    if ($null -eq $v) { return @() }
    if ($v -is [System.Array]) { return @($v) }
    return @([string]$v)
}

function Remove-DfFromFilterList {
    param([string]$KeyPath, [string]$ValueName, [switch]$DryRun)
    $items = Get-FilterListItems -KeyPath $KeyPath -ValueName $ValueName
    if ($null -eq $items) { return $false }
    if ($items.Count -eq 0) { return $false }

    $kept = @($items | Where-Object { $_ -ne '' -and ($_ -notmatch $script:DfNameRegex) })
    if ($kept.Count -eq $items.Count) { return $false }

    $removed = @($items | Where-Object { $_ -and ($_ -match $script:DfNameRegex) })
    if ($DryRun) {
        Write-Log ("  [演练] {0}\{1} 移除 {2}" -f $KeyPath, $ValueName, ($removed -join ', ')) 'DIM'
        return $true
    }

    try {
        if ($kept.Count -eq 0) {
            Remove-ItemProperty -LiteralPath $KeyPath -Name $ValueName -Force -ErrorAction Stop
        } else {
            Set-ItemProperty -LiteralPath $KeyPath -Name $ValueName -Value ([string[]]$kept) -Type MultiString -Force -ErrorAction Stop
        }
        Write-Log ("  已清理过滤器 {0}\{1}：移除 {2}，保留 {3}" -f $KeyPath, $ValueName, ($removed -join ','), (($kept -join ',') -replace '^$', '无')) 'OK'
        return $true
    } catch {
        Write-Log ("  清理过滤器失败 {0}\{1}：{2}" -f $KeyPath, $ValueName, $_.Exception.Message) 'ERROR'
        return $false
    }
}

# 计划在下次启动时删除（用于被占用的 .sys）
if (-not ('DfNativeFile' -as [type])) {
    try {
        Add-Type -Namespace '' -Name 'DfNativeFile' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@ -ErrorAction Stop
    } catch { }
}

function Remove-FileHard {
    param([string]$Path, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($DryRun) { Write-Log ("  [演练] 删除文件 {0}" -f $Path) 'DIM'; return $true }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Log ("  已删除文件 {0}" -f $Path) 'OK'
        return $true
    } catch { }

    # 被内核占用 → 登记为"下次启动删除"
    try {
        $ok = [DfNativeFile]::MoveFileEx($Path, $null, 4)   # MOVEFILE_DELAY_UNTIL_REBOOT
        if ($ok) {
            Write-Log ("  文件正被占用，已登记重启后删除：{0}" -f $Path) 'WARN'
            return $true
        }
    } catch { }

    Write-Log ("  删除失败（可能被占用），重启后再试：{0}" -f $Path) 'ERROR'
    return $false
}

function Remove-DirHard {
    param([string]$Path, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($DryRun) { Write-Log ("  [演练] 删除目录 {0}" -f $Path) 'DIM'; return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log ("  已删除目录 {0}" -f $Path) 'OK'
        return $true
    } catch {
        Write-Log ("  目录删除不完整：{0}（{1}）" -f $Path, $_.Exception.Message) 'WARN'
        return $false
    }
}

# ============================================================================
# 在线卸载
# ============================================================================
function Invoke-DfRemove {
    param($Snap, [switch]$Force, [switch]$DryRun)

    if (-not $Snap.Installed) {
        Write-Log '  没有可卸载的内容。' 'OK'
        return $true
    }
    if ($Snap.DriverRunning -and -not $Force) {
        Write-Rule '已阻止：系统处于冻结/受保护状态'
        Write-Log '  过滤驱动正在运行，现在做在线卸载 100% 会被重启还原，还可能把系统弄成半残。' 'ERROR'
        Write-Log '  请改用【离线卸载】：菜单 [2] 生成 PE 离线卸载包。' 'WARN'
        Write-Log '  （确实要强行尝试，可加 -Force 参数，但后果自负。）' 'DIM'
        return $false
    }

    Write-Rule '开始在线卸载'
    if ($DryRun) { Write-Log '  === 演练模式：只显示动作，不改动系统 ===' 'WARN' }

    $bk = New-DfBackup -Snap $Snap -PreferredDir $BackupDir
    $ok = $true

    # --- 1. 停止服务 ---
    foreach ($s in $Snap.Services) {
        if ($s.Status -eq 'Running' -and -not $s.IsKernel) {
            if ($DryRun) { Write-Log ("  [演练] 停止服务 {0}" -f $s.Name) 'DIM'; continue }
            & sc.exe stop $s.Name 2>&1 | Out-Null
            Start-Sleep -Milliseconds 400
            Write-Log ("  已请求停止服务 {0}" -f $s.Name) 'OK'
        }
    }
    Start-Sleep -Milliseconds 600

    # --- 2. 删除服务/驱动登记 ---
    foreach ($s in $Snap.Services) {
        if ($DryRun) { Write-Log ("  [演练] sc delete {0}" -f $s.Name) 'DIM'; continue }
        & sc.exe delete $s.Name 2>&1 | Out-Null
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Log ("  已删除服务 {0}" -f $s.Name) 'OK'
        } elseif ($code -eq 1072) {
            Write-Log ("  服务 {0} 已标记为删除（重启后彻底消失）" -f $s.Name) 'OK'
        } else {
            if (Remove-RegKeySafe -Path $s.KeyPath -DryRun:$DryRun) {
                Write-Log ("  sc 删除失败({0})，已直接删除服务键 {1}" -f $code, $s.Name) 'OK'
            } else {
                Write-Log ("  无法删除服务 {0}" -f $s.Name) 'ERROR'
                $ok = $false
            }
        }
    }

    # --- 3. 清理设备类过滤器 ---
    foreach ($r in $Snap.FilterRefs) {
        if (-not (Remove-DfFromFilterList -KeyPath $r.Key -ValueName $r.ValueName -DryRun:$DryRun)) {
            Write-Log ("  警告：过滤器项未清理干净 {0}\{1}" -f $r.Key, $r.ValueName) 'WARN'
        }
    }

    # --- 4. 删除文件与目录 ---
    foreach ($f in $Snap.DriverFiles) {
        if (-not (Remove-FileHard -Path $f.Path -DryRun:$DryRun)) { $ok = $false }
    }
    foreach ($d in $Snap.Dirs) {
        if (-not (Remove-DirHard -Path $d -DryRun:$DryRun)) { $ok = $false }
    }
    foreach ($f in $Snap.DataFiles) {
        if (-not (Remove-FileHard -Path $f.Path -DryRun:$DryRun)) { $ok = $false }
    }

    # --- 5. 注册表清理 ---
    foreach ($k in $Snap.FaronicsKeys) {
        if (Remove-RegKeySafe -Path $k -DryRun:$DryRun) {
            Write-Log ("  已删除注册表键 {0}" -f $k) 'OK'
        } else {
            Write-Log ("  删除注册表键失败 {0}" -f $k) 'ERROR'
            $ok = $false
        }
    }
    foreach ($u in $Snap.Uninstall) {
        if (Remove-RegKeySafe -Path $u.Path -DryRun:$DryRun) {
            Write-Log ("  已删除卸载登记项 {0}" -f $u.Name) 'OK'
        }
    }
    foreach ($rv in $Snap.RunValues) {
        if ($DryRun) { continue }
        try {
            Remove-ItemProperty -LiteralPath $rv.Key -Name $rv.Name -Force -ErrorAction Stop
            Write-Log ("  已删除启动项 {0}" -f $rv.Name) 'OK'
        } catch {
            Write-Log ("  删除启动项失败 {0}" -f $rv.Name) 'WARN'
        }
    }

    # --- 6. 计划任务 / 快捷方式 / 防火墙 ---
    foreach ($t in $Snap.Tasks) {
        if ($DryRun) { Write-Log ("  [演练] 删除计划任务 {0}{1}" -f $t.Path, $t.Name) 'DIM'; continue }
        try {
            Unregister-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -Confirm:$false -ErrorAction Stop
            Write-Log ("  已删除计划任务 {0}{1}" -f $t.Path, $t.Name) 'OK'
        } catch {
            Write-Log ("  删除计划任务失败 {0}{1}" -f $t.Path, $t.Name) 'WARN'
        }
    }
    foreach ($s in $Snap.Shortcuts) {
        if ($DryRun) { continue }
        try {
            Remove-Item -LiteralPath $s -Force -ErrorAction Stop
            Write-Log ("  已删除快捷方式 {0}" -f $s) 'OK'
        } catch { }
    }
    foreach ($f in $Snap.Firewall) {
        if ($DryRun) { continue }
        try {
            Remove-NetFirewallRule -DisplayName $f -ErrorAction Stop
            Write-Log ("  已删除防火墙规则 {0}" -f $f) 'OK'
        } catch { }
    }

    Write-Rule '在线卸载结束'
    if ($ok) {
        Write-Log '  ✅ 组件已清理。' 'OK'
        Write-Log '  ⚠ 请立即重启，重启后再运行一次 [4] 复查残留。' 'WARN'
        Write-Log '    重启前不要再做其他"重要"改动——万一还有残留过滤器，重启可能失败。' 'DIM'
        if ($bk -and $bk.Dir -and $bk.Count -gt 0) {
            Write-Log ("  如需回滚：{0}\restore.cmd" -f $bk.Dir) 'DIM'
        } elseif ($bk -and $bk.Dir) {
            Write-Log ("  本次没有可回滚的注册表备份，详见 {0}" -f $bk.Dir) 'WARN'
        }
    } else {
        Write-Log '  ⚠ 有项目未能清理（见上方红字），重启后请再运行一次卸载或改用离线方案。' 'WARN'
    }
    return $ok
}

# ============================================================================
# 生成 PE 离线卸载包
# ============================================================================
function New-DfOfflineKit {
    param($Snap, [string]$KitDir)

    if (-not $KitDir) {
        # 优先直接写到 U 盘（离线包必须在 U 盘上才有意义），其次脚本目录
        $rem = Get-RemovableDrives
        if ($rem.Count -ge 1) {
            $KitDir = Join-Path $rem[0] 'PE离线卸载包'
            Write-Log ("  检测到可移动磁盘 {0}，离线包将直接写到 U 盘。" -f $rem[0]) 'OK'
        } else {
            $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
            $KitDir = Join-Path $base 'PE离线卸载包'
            Write-Log '  没检测到 U 盘，先写到脚本目录；生成后请手动拷到 U 盘。' 'WARN'
        }
    }

    Write-Rule '生成 PE 离线卸载包'
    if (-not (Test-PathWritable -Dir (Split-Path -Parent $KitDir))) {
        # 父目录不可写（比如只读共享），退到 TEMP
        $alt = Get-PortableWritableDir
        if ($alt) {
            $KitDir = Join-Path $alt 'PE离线卸载包'
            Write-Log ("  目标不可写，改写到：{0}" -f $KitDir) 'WARN'
        }
    }
    try {
        New-Item -ItemType Directory -Path $KitDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log ("  无法创建目录 {0}：{1}" -f $KitDir, $_.Exception.Message) 'ERROR'
        return $false
    }

    $srcDir = Join-Path $PSScriptRoot 'Offline'
    $copied = 0
    foreach ($n in @('一键卸载-触摸.cmd', 'DF-Offline-Clean.cmd', 'DF-Offline-Clean.ps1', '离线操作.txt')) {
        $src = Join-Path $srcDir $n
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $KitDir $n) -Force
            $copied++
        }
    }
    $readme = Join-Path $PSScriptRoot '使用说明.md'
    if (Test-Path -LiteralPath $readme) { Copy-Item -LiteralPath $readme $KitDir -Force }

    # 定制一份"本机专属"的操作提示
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add('冰点还原 · PE 离线强制卸载（本机专属步骤）')
    $report.Add('=' * 60)
    $report.Add(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $report.Add(('计算机名：{0}' -f $env:COMPUTERNAME))
    $report.Add(('系统盘　：{0}' -f $env:SystemDrive))
    $report.Add('')
    $report.Add('【本机检测到的冰点组件】')
    if ($Snap.Services.Count) { $report.Add('  服务/驱动：' + (($Snap.Services | ForEach-Object { $_.Name }) -join ', ')) }
    if ($Snap.FilterRefs.Count) { $report.Add('  类过滤器：' + (($Snap.FilterRefs | ForEach-Object { $_.KeyName + ':' + $_.ValueName }) -join ', ')) }
    if ($Snap.DriverFiles.Count) { $report.Add('  驱动文件：' + (($Snap.DriverFiles | ForEach-Object { Split-Path -Leaf $_.Path }) -join ', ')) }
    if ($Snap.Dirs.Count) { $report.Add('  安装目录：' + (($Snap.Dirs) -join '; ')) }
    $report.Add('')
    $report.Add('【操作步骤】')
    $report.Add('  1. 把本文件夹整个拷到 U 盘（FAT32 或 NTFS 都行）。')
    $report.Add('  2. 关机，用 U 盘启动进 PE（微PE/优启通/Windows 安装盘 按 Shift+F10 均可）。')
    $report.Add('  3. 打开 PE 里的"命令提示符"，执行：')
    $report.Add('        X:\你的U盘\PE离线卸载包\DF-Offline-Clean.cmd')
    $report.Add('     （X 换成 U 盘实际盘符；路径有空格要加引号）')
    $report.Add('  4. 确认目标系统盘（一般会自动识别为 C: 或 D:），输入 Y 回车。')
    $report.Add('  5. 看到"清理完成"后重启，进系统后再运行一次 DFRemover.ps1 的 [4] 复查。')
    $report.Add('')
    $report.Add('【如果 PE 里没有 CMD 的中文显示 / 想更彻底】')
    $report.Add('  在 PE 的命令提示符里执行（需要 PE 自带 PowerShell）：')
    $report.Add('        powershell -ExecutionPolicy Bypass -File X:\...\DF-Offline-Clean.ps1')
    $report.Add('')
    $report.Add('【重要】')
    $report.Add('  · 一定要在"关机后"再启动 PE，不要在休眠/快速启动状态下操作。')
    $report.Add('  · 脚本会先把 SYSTEM/SOFTWARE 注册表备份到目标盘 DFBackup_* 目录。')
    $report.Add('  · 切勿先删文件后删注册表，顺序错了会导致开机 0x7B 蓝屏。')
    $report.Add('  · 本工具不做密码破解；忘记密码时用这种"物理摘除"方式，效果等同卸载。')
    Set-Content -LiteralPath (Join-Path $KitDir '离线操作.txt') -Value $report -Encoding UTF8

    Write-Log ("  ✅ 已生成：{0}（含 {1} 个脚本）" -f $KitDir, $copied) 'OK'
    Write-Log '  ⚠ 现在就把整个文件夹拷到 U 盘，再重启进 PE 执行。' 'WARN'
    Write-Log '    脚本写在本机硬盘上是没用的——冻结状态重启就没了。' 'WARN'
    return $true
}

# ============================================================================
# 复查
# ============================================================================
function Invoke-DfVerify {
    Write-Rule '卸载后残留复查'
    $snap = Get-DfSnapshot
    $left = @()
    if ($snap.Services.Count) { $left += ('服务/驱动 ' + (($snap.Services | ForEach-Object { $_.Name }) -join ',')) }
    if ($snap.FilterRefs.Count) { $left += ('类过滤器 ' + (($snap.FilterRefs | ForEach-Object { $_.KeyName }) -join ',')) }
    if ($snap.DriverFiles.Count) { $left += ('驱动文件 ' + (($snap.DriverFiles | ForEach-Object { Split-Path -Leaf $_.Path }) -join ',')) }
    if ($snap.Dirs.Count) { $left += ('安装目录 ' + ($snap.Dirs -join ',')) }
    if ($snap.FaronicsKeys.Count) { $left += ('注册表 ' + ($snap.FaronicsKeys -join ',')) }
    if ($snap.Uninstall.Count) { $left += ('卸载登记 ' + (($snap.Uninstall | ForEach-Object { $_.Name }) -join ',')) }
    if ($snap.DataFiles.Count) { $left += ('数据文件 ' + (($snap.DataFiles | ForEach-Object { $_.Path }) -join ',')) }
    if ($snap.Tasks.Count) { $left += ('计划任务 ' + (($snap.Tasks | ForEach-Object { $_.Name }) -join ',')) }

    if ($left.Count -eq 0) {
        Write-Log '  ✅ 干净了：服务、驱动、过滤器、目录、注册表、数据文件 全部无残留。' 'OK'
        Write-Log '  建议再做一次重启验证：重启后本报告仍然"干净"，才算真正彻底。' 'DIM'
        return $true
    }

    Write-Log '  仍发现以下残留：' 'WARN'
    foreach ($l in $left) { Write-Host ("      · " + $l) -ForegroundColor Gray }
    Write-Log ''
    Write-Log '  如果刚刚在线卸载过，请先重启；重启后仍有残留，请用 PE 离线包再清一次。' 'WARN'
    return $false
}

# ============================================================================
# 导出配置清单（刻意不含密码：只记录结构信息，不导出任何注册表值）
# ============================================================================
function Invoke-DfExportConfig {
    param($Snap, [string]$OutDir)

    Write-Rule '导出配置清单（不含密码）'

    if (-not $OutDir) {
        $OutDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }
    if (-not (Test-PathWritable -Dir $OutDir)) {
        $alt = Get-PortableWritableDir
        if ($alt) { $OutDir = $alt } else {
            Write-Log '  ✗ 找不到可写目录，无法导出。' 'ERROR'
            return $false
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = Join-Path $OutDir ('DF配置清单-' + $stamp + '.md')
    $outEnc = New-Object System.Text.UTF8Encoding($true)

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('# 冰点还原 (Deep Freeze) 配置清单')
    $L.Add('')
    $L.Add('> 本文件**刻意不包含任何注册表值**。冰点把与密码相关的数据存放在注册表值里，')
    $L.Add('> 因此这里只记录"结构信息"（有哪些组件、在哪、什么版本），供卸载后重装时对照。')
    $L.Add('')
    $L.Add('## 基本信息')
    $L.Add('')
    $L.Add('| 项 | 值 |')
    $L.Add('|---|---|')
    $L.Add(('| 生成时间 | {0} |' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $L.Add(('| 计算机名 | {0} |' -f $env:COMPUTERNAME))
    $L.Add(('| 操作系统 | {0} |' -f (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption))
    $L.Add(('| 系统盘 | {0} |' -f $env:SystemDrive))
    $L.Add(('| 冻结状态判断 | {0} |' -f $(if ($Snap.DriverRunning) { '过滤驱动正在运行（很可能是冻结状态）' } else { '过滤驱动未运行（未冻结或已禁用）' })))
    $L.Add('')

    $L.Add('## 检测到的组件')
    $L.Add('')
    if (-not ($Snap.Services.Count -or $Snap.FilterRefs.Count -or $Snap.Dirs.Count -or
              $Snap.DriverFiles.Count -or $Snap.DataFiles.Count -or $Snap.FaronicsKeys.Count)) {
        $L.Add('（未检测到冰点组件）')
        $L.Add('')
    }
    if ($Snap.Services.Count) {
        $L.Add('### 服务 / 驱动')
        $L.Add('')
        $L.Add('| 名称 | 类型 | 状态 | 映像路径 |')
        $L.Add('|---|---|---|---|')
        foreach ($s in $Snap.Services) {
            $L.Add(('| {0} | {1} | {2} | {3} |' -f $s.Name, $(if ($s.IsKernel) { '驱动' } else { '服务' }), $s.Status, $s.ImagePath))
        }
        $L.Add('')
    }
    if ($Snap.FilterRefs.Count) {
        $L.Add('### 开机过滤器（UpperFilters / LowerFilters）')
        $L.Add('')
        $L.Add('| 设备类 GUID | 值名 | 当前内容 | 冰点条目 |')
        $L.Add('|---|---|---|---|')
        foreach ($r in $Snap.FilterRefs) {
            $L.Add(('| {0} | {1} | {2} | {3} |' -f $r.KeyName, $r.ValueName, $r.Full, $r.Hits))
        }
        $L.Add('')
    }
    if ($Snap.Dirs.Count) {
        $L.Add('### 安装目录')
        $L.Add('')
        foreach ($d in $Snap.Dirs) { $L.Add(('- `' + $d + '`')) }
        $L.Add('')
    }
    if ($Snap.DriverFiles.Count) {
        $L.Add('### 驱动 / 程序文件')
        $L.Add('')
        foreach ($f in $Snap.DriverFiles) { $L.Add(('- `' + $f.Path + '`')) }
        $L.Add('')
    }
    if ($Snap.DataFiles.Count) {
        $L.Add('### 数据文件（persi*.sys）')
        $L.Add('')
        $L.Add('这些文件所在的卷，很可能就是冰点"冻结"的卷：')
        $L.Add('')
        foreach ($f in $Snap.DataFiles) {
            $vol = Split-Path -Qualifier $f.Path
            $L.Add(('- `' + $f.Path + '`（卷 {0}）' -f $vol))
        }
        $L.Add('')
    }
    if ($Snap.FaronicsKeys.Count) {
        $L.Add('### 注册表键（只列路径，不导出内容）')
        $L.Add('')
        foreach ($k in $Snap.FaronicsKeys) { $L.Add(('- `' + $k + '`')) }
        $L.Add('')
    }

    $L.Add('## 版本信息')
    $L.Add('')
    if ($Snap.Uninstall.Count) {
        $L.Add('| 名称 | 版本 | 发布者 |')
        $L.Add('|---|---|---|')
        foreach ($u in $Snap.Uninstall) { $L.Add(('| {0} | {1} | {2} |' -f $u.Name, $u.Version, $u.Publisher)) }
    } else {
        $L.Add('（未在控制面板卸载项中找到版本信息）')
    }
    $L.Add('')

    $L.Add('## 重装后对照表')
    $L.Add('')
    $L.Add('卸载并重新安装冰点时，按这张表逐项确认（重装时可以设置**新密码**）：')
    $L.Add('')
    $vols = @($Snap.DataFiles | ForEach-Object { Split-Path -Qualifier $_.Path } | Select-Object -Unique)
    $L.Add(('- [ ] 需要冻结的卷：{0}' -f $(if ($vols) { $vols -join ', ' } else { '（未推断出，请按实际情况勾选）' })))
    $L.Add(('- [ ] 是否开机即冻结：{0}' -f '需要在冰点界面确认（本清单无法读取该设置）'))
    $L.Add('- [ ] 解冻/冻结的时间窗口（如有）')
    $L.Add('- [ ] 密码：重新设置')
    if ($Snap.Tasks.Count) {
        $L.Add(('- [ ] 计划任务：{0}' -f (($Snap.Tasks | ForEach-Object { $_.Path + $_.Name }) -join '; ')))
    }
    if ($Snap.RunValues.Count) {
        $L.Add(('- [ ] 开机启动项：{0}' -f (($Snap.RunValues | ForEach-Object { $_.Name }) -join '; ')))
    }
    $L.Add('')

    try {
        [IO.File]::WriteAllLines($file, [string[]]$L, $outEnc)
        Write-Log ('  ✅ 已导出：' + $file) 'OK'
        Write-Log '  该文件只含结构信息，不含密码相关数据。' 'DIM'
        return $true
    } catch {
        Write-Log ('  ✗ 写入失败：' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Show-UninstallGuide {
    $doc = Join-Path $PSScriptRoot 'docs\卸载思路对比.md'
    if (Test-Path -LiteralPath $doc) {
        Write-Log ('  教程：' + $doc) 'OK'
        try { Start-Process -FilePath $doc -ErrorAction Stop | Out-Null }
        catch { Write-Log '  无法自动打开，请按上面的路径手动查看。' 'WARN' }
    } else {
        Write-Log ('  找不到教程文件：' + $doc) 'ERROR'
        Write-Log '  请确认 docs 文件夹完整（可从仓库重新下载）。' 'DIM'
    }
}
# ============================================================================
# UEFI 一次性启动：下次启动进 U 盘 / PE（不改 BIOS 启动顺序）
# ============================================================================
function Test-UefiFirmware {
    try {
        if ($env:firmware_type) { return ($env:firmware_type -eq 'UEFI') }
        $p = Get-CimInstance Win32_DiskPartition -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq 'GPT: System' }
        return ([bool]$p)
    } catch { return $false }
}

function Get-FirmwareBootEntries {
    # 解析 bcdedit /enum firmware。标签可能是英文也可能被本地化，所以按"GUID 结构"解析而不是按词。
    $lines = @(& bcdedit.exe /enum firmware 2>$null)
    $out = New-Object System.Collections.ArrayList
    $cur = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(?:identifier|标识符)\s+(\{[0-9a-fA-F\-]+\})') {
            if ($cur) { [void]$out.Add($cur) }
            $cur = [pscustomobject]@{ Guid = $matches[1]; Name = ''; Title = '' }
            # 标题是 identifier 上方最近的一行非空、非分隔线文本
            for ($j = $i - 1; $j -ge 0; $j--) {
                $cand = $lines[$j]
                if ([string]::IsNullOrWhiteSpace($cand)) { continue }
                if ($cand -match '^-+$') { continue }
                $cur.Title = $cand.Trim()
                break
            }
            continue
        }
        if ($cur -and ($line -match '^\s*(?:description|描述)\s+(.+)$')) {
            $cur.Name = $matches[1].Trim()
        }
    }
    if ($cur) { [void]$out.Add($cur) }
    return @($out | Where-Object { $_.Guid -ne '{fwbootmgr}' })
}

function Get-FwBootSequence {
    # {fwbootmgr} 里"标签 + GUID 同一行"的项就是 bootsequence（displayorder 是标签行 + 独立 GUID 行）
    $lines = @(& bcdedit.exe /enum '{fwbootmgr}' 2>$null)
    foreach ($l in $lines) {
        if ($l -match '^\s*(\S+)\s+(\{[0-9a-fA-F\-]{36}\})\s*$') {
            if ($matches[1] -match '^(identifier|标识符)$') { continue }
            return $matches[2]
        }
    }
    return $null
}

function Set-OneTimeBoot {
    param([string]$Guid, [switch]$DryRun)

    if ($DryRun) {
        Write-Log ('  [演练] 将设置一次性启动：' + $Guid) 'DIM'
        return $true
    }

    # 改 BCD 前先导出备份
    try {
        $dir = if (Test-PathWritable -Dir $PSScriptRoot) { $PSScriptRoot } else { Get-PortableWritableDir }
        if ($dir) {
            $bk = Join-Path $dir ('BCD-Backup-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.bcd')
            & bcdedit.exe /export $bk 2>$null | Out-Null
            if (Test-Path -LiteralPath $bk) {
                Write-Log ('  BCD 已备份：' + $bk) 'OK'
            }
        }
    } catch { }

    $r = & bcdedit.exe /set '{fwbootmgr}' bootsequence $Guid 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log ('  ✗ 设置失败：' + ($r -join ' ')) 'ERROR'
        return $false
    }
    $now = Get-FwBootSequence
    if ($now -eq $Guid) {
        Write-Log ('  ✅ 已设置：下次启动优先尝试 ' + $Guid) 'OK'
    } else {
        Write-Log ('  ⚠ 命令返回成功，但回读不一致（当前：' + $now + '）') 'WARN'
        Write-Log '    某些 OEM 固件不支持这种一次性引导，重启后可能仍进 Windows。' 'DIM'
    }
    return $true
}

function Clear-OneTimeBoot {
    $had = Get-FwBootSequence
    $r = & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log '  已清除一次性启动项，恢复原有启动顺序。' 'OK'
        return $true
    }
    if ($had) {
        Write-Log ('  ✗ 清除失败：' + ($r -join ' ')) 'ERROR'
        return $false
    }
    Write-Log '  当前本来就没有设置一次性启动项。' 'DIM'
    return $true
}

function Invoke-BootEntry {
    param([switch]$DryRun)

    Write-Rule '下次启动进入 U 盘 / PE（UEFI 一次性启动）'

    if (-not (Test-UefiFirmware)) {
        Write-Log '  当前是 Legacy BIOS 启动，Windows 无法安排"一次性启动项"。' 'ERROR'
        Write-Log '  Legacy 机器只能用开机热键（F12 / F11 / Esc / F8）选启动设备。' 'DIM'
        Write-Log '  不想按热键的话：菜单 [7] 进"高级启动"，再点【使用设备】选 U 盘。' 'DIM'
        return $false
    }

    $entries = @(Get-FirmwareBootEntries)
    if ($entries.Count -eq 0) {
        Write-Log '  没有读到任何固件启动项（bcdedit 可能被策略限制）。' 'ERROR'
        return $false
    }

    $cur = Get-FwBootSequence
    if ($cur) {
        Write-Log ('  注意：当前已经设置了一次性启动 -> ' + $cur) 'WARN'
        Write-Log '        它只生效一次；重启后会自动恢复。选 [0] 可以立即清除。' 'DIM'
    }

    Write-Host ''
    Write-Log '  固件里可用的启动项：'
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $name = if ($entries[$i].Name) { $entries[$i].Name } else { $entries[$i].Title }
        Write-Host ("    [{0}] {1}" -f ($i + 1), $name) -ForegroundColor White
        Write-Host ("         {0}" -f $entries[$i].Guid) -ForegroundColor DarkGray
    }
    Write-Host '    [0] 清除已设置的一次性启动项' -ForegroundColor DarkGray
    Write-Host ''

    $sel = Read-Host '  选择序号（直接回车 = 取消）'
    if ([string]::IsNullOrWhiteSpace($sel)) { Write-Log '  已取消。' 'DIM'; return $false }

    if ($sel.Trim() -eq '0') { return (Clear-OneTimeBoot) }

    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $entries.Count) {
        Write-Log '  序号无效。' 'ERROR'
        return $false
    }
    $e = $entries[$n - 1]
    $name = if ($e.Name) { $e.Name } else { $e.Title }

    Write-Host ''
    Write-Log ('  下次启动将指向：' + $name) 'OK'
    Write-Log '  · 只影响**下一次**启动，之后自动回到原来的顺序' 'DIM'
    Write-Log '  · **不会**修改 BIOS 里保存的启动顺序' 'DIM'
    Write-Log '  · 如果该设备其实不可启动，大多数固件会自动跳到下一项（回到 Windows）' 'DIM'
    Write-Log '  · 前提：U 盘是 UEFI 可引导的（PE 支持 UEFI）' 'DIM'

    if (-not $DryRun) {
        $ok = Read-Host '  确认设置？输入 YES 继续'
        if ($ok -ne 'YES') { Write-Log '  已取消。' 'DIM'; return $false }
    }

    $done = Set-OneTimeBoot -Guid $e.Guid -DryRun:$DryRun
    if (-not $done) { return $false }

    if (-not $DryRun) {
        $a = Read-Host '  现在重启吗？输入 REBOOT 立即重启，回车稍后自己重启'
        if ($a -eq 'REBOOT') {
            Write-Log '  5 秒后重启（开机时请确保 U 盘已插好）...' 'WARN'
            & shutdown.exe /r /t 5
        } else {
            Write-Log '  已就绪，你随时重启即可。' 'DIM'
        }
    }
    return $true
}

# ============================================================================
# 菜单
# ============================================================================
$script:MenuEmpty = 0
function Show-DfMenu {
    while ($true) {
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║        冰点还原 (Deep Freeze) 强制卸载 · 彻底清理            ║' -ForegroundColor Cyan
        Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1] 扫描本机（只读，建议先看这个）' -ForegroundColor White
        Write-Host '    [2] 生成 PE 离线卸载包 ★忘记密码时用这个' -ForegroundColor Green
        Write-Host '    [3] 在线强制卸载（仅限已解冻的系统）' -ForegroundColor Yellow
        Write-Host '    [4] 卸载后复查残留' -ForegroundColor White
        Write-Host '    [5] 环境自检（换电脑先跑这个）' -ForegroundColor White
        Write-Host '    [6] 不想做 U 盘？用系统自带恢复环境卸载' -ForegroundColor Green
        Write-Host '    [7] 一键重启到恢复环境（没有实体键盘用这个）' -ForegroundColor Green
        Write-Host '    [8] 导出配置清单（不含密码，重装时对照）' -ForegroundColor White
        Write-Host '    [9] 卸载思路对比（打开教程）' -ForegroundColor White
        Write-Host '   [10] 下次启动进 U 盘/PE（UEFI 一次性启动）' -ForegroundColor Green
        Write-Host '    [0] 退出' -ForegroundColor DarkGray
        Write-Host ''
        $c = Read-Host '  请选择'
        if ([string]::IsNullOrWhiteSpace($c)) {
            $script:MenuEmpty++
            if ($script:MenuEmpty -ge 3) { Write-Host '  连续空输入，退出。' -ForegroundColor DarkGray; return }
        } else { $script:MenuEmpty = 0 }
        switch ($c.Trim()) {
            '1' { $s = Get-DfSnapshot; Show-DfReport -Snap $s }
            '2' { $s = Get-DfSnapshot; Show-DfReport -Snap $s; [void](New-DfOfflineKit -Snap $s -KitDir $KitDir) }
            '3' {
                $s = Get-DfSnapshot
                Show-DfReport -Snap $s
                if (-not $s.Installed) { break }
                if ($s.DriverRunning) {
                    Write-Log '  驱动仍在运行，在线卸载无效。请改用 [2] 或 [6]。' 'ERROR'
                    break
                }
                $ans = Read-Host '  确认执行在线卸载？输入 YES 继续'
                if ($ans -eq 'YES') { [void](Invoke-DfRemove -Snap $s -Force:$Force -DryRun:$DryRun) }
            }
            '4' { [void](Invoke-DfVerify) }
            '5' { [void](Show-Doctor) }
            '7' { [void](Invoke-RebootToRecovery -DryRun:$DryRun) }
            '8' { $s = Get-DfSnapshot; [void](Invoke-DfExportConfig -Snap $s) }
            '9' { Show-UninstallGuide }
            '10' { [void](Invoke-BootEntry -DryRun:$DryRun) }
            '6' {
                Show-NoUsbOptions
                $a = Read-Host '  现在准备"用系统自带恢复环境"的方案吗？输入 Y 继续'
                if ($a -match '^(y|yes|是)$') { [void](Invoke-WinREPrep -Volume $StageVolume -DryRun:$DryRun -StageOnly:$StageOnly) }
            }
            '0' { return }
            default { Write-Host '  无效选择。' -ForegroundColor DarkGray }
        }
    }
}

# ============================================================================
# PE 模式：在 PE / WinRE 里直接卸载（不需要再去找另一个脚本）
# ============================================================================
function Get-PeTargets {
    # 找所有"装了 Windows"的卷（排除 PE 自己的 X: 盘）
    $out = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root -or $d.Root -notmatch '^[A-Za-z]:\\$') { continue }
        if ($env:SystemDrive -and ($d.Root -eq ($env:SystemDrive + '\'))) { continue }
        $w = Join-Path $d.Root 'Windows'
        if (Test-Path -LiteralPath (Join-Path $w 'System32\config\SYSTEM')) {
            [void]$out.Add([pscustomobject]@{ WinDir = $w; Root = $d.Root })
        }
    }
    return @($out)
}

function Invoke-RegQuiet {
    param([string[]]$A)
    & reg.exe @A 2>$null | Out-Null
    return $LASTEXITCODE
}

function Dismount-PeHive {
    # 带重试的卸载：hive 一旦泄漏，同一个文件再也挂不上，所以必须确认卸掉
    param([string]$Name)
    for ($i = 0; $i -lt 4; $i++) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        if ((Invoke-RegQuiet @('unload', "HKLM\$Name")) -eq 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Get-RegLines {
    param([string[]]$A)
    $out = & reg.exe @A 2>$null
    return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = @($out) }
}

function Get-RegMultiSz {
    # 从 reg query 输出里取出某个 REG_MULTI_SZ，按 \0 拆开
    param([string[]]$Lines, [string]$ValueName)
    $pat = '^\s+' + [regex]::Escape($ValueName) + '\s+REG_MULTI_SZ\s*(.*)$'
    foreach ($line in $Lines) {
        if ($line -match $pat) {
            $raw = $matches[1]
            if (-not $raw) { return @() }
            return @($raw -split '\\0')
        }
    }
    return @()
}

function Get-PeHiveFindings {
    # 只读检查：挂上目标注册表数一数，然后卸掉。
    # 全程用 reg.exe，不走 PowerShell 注册表提供程序——提供程序会缓存句柄，
    # 导致 reg unload 失败、hive 泄漏（泄漏后同一文件再也挂不上）。
    param([string]$WinDir)

    $res = [pscustomobject]@{ Services = @(); Filters = @(); Faronics = $false; Error = '' }
    $sysFile = Join-Path $WinDir 'System32\config\SYSTEM'
    $swFile = Join-Path $WinDir 'System32\config\SOFTWARE'
    $hive = 'DF_PECHK'

    [void](Dismount-PeHive -Name $hive)
    if ((Invoke-RegQuiet @('load', "HKLM\$hive", $sysFile)) -ne 0) {
        $res.Error = '无法挂载 SYSTEM 注册表（BitLocker 加密 / 文件损坏 / 盘符不对）'
        return $res
    }

    try {
        $sets = @()
        $r = Get-RegLines @('query', "HKLM\$hive")
        foreach ($l in $r.Lines) {
            if ($l -match '\\(ControlSet\d{3})$') { $sets += $matches[1] }
        }
        if ($sets.Count -eq 0) { $sets = @('ControlSet001') }

        foreach ($cs in $sets) {
            $svc = Get-RegLines @('query', "HKLM\$hive\$cs\Services")
            if ($svc.Code -eq 0) {
                $names = @()
                foreach ($l in $svc.Lines) { if ($l -match '\\([^\\]+)$') { $names += $matches[1] } }
                foreach ($n in $script:DfServiceNames) {
                    if ($names -contains $n) { $res.Services += ($cs + '\' + $n) }
                }
            }

            $clsRoot = "HKLM\$hive\$cs\Control\Class"
            $cls = Get-RegLines @('query', $clsRoot)
            if ($cls.Code -ne 0) { continue }
            foreach ($l in $cls.Lines) {
                if ($l -notmatch '\{[0-9a-fA-F\-]{36}\}$') { continue }
                $guid = $matches[0].Trim()
                $keyPath = "$clsRoot\$guid"
                foreach ($vn in @('UpperFilters', 'LowerFilters')) {
                    $q = Get-RegLines @('query', $keyPath, '/v', $vn)
                    if ($q.Code -ne 0) { continue }
                    $items = Get-RegMultiSz -Lines $q.Lines -ValueName $vn
                    foreach ($it in $items) {
                        if ($it -and ($it -match $script:DfNameRegex)) {
                            $res.Filters += ($guid + ':' + $vn + '=' + $it)
                        }
                    }
                }
            }
        }
    } finally {
        if (-not (Dismount-PeHive -Name $hive)) {
            $res.Error = '注册表挂载后无法卸载，请重启 PE 后再试'
        }
    }

    if (Test-Path -LiteralPath $swFile) {
        $h2 = 'DF_PECHKSW'
        [void](Dismount-PeHive -Name $h2)
        if ((Invoke-RegQuiet @('load', "HKLM\$h2", $swFile)) -eq 0) {
            try {
                if ((Get-RegLines @('query', "HKLM\$h2\Faronics")).Code -eq 0) { $res.Faronics = $true }
            } finally {
                if (-not (Dismount-PeHive -Name $h2)) {
                    $res.Error = 'SOFTWARE 注册表挂载后无法卸载，请重启 PE 后再试'
                }
            }
        }
    }
    return $res
}

function Show-PeFindings {
    param($Targets)

    Write-Rule 'PE 里的检测结果'
    if (-not $Targets -or $Targets.Count -eq 0) {
        Write-Log '  没有找到任何 Windows 系统。' 'ERROR'
        Write-Log '  如果盘是 BitLocker 加密的，PE 下读不到，需要先解锁。' 'DIM'
        return $false
    }

    $any = $false
    foreach ($tg in $Targets) {
        Write-Host ('  ● 目标系统：' + $tg.WinDir) -ForegroundColor White
        $f = Get-PeHiveFindings -WinDir $tg.WinDir
        if ($f.Error) {
            Write-Log ('      ' + $f.Error) 'WARN'
            continue
        }
        if ((($f.Services.Count + $f.Filters.Count) -eq 0) -and (-not $f.Faronics)) {
            Write-Log '      未发现冰点组件' 'OK'
            continue
        }
        $any = $true
        if ($f.Services.Count) { Write-Host ('      服务/驱动：' + ($f.Services -join ', ')) -ForegroundColor Gray }
        if ($f.Filters.Count) { Write-Host ('      开机过滤器：' + ($f.Filters -join ', ')) -ForegroundColor Gray }
        if ($f.Faronics) { Write-Host '      注册表：存在 Faronics 键' -ForegroundColor Gray }
    }
    return $any
}

function Select-PeTarget {
    param($Targets)
    if ($Targets.Count -le 1) { return $Targets[0] }
    Write-Log ('  检测到 {0} 个 Windows 系统：' -f $Targets.Count) 'WARN'
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        Write-Host ('    [{0}] {1}' -f ($i + 1), $Targets[$i].WinDir) -ForegroundColor White
    }
    $s = Read-Host '  输入序号（直接回车 = 清理第 1 个）'
    $n = 1
    if ([int]::TryParse($s, [ref]$n) -and $n -ge 1 -and $n -le $Targets.Count) { return $Targets[$n - 1] }
    return $Targets[0]
}

function Invoke-PeRemove {
    param([switch]$RebootAfter)

    Write-Rule 'PE 强制卸载'
    $targets = Get-PeTargets
    if ($targets.Count -eq 0) {
        Write-Log '  没有找到 Windows 系统，无法卸载。' 'ERROR'
        return $false
    }

    $tg = Select-PeTarget -Targets $targets
    Write-Log ('  目标系统：{0}' -f $tg.WinDir) 'OK'

    $f = Get-PeHiveFindings -WinDir $tg.WinDir
    if ($f.Error) { Write-Log ('  ' + $f.Error) 'ERROR'; return $false }
    if ((($f.Services.Count + $f.Filters.Count) -eq 0) -and (-not $f.Faronics)) {
        Write-Log '  这个系统里没有发现冰点，无需卸载。' 'OK'
        return $false
    }

    Write-Log '  将执行：摘除服务/驱动登记 -> 清开机过滤器 -> 删 Faronics 键与卸载项 -> 删驱动文件与数据文件' 'DIM'
    $a = Read-Host '  确认强制卸载？输入 YES 继续'
    if ($a -ne 'YES') { Write-Log '  已取消。' 'DIM'; return $false }

    $engine = Join-Path $PSScriptRoot 'Offline\DF-Offline-Clean.ps1'
    if (-not (Test-Path -LiteralPath $engine)) {
        Write-Log ('  找不到卸载引擎：' + $engine) 'ERROR'
        Write-Log '  请确认 Offline 文件夹完整。' 'DIM'
        return $false
    }

    # 注意：数组 splat 会被当成位置参数，必须用哈希表 splat 才能传具名参数
    $engineArgs = @{ TargetWindows = $tg.WinDir; Yes = $true }
    if ($RebootAfter) { $engineArgs['Reboot'] = $true }
    Write-Log '  开始调用卸载引擎...' 'OK'
    & $engine @engineArgs

    Write-Host ''
    Write-Rule '卸载后复查'
    $f2 = Get-PeHiveFindings -WinDir $tg.WinDir
    if ($f2.Error) {
        Write-Log ('  ' + $f2.Error) 'WARN'
    } elseif ((($f2.Services.Count + $f2.Filters.Count) -eq 0) -and (-not $f2.Faronics)) {
        Write-Log '  ✅ 注册表里已经干净了（服务、过滤器、Faronics 键都没了）' 'OK'
    } else {
        Write-Log '  ⚠ 仍有残留：' 'WARN'
        if ($f2.Services.Count) { Write-Host ('      ' + ($f2.Services -join ', ')) -ForegroundColor Gray }
        if ($f2.Filters.Count) { Write-Host ('      ' + ($f2.Filters -join ', ')) -ForegroundColor Gray }
        if ($f2.Faronics) { Write-Host '      Faronics 键仍在' -ForegroundColor Gray }
        Write-Log '    可以再跑一次 [2]。' 'DIM'
    }

    if (-not $RebootAfter) {
        Write-Log '  现在可以按 [4] 重启回 Windows。' 'DIM'
    }
    return $true
}

function Invoke-PeReboot {
    $a = Read-Host '  现在重启回 Windows 吗？输入 REBOOT 继续，回车取消'
    if ($a -ne 'REBOOT') { Write-Log '  已取消。' 'DIM'; return }
    Write-Log '  正在重启...' 'WARN'
    $w = Join-Path $env:SystemRoot 'System32\wpeutil.exe'
    if (Test-Path -LiteralPath $w) { & $w reboot; return }
    & shutdown.exe /r /t 3 /f
}

$script:PeEmpty = 0
function Show-PeMenu {
    while ($true) {
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║        冰点还原 (Deep Freeze) 强制卸载 · PE 模式             ║' -ForegroundColor Cyan
        Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1] 检测目标系统里的冰点（只读）' -ForegroundColor White
        Write-Host '    [2] 强制卸载冰点 ★免密码，直接摘除' -ForegroundColor Green
        Write-Host '    [3] 卸载后复查' -ForegroundColor White
        Write-Host '    [4] 重启回 Windows' -ForegroundColor White
        Write-Host '    [5] 环境自检' -ForegroundColor White
        Write-Host '    [0] 退出' -ForegroundColor DarkGray
        Write-Host ''
        $c = Read-Host '  请选择'
        if ([string]::IsNullOrWhiteSpace($c)) {
            $script:PeEmpty++
            if ($script:PeEmpty -ge 3) { Write-Host '  连续空输入，退出。' -ForegroundColor DarkGray; return }
        } else { $script:PeEmpty = 0 }
        switch ($c.Trim()) {
            '1' { [void](Show-PeFindings -Targets (Get-PeTargets)) }
            '2' { [void](Invoke-PeRemove) }
            '3' { [void](Show-PeFindings -Targets (Get-PeTargets)) }
            '4' { Invoke-PeReboot }
            '5' { [void](Show-Doctor) }
            '0' { return }
            default { Write-Host '  无效选择。' -ForegroundColor DarkGray }
        }
    }
}

# ============================================================================
# 主流程
# ============================================================================
Initialize-Log

Write-Host ''
Write-Host '  冰点还原 (Deep Freeze) 强制卸载工具  v1.2.2' -ForegroundColor Cyan
Write-Host '  ──────────────────────────────────────────────────────────────' -ForegroundColor DarkCyan

$script:IsAdmin = Test-AdminRights
if (-not $script:IsAdmin) {
    # 自己提权（不依赖 cmd 里的引号拼接，路径带空格/中文都不会坏）
    Write-Host '  需要管理员权限，正在尝试提权（会弹 UAC，请点"是"）...' -ForegroundColor Yellow

    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    $exe = 'powershell.exe'
    try { $exe = (Get-Process -Id $PID).Path } catch { }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $self))
    foreach ($k in $PSBoundParameters.Keys) {
        switch ($k) {
            { $_ -in @('Mode', 'KitDir', 'BackupDir') } {
                $argList += ('-' + $k)
                $argList += ('"{0}"' -f $PSBoundParameters[$k])
            }
            { $_ -in @('Force', 'DryRun', 'NoPause') } {
                if ($PSBoundParameters[$k]) { $argList += ('-' + $k) }
            }
        }
    }

    try {
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        exit 2      # 约定：2 = 已提权并另开窗口，Start.cmd 见到 2 就不再暂停
    } catch {
        Write-Host '  ✗ 提权失败或被取消。请右键"以管理员身份运行"，或双击 Start.cmd。' -ForegroundColor Red
        if (-not $NoPause) { Read-Host '按回车退出' | Out-Null }
        exit 1
    }
}

# 换电脑使用时的两个高频坑，开机就先说清楚
$script:InPE = Test-IsWinPE
if ($script:InPE) {
    Write-Host '  ✔ 检测到当前在 PE / Windows RE 中，自动进入【PE 模式】（可直接强制卸载）。' -ForegroundColor Green
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host '  ⚠ 当前是 32 位 PowerShell，注册表会被重定向到 WOW6432Node，可能漏键。' -ForegroundColor Yellow
    Write-Host '    建议用 Start.cmd 启动（它会自动选 64 位 PowerShell）。' -ForegroundColor Yellow
}

try {
    if ($script:InPE) {
        switch ($Mode) {
            'PeScan'   { [void](Show-PeFindings -Targets (Get-PeTargets)) }
            'PeRemove' { [void](Invoke-PeRemove) }
            'PeVerify' { [void](Show-PeFindings -Targets (Get-PeTargets)) }
            'Doctor'   { [void](Show-Doctor) }
            default    { Show-PeMenu }
        }
        return
    }

    switch ($Mode) {
        'Scan' {
            $s = Get-DfSnapshot
            Show-DfReport -Snap $s
        }
        'Auto' {
            $s = Get-DfSnapshot
            Show-DfReport -Snap $s
            [void](New-DfOfflineKit -Snap $s -KitDir $KitDir)
        }
        'PrepareOffline' {
            $s = Get-DfSnapshot
            Show-DfReport -Snap $s
            [void](New-DfOfflineKit -Snap $s -KitDir $KitDir)
        }
        'Remove' {
            $s = Get-DfSnapshot
            Show-DfReport -Snap $s
            if ($s.Installed) { [void](Invoke-DfRemove -Snap $s -Force:$Force -DryRun:$DryRun) }
        }
        'Verify' { [void](Invoke-DfVerify) }
        'Doctor' { [void](Show-Doctor) }
        'BootMenu' { [void](Invoke-RebootToRecovery -DryRun:$DryRun) }
        'Inventory' { $s = Get-DfSnapshot; Show-DfReport -Snap $s; [void](Invoke-DfExportConfig -Snap $s) }
        'Guide' { Show-UninstallGuide }
        'BootEntry' { [void](Invoke-BootEntry -DryRun:$DryRun) }
        'BootEntryClear' { [void](Clear-OneTimeBoot) }
        'WinRE' {
            Show-NoUsbOptions
            [void](Invoke-WinREPrep -Volume $StageVolume -DryRun:$DryRun -StageOnly:$StageOnly)
        }
        default { Show-DfMenu }
    }
} catch {
    Write-Host ''
    Write-Host ('  ✗ 运行出错：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('    ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
    $script:LogLines.Add('EXCEPTION: ' + ($_ | Out-String))
} finally {
    Save-Log
}

if (-not $NoPause -and $Mode -ne 'Menu') {
    Write-Host ''
    if ($script:LogPath) { Write-Host ("  日志：{0}" -f $script:LogPath) -ForegroundColor DarkGray }
    Read-Host '按回车退出' | Out-Null
}
