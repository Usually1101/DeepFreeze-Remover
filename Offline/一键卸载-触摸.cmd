@echo off
chcp 936 >nul 2>&1
title 冰点还原 · 一键卸载（触摸版 / 无需键盘）
setlocal
pushd "%~dp0"
set "DF_NOPAUSE=1"

echo.
echo  ============================================================
echo    冰点还原  一键卸载   （触摸版：全程不需要键盘）
echo  ============================================================
echo.
echo    正在自动识别系统盘并清理冰点，请稍候...
echo    清理完成后会自动重启回 Windows。
echo.
echo    本窗口不需要任何输入，也不用按任何键。
echo.

call "%~dp0DF-Offline-Clean.cmd" /auto

echo.
echo    如果上面显示"清理完成"，10 秒后会自动重启；
echo    如果显示"已拒绝执行"，说明当前不是 PE 环境，请重启进 PE 再双击本文件。
ping -n 13 127.0.0.1 >nul 2>&1
popd
endlocal