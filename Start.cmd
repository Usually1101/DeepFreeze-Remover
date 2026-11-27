@echo off
rem ===========================================================================
rem  冰点还原 强制卸载工具 —— 一键入口
rem  · 自动选 64 位 PowerShell（从 32 位宿主启动时 System32 会被重定向）
rem  · 管理员权限由 DFRemover.ps1 自己申请（路径带空格/中文也不会坏）
rem  · 支持放在 U 盘、桌面、网络共享里直接运行
rem ===========================================================================
chcp 936 >nul 2>&1
title 冰点还原 强制卸载工具
setlocal
pushd "%~dp0"

if not exist "DFRemover.ps1" (
    echo.
    echo   [错误] 找不到 DFRemover.ps1
    echo   请确认拷过来的是完整文件夹（Start.cmd + DFRemover.ps1 + Offline 文件夹）。
    goto :END
)

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

if not exist "%~dp0Offline\DF-Offline-Clean.cmd" (
    echo.
    echo   [提醒] 缺少 Offline 文件夹，离线卸载包将无法生成。
    echo          但仍然可以做扫描和在线卸载。
    echo.
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DFRemover.ps1"
if errorlevel 2 goto :END

:END
popd
echo.
pause
endlocal