#requires -Version 5.1
<#
  自检脚本：在临时目录里伪造"已安装冰点"的 Windows 系统，
  跑 DF-Offline-Clean.ps1 / .cmd，然后逐项断言清理结果。
  不会改动本机任何真实注册表位置（只写 HKCU 下的临时键，用完删除）。
#>
[CmdletBinding()]
param(
    [ValidateSet('PS', 'CMD', 'All')]
    [string]$Which = 'All'
)

# 注意：这里必须是 Continue —— PS 5.1 会把原生命令(reg.exe)的 stderr 当成
# terminating error，Stop 模式下探测性质的 reg 调用会直接中断整个自检。
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$toolRoot = Split-Path -Parent $PSScriptRoot
$psCleaner = Join-Path $toolRoot 'Offline\DF-Offline-Clean.ps1'
$cmdCleaner = Join-Path $toolRoot 'Offline\DF-Offline-Clean.cmd'

$script:Pass = 0
$script:Fail = 0
$script:FailNames = @()

function Check {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) {
        $script:Pass++
        Write-Host ("    [OK]   " + $Name) -ForegroundColor Green
    } else {
        $script:Fail++
        $script:FailNames += $Name
        Write-Host ("    [FAIL] " + $Name + $(if ($Detail) { "  -> $Detail" } else { '' })) -ForegroundColor Red
    }
}

function Write-Step {
    param([string]$T)
    Write-Host ''
    Write-Host ("=== " + $T) -ForegroundColor Cyan
}

# 静默调用 reg.exe（PS 5.1 会把原生命令的 stderr 变成终止性错误，必须重定向到 $null）
function Reg-Quiet {
    param([string[]]$A)
    & reg.exe @A 2>$null | Out-Null
    return $LASTEXITCODE
}

