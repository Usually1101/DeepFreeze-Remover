#requires -Version 5.1
<#
  冰点还原 (Faronics Deep Freeze) · PE 离线强制卸载器
  ============================================================================
  文件名 : DF-Offline-Clean.ps1
  运行环境: WinPE / Windows RE（需要 PowerShell；没有 PowerShell 的 PE 请用
            同目录下的 DF-Offline-Clean.cmd）
  作  用 : 系统关机后从 PE 启动，把冰点的"注册表加载点 + 驱动文件 + 过滤器 +
            安装目录 + 数据文件"一次性摘除。因为过滤驱动没在运行，改动不会被还原。

  为什么必须离线：
    冰点的过滤驱动在内核里拦截所有写入。系统跑起来时，你删掉的服务键、文件，
    重启后都会被驱动从"冻结基线"里恢复回去。只有驱动没加载的环境（PE / 另一套
    系统）才能真删掉。

  为什么顺序不能反（先注册表、后文件）：
    如果先删 DFFilter.sys，却留着 Services\DFFilter 和 UpperFilters 登记，下次
    开机内核会去加载一个不存在的驱动 → 0x7B INACCESSIBLE_BOOT_DEVICE 蓝屏。
    本脚本严格按"先摘登记、再删实体"的顺序执行。

  用法：
    powershell -ExecutionPolicy Bypass -File DF-Offline-Clean.ps1
    powershell -ExecutionPolicy Bypass -File DF-Offline-Clean.ps1 -TargetWindows D:\Windows -Yes
    powershell -ExecutionPolicy Bypass -File DF-Offline-Clean.ps1 -DryRun     # 只看不动
#>
[CmdletBinding()]
param(
    # 目标系统的 Windows 目录，例如 D:\Windows。不填则自动搜索。
    [string]$TargetWindows,

    # 跳过所有确认（自动模式）
    [switch]$Yes,

    # 只显示将要做什么，不实际修改
    [switch]$DryRun,

    # 注册表备份输出目录，默认放在目标盘根目录 DFBackup_时间戳
    [string]$BackupDir,

    # 保留 persi0.sys 等数据文件（一般不需要）
    [switch]$KeepData,

    # 不处理 hiberfil.sys（不推荐：快速启动/休眠会让注册表改动失效）
    [switch]$SkipHibernationFix,

    # 备份失败时也继续卸载（默认会询问；加这个参数表示"不问，照做"）
    # 同时用作"跳过 PE 环境检查"的强制开关（在正常系统里调试时用，危险）
    [switch]$Force,

    # 清理完成后自动重启（PE 里用 wpeutil reboot，回到 Windows）
    [switch]$Reboot,

    # 明确不重启（默认行为，写出来更清楚；会覆盖 -Reboot）
    [switch]$NoReboot,

    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# ============================================================================
# 组件清单 —— 必须与 DFRemover.ps1 / DF-Offline-Clean.cmd 保持一致
# ============================================================================
$DfServiceNames = @(
    'DFServ', 'DFFilter', 'DeepFrz', 'DfDiskLo', 'FarDisk', 'FarSpace', 'DFInstall'
)
$DfDriverFiles = @(
    'DFFilter.sys', 'DeepFrz.sys', 'FarDisk.sys', 'FarSpace.sys', 'DfDiskLo.sys'
)
$DfPathRegex = '(?i)(Faronics|\\DFFilter\.sys|\\DeepFrz\.sys|\\FarDisk\.sys|\\FarSpace\.sys|\\DfDiskLo\.sys|\\DFServ(\.exe)?(\s|$|"))'
$DfNameRegex = '(?i)(DFServ|DFFilter|DFInstall|Deep\s*-\s*Freeze|DeepFreeze|Deep\s*Freeze|DeepFrz|FarDisk|FarSpace|DfDiskLo|Faronics|冰点)'

$HiveSys = 'HKLM\DF_OFF_SYS'
$HiveSw = 'HKLM\DF_OFF_SW'
$script:Removed = New-Object System.Collections.Generic.List[string]
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:Skipped = New-Object System.Collections.Generic.List[string]
$script:HadHiber = $false
$script:DidRun = $false

# ============================================================================
# 输出
# ============================================================================
function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
# 状态标签带英文，方便在非中文代码页 / 缺少中文字体的 PE 里对照阅读
function Write-Ok   { param([string]$T) Write-Host ('  [完成 OK] '   + $T) -ForegroundColor Green;    $script:Removed.Add($T) }
function Write-Warn { param([string]$T) Write-Host ('  [注意 WARN] ' + $T) -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host ('  [失败 FAIL] ' + $T) -ForegroundColor Red;      $script:Failed.Add($T) }
function Write-Info { param([string]$T) Write-Host ('             '   + $T) -ForegroundColor Gray }
function Write-Skip { param([string]$T) Write-Host ('  [跳过 SKIP] ' + $T) -ForegroundColor DarkGray; $script:Skipped.Add($T) }

function Test-IsWinPE {
    # WinPE 和 Windows RE 都有这个键；正常系统没有
    try { return (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') } catch { return $false }
}

function Confirm-Action {
    param([string]$Question)
    if ($Yes) { return $true }
    if ($DryRun) { return $true }   # 演练模式：继续走流程，但所有动作只打印不执行
    $a = Read-Host ("  " + $Question + " [Y/N]")
    return ($a -match '^(y|yes|是)')
}

function Invoke-Reg {
    param([string[]]$Arguments)
    $out = & reg.exe @Arguments 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
}

# ============================================================================
# 1. 定位目标系统
# ============================================================================
function Resolve-Target {
    param([string]$Path)

    if ($Path) {
        $p = $Path.TrimEnd('\')
        if ($p -match '^[A-Za-z]:$') { $p = $p + '\Windows' }
        if (Test-Path -LiteralPath (Join-Path $p 'System32\config\SYSTEM')) { return $p }
        Write-Bad ("指定的目录不是有效的 Windows 目录：{0}" -f $Path)
        return $null
    }

    $candidates = @()
    try {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $d.Root) { continue }
            $w = Join-Path $d.Root 'Windows'
            if (Test-Path -LiteralPath (Join-Path $w 'System32\config\SYSTEM')) {
                $candidates += $w
            }
        }
    } catch { }

    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    Write-Warn '检测到多个 Windows 系统，请选择要清理的那一个：'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), $candidates[$i]) -ForegroundColor White
    }
    if ($Yes) {
        Write-Info ("自动模式，默认选择第一个：{0}" -f $candidates[0])
        return $candidates[0]
    }
    $sel = Read-Host '  序号'
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
        return $candidates[$n - 1]
    }
    Write-Bad '选择无效。'
    return $null
}

