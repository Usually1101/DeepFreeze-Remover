@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 936 >nul 2>&1
color 0F
title 冰点还原 PE 离线强制卸载器

rem ===========================================================================
rem  冰点还原 (Faronics Deep Freeze) PE 离线强制卸载器 —— 纯 CMD 版
rem  适用于没有 PowerShell 的 PE（微PE / 优启通 / Windows 安装盘 Shift+F10）
rem  组件清单必须与 DFRemover.ps1 / DF-Offline-Clean.ps1 保持一致
rem
rem  用法： DF-Offline-Clean.cmd [系统盘或Windows目录] [/y | /auto]
rem                                   [/reboot | /noreboot] [/force]
rem    /y        免确认
rem    /auto     免确认 + 清理完自动重启回 Windows（无键盘场景用这个）
rem    /reboot   只加自动重启        /noreboot 明确不重启
rem    /force    跳过 PE 环境检查（仅供调试，危险）
rem    例： DF-Offline-Clean.cmd /auto
rem         DF-Offline-Clean.cmd D:\Windows /auto
rem ===========================================================================

set "WIN="
set "AUTO="
set "REBOOT="
set "FORCE="
:PARSEARGS
if "%~1"=="" goto :PARSED
if /i "%~1"=="/y"        ( set "AUTO=/y" & shift & goto :PARSEARGS )
if /i "%~1"=="/auto"     ( set "AUTO=/y" & set "REBOOT=1" & shift & goto :PARSEARGS )
if /i "%~1"=="/reboot"   ( set "REBOOT=1" & shift & goto :PARSEARGS )
if /i "%~1"=="/noreboot" ( set "REBOOT=" & shift & goto :PARSEARGS )
if /i "%~1"=="/force"    ( set "FORCE=1" & shift & goto :PARSEARGS )
if not defined WIN set "WIN=%~1"
shift
goto :PARSEARGS
:PARSED

echo.
echo  ============================================================
echo    冰点还原 Deep Freeze  --  PE 离线强制卸载器  v1.0
echo  ============================================================
echo.

if not defined WIN call :AUTODETECT
if not defined WIN goto :NOTFOUND

rem ---- 归一化路径 ----
if "%WIN:~-1%"=="\" set "WIN=%WIN:~0,-1%"
if /i not "%WIN:~-8%"=="\Windows" set "WIN=%WIN%\Windows"
if not exist "%WIN%\System32\config\SYSTEM" goto :BADWIN

rem ---- 安全阀：必须在 PE / Windows RE 里运行 ----
reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1
if errorlevel 1 if not defined FORCE (
   echo   [失败 FAIL] 当前不是 PE / Windows RE 环境，已拒绝执行（保护措施）。
   echo               在正常系统里跑会改坏正在运行的系统。
   echo               正确做法：重启进 PE 后再运行；调试可用 /force 跳过。
   rem 拒绝执行时不要停下来等按键（无键盘设备会卡死），留几秒自动关闭
   set "DF_NOPAUSE=1"
   goto :END
)

for %%I in ("%WIN%\..") do set "ROOT=%%~fI"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

echo   目标系统 : %WIN%
echo   系统盘   : %ROOT%
echo.

rem ---- 休眠镜像检查 ----
if exist "%ROOT%\hiberfil.sys" call :HIBCHECK

echo   即将执行：
echo     1. 删除注册表里的冰点服务/驱动登记（所有 ControlSet）
echo     2. 从设备类过滤器 UpperFilters/LowerFilters 中摘掉冰点
echo     3. 删除 Faronics 注册表键、控制面板卸载项、开机启动项
echo     4. 删除驱动文件、安装目录、persi*.sys 数据文件
echo.
if /i not "%AUTO%"=="/y" (
   set "ANS="
   set /p "ANS=  确认执行? 输入 Y 回车: "
   if /i not "%ANS%"=="Y" goto :CANCEL
)
set "STARTED=1"

rem ---- 备份（多位置回退：指定目录 -> 系统盘 -> U盘 -> RAM盘 -> TEMP）----
call :BACKUP
if not defined BKOK goto :END
echo.

