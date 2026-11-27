#requires -Version 5.1
<#
  发布打包：把工具做成"拷到任何电脑/U 盘就能用"的形态
  ============================================================================
  用法：
    powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1
    powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1 -ToUsb E:\
    powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1 -NoZip

  产出：
    dist\DeepFreezeRemover-v1.0\        ← 便携目录，直接整个拷到 U 盘
    dist\DeepFreezeRemover-v1.0.zip     ← 压缩包，便于分发
    dist\SHA256.txt                     ← 校验值（换电脑后可比对，确认没被改过）
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$ToUsb,
    [switch]$NoZip,
    [switch]$IncludeTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Version = '1.0'
$Src = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $Src 'dist' }
$Name = "DeepFreezeRemover-v$Version"
$Stage = Join-Path $OutDir $Name
$Zip = Join-Path $OutDir ($Name + '.zip')

function Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Good { param([string]$T) Write-Host ('  [OK]   ' + $T) -ForegroundColor Green }
function Bad  { param([string]$T) Write-Host ('  [FAIL] ' + $T) -ForegroundColor Red }
function Warn { param([string]$T) Write-Host ('  [WARN] ' + $T) -ForegroundColor Yellow }

Write-Host ''
Write-Host '  冰点还原卸载工具 · 发布打包' -ForegroundColor Magenta
Write-Host ('  版本 v{0}' -f $Version) -ForegroundColor Magenta

$fail = 0

# ---------------------------------------------------------------- 1. 质检
Step '1. 打包前质检'

$required = @(
    'Start.cmd',
    'DFRemover.ps1',
    '使用说明.md',
    'Offline\DF-Offline-Clean.cmd',
    'Offline\DF-Offline-Clean.ps1'
)
foreach ($f in $required) {
    $p = Join-Path $Src $f
    if (Test-Path -LiteralPath $p) { Good ("存在 " + $f) } else { Bad ("缺少 " + $f); $fail++ }
}

# PowerShell 脚本语法
foreach ($f in @('DFRemover.ps1', 'Offline\DF-Offline-Clean.ps1')) {
    $p = Join-Path $Src $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $errs = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Bad ("语法错误 " + $f + " 共 " + $errs.Count + " 处")
        $errs | Select-Object -First 5 | ForEach-Object { Write-Host ('         行 ' + $_.Extent.StartLineNumber + ': ' + $_.Message) -ForegroundColor DarkYellow }
        $fail++
    } else {
        Good ("语法通过 " + $f)
    }
}

# 编码：.ps1 必须 UTF-8 BOM；.cmd 必须 GBK + CRLF（否则中文乱码、goto 标签失效）
foreach ($f in @('DFRemover.ps1', 'Offline\DF-Offline-Clean.ps1')) {
    $p = Join-Path $Src $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [IO.File]::ReadAllBytes($p)
    if ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Good ("UTF-8 BOM " + $f) }
    else { Bad ("缺少 BOM，中文会乱码：" + $f); $fail++ }
}
foreach ($f in @('Start.cmd', 'Offline\DF-Offline-Clean.cmd')) {
    $p = Join-Path $Src $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [IO.File]::ReadAllBytes($p)
    $txt = [Text.Encoding]::GetEncoding(936).GetString($b)
    $lone = ([regex]::Matches($txt, "(?<!`r)`n")).Count
    $cn = $txt -match '[\u4e00-\u9fa5]'
    if ($lone -eq 0 -and $cn) { Good ("GBK/CRLF 正常 " + $f) }
    elseif ($lone -gt 0) { Bad ("存在孤立 LF（批处理会出错）：" + $f); $fail++ }
    else { Warn ($f + " 中文可能已损坏") }
}

# 组件清单三处一致
Step '2. 组件清单一致性（三个脚本）'
$ps1 = Get-Content -LiteralPath (Join-Path $Src 'DFRemover.ps1') -Raw -Encoding UTF8
$ps2 = Get-Content -LiteralPath (Join-Path $Src 'Offline\DF-Offline-Clean.ps1') -Raw -Encoding UTF8
$cmd = [Text.Encoding]::GetEncoding(936).GetString([IO.File]::ReadAllBytes((Join-Path $Src 'Offline\DF-Offline-Clean.cmd')))
foreach ($n in @('DFServ', 'DFFilter', 'DeepFrz', 'DfDiskLo', 'FarDisk', 'FarSpace', 'DFInstall')) {
    $ok = ($ps1 -match [regex]::Escape("'" + $n + "'")) -and ($ps2 -match [regex]::Escape("'" + $n + "'")) -and ($cmd -match [regex]::Escape($n))
    if ($ok) { Good ("组件 " + $n) } else { Bad ("组件不一致：" + $n); $fail++ }
}

if ($fail -gt 0) {
    Write-Host ''
    Bad ("质检未通过（" + $fail + " 项），已停止打包。")
    exit 1
}

# ---------------------------------------------------------------- 3. 组包
Step '3. 生成便携目录'
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Stage 'Offline') -Force | Out-Null