# ============================================================================
# 2. 预检
# ============================================================================
function Test-Preflight {
    param([string]$WinDir)

    $root = Split-Path -Parent $WinDir
    $sysFile = Join-Path $WinDir 'System32\config\SYSTEM'
    $swFile = Join-Path $WinDir 'System32\config\SOFTWARE'

    if (-not (Test-Path -LiteralPath $sysFile)) {
        Write-Bad ("找不到注册表文件：{0}" -f $sysFile)
        Write-Info '该分区可能启用了 BitLocker（离线无法读取），或选错了盘。'
        return $false
    }

    # 休眠文件 / 快速启动：会让离线改的注册表在开机时被"旧快照"覆盖
    $hib = Join-Path $root 'hiberfil.sys'
    if ((Test-Path -LiteralPath $hib) -and -not $SkipHibernationFix) {
        $script:HadHiber = $true
        Write-Warn '发现 hiberfil.sys（系统休眠/快速启动的镜像）。'
        Write-Info '它的存在会让开机时用"旧内核快照"覆盖我们刚改的注册表，导致卸载失效。'
        if (-not $DryRun) {
            if (Confirm-Action '删除 hiberfil.sys 以强制冷启动？（不会丢文件，只是丢弃休眠中的内存镜像）') {
                try {
                    Remove-Item -LiteralPath $hib -Force -ErrorAction Stop
                    Write-Ok '已删除 hiberfil.sys，下次为完整冷启动'
                } catch {
                    Write-Bad ("删除 hiberfil.sys 失败：{0}" -f $_.Exception.Message)
                }
            } else {
                Write-Skip '保留 hiberfil.sys —— 卸载可能不生效，建议之后强制关机再开机'
            }
        }
    }
    return $true
}