rem ---- 挂载 ----
reg unload HKLM\DFOFF_SYS >nul 2>&1
reg unload HKLM\DFOFF_SW  >nul 2>&1
reg load HKLM\DFOFF_SYS "%WIN%\System32\config\SYSTEM" >nul 2>&1
if errorlevel 1 goto :LOADFAIL
reg load HKLM\DFOFF_SW "%WIN%\System32\config\SOFTWARE" >nul 2>&1
if errorlevel 1 (set "SWOK=0" & echo   [注意 WARN] SOFTWARE 挂载失败，跳过软件项清理) else (set "SWOK=1")
echo   [完成 OK] 注册表已挂载
echo.

rem ---- 清理 SYSTEM ----
echo   --- 清理服务 / 驱动登记 ---
for %%C in (ControlSet001 ControlSet002 ControlSet003 ControlSet004) do (
   reg query "HKLM\DFOFF_SYS\%%C" >nul 2>&1
   if not errorlevel 1 (
      call :DELSERV "HKLM\DFOFF_SYS\%%C\Services"
      call :CLEANCLASS "HKLM\DFOFF_SYS\%%C\Control\Class"
   )
)
echo.

rem ---- 清理 SOFTWARE ----
if "%SWOK%"=="1" call :CLEANSW

rem ---- 卸载 ----
echo.
echo   --- 卸载注册表 ---
reg unload HKLM\DFOFF_SYS >nul 2>&1
if "%SWOK%"=="1" reg unload HKLM\DFOFF_SW >nul 2>&1
echo   [完成 OK] 注册表已卸载

rem ---- 删文件 ----
echo.
echo   --- 删除驱动 / 程序 / 目录 ---
for %%F in (DFFilter.sys DeepFrz.sys FarDisk.sys FarSpace.sys DfDiskLo.sys) do (
   if exist "%WIN%\System32\drivers\%%F" (
      del /f /q "%WIN%\System32\drivers\%%F" >nul 2>&1
      if exist "%WIN%\System32\drivers\%%F" (echo   [失败 FAIL] drivers\%%F) else (echo   [完成 OK] 删除 drivers\%%F)
   )
)
for %%F in (DFServ.exe DFServMain.exe DFInstall.exe) do (
   if exist "%WIN%\System32\%%F" (
      del /f /q "%WIN%\System32\%%F" >nul 2>&1
      if exist "%WIN%\System32\%%F" (echo   [失败 FAIL] System32\%%F) else (echo   [完成 OK] 删除 System32\%%F)
   )
)
for %%D in ("%ROOT%\Program Files\Faronics" "%ROOT%\Program Files (x86)\Faronics" "%ROOT%\ProgramData\Faronics") do (
   if exist "%%~D" (
      rd /s /q "%%~D" >nul 2>&1
      if exist "%%~D" (echo   [失败 FAIL] 目录 %%~D) else (echo   [完成 OK] 删除目录 %%~D)
   )
)

echo.
echo   --- 删除数据文件 persi*.sys ---
for %%N in (persi0.sys persi1.sys persi2.sys) do (
   if exist "%ROOT%\%%N" (
      del /f /q "%ROOT%\%%N" >nul 2>&1
      if exist "%ROOT%\%%N" (echo   [失败 FAIL] 删除系统盘根目录 %%N) else (echo   [完成 OK] 删除系统盘根目录 %%N)
   )
)
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
   for %%N in (persi0.sys persi1.sys persi2.sys) do (
      if exist "%%D:\%%N" (
         del /f /q "%%D:\%%N" >nul 2>&1
         if exist "%%D:\%%N" (echo   [失败 FAIL] 删除 %%D:\%%N) else (echo   [完成 OK] 删除 %%D:\%%N)
      )
   )
)

rem ---- 复查 ----
echo.
echo   --- 复查残留 ---
call :VERIFY