function Reg-Unload {
    param([string]$Hive)
    for ($i = 0; $i -lt 3; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        if ((Reg-Quiet @('unload', "HKLM\$Hive")) -eq 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Reg-Load {
    param([string]$Hive, [string]$File)
    for ($i = 0; $i -lt 3; $i++) {
        if ((Reg-Quiet @('load', "HKLM\$Hive", $File)) -eq 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# ---------------------------------------------------------------- 造现场
$DrvList = @('DFFilter.sys', 'DeepFrz.sys')
$LegitDrivers = @('partmgr.sys', 'volsnap.sys')

function New-Fixture {
    param([string]$Tag, [switch]$WithOtherProduct)

    $t = Join-Path $env:TEMP ("dftest_{0}_{1}" -f $Tag, [guid]::NewGuid().ToString('N').Substring(0, 6))
    $win = Join-Path $t 'Windows'
    foreach ($d in @(
            (Join-Path $win 'System32\config'),
            (Join-Path $win 'System32\drivers'),
            (Join-Path $t 'Program Files (x86)\Faronics\Deep Freeze'),
            (Join-Path $t 'Program Files\Faronics'),
            (Join-Path $t 'ProgramData\Faronics')
        )) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    foreach ($n in $DrvList) { Set-Content -LiteralPath (Join-Path $win ('System32\drivers\' + $n)) -Value 'fakedriver' -NoNewline }
    foreach ($n in $LegitDrivers) { Set-Content -LiteralPath (Join-Path $win ('System32\drivers\' + $n)) -Value 'legit' -NoNewline }
    Set-Content -LiteralPath (Join-Path $t 'Program Files (x86)\Faronics\Deep Freeze\DFServ.exe') -Value 'fake' -NoNewline
    Set-Content -LiteralPath (Join-Path $t 'persi0.sys') -Value 'fakepersist' -NoNewline

    # ---------------- 合成 SYSTEM 配置单元 ----------------
    $sysKey = "HKCU:\Software\__DFT_SYS_$Tag"
    Remove-Item -LiteralPath $sysKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path "$sysKey\Select" -Force | Out-Null
    New-ItemProperty -Path "$sysKey\Select" -Name 'Current' -Value 1 -PropertyType DWord -Force | Out-Null

    $svc = "$sysKey\ControlSet001\Services"
    New-Item -Path "$svc\DFServ" -Force | Out-Null
    New-ItemProperty -Path "$svc\DFServ" -Name 'Type' -Value 0x10 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "$svc\DFServ" -Name 'Start' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "$svc\DFServ" -Name 'ImagePath' -Value 'C:\Program Files (x86)\Faronics\Deep Freeze\DFServ.exe' -Force | Out-Null
    New-ItemProperty -Path "$svc\DFServ" -Name 'DisplayName' -Value 'Deep Freeze Service' -Force | Out-Null

    foreach ($pair in @(@('DFFilter', 2), @('DeepFrz', 1))) {
        $n = $pair[0]
        New-Item -Path "$svc\$n" -Force | Out-Null
        New-ItemProperty -Path "$svc\$n" -Name 'Type' -Value $pair[1] -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path "$svc\$n" -Name 'Start' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path "$svc\$n" -Name 'ImagePath' -Value ("System32\drivers\$n.sys") -Force | Out-Null
    }

    # 正常驱动，必须保留（防止"误杀"）
    New-Item -Path "$svc\TestLegit" -Force | Out-Null
    New-ItemProperty -Path "$svc\TestLegit" -Name 'Type' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "$svc\TestLegit" -Name 'Start' -Value 3 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "$svc\TestLegit" -Name 'ImagePath' -Value 'System32\drivers\partmgr.sys' -Force | Out-Null

    # 第二个 ControlSet 也放一份（检验"所有 ControlSet"覆盖）
    New-Item -Path "$sysKey\ControlSet002\Services\DFServ" -Force | Out-Null
    New-ItemProperty -Path "$sysKey\ControlSet002\Services\DFServ" -Name 'Type' -Value 0x10 -PropertyType DWord -Force | Out-Null

    # 设备类过滤器
    $cls = "$sysKey\ControlSet001\Control\Class"
    New-Item -Path "$cls\{4d36e967-e325-11ce-bfc1-08002be10318}" -Force | Out-Null
    New-ItemProperty -Path "$cls\{4d36e967-e325-11ce-bfc1-08002be10318}" -Name 'UpperFilters' `
        -Value ([string[]]@('partmgr', 'DFFilter')) -PropertyType MultiString -Force | Out-Null
    New-Item -Path "$cls\{71a27cdd-812a-11d0-bec7-08002be2092f}" -Force | Out-Null
    New-ItemProperty -Path "$cls\{71a27cdd-812a-11d0-bec7-08002be2092f}" -Name 'UpperFilters' `
        -Value ([string[]]@('volsnap', 'DFFilter', 'partmgr')) -PropertyType MultiString -Force | Out-Null
    New-Item -Path "$cls\{50dd5230-ba8a-11d1-bf5d-0000f805f530}" -Force | Out-Null
    New-ItemProperty -Path "$cls\{50dd5230-ba8a-11d1-bf5d-0000f805f530}" -Name 'LowerFilters' `
        -Value ([string[]]@('DFFilter')) -PropertyType MultiString -Force | Out-Null
    New-Item -Path "$cls\{eec5ad98-8080-425f-922a-dabf3de3f69a}" -Force | Out-Null
    New-ItemProperty -Path "$cls\{eec5ad98-8080-425f-922a-dabf3de3f69a}" -Name 'UpperFilters' `
        -Value ([string[]]@('WpdUpFltr')) -PropertyType MultiString -Force | Out-Null

    [void](Reg-Quiet @('save', "HKCU\Software\__DFT_SYS_$Tag", (Join-Path $win 'System32\config\SYSTEM'), '/y'))
    Remove-Item -LiteralPath $sysKey -Recurse -Force

    # ---------------- 合成 SOFTWARE 配置单元 ----------------
    $swKey = "HKCU:\Software\__DFT_SW_$Tag"
    Remove-Item -LiteralPath $swKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path "$swKey\Faronics\Deep Freeze Standard" -Force | Out-Null
    New-ItemProperty -Path "$swKey\Faronics\Deep Freeze Standard" -Name 'InstallDir' -Value 'C:\Program Files (x86)\Faronics\Deep Freeze' -Force | Out-Null
    if ($WithOtherProduct) {
        New-Item -Path "$swKey\Faronics\Anti-Executable" -Force | Out-Null
        New-ItemProperty -Path "$swKey\Faronics\Anti-Executable" -Name 'Version' -Value '5.0' -Force | Out-Null
    }

    $un = "$swKey\Microsoft\Windows\CurrentVersion\Uninstall"
    New-Item -Path "$un\Deep Freeze Standard" -Force | Out-Null
    New-ItemProperty -Path "$un\Deep Freeze Standard" -Name 'DisplayName' -Value 'Deep Freeze Standard' -Force | Out-Null
    New-ItemProperty -Path "$un\Deep Freeze Standard" -Name 'Publisher' -Value 'Faronics' -Force | Out-Null
    New-Item -Path "$un\SomeOtherApp" -Force | Out-Null
    New-ItemProperty -Path "$un\SomeOtherApp" -Name 'DisplayName' -Value 'Some Other App' -Force | Out-Null
    New-ItemProperty -Path "$un\SomeOtherApp" -Name 'Publisher' -Value 'Contoso' -Force | Out-Null

    $run = "$swKey\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $run -Force | Out-Null
    New-ItemProperty -Path $run -Name 'DFServ' -Value 'C:\Program Files (x86)\Faronics\Deep Freeze\DFServ.exe /start' -Force | Out-Null
    New-ItemProperty -Path $run -Name 'Legit' -Value 'C:\Windows\notepad.exe' -Force | Out-Null

    [void](Reg-Quiet @('save', "HKCU\Software\__DFT_SW_$Tag", (Join-Path $win 'System32\config\SOFTWARE'), '/y'))
    Remove-Item -LiteralPath $swKey -Recurse -Force

    return [pscustomobject]@{ Root = $t; Win = $win }
}

function Remove-Fixture {
    param($Fx)
    foreach ($h in @('DF_VERIFY', 'DFOFF_SYS', 'DFOFF_SW', 'DF_OFF_SYS', 'DF_OFF_SW', 'DFVER_SYS')) {
        [void](Reg-Unload $h)
    }
    if ($Fx -and (Test-Path -LiteralPath $Fx.Root)) {
        Remove-Item -LiteralPath $Fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 断言
function Test-CleanResult {
    param($Fx, [string]$Label)

    Check "$Label : 驱动 DFFilter.sys 已删除" (-not (Test-Path (Join-Path $Fx.Win 'System32\drivers\DFFilter.sys')))
    Check "$Label : 驱动 DeepFrz.sys 已删除" (-not (Test-Path (Join-Path $Fx.Win 'System32\drivers\DeepFrz.sys')))
    Check "$Label : 正常驱动 partmgr.sys 未被误删" (Test-Path (Join-Path $Fx.Win 'System32\drivers\partmgr.sys'))
    Check "$Label : 安装目录 Faronics 已删除" (-not (Test-Path (Join-Path $Fx.Root 'Program Files (x86)\Faronics')))
    Check "$Label : persi0.sys 已删除" (-not (Test-Path (Join-Path $Fx.Root 'persi0.sys')))
    Check "$Label : 注册表备份已生成" (@(Get-ChildItem -LiteralPath $Fx.Root -Directory -Filter 'DFBackup*').Count -ge 1)

    $sysFile = Join-Path $Fx.Win 'System32\config\SYSTEM'
    $swFile = Join-Path $Fx.Win 'System32\config\SOFTWARE'

    $sysOk = Reg-Load -Hive 'DF_VERIFY' -File $sysFile
    Check "$Label : 清理后 SYSTEM 仍可正常挂载（未损坏）" $sysOk
    if ($sysOk) {
        try {
            Check "$Label : 服务键 DFServ 已删除" (-not (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\DFServ'))
            Check "$Label : 服务键 DFFilter 已删除" (-not (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\DFFilter'))
            Check "$Label : 服务键 DeepFrz 已删除" (-not (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\DeepFrz'))
            Check "$Label : 第二 ControlSet 的 DFServ 也已清理" (-not (Test-Path 'HKLM:\DF_VERIFY\ControlSet002\Services\DFServ'))
            Check "$Label : 正常服务 TestLegit 未被误删" (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\TestLegit')

            $k1 = 'HKLM:\DF_VERIFY\ControlSet001\Control\Class\{4d36e967-e325-11ce-bfc1-08002be10318}'
            $v1 = Get-ItemProperty -LiteralPath $k1 -Name UpperFilters -ErrorAction SilentlyContinue
            $s1 = if ($v1) { (@($v1.UpperFilters) -join ';') } else { '<无>' }
            Check "$Label : 磁盘类过滤器 = partmgr（冰点已摘除、partmgr 保留）" ($s1 -eq 'partmgr') "实际=$s1"

            $k2 = 'HKLM:\DF_VERIFY\ControlSet001\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}'
            $v2 = Get-ItemProperty -LiteralPath $k2 -Name UpperFilters -ErrorAction SilentlyContinue
            $s2 = if ($v2) { (@($v2.UpperFilters) -join ';') } else { '<无>' }
            Check "$Label : 卷类过滤器 = volsnap;partmgr（中间项被摘除、顺序保持）" ($s2 -eq 'volsnap;partmgr') "实际=$s2"

            $k3 = 'HKLM:\DF_VERIFY\ControlSet001\Control\Class\{50dd5230-ba8a-11d1-bf5d-0000f805f530}'
            $v3 = Get-ItemProperty -LiteralPath $k3 -Name LowerFilters -ErrorAction SilentlyContinue
            Check "$Label : 仅含冰点的过滤器值被整体删除" ($null -eq $v3 -or @($v3.LowerFilters).Count -eq 0)

            $k4 = 'HKLM:\DF_VERIFY\ControlSet001\Control\Class\{eec5ad98-8080-425f-922a-dabf3de3f69a}'
            $v4 = Get-ItemProperty -LiteralPath $k4 -Name UpperFilters -ErrorAction SilentlyContinue
            $s4 = if ($v4) { (@($v4.UpperFilters) -join ';') } else { '<无>' }
            Check "$Label : 无关过滤器 WpdUpFltr 未被误改" ($s4 -eq 'WpdUpFltr') "实际=$s4"
        } finally {
            [void](Reg-Unload 'DF_VERIFY')
        }
    }

    $swOk = Reg-Load -Hive 'DF_VERIFY' -File $swFile
    Check "$Label : 清理后 SOFTWARE 仍可正常挂载" $swOk
    if ($swOk) {
        try {
            $hasOther = Test-Path 'HKLM:\DF_VERIFY\Faronics\Anti-Executable'
            if ($hasOther) {
                Check "$Label : 只删冰点子键（Faronics 下其他产品保留）" (-not (Test-Path 'HKLM:\DF_VERIFY\Faronics\Deep Freeze Standard'))
                Check "$Label : 其他 Faronics 产品确实还在" (Test-Path 'HKLM:\DF_VERIFY\Faronics\Anti-Executable')
            } else {
                Check "$Label : Faronics 注册表根键已删除" (-not (Test-Path 'HKLM:\DF_VERIFY\Faronics'))
            }
            Check "$Label : 控制面板卸载项已删除" (-not (Test-Path 'HKLM:\DF_VERIFY\Microsoft\Windows\CurrentVersion\Uninstall\Deep Freeze Standard'))
            Check "$Label : 其他软件的卸载项未被误删" (Test-Path 'HKLM:\DF_VERIFY\Microsoft\Windows\CurrentVersion\Uninstall\SomeOtherApp')
            $rv = Get-ItemProperty -LiteralPath 'HKLM:\DF_VERIFY\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
            Check "$Label : 冰点开机启动项已删除" (-not ($rv -and ($rv.PSObject.Properties.Name -contains 'DFServ')))
            Check "$Label : 正常启动项未被误删" ($rv -and ($rv.PSObject.Properties.Name -contains 'Legit'))
        } finally {
            [void](Reg-Unload 'DF_VERIFY')
        }
    }
}

# ---------------------------------------------------------------- 运行清理器
function Invoke-PsCleaner {
    param($Fx, [switch]$DryRun, [string]$BackupDir)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psCleaner,
        '-TargetWindows', $Fx.Win, '-Yes', '-Force', '-NoReboot', '-SkipHibernationFix')
    if ($DryRun) { $a += '-DryRun' }
    if ($BackupDir) { $a += @('-BackupDir', $BackupDir) }
    $out = & powershell.exe @a 2>&1
    return ($out -join "`n")
}

function Invoke-CmdCleaner {
    param($Fx)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $stdin = Join-Path $env:TEMP "dfstdin_$tag.txt"
    $stdout = Join-Path $env:TEMP "dfstdout_$tag.txt"
    $stderr = Join-Path $env:TEMP "dfstderr_$tag.txt"
    Set-Content -LiteralPath $stdin -Value '' -NoNewline
    $p = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList ('/c ""{0}" "{1}" /y /force /noreboot"' -f $cmdCleaner, $Fx.Win) `
        -NoNewWindow -Wait -PassThru -RedirectStandardInput $stdin `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $out = ''
    if (Test-Path $stdout) { $out = [System.IO.File]::ReadAllText($stdout, [System.Text.Encoding]::GetEncoding(936)) }
    $err = ''
    if (Test-Path $stderr) { $err = [System.IO.File]::ReadAllText($stderr, [System.Text.Encoding]::GetEncoding(936)) }
    Remove-Item $stdin, $stdout, $stderr -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

# ================================================================ 用例
Write-Host ''
Write-Host '############################################################' -ForegroundColor Magenta
Write-Host '  冰点卸载工具 · 离线清理器 自检' -ForegroundColor Magenta
Write-Host '############################################################' -ForegroundColor Magenta

# ---- 用例 0：组件清单一致性 ----
Write-Step '用例 0：三个脚本的冰点组件清单是否一致'
$ps1 = Get-Content -LiteralPath (Join-Path $toolRoot 'DFRemover.ps1') -Raw -Encoding UTF8
$ps2 = Get-Content -LiteralPath $psCleaner -Raw -Encoding UTF8
$cmd = Get-Content -LiteralPath $cmdCleaner -Raw -Encoding Default
foreach ($n in @('DFServ', 'DFFilter', 'DeepFrz', 'DfDiskLo', 'FarDisk', 'FarSpace', 'DFInstall')) {
    $a = $ps1 -match [regex]::Escape("'" + $n + "'")
    $b = $ps2 -match [regex]::Escape("'" + $n + "'")
    $c = $cmd -match [regex]::Escape($n)
    Check ("组件 {0} 在三个脚本中都有出现" -f $n) ($a -and $b -and $c) ("ps1={0} ps2={1} cmd={2}" -f $a, $b, $c)
}

# ---- 用例 1：PowerShell 版正常清理 ----
if ($Which -in @('PS', 'All')) {
    Write-Step '用例 1：DF-Offline-Clean.ps1 正常清理'
    $fx = New-Fixture -Tag 'ps'
    try {
        $log = Invoke-PsCleaner -Fx $fx
        Write-Host '    ---- 脚本输出（节选） ----' -ForegroundColor DarkGray
        ($log -split "`n" | Where-Object { $_ -match '\[(完成|失败|注意)' } | Select-Object -First 6) |
            ForEach-Object { Write-Host ('    ' + $_.TrimEnd()) -ForegroundColor DarkGray }
        Test-CleanResult -Fx $fx -Label 'PS'
        $backup = @(Get-ChildItem -LiteralPath $fx.Root -Directory -Filter 'DFBackup*')[0]
        Check 'PS : 备份里有 SYSTEM.bak' (Test-Path (Join-Path $backup.FullName 'SYSTEM.bak'))
        Check 'PS : 备份里有 SOFTWARE.bak' (Test-Path (Join-Path $backup.FullName 'SOFTWARE.bak'))
        Check 'PS : 生成了卸载日志' (Test-Path (Join-Path $fx.Root 'DFUninstall.log'))
    } finally { Remove-Fixture -Fx $fx }

    # ---- 用例 2：幂等性 ----
    Write-Step '用例 2：重复执行是否安全（幂等）'
    $fx = New-Fixture -Tag 'ps2'
    try {
        [void](Invoke-PsCleaner -Fx $fx)
        $log2 = Invoke-PsCleaner -Fx $fx
        Check 'PS : 第二次执行未报致命错误' (-not ($log2 -match '发生错误'))
        Test-CleanResult -Fx $fx -Label 'PS重复'
    } finally { Remove-Fixture -Fx $fx }

    # ---- 用例 3：演练模式 ----
    Write-Step '用例 3：-DryRun 演练模式必须"只说不做"'
    $fx = New-Fixture -Tag 'dry'
    try {
        $log = Invoke-PsCleaner -Fx $fx -DryRun
        Check '演练 : 驱动文件仍在' (Test-Path (Join-Path $fx.Win 'System32\drivers\DFFilter.sys'))
        Check '演练 : 安装目录仍在' (Test-Path (Join-Path $fx.Root 'Program Files (x86)\Faronics'))
        Check '演练 : persi0.sys 仍在' (Test-Path (Join-Path $fx.Root 'persi0.sys'))
        if (Reg-Load -Hive 'DF_VERIFY' -File (Join-Path $fx.Win 'System32\config\SYSTEM')) {
            try {
                Check '演练 : 注册表服务键未被删除' (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\DFFilter')
            } finally { [void](Reg-Unload 'DF_VERIFY') }
        }
    } finally { Remove-Fixture -Fx $fx }

    # ---- 用例 4：Faronics 下还有其他产品 ----
    Write-Step '用例 4：同一台机器还装着 Faronics 其他产品时，不能误删'
    $fx = New-Fixture -Tag 'multi' -WithOtherProduct
    try {
        [void](Invoke-PsCleaner -Fx $fx)
        Test-CleanResult -Fx $fx -Label '多产品'
    } finally { Remove-Fixture -Fx $fx }

    # ---- 用例 6：备份目录不可用时应自动回退，而不是中止 ----
    Write-Step '用例 6：指定的备份目录不存在/不可写时，应自动换位置并继续'
    $fx = New-Fixture -Tag 'bk'
    try {
        $log = Invoke-PsCleaner -Fx $fx -BackupDir 'Q:\NoSuchDrive\dfbk'
        Check '备份回退 : 没有因备份失败而中止' (-not ($log -match '发生错误'))
        Check '备份回退 : 提示里说明了备份失败原因' ($log -match '备份' )
        Test-CleanResult -Fx $fx -Label '备份回退'
    } finally { Remove-Fixture -Fx $fx }

    # ---- 用例 7：不在 PE 里时必须拒绝执行（安全阀） ----
    Write-Step '用例 7：非 PE 环境必须拒绝执行（防止在正常系统里自毁）'
    $fx = New-Fixture -Tag 'guard'
    try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psCleaner,
            '-TargetWindows', $fx.Win, '-Yes', '-NoReboot', '-SkipHibernationFix')
        $out = & powershell.exe @a 2>&1
        $log = ($out -join "`n")
        Check '安全阀 : PS 版拒绝在非 PE 环境执行' ($log -match '不是 PE')
        Check '安全阀 : 拒绝后没有删除任何东西' (Test-Path (Join-Path $fx.Win 'System32\drivers\DFFilter.sys'))
        $loaded = Reg-Load -Hive 'DF_VERIFY' -File (Join-Path $fx.Win 'System32\config\SYSTEM')
        Check '安全阀 : 拒绝后没有改动注册表' ($loaded -and (Test-Path 'HKLM:\DF_VERIFY\ControlSet001\Services\DFFilter'))
        if ($loaded) { [void](Reg-Unload 'DF_VERIFY') }
    } finally { Remove-Fixture -Fx $fx }
}


# ---- 用例 5：纯 CMD 版 ----
if ($Which -in @('CMD', 'All')) {
    Write-Step '用例 5：DF-Offline-Clean.cmd（纯批处理版）正常清理'
    $fx = New-Fixture -Tag 'cmd'
    try {
        $r = Invoke-CmdCleaner -Fx $fx
        Write-Host ("    退出码 = {0}" -f $r.Exit) -ForegroundColor DarkGray
        Write-Host '    ---- 脚本输出（节选） ----' -ForegroundColor DarkGray
        ($r.Out -split "`r?`n" | Where-Object { $_ -match '\[(完成|失败|注意|残留)' } | Select-Object -First 14) |
            ForEach-Object { Write-Host ('    ' + $_.TrimEnd()) -ForegroundColor DarkGray }
        if ($r.Err) { Write-Host ('    STDERR: ' + $r.Err) -ForegroundColor DarkYellow }
        Check 'CMD : 执行完成（输出含"清理完成"）' ($r.Out -match '清理完成')
        Test-CleanResult -Fx $fx -Label 'CMD'
    } finally { Remove-Fixture -Fx $fx }
}

# ================================================================ 汇总
Write-Host ''
Write-Host '############################################################' -ForegroundColor Magenta
$color = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  通过 {0} 项，失败 {1} 项" -f $script:Pass, $script:Fail) -ForegroundColor $color
if ($script:Fail -gt 0) {
    Write-Host '  失败项：' -ForegroundColor Red
    foreach ($f in $script:FailNames) { Write-Host ('    · ' + $f) -ForegroundColor Red }
}
Write-Host '############################################################' -ForegroundColor Magenta
Write-Host ''

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
