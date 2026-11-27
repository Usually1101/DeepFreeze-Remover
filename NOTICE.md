# 代码来源与致谢

## 1. 代码来源

本仓库的全部脚本（`Start.cmd`、`DFRemover.ps1`、`Offline\*`、`Build-Release.ps1`、`tests\*` 等）
由 **AI 编程助手（DeepSeek Harness）** 在用户需求驱动下从零编写，
**未复制、未反编译、未包含任何第三方项目的源代码或二进制文件**。

- 需求提出、方案取舍、结果验收：仓库所有者
- 代码编写、重构、测试用例与验证：AI 编程助手
- 首次发布：2026-11

## 2. 参考的公开资料（只借鉴思路与事实，未复制代码）

### 2.1 冰点还原的组件清单与"卸载顺序"

**吾爱破解论坛 —《冰点还原纯手工卸载！暴力卸载！无密码！》**
<https://www.52pojie.cn/thread-1151774-1-1.html>

借鉴内容：

- 组件清单：`DFFilter.sys` / `DeepFrz.sys` / `FarDisk.sys` / `FarSpace.sys` / `DfDiskLo.sys`、
  服务 `DFServ`、安装目录 `Faronics`、卷根目录 `persi0.sys`、注册表 `Faronics` 键与 `UpperFilters`；
- **关键结论：必须先摘注册表登记、再删文件**——该帖作者先删文件，结果重启蓝屏，
  要靠"最后一次正确配置"救回。本项目的执行顺序就是据此设计的。

### 2.2 内核级方案（本项目**未采用**）

**TimBlack422/DeepThaw** — <https://github.com/TimBlack422/DeepThaw>
（一个能"在冰点运行且被密码锁定时直接禁用"的开源工具）

本项目的评估见 [docs/DeepThaw-技术评估.md](docs/DeepThaw-技术评估.md)。**没有借用其任何代码**，
原因写在评估文档里：它需要加载未签名内核驱动、在内核里用 `MmMapIoSpace` 改冰点驱动的 IAT、
把判断指令改成 `mov al,1`，还要关闭驱动签名强制；这对一个"拷过去就能跑"的脚本工具来说代价过高。

只借鉴了两个**认识**（不是代码）：

1. "**禁用 ≠ 卸载**"——任何解冻手段都只是让保护失效，真正的清理仍要卸载；
2. 冰点之外还有其它"重启还原"类软件（Reboot Restore Rx / Rollback Rx / Shadow Defender），
   因此本项目的扫描会**额外识别**这几类产品（只识别、不处理）。

### 2.3 官方说明（事实来源）

**Faronics Knowledge Base — 忘记密码怎么办**
<https://support.faronics.com/help/en-ca/29-deep-freeze-windows/101-i-installed-deep-freeze-and-forgot-my-password-can-you-give-me-a-password-to-turn-deep-freeze-off>

借鉴内容（均为事实，非代码）：

- 官方**不存在后门密码**，也不会帮用户找回密码；
- 企业版可用 **一次性密码（OTP）** 解冻；
- 未输入序列号的**试用版**可用"BIOS 时钟前推 60 天"使其失效。

### 2.4 其它

- Windows 恢复环境 / WinPE 的 `wpeutil`、`reagentc`、`bcdedit`、`reg load/export` 等用法，
  均来自 Microsoft 官方文档与系统自带工具的常规用法。
- 无其它第三方库、无 NuGet/子模块依赖；整个项目只依赖 Windows 自带组件
  （PowerShell 5.1、`reg.exe`、`shutdown`、PE 自带的 `wpeutil`）。

## 3. 商标声明

Deep Freeze®、Faronics® 是 Faronics Corporation 的商标。
Reboot Restore Rx、Rollback Rx 是 Horizon DataSys 的商标。
本项目与上述公司**无关**，未获得其授权、赞助或背书，仅出于互操作与系统维护目的而提及。

## 4. 许可证

本项目以 [MIT](LICENSE) 许可证发布。