echo.
echo  ============================================================
echo    清理完成。请重启电脑进入系统。
echo    进系统后运行 DFRemover.ps1 选 [4] 做最终复查。
if defined BK echo    注册表备份在： %BK%
if not defined BK echo    [注意 WARN] 本次没有注册表备份（无回滚能力，但已按确认继续）
echo  ============================================================
echo.
goto :END

rem ===========================================================================
:DELSERV
set "SVC=%~1"
reg query "%SVC%" >nul 2>&1
if errorlevel 1 exit /b 0
for %%N in (DFServ DFFilter DeepFrz DfDiskLo FarDisk FarSpace DFInstall) do (
   reg query "%SVC%\%%N" >nul 2>&1
   if not errorlevel 1 (
      reg delete "%SVC%\%%N" /f >nul 2>&1
      reg query "%SVC%\%%N" >nul 2>&1
      if errorlevel 1 (echo   [完成 OK] 删除服务键 %%N) else (echo   [失败 FAIL] 服务键 %%N)
   )
)
exit /b 0

rem ===========================================================================
:CLEANCLASS
set "CLS=%~1"
reg query "%CLS%" >nul 2>&1
if errorlevel 1 exit /b 0
for /f "tokens=*" %%K in ('reg query "%CLS%" 2^>nul ^| findstr /i /c:"HKEY_LOCAL_MACHINE"') do (
   call :FIXVAL "%%K" UpperFilters
   call :FIXVAL "%%K" LowerFilters
)
exit /b 0

rem ===========================================================================
rem  :FIXVAL <键> <值名>   把过滤器值里的冰点条目摘掉，其余保留
rem ===========================================================================
:FIXVAL
set "K=%~1"
set "V=%~2"
set "RAW="
for /f "tokens=2,*" %%A in ('reg query "%K%" /v %V% 2^>nul ^| findstr /i /c:" %V% "') do set "RAW=%%B"
if not defined RAW exit /b 0

rem 只处理 REG_MULTI_SZ
set "VAL=%RAW:REG_MULTI_SZ=%"
for /f "tokens=* delims= " %%X in ("%VAL%") do set "VAL=%%X"
if not defined VAL exit /b 0

rem 不含冰点关键字就跳过
echo %VAL% | findstr /i /c:"DFFilter" /c:"DeepFrz" /c:"FarDisk" /c:"FarSpace" /c:"DfDiskLo" /c:"DFServ" >nul
if errorlevel 1 exit /b 0

set "SRC=%VAL:\0=;%"
set "OUT="
:SPLITLOOP
if not defined SRC goto :SPLITEND
set "TOK="
for /f "tokens=1,* delims=;" %%X in ("!SRC!") do (
   set "TOK=%%X"
   set "SRC=%%Y"
)
if not defined TOK goto :SPLITEND
call :ISDF "!TOK!"
if errorlevel 1 (
   echo   [完成 OK] 从 %V% 移除冰点条目 !TOK!
) else (
   if defined OUT (set "OUT=!OUT!\0!TOK!") else (set "OUT=!TOK!")
)
goto :SPLITLOOP

:SPLITEND
if defined OUT (
   reg add "%K%" /v %V% /t REG_MULTI_SZ /d "!OUT!" /f >nul 2>&1
   if errorlevel 1 (echo   [失败 FAIL] 写回 %V% @ %K%) else (echo   [完成 OK] 写回 %V% = !OUT!)
) else (
   reg delete "%K%" /v %V% /f >nul 2>&1
   echo   [完成 OK] %V% 已无其他过滤器，值已删除
)
exit /b 0

rem ===========================================================================
:ISDF
rem  返回 1 表示该条目属于冰点
for %%K in (DFFilter DeepFrz FarDisk FarSpace DfDiskLo DFServ) do (
   if /i "%~1"=="%%K" exit /b 1
)
exit /b 0

rem ===========================================================================
:CLEANSW
for %%R in ("" "\WOW6432Node") do (
   set "FK=HKLM\DFOFF_SW%%~R\Faronics"
   reg query "!FK!" >nul 2>&1
   if not errorlevel 1 (
      reg delete "!FK!" /f >nul 2>&1
      reg query "!FK!" >nul 2>&1
      if errorlevel 1 (echo   [完成 OK] 删除注册表键 !FK!) else (echo   [失败 FAIL] 删除 !FK!)
   )
)
rem 控制面板卸载项 + 开机启动项：按关键字搜索后删除
call :CLEANUNINST
call :CLEANRUN
exit /b 0

