# CopilotKeyBridge

[English](README.md)

让 Windows Copilot 键启动或唤醒任意桌面 `.exe`，无需常驻热键进程。

CopilotKeyBridge 会注册一个小型、已签名的 MSIX 应用，作为 Windows 官方 Copilot Key Provider。按下实体 Copilot 键，或者在支持该行为的 Windows 版本中按下 `Win+C` 后，桥接程序会优先恢复目标应用的已有窗口；找不到窗口时才冷启动目标程序。处理完成后桥接进程立即退出。

## 为什么需要它

Windows 设置只会列出已打包、已签名，并注册了 `com.microsoft.windows.copilotkeyprovider` 扩展的应用。大多数传统 Win32 程序没有 MSIX 身份，因此无法出现在选择器中。

开始菜单里的 AppUserModelID 不一定是可启动的已打包 AUMID。直接把 Copilot 键指向普通快捷方式 ID，可能在程序运行时看起来有效，但程序完全退出后会退回到搜索或开始菜单。CopilotKeyBridge 补上了这层可启动的打包应用身份。

## 功能

- 冷启动未打包的 Win32 程序。
- 按目标可执行文件完整路径查找、恢复并置前已有窗口。
- 不依赖 AutoHotkey、PowerToys、Windows 服务、计划任务或开机启动项。
- 不支持 Shell 命令或任意命令行参数，减少注入面。
- 使用 Windows 官方 Copilot Key Provider 扩展和设置页面。
- 创建不可导出的临时包签名私钥，并在签名完成后立即删除。
- 本机没有 Windows SDK 时才下载微软官方 Build Tools，并校验固定 SHA-256。
- 支持 Windows 11 x64 和 ARM64。
- 提供明确的卸载和证书清理流程。

## 系统要求

- Windows 11 客户端，内部版本 `22621.4391` 或更高。
- 具有 Copilot 实体键，或者当前 Windows 将 `Win+C` 映射到同一 branded-key 动作。
- Windows PowerShell 5.1。
- 首次安装时如果电脑没有 Windows SDK，需要联网。
- 一次 UAC 确认，用于信任本机生成的包签名证书。

微软记录的 Copilot 硬件键组策略适用于专业版、企业版、教育版和 IoT 企业版。CopilotKeyBridge 本身使用面向用户的 Windows 设置选择器，不写入这条策略。

## 快速开始

1. 下载或克隆此仓库。
2. 双击 `Setup.cmd`。
3. 选择目标 `.exe`。
4. 同意证书信任 UAC 提示。
5. 在自动打开的 Windows 设置中选择 **打开应用** 或 **自定义**，然后选择 `CopilotKeyBridge: <应用名>`。

命令行安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Target "C:\Program Files\WorkBuddy\WorkBuddy.exe" `
  -DisplayName "WorkBuddy"
```

## 更换目标程序

再次运行 `Setup.cmd` 并选择新的 `.exe`。安装器会创建更高版本的包，同时保持 Package Family 和 AUMID 不变，因此已有的 Copilot 键选择仍然有效。

## 卸载

双击 `Uninstall.cmd`，或运行：

```powershell
.\uninstall.ps1
```

如果 CopilotKeyBridge 当前仍被选中，卸载器会要求先在 Windows 设置中改为搜索或其他应用，然后再移除包。它会清理当前用户的应用包、本地私钥，并在没有其他用户使用该包时删除机器级信任证书。

脚本化清理可以使用 `uninstall.ps1 -Force` 跳过选择检查，但证书清理仍可能显示 UAC。Windows 可能保留旧 AUMID，直到用户手工选择其他按键行为，因此正常情况下建议交互式卸载。

## 工作原理

```text
Copilot 键 / Win+C
        |
        v
Windows branded-key broker
        |
        v
已签名 MSIX Provider（CopilotKeyBridge）
        |
        +--> 找到目标顶层窗口 -> 恢复并置前
        |
        `--> 没有目标窗口 -> 启动配置的绝对 .exe 路径
