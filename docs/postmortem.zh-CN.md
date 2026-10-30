# 复盘：看似有效的 AppUserModelID 为什么无法冷启动

## 事件

最初需求是把笔记本的 Copilot 实体键从 Microsoft 365 Copilot 改为启动 WorkBuddy。WorkBuddy 是一个未打包的 Electron 桌面应用。

`Get-StartApps` 返回：

```text
WorkBuddy    WorkBuddy.WorkBuddy
```

把这个 ID 写成 Copilot 键目标后，WorkBuddy 已运行时可以被按键唤起；彻底退出 WorkBuddy 后，同一个按键却打开了开始菜单。

## 根因

`WorkBuddy.WorkBuddy` 是普通 Win32 快捷方式的 AppUserModelID。它可以用来分组和识别已经存在的窗口，但不是一个带激活入口的已安装打包应用 AUMID。Windows 能切换到现有窗口，却无法用这个 ID 创建新进程。

Copilot 键选择器比普通开始菜单快捷方式要求更严格：

1. 目标应用必须具有包身份。
2. 应用包必须签名且受系统信任。
3. 清单必须注册 `com.microsoft.windows.copilotkeyprovider`。
4. 对应应用入口必须可启动，并且在 Windows 应用目录中可见。

## 调试中的错误

### 错误 1：把 `Get-StartApps` 输出当成可冷启动证明

AppUserModelID 是身份，不保证 `shell:AppsFolder\<id>` 可以创建新进程。正确测试方法是先彻底停止应用，再通过 AppsFolder 调用该 ID。

### 错误 2：只验证了热路径

第一次测试时 WorkBuddy 已经有窗口，验证的是窗口切换，不是应用激活。冷路径测试必须从零个匹配进程开始。

### 错误 3：把某一种注册表格式套用到所有 Windows 版本

微软当前文档将 `SetCopilotHardwareKey` 定义为保存 AUMID 的 `REG_SZ`。早期预览版出现过 `DWORD SetCopilotHardwareKey=1` 加 `REG_SZ EnterAppAumid`。混用格式可能让设置页面出现选项，却无法得到稳定映射。CopilotKeyBridge 默认不写策略，而是使用 Windows 设置选择器。

### 错误 4：过早隐藏 Provider

最初桥接包使用了 `AppListEntry="none"`。它仍出现在 `AppExtensionCatalog` 中，但 Windows 设置会把它从应用选择器中筛掉。保持 Provider 可见后，资格检查才通过。

### 错误 5：低估 MSIX 信任范围

在测试机器上，只把自签名证书放进 `CurrentUser\TrustedPeople` 不足以通过 AppX 部署验证。最终流程通过最小化 UAC 操作，只把公开的终端证书加入 `LocalMachine\TrustedPeople`。

## 正确设计

CopilotKeyBridge 创建一个真正可激活的小型打包 Provider，并把一个绝对目标 `.exe` 路径嵌入包内。它被激活后：

1. 用命名互斥量串行化连续按键。
2. 枚举当前会话的顶层窗口。
3. 用规范化后的完整可执行文件路径匹配窗口进程。
4. 找到窗口时恢复并尝试置前。
5. 没有窗口时，以目标安装目录作为工作目录启动程序。
6. 立即退出。

因为实体键路由由 Windows 负责，所以不需要全局键盘钩子或后台常驻进程。

## 完成标准

- Provider 存在于 `AppExtensionCatalog`。
- Provider AUMID 存在于 `Get-StartApps`。
- Provider 出现在 Copilot 应用选择器中。
- Shell 状态为 `BrandedKeyChoiceType=App` 且 AUMID 正确。
- 冷启动测试从零个目标进程开始，并最终出现目标主窗口。
- 热启动测试能恢复最小化窗口，且目标进程数不增加。
- 激活完成后没有残留桥接进程。
- 卸载能移除包，并且只在证书不再被使用时删除机器信任。

## 通用经验

- 身份、激活和窗口切换是三个不同能力，必须分别测试。
- 永远同时测试冷路径和热路径。
- 优先使用系统提供的扩展点，而不是模拟热键。
- 优先让用户在设置中可见地确认，不用 UI Automation 或私有注册表写入代替用户选择。
- 除非宿主明确支持，否则不要隐藏扩展 Provider。
- 管理员权限操作应保持最小；包注册和用户选择都应在交互用户上下文中完成。