rem ===========================================================================
:CLEANRUN
for %%R in ("HKLM\DFOFF_SW\Microsoft\Windows\CurrentVersion\Run" "HKLM\DFOFF_SW\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" "HKLM\DFOFF_SW\Microsoft\Windows\CurrentVersion\RunOnce") do (
   reg query "%%~R" >nul 2>&1
   if not errorlevel 1 (
      for /f "tokens=1,2,*" %%A in ('reg query "%%~R" 2^>nul ^| findstr /i /r /c:"REG_SZ"') do (
         echo %%C | findstr /i /c:"Faronics" /c:"DFServ" /c:"Deep Freeze" /c:"冰点" >nul
         if not errorlevel 1 (
            reg delete "%%~R" /v "%%A" /f >nul 2>&1
            echo   [完成 OK] 删除启动项 %%A
         )
      )
   )
)
exit /b 0

rem ===========================================================================
:CLEANUNINST
for %%U in ("HKLM\DFOFF_SW\Microsoft\Windows\CurrentVersion\Uninstall" "HKLM\DFOFF_SW\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall") do (
   reg query "%%~U" >nul 2>&1
   if not errorlevel 1 (
      for /f "tokens=*" %%K in ('reg query "%%~U" 2^>nul ^| findstr /i /c:"HKEY_LOCAL_MACHINE"') do (
         set "HIT=0"
         for /f "tokens=2,*" %%A in ('reg query "%%~K" 2^>nul ^| findstr /i /c:"DisplayName" /c:"Publisher"') do (
            echo %%B | findstr /i /c:"Deep Freeze" /c:"DeepFreeze" /c:"Faronics" /c:"冰点" >nul
            if not errorlevel 1 set "HIT=1"
         )
         if "!HIT!"=="1" (
            reg delete "%%~K" /f >nul 2>&1
            echo   [完成 OK] 删除卸载项 %%~nxK
         )
      )
   )
)
exit /b 0

rem ===========================================================================
:VERIFY
reg load HKLM\DFVER_SYS "%WIN%\System32\config\SYSTEM" >nul 2>&1
if errorlevel 1 (
   echo   [注意 WARN] 无法重新挂载注册表做复查，跳过。
   exit /b 0
)
set "LEFT=0"
for %%C in (ControlSet001 ControlSet002 ControlSet003 ControlSet004) do (
   for %%N in (DFServ DFFilter DeepFrz DfDiskLo FarDisk FarSpace) do (
      reg query "HKLM\DFVER_SYS\%%C\Services\%%N" >nul 2>&1
      if not errorlevel 1 (
         echo   [残留 LEFT] %%C\Services\%%N
         set /a LEFT+=1
      )
   )
)
reg unload HKLM\DFVER_SYS >nul 2>&1
if "!LEFT!"=="0" (echo   [完成 OK] 注册表中已无冰点服务登记) else (echo   [注意 WARN] 仍有 !LEFT! 处残留，可重启后再跑一次)
exit /b 0

rem ===========================================================================
rem ===========================================================================
:BACKUP
set "BK="
set "BKOK="
for %%C in ("%DF_BACKUP_DIR%" "%ROOT%\DFBackup" "%~d0\DFBackup_%RANDOM%" "%SystemDrive%\DFBackup" "%TEMP%\DFBackup") do (
   if not defined BK call :TRYBK "%%~C"
)
if defined BK (set "BKOK=1" & exit /b 0)
echo   [失败 FAIL] 没有任何可用的备份位置（U盘写保护 / 磁盘满 / 分区只读 / 安全软件拦截）。
echo               可以设置环境变量 DF_BACKUP_DIR 指定目录，例如 set DF_BACKUP_DIR=D:\dfbk
set "ANS="
if /i not "%AUTO%"=="/y" set /p "ANS=  没有备份也要继续卸载吗？输入 YES 继续，回车取消: "
if /i "%ANS%"=="YES" (
   echo   [注意 WARN] 按用户确认继续（本次没有回滚能力）。
   set "BKOK=1"
   exit /b 0
)
if /i "%AUTO%"=="/y" (
   echo   [注意 WARN] 自动模式，无备份继续。
   set "BKOK=1"
   exit /b 0
)
echo   已取消，未做任何修改。
exit /b 1