```

安装器会让 Provider 保持在 Windows 应用目录中可见。当前 Windows 设置会过滤使用 `AppListEntry="none"` 隐藏的 Provider，即使它仍然存在于 `AppExtensionCatalog` 中。

## 安全模型

在受管理环境部署前请阅读 [SECURITY.md](SECURITY.md)。

- 目标必须是已经存在的绝对 `.exe` 路径。
- 启动器不保存参数，也不调用 `cmd.exe` 或 PowerShell。
- 通过当前用户会话中的规范化可执行文件路径匹配窗口，而不是只比较进程名。
- 包签名私钥以不可导出方式生成，并在应用包签名后立即删除。
- 只有公钥证书会加入 `LocalMachine\TrustedPeople`。
- 生成的是 `CA=false` 的终端代码签名证书，不是根 CA。
- 机器证书所有权记录在管理员保护的 `HKLM\SOFTWARE\CopilotKeyBridge`；卸载器不会信任用户可写状态文件来决定删除哪张机器证书。
- 启动器以普通完整性级别运行，无法可靠控制管理员权限目标程序。
- 应用包不带时间戳；保留的 MSIX 仅用于诊断，不是长期恢复介质。

安装器之所以在本机构建，是因为目标程序路径会嵌入并签名到应用包中。每次重新配置都会创建新的公开证书，并立即销毁对应私钥。历史公开证书会继续受信任，以免其他 Windows 用户仍在使用旧版用户包；最后一个用户包卸载后，卸载器会尝试删除项目拥有的全部公开证书。如果系统拒绝查询所有用户包，清理会中止并保留信任，而不会破坏其他用户的应用包；管理员需要手工完成清理。未来也可以设计预签名版本，但需要不同的配置存储和发布信任模型。

## 已知限制

- 窗口唤醒是尽力而为。托盘应用、控制台、管理员程序、多实例及特殊多进程应用可能被再次启动，或者无法置前。
- Windows 会限制前台窗口切换，其他程序偶尔可能继续保持焦点。
- Provider 必须保留在开始菜单/所有应用目录中，才能通过当前 Windows 设置的资格检查。点击该项目会启动配置的目标程序。
- v1 仅支持一个目标，不支持命令行参数。
- 不支持网络共享中的可执行文件路径。
- 选择操作由用户在 Windows 设置中完成；CopilotKeyBridge 不自动操控设置界面，也不写私有设置状态。
- 企业 GPO/MDM 可以覆盖用户的设置选择。

## 故障排查

### 设置里看不到 Provider

```powershell
Get-AppxPackage CopilotKeyBridge
Get-StartApps | Where-Object AppID -match CopilotKeyBridge
Start-Process 'ms-settings:personalization-textinput-copilot-hardwarekey'
```

### 按键仍打开搜索或开始菜单

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\BrandedKey'
```

`BrandedKeyChoiceType` 应为 `App`，`AppAumid` 应以 `!Bridge` 结尾。

### MSIX 部署失败

PowerShell 通常会输出 AppX Activity ID：

```powershell
Get-AppPackageLog -ActivityID '<activity-id>'
```

也可查看 **事件查看器 > 应用程序和服务日志 > Microsoft > Windows > AppxDeployment-Server**。

### 目标程序没有启动

查看：

```text
%LOCALAPPDATA%\CopilotKeyBridge\CopilotKeyBridge.log
```

如果应用升级后安装路径改变，请重新运行 `Setup.cmd`。

## 测试

静态检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
```

完整发布检查单见 [docs/release-checklist.md](docs/release-checklist.md)。

集成测试会安装或重新配置当前用户的应用包，建议在一次性 Windows 测试机上运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Integration.Tests.ps1 `
  -Target "C:\Path\YourApp.exe"
```

实体 Copilot 键的冷启动和热唤醒仍是人工发布门禁。

一次真实问题的完整复盘见 [docs/postmortem.zh-CN.md](docs/postmortem.zh-CN.md)。

## 许可证

[MIT](LICENSE)

Windows 和 Microsoft Copilot 是 Microsoft Corporation 的商标。CopilotKeyBridge 是独立项目，与微软没有隶属或背书关系。