# ============================================================================
# 3. 备份（多位置回退 + 完整性校验，不再"失败即中止"）
# ============================================================================
function Test-DirWritable {
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

function Copy-HiveVerified {
    param([string]$Src, [string]$Dst)
    $res = [pscustomobject]@{ Ok = $false; Why = '' }
    try {
        Copy-Item -LiteralPath $Src -Destination $Dst -Force -ErrorAction Stop
    } catch {
        $res.Why = $_.Exception.Message
        return $res
    }
    $fi = Get-Item -LiteralPath $Dst -ErrorAction SilentlyContinue
    if (-not $fi -or $fi.Length -le 0) {
        $res.Why = '备份文件是空的（磁盘满或写入被拦截）'
        return $res
    }
    # 真正校验它能不能被当成配置单元挂载（防止"看似拷到了其实是坏文件"）
    $probe = 'DF_BKCHECK'
    [void](Invoke-Reg @('unload', "HKLM\$probe"))   # 清掉上次可能残留的挂载
    for ($i = 0; $i -lt 2; $i++) {
        if ((Invoke-Reg @('load', "HKLM\$probe", $Dst)).Code -eq 0) {
            [void](Invoke-Reg @('unload', "HKLM\$probe"))
            $res.Ok = $true
            return $res
        }
        Start-Sleep -Milliseconds 300
    }
    $res.Why = '备份文件无法挂载（可能被截断/损坏）'
    return $res
}

function Get-BackupResult {
    param([string]$WinDir, [string]$Preferred)
    $root = Split-Path -Parent $WinDir
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $cands = New-Object System.Collections.ArrayList
    if ($Preferred) { [void]$cands.Add($Preferred) }
    # 1) 目标系统盘根目录：重启后仍在，最推荐
    [void]$cands.Add((Join-Path $root ('DFBackup_' + $stamp)))
    # 2) 脚本所在盘（U 盘），换机器时也能带走
    if ($PSScriptRoot) {
        $q = Split-Path -Qualifier $PSScriptRoot
        if ($q) { [void]$cands.Add(($q + '\DFBackup_' + $stamp)) }
    }
    # 3) PE 的 RAM 盘 / 系统盘
    if ($env:SystemDrive) { [void]$cands.Add((Join-Path ($env:SystemDrive + '\') 'DFBackup')) }
    # 4) TEMP
    if ($env:TEMP) { [void]$cands.Add((Join-Path $env:TEMP 'DFBackup')) }

    $tried = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        if (-not (Test-DirWritable -Dir $c)) {
            [void]$tried.Add($c + '  (不可写)')
            continue
        }
        $sysSrc = Join-Path $WinDir 'System32\config\SYSTEM'
        $swSrc = Join-Path $WinDir 'System32\config\SOFTWARE'
        $r1 = Copy-HiveVerified -Src $sysSrc -Dst (Join-Path $c 'SYSTEM.bak')
        if (-not $r1.Ok) {
            [void]$tried.Add($c + '  (SYSTEM: ' + $r1.Why + ')')
            continue
        }
        $r2 = $null
        if (Test-Path -LiteralPath $swSrc) {
            $r2 = Copy-HiveVerified -Src $swSrc -Dst (Join-Path $c 'SOFTWARE.bak')
            if (-not $r2.Ok) { [void]$tried.Add($c + '  (SOFTWARE: ' + $r2.Why + ')') }
        }
        return [pscustomobject]@{
            Dir      = $c
            SystemOk = $true
            SoftwareOk = [bool]($r2 -and $r2.Ok)
            Tried    = @($tried)
        }
    }
    return [pscustomobject]@{ Dir = $null; SystemOk = $false; SoftwareOk = $false; Tried = @($tried) }
}

function New-Backup {
    param([string]$WinDir)

    if ($DryRun) { Write-Info ('[演练] 将把注册表备份到 ' + (Join-Path (Split-Path -Parent $WinDir) 'DFBackup_*')); return $null }

    $r = Get-BackupResult -WinDir $WinDir -Preferred $BackupDir
    if (-not $r.Dir) {
        Write-Bad '注册表备份失败：所有候选位置都不可写或写入无效。'
        foreach ($t in $r.Tried) { Write-Info $t }
        Write-Info '常见原因：U 盘写保护 / 光盘 / 分区只读 / 磁盘空间不足 / BitLocker 未解锁 / 安全软件拦截。'
        Write-Info '可用 -BackupDir 指定一个可写目录，例如：-BackupDir X:\dfbk'
        return $null
    }

    $note = @(
        '冰点卸载前的注册表备份',
        ('时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('来源：' + $WinDir),
        '',
        '回滚方法（PE 中）：',
        '  copy /y SYSTEM.bak   <系统盘>\Windows\System32\config\SYSTEM',
        '  copy /y SOFTWARE.bak <系统盘>\Windows\System32\config\SOFTWARE',
        '  del /f /q <系统盘>\Windows\System32\config\*.LOG',
        '',
        '或在 PE 里 reg load 出错时，先删 config 目录下的 .LOG 文件再试。'
    )
    Set-Content -LiteralPath (Join-Path $r.Dir '回滚说明.txt') -Value $note -Encoding UTF8 -ErrorAction SilentlyContinue

    if ($r.SoftwareOk) {
        Write-Ok ('注册表已备份（SYSTEM + SOFTWARE，已校验可挂载）→ ' + $r.Dir)
    } else {
        Write-Warn ('注册表已备份 SYSTEM → ' + $r.Dir + '（SOFTWARE 未能备份，不影响开机）')
    }
    return $r.Dir
}

# ============================================================================
# 4. 加载 / 卸载注册表配置单元
# ============================================================================
function Mount-Hive {
    param([string]$HiveName, [string]$File)
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Reg @('load', $HiveName, $File)
        if ($r.Code -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    Write-Bad ("加载注册表失败：{0} <- {1}" -f $HiveName, $File)
    Write-Info $r.Output
    return $false
}

function Dismount-Hive {
    param([string]$HiveName)
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Reg @('unload', $HiveName)
        if ($r.Code -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    Write-Warn ("卸载注册表失败：{0}（重启后会自动释放）" -f $HiveName)
    return $false
}

# ============================================================================
# 5. 注册表手术
# ============================================================================
function Get-ControlSets {
    param([string]$HiveRoot)
    return @(Get-ChildItem -LiteralPath ("HKLM:\" + $HiveRoot) -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' } |
        ForEach-Object { $_.PSChildName })
}

function Remove-ServiceKey {
    param([string]$KeyPath)
    if (-not (Test-Path -LiteralPath $KeyPath)) { return $false }
    if ($DryRun) { Write-Info ("[演练] 删除服务键 {0}" -f $KeyPath); return $true }
    try {
        Remove-Item -LiteralPath $KeyPath -Recurse -Force -ErrorAction Stop
        Write-Ok ("删除服务/驱动登记：{0}" -f (Split-Path -Leaf $KeyPath))
        return $true
    } catch {
        $rp = $KeyPath -replace '^HKLM:\\', 'HKLM\'
        $r = Invoke-Reg @('delete', $rp, '/f')
        if ($r.Code -eq 0) {
            Write-Ok ("删除服务/驱动登记：{0}" -f (Split-Path -Leaf $KeyPath))
            return $true
        }
        Write-Bad ("无法删除 {0}" -f $KeyPath)
        return $false
    }
}

function Get-FilterValueItems {
    param([string]$KeyPath, [string]$ValueName)
    $p = Get-ItemProperty -LiteralPath $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $v = $p.$ValueName
    if ($null -eq $v) { return @() }
    if ($v -is [System.Array]) { return @($v) }
    return @([string]$v)
}

function Clear-FilterValue {
    param([string]$KeyPath, [string]$ValueName)
    $items = Get-FilterValueItems -KeyPath $KeyPath -ValueName $ValueName
    if ($null -eq $items -or $items.Count -eq 0) { return $false }

    $kept = @($items | Where-Object { $_ -and ($_ -notmatch $DfNameRegex) })
    if ($kept.Count -eq $items.Count) { return $false }
    $gone = @($items | Where-Object { $_ -and ($_ -match $DfNameRegex) })

    if ($DryRun) {
        Write-Info ("[演练] {0} 的 {1} 移除：{2}" -f (Split-Path -Leaf $KeyPath), $ValueName, ($gone -join ','))
        return $true
    }
    try {
        if ($kept.Count -eq 0) {
            Remove-ItemProperty -LiteralPath $KeyPath -Name $ValueName -Force -ErrorAction Stop
        } else {
            Set-ItemProperty -LiteralPath $KeyPath -Name $ValueName -Value ([string[]]$kept) -Type MultiString -Force -ErrorAction Stop
        }
        Write-Ok ("清理开机过滤器 {0}：移除 [{1}]，保留 [{2}]" -f (Split-Path -Leaf $KeyPath), ($gone -join ','), (($kept -join ',') -replace '^$', '无'))
        return $true
    } catch {
        Write-Bad ("清理过滤器失败 {0}\{1}：{2}" -f $KeyPath, $ValueName, $_.Exception.Message)
        return $false
    }
}

function Clear-SystemHive {
    param([string]$HiveRoot)

    # ---- 5.1 服务 / 驱动登记 ----
    foreach ($cs in (Get-ControlSets -HiveRoot $HiveRoot)) {
        $svcRoot = ('HKLM:\{0}\{1}\Services' -f $HiveRoot, $cs)
        if (-not (Test-Path -LiteralPath $svcRoot)) { continue }

        # (a) 已知名字，直接删
        foreach ($n in $DfServiceNames) {
            [void](Remove-ServiceKey -KeyPath (Join-Path $svcRoot $n))
        }

        # (b) 兜底：按 ImagePath 找"换了马甲"的冰点服务
        foreach ($k in (Get-ChildItem -LiteralPath $svcRoot -ErrorAction SilentlyContinue)) {
            if ($DfServiceNames -contains $k.PSChildName) { continue }
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $img = [string]$p.ImagePath
            $disp = [string]$p.DisplayName
            if (($img -and ($img -match $DfPathRegex)) -or ($disp -and ($disp -match $DfNameRegex))) {
                [void](Remove-ServiceKey -KeyPath $k.PSPath)
            }
        }
    }

    # ---- 5.2 设备类过滤器 UpperFilters / LowerFilters ----
    foreach ($cs in (Get-ControlSets -HiveRoot $HiveRoot)) {
        $classRoot = ('HKLM:\{0}\{1}\Control\Class' -f $HiveRoot, $cs)
        if (-not (Test-Path -LiteralPath $classRoot)) { continue }
        foreach ($cls in (Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
            foreach ($vn in @('UpperFilters', 'LowerFilters')) {
                [void](Clear-FilterValue -KeyPath $cls.PSPath -ValueName $vn)
            }
        }
    }
}

function Clear-SoftwareHive {
    param([string]$HiveRoot)

    # ---- 6.1 Faronics 主键 ----
    foreach ($sub in @('', '\WOW6432Node')) {
        $fk = ('HKLM:\{0}{1}\Faronics' -f $HiveRoot, $sub)
        if (-not (Test-Path -LiteralPath $fk)) { continue }

        $children = @(Get-ChildItem -LiteralPath $fk -ErrorAction SilentlyContinue)
        $dfChildren = @($children | Where-Object { $_.PSChildName -match $DfNameRegex })
        $otherChildren = @($children | Where-Object { $_.PSChildName -notmatch $DfNameRegex })

        if ($otherChildren.Count -eq 0) {
            # 只装了冰点 → 整个 Faronics 键删掉
            if ($DryRun) { Write-Info ("[演练] 删除 {0}" -f $fk); continue }
            try {
                Remove-Item -LiteralPath $fk -Recurse -Force -ErrorAction Stop
                Write-Ok ("删除注册表根键 {0}\Faronics" -f $sub)
            } catch {
                Write-Bad ("删除 {0} 失败" -f $fk)
            }
        } else {
            # 还有 Faronics 其他产品 → 只删冰点自己的子键
            foreach ($c in $dfChildren) {
                if ($DryRun) { Write-Info ("[演练] 删除 {0}" -f $c.PSPath); continue }
                try {
                    Remove-Item -LiteralPath $c.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Ok ("删除注册表键 Faronics\{0}" -f $c.PSChildName)
                } catch {
                    Write-Bad ("删除 {0} 失败" -f $c.PSPath)
                }
            }
            Write-Info ("保留其他 Faronics 产品配置：{0}" -f (($otherChildren | ForEach-Object { $_.PSChildName }) -join ', '))
        }
    }

    # ---- 6.2 控制面板卸载项 ----
    foreach ($u in @(
            ('HKLM:\{0}\Microsoft\Windows\CurrentVersion\Uninstall' -f $HiveRoot),
            ('HKLM:\{0}\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -f $HiveRoot)
        )) {
        if (-not (Test-Path -LiteralPath $u)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $u -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $dn = [string]$p.DisplayName
            $pub = [string]$p.Publisher
            if ($dn -match $DfNameRegex -or $pub -match 'Faronics') {
                if ($DryRun) { Write-Info ("[演练] 删除卸载项 {0}" -f $dn); continue }
                try {
                    Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Ok ("删除控制面板卸载项：{0}" -f $dn)
                } catch {
                    Write-Bad ("删除卸载项 {0} 失败" -f $k.PSPath)
                }
            }
        }
    }

    # ---- 6.3 开机启动项 ----
    foreach ($rk in @(
            ('HKLM:\{0}\Microsoft\Windows\CurrentVersion\Run' -f $HiveRoot),
            ('HKLM:\{0}\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' -f $HiveRoot),
            ('HKLM:\{0}\Microsoft\Windows\CurrentVersion\RunOnce' -f $HiveRoot)
        )) {
        if (-not (Test-Path -LiteralPath $rk)) { continue }
        $p = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $val = [string]$prop.Value
            if (($val -match $DfPathRegex) -or ($prop.Name -match $DfNameRegex)) {
                if ($DryRun) { Write-Info ("[演练] 删除启动项 {0}" -f $prop.Name); continue }
                try {
                    Remove-ItemProperty -LiteralPath $rk -Name $prop.Name -Force -ErrorAction Stop
                    Write-Ok ("删除开机启动项：{0}" -f $prop.Name)
                } catch {
                    Write-Bad ("删除启动项 {0} 失败" -f $prop.Name)
                }
            }
        }
    }
}

# ============================================================================
# 6. 清理后复查（注册表内是否还有冰点字样）
# ============================================================================
function Find-Remnants {
    param([string]$HiveRoot)
    $hits = New-Object System.Collections.ArrayList
    foreach ($cs in (Get-ControlSets -HiveRoot $HiveRoot)) {
        foreach ($n in $DfServiceNames) {
            $p = ('HKLM:\{0}\{1}\Services\{2}' -f $HiveRoot, $cs, $n)
            if (Test-Path -LiteralPath $p) { [void]$hits.Add($p) }
        }
        $classRoot = ('HKLM:\{0}\{1}\Control\Class' -f $HiveRoot, $cs)
        if (Test-Path -LiteralPath $classRoot) {
            foreach ($cls in (Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
                foreach ($vn in @('UpperFilters', 'LowerFilters')) {
                    $items = Get-FilterValueItems -KeyPath $cls.PSPath -ValueName $vn
                    if ($null -eq $items) { continue }
                    foreach ($it in $items) {
                        if ($it -and ($it -match $DfNameRegex)) {
                            [void]$hits.Add(('{0}\{1} => {2}' -f $cls.PSPath, $vn, $it))
                        }
                    }
                }
            }
        }
    }
    return @($hits)
}

# ============================================================================
# 7. 文件清理
# ============================================================================
function Remove-PathSafe {
    param([string]$Path, [switch]$Dir)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) { Write-Info ("[演练] 删除 {0}" -f $Path); return }
    try {
        if ($Dir) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        Write-Ok ("删除 {0}" -f $Path)
    } catch {
        Write-Bad ("删除失败 {0}：{1}" -f $Path, $_.Exception.Message)
    }
}

function Clear-Files {
    param([string]$WinDir)

    $root = Split-Path -Parent $WinDir

    # 驱动文件
    foreach ($n in $DfDriverFiles) {
        Remove-PathSafe -Path (Join-Path $WinDir ('System32\drivers\' + $n))
    }
    # System32 下的冰点程序（注意：绝对不能动 dfsc.sys / dfshim.dll 等微软 DFS 文件）
    foreach ($n in @('DFServ.exe', 'DFServMain.exe', 'DFInstall.exe', 'DeepFrz.exe')) {
        Remove-PathSafe -Path (Join-Path $WinDir ('System32\' + $n))
    }
    # 安装目录
    foreach ($d in @(
            (Join-Path $root 'Program Files\Faronics'),
            (Join-Path $root 'Program Files (x86)\Faronics'),
            (Join-Path $root 'ProgramData\Faronics')
        )) {
        Remove-PathSafe -Path $d -Dir
    }

    # 卷根目录的数据文件（冰点的持久化数据，多分区可能都有）
    if (-not $KeepData) {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $d.Root) { continue }
            foreach ($n in @('persi0.sys', 'persi1.sys', 'persi2.sys')) {
                Remove-PathSafe -Path (Join-Path $d.Root $n)
            }
        }
        # 目标盘根目录即使在 PE 里没有盘符也兜一遍
        foreach ($n in @('persi0.sys', 'persi1.sys', 'persi2.sys')) {
            Remove-PathSafe -Path (Join-Path $root $n)
        }
    } else {
        Write-Skip '按参数要求保留 persi*.sys 数据文件'
    }
}

# ============================================================================
# 主流程
# ============================================================================
$startTime = Get-Date

Write-Host ''
Write-Host '  ┌──────────────────────────────────────────────────────────────┐' -ForegroundColor Cyan
Write-Host '  │   冰点还原 (Deep Freeze)  PE 离线强制卸载器   v1.0            │' -ForegroundColor Cyan
Write-Host '  └──────────────────────────────────────────────────────────────┘' -ForegroundColor Cyan

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Bad '需要管理员权限（PE 里默认就是管理员，请确认没有用错账户）。'
        return
    }

    # ---------- 安全阀：必须在 PE / WinRE 里跑 ----------
    # 在正常运行的 Windows 里挂载"自己正在用的"注册表并改驱动登记，会把系统直接搞坏。
    $isPE = Test-IsWinPE
    if (-not $isPE -and -not $Force) {
        Write-Bad '当前不是 PE / Windows RE 环境，已拒绝执行（这是保护措施）。'
        Write-Info '在正常系统里跑这个清理器，会把正在运行的系统改坏（改的是它自己的驱动登记）。'
        Write-Info '正确用法：重启进 PE / 恢复环境后再运行；或先在正常系统里用 DFRemover 的 [2]/[7] 准备。'
        Write-Info '确实要强行执行（仅供调试）：加 -Force'
        return
    }
    if (-not $isPE) { Write-Warn '已用 -Force 跳过 PE 环境检查，请确认你知道自己在做什么。' }

    # ---------- 定位 ----------
    Write-Title '第 1 步：定位要清理的 Windows 系统'
    $winDir = Resolve-Target -Path $TargetWindows
    if (-not $winDir) {
        Write-Bad '没有找到可清理的 Windows 系统。'
        Write-Info '如果分区被 BitLocker 加密，离线无法读取，需要先解锁（manage-bde -unlock）。'
        Write-Info '也可以手动指定：-TargetWindows D:\Windows'
        return
    }
    $root = Split-Path -Parent $winDir
    Write-Ok ("目标系统：{0}    系统盘：{1}" -f $winDir, $root)

    if (-not (Test-Preflight -WinDir $winDir)) { return }

    # ---------- 确认 ----------
    Write-Title '第 2 步：确认操作'
    Write-Host '  即将执行（不可自动撤销，但会先备份注册表）：' -ForegroundColor White
    Write-Host '    1) 删除 SYSTEM 注册表里的冰点服务/驱动登记（所有 ControlSet）' -ForegroundColor Gray
    Write-Host '    2) 从设备类过滤器 UpperFilters/LowerFilters 中摘掉冰点' -ForegroundColor Gray
    Write-Host '    3) 删除 SOFTWARE 注册表里的 Faronics 键、卸载项、启动项' -ForegroundColor Gray
    Write-Host '    4) 删除驱动文件、安装目录、persi*.sys 数据文件' -ForegroundColor Gray
    if ($DryRun) { Write-Warn '当前是【演练模式】，不会真正修改任何东西。' }
    if (-not (Confirm-Action '确认执行？')) {
        Write-Host '  已取消。' -ForegroundColor Yellow
        return
    }
    $script:DidRun = $true

    # ---------- 备份 ----------
    Write-Title '第 3 步：备份注册表'
    $bk = New-Backup -WinDir $winDir
    if (-not $bk -and -not $DryRun) {
        # 不再"失败即中止"，而是把选择权交给用户：很多 PE 场景下备份位置确实没有可写的
        Write-Warn '没有可用的注册表备份。'
        $go = $false
        if ($Force -or $Yes) {
            $go = $true
            Write-Warn '自动模式（-Yes / -Force），无备份继续。'
        } else {
            $a = Read-Host '  继续卸载吗？没有备份就无法回滚。输入 YES 继续，直接回车取消'
            $go = ($a -match '^(y|yes|是)$')
        }
        if (-not $go) {
            Write-Host '  已取消，未做任何修改。' -ForegroundColor Yellow
            Write-Info '可以换个可写目录重来：-BackupDir X:\dfbk'
            return
        }
        Write-Warn '按用户确认继续（无备份）。'
    }

    # ---------- 加挂 ----------
    Write-Title '第 4 步：挂载离线注册表'
    $sysFile = Join-Path $winDir 'System32\config\SYSTEM'
    $swFile = Join-Path $winDir 'System32\config\SOFTWARE'

    $sysOk = Mount-Hive -HiveName $HiveSys -File $sysFile
    $swOk = $false
    if ($sysOk) { $swOk = Mount-Hive -HiveName $HiveSw -File $swFile }
    if (-not $sysOk) {
        Write-Bad '关键注册表挂载失败，终止（未做任何修改）。'
        return
    }
    Write-Ok '注册表已挂载'

    try {
        # ---------- 清理 SYSTEM ----------
        Write-Title '第 5 步：清理 SYSTEM（服务 / 驱动 / 开机过滤器）'
        Clear-SystemHive -HiveRoot 'DF_OFF_SYS'

        Write-Title '第 6 步：清理 SOFTWARE（Faronics / 卸载项 / 启动项）'
        if ($swOk) {
            Clear-SoftwareHive -HiveRoot 'DF_OFF_SW'
        } else {
            Write-Warn 'SOFTWARE 未能挂载，跳过（不影响开机，可进系统后再清）'
        }

        # ---------- 复查 ----------
        Write-Title '第 7 步：注册表复查'
        $left = Find-Remnants -HiveRoot 'DF_OFF_SYS'
        if ($left.Count -eq 0) {
            Write-Ok 'SYSTEM 中已无冰点的服务与过滤器登记'
        } else {
            Write-Bad ('仍有 {0} 处残留：' -f $left.Count)
            foreach ($l in $left) { Write-Info $l }
        }
    } finally {
        Write-Title '第 8 步：卸载注册表'
        [void](Dismount-Hive -HiveName $HiveSys)
        if ($swOk) { [void](Dismount-Hive -HiveName $HiveSw) }
    }

    # ---------- 文件 ----------
    Write-Title '第 9 步：删除文件与目录'
    Clear-Files -WinDir $winDir

    # ---------- 汇总 ----------
    Write-Title '完成'
    Write-Host ("  成功处理 {0} 项，失败 {1} 项，跳过 {2} 项。" -f $script:Removed.Count, $script:Failed.Count, $script:Skipped.Count) -ForegroundColor White
    if ($bk) { Write-Host ("  注册表备份：{0}" -f $bk) -ForegroundColor Gray }
    if ($script:Failed.Count -gt 0) {
        Write-Host ''
        Write-Host '  以下项目没做干净（可重启后再跑一次本脚本）：' -ForegroundColor Yellow
        foreach ($f in $script:Failed) { Write-Host ('    · ' + $f) -ForegroundColor DarkYellow }
    }
    Write-Host ''
    Write-Host '  ✅ 现在请重启电脑，正常进入系统。' -ForegroundColor Green
    Write-Host '     进系统后运行 DFRemover.ps1 选 [4] 复查，确认彻底干净。' -ForegroundColor Gray
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host ('  ✗ 发生错误：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
    Write-Host '  如果注册表仍处于挂载状态，可在命令提示符执行： reg unload HKLM\DF_OFF_SYS' -ForegroundColor Yellow
}
finally {
    # 日志
    try {
        if (-not $LogPath -and $winDir) { $LogPath = Join-Path (Split-Path -Parent $winDir) 'DFUninstall.log' }
        if (-not $LogPath) { $LogPath = Join-Path $env:TEMP 'DFUninstall.log' }
        $lines = @()
        $lines += ('===== {0} =====' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $lines += ('目标：{0}' -f $winDir)
        $lines += ('结果：成功 {0}，失败 {1}，跳过 {2}，耗时 {3:N1} 秒' -f $script:Removed.Count, $script:Failed.Count, $script:Skipped.Count, ((Get-Date) - $startTime).TotalSeconds)
        $lines += '--- 成功 ---'; $lines += $script:Removed
        $lines += '--- 失败 ---'; $lines += $script:Failed
        $lines += '--- 跳过 ---'; $lines += $script:Skipped
        Add-Content -LiteralPath $LogPath -Value $lines -ErrorAction SilentlyContinue
        Write-Host ("  日志：{0}" -f $LogPath) -ForegroundColor DarkGray
    } catch { }
}

# ============================================================================
# 自动重启回 Windows（无键盘场景的关键：不留任何"按任意键"）
# ============================================================================
if ($Reboot -and -not $NoReboot -and -not $DryRun -and $script:DidRun) {
    Write-Host ''
    Write-Host '  10 秒后自动重启回 Windows（无需任何按键）...' -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    try {
        if (Test-IsWinPE) {
            # PE / RE 里用 wpeutil，它会把控制权交回正常启动流程
            $w = Get-Command wpeutil.exe -ErrorAction SilentlyContinue
            if ($w) {
                Write-Host '  正在重启（wpeutil reboot）...' -ForegroundColor Yellow
                & $w.Source reboot | Out-Null
            } else {
                & shutdown.exe /r /t 3 /f | Out-Null
            }
        } else {
            & shutdown.exe /r /t 3 /f | Out-Null
        }
    } catch {
        Write-Host '  自动重启失败，请手动重启。' -ForegroundColor Red
    }
}