:TRYBK
if "%~1"=="" exit /b 0
set "D=%~1"
if not exist "%D%\." mkdir "%D%" >nul 2>&1
if not exist "%D%\." exit /b 0
copy /y "%WIN%\System32\config\SYSTEM" "%D%\SYSTEM.bak" >nul 2>&1
if not exist "%D%\SYSTEM.bak" exit /b 0
rem 真校验：能不能当配置单元挂载（防止"看着拷到了其实是坏文件"）
reg load HKLM\DFBKCHK "%D%\SYSTEM.bak" >nul 2>&1
if errorlevel 1 (
   del /f /q "%D%\SYSTEM.bak" >nul 2>&1
   exit /b 0
)
reg unload HKLM\DFBKCHK >nul 2>&1
copy /y "%WIN%\System32\config\SOFTWARE" "%D%\SOFTWARE.bak" >nul 2>&1
set "BK=%D%"
echo   [完成 OK] 注册表已备份到 %BK%
exit /b 0

:AUTODETECT
echo   正在搜索已安装的 Windows 系统...
set "FOUND=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
   if exist "%%D:\Windows\System32\config\SYSTEM" (
      echo     发现 %%D:\Windows
      set "WIN=%%D:\Windows"
      set /a FOUND+=1
   )
)
if not "!FOUND!"=="0" if not "!FOUND!"=="1" echo     [注意 WARN] 发现 !FOUND! 个系统，默认使用最后一个；可用参数手动指定
echo.
exit /b 0

rem ===========================================================================
:HIBCHECK
echo   [注意 WARN] 检测到 hiberfil.sys（休眠 / 快速启动镜像）
echo          它会让开机时用旧快照覆盖注册表改动，导致卸载失效。
set "ANS="
set /p "ANS=  删除它并强制冷启动? 输入 Y 回车: "
if /i "%ANS%"=="Y" (
   del /f /q "%ROOT%\hiberfil.sys" >nul 2>&1
   echo   [完成 OK] 已删除 hiberfil.sys
) else (
   echo   [注意 WARN] 已保留 hiberfil.sys，卸载可能不生效
)
echo.
exit /b 0

rem ===========================================================================
:NOTFOUND
echo   [失败 FAIL] 没有找到任何已安装的 Windows 系统。
echo   如果分区被 BitLocker 加密，离线无法读取，需要先解锁。
echo   也可以手动指定： DF-Offline-Clean.cmd D:\Windows
goto :END

:BADWIN
echo   [失败 FAIL] 不是有效的 Windows 目录： %WIN%
goto :END

:LOADFAIL
echo   [失败 FAIL] 无法挂载注册表，未做任何修改。
echo   可能原因：注册表已被其他程序占用，或该分区只读。
reg unload HKLM\DFOFF_SYS >nul 2>&1
goto :END

:CANCEL
echo   已取消，未做任何修改。
goto :END

:END
if defined REBOOT if defined STARTED (
   echo.
   echo   10 秒后自动重启回 Windows（无需任何按键）...
   ping -n 11 127.0.0.1 >nul 2>&1
   if exist "%SystemRoot%\System32\wpeutil.exe" (
      "%SystemRoot%\System32\wpeutil.exe" reboot
      exit /b
   )
   shutdown /r /t 3 /f
   exit /b
)
if defined DF_NOPAUSE (
   rem 触摸场景：绝不等待按键，留几秒让人看清提示就自动关闭
   ping -n 13 127.0.0.1 >nul 2>&1
   exit /b
)
echo.
pause
endlocal