foreach ($f in @('Start.cmd', 'DFRemover.ps1', '使用说明.md')) {
    Copy-Item -LiteralPath (Join-Path $Src $f) -Destination $Stage -Force
}
foreach ($f in @('DF-Offline-Clean.cmd', 'DF-Offline-Clean.ps1', '一键卸载-触摸.cmd')) {
    Copy-Item -LiteralPath (Join-Path $Src ('Offline\' + $f)) -Destination (Join-Path $Stage 'Offline') -Force
}
if (Test-Path -LiteralPath (Join-Path $Src 'docs')) {
    Copy-Item -LiteralPath (Join-Path $Src 'docs') -Destination $Stage -Recurse -Force
}
if ($IncludeTests -and (Test-Path (Join-Path $Src 'tests\Test-OfflineClean.ps1'))) {
    New-Item -ItemType Directory -Path (Join-Path $Stage 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Src 'tests\Test-OfflineClean.ps1') -Destination (Join-Path $Stage 'tests') -Force
}

$quick = @(
    ('冰点还原 (Deep Freeze) 强制卸载工具  v' + $Version),
    ('=' * 56),
    '',
    '第一步：双击 Start.cmd（会弹 UAC，点"是"）',
    '',
    '  [1] 扫描     先看这台机器到底装没装、是不是冻结状态',
    '  [2] 生成离线包   忘记密码时用这个：会直接写到 U 盘',
    '  [3] 在线卸载   只在"已解冻"时可用',
    '  [4] 复查     卸载完再跑一次',
    '  [5] 环境自检   换了一台电脑、或工具行为不对，先跑这个',
    '  [6] 不用 U 盘   用系统自带的恢复环境（WinRE）卸载',
    '  [7] 不用键盘   一键重启到恢复环境（触摸设备 / 希沃这类机器）',
    '',
    '离线卸载（忘记密码 + 系统冻结）三步：',
    '  1) 选 [2]，把生成的 PE离线卸载包 拷到 U 盘',
    '  2) 关机，U 盘启动进 PE（Windows 安装盘按 Shift+F10）',
    '  3) 在 PE 里运行 U 盘上 DF-Offline-Clean.cmd，按提示确认',
    '',
    '不想做 U 盘？按 [6]：它会把清理脚本放到非系统盘，',
    '再重启进“高级启动 → 命令提示符”清理，全程不需要 U 盘。',
    '',
    '进了 PE 之后：双击 Start.cmd，工具会自动进入 PE 模式，按 [2] 强制卸载；',
    '（没有键盘就双击 一键卸载-触摸.cmd，全程零输入）',
    '',
    '没有实体键盘（希沃等触摸设备）：按 [7] → 重启后点【使用设备】选 U 盘',
    '→ 进 PE 后双击 DF-Auto\一键卸载-触摸.cmd，自动清理并自动重启回 Windows。',
    '全程只要“点”，不需要任何按键。',
    '',
    '详细说明见 使用说明.md',
    '本工具只用于你自己有管理权限的计算机。'
)
# 注意：PS 5.1 里 -Value 传数组有时会被折叠成一行，这里显式逐行写，保证格式
[IO.File]::WriteAllLines((Join-Path $Stage '快速开始.txt'), [string[]]$quick, (New-Object System.Text.UTF8Encoding($true)))

Good ('已生成 ' + $Stage)

# ---------------------------------------------------------------- 4. 校验值
Step '4. 计算校验值'
$hashLines = @()
Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    $rel = $_.FullName.Substring($Stage.Length).TrimStart('\')
    $hashLines += ('{0}  {1}' -f $h, $rel)
}
$hashFile = Join-Path $Stage 'SHA256.txt'
Set-Content -LiteralPath $hashFile -Value $hashLines -Encoding ASCII
$hashLines | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 5. 打 ZIP
if (-not $NoZip) {
    Step '5. 打包 ZIP'
    if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
    try {
        Compress-Archive -Path $Stage -DestinationPath $Zip -CompressionLevel Optimal -ErrorAction Stop
        Good ('已生成 ' + $Zip + '  (' + [math]::Round((Get-Item $Zip).Length / 1KB, 1) + ' KB)')
        $zh = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
        Set-Content -LiteralPath (Join-Path $OutDir 'SHA256.txt') -Value @(
            ('{0}  {1}' -f $zh, (Split-Path $Zip -Leaf))
        ) -Encoding ASCII
        Write-Host ('  ZIP SHA256: ' + $zh) -ForegroundColor DarkGray
    } catch {
        Warn ('压缩失败（不影响便携目录使用）：' + $_.Exception.Message)
        Warn '如果解压后中文文件名乱码，请用 7-Zip 或 PowerShell 的 Expand-Archive 解压。'
    }
}

# ---------------------------------------------------------------- 6. 拷到 U 盘
if ($ToUsb) {
    Step '6. 复制到 U 盘'
    $dst = Join-Path $ToUsb $Name
    if (-not (Test-Path -LiteralPath $ToUsb)) {
        Bad ('目标不存在：' + $ToUsb)
    } else {
        try {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            Copy-Item -LiteralPath $Stage -Destination $dst -Recurse -Force
            Good ('已复制到 ' + $dst)
            Good '现在可以直接拔 U 盘，插到出问题的电脑上运行 Start.cmd'
        } catch {
            Bad ('复制失败（U 盘写保护？）：' + $_.Exception.Message)
        }
    }
}

Step '完成'
Write-Host ('  便携目录：' + $Stage) -ForegroundColor White
if (-not $NoZip) { Write-Host ('  压缩包  ：' + $Zip) -ForegroundColor White }
Write-Host '  用法：把便携目录整个拷到目标电脑（或 U 盘），双击 Start.cmd。' -ForegroundColor Gray
Write-Host ''
