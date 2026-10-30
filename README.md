# CopilotKeyBridge

[简体中文](README.zh-CN.md)

Use the Windows Copilot key to launch or activate any desktop `.exe`, without a resident hotkey process.

CopilotKeyBridge registers a small, signed MSIX application as an official Windows Copilot key provider. Pressing the physical Copilot key, or `Win+C` where Windows maps it to the same action, starts the bridge. The bridge restores an existing target window when possible and cold-starts the configured executable otherwise. It exits immediately after handling the key.

## Why this exists

Windows Settings only lists packaged and signed applications that register the `com.microsoft.windows.copilotkeyprovider` extension. Most Win32 applications are unpackaged, so they cannot appear in that picker.

A Start menu AppUserModelID is not necessarily a launchable packaged AUMID. Pointing the Copilot policy at a plain shortcut ID can appear to work while the app is already running, then fall back to Search or Start when the app is closed. CopilotKeyBridge supplies the missing packaged activation boundary.

## Features

- Cold-starts an unpackaged Win32 application.
- Restores and focuses an existing window by exact executable path.
- No AutoHotkey, PowerToys, service, scheduled task, or startup process.
- No shell commands or arbitrary command-line arguments.
- Uses the documented Windows Copilot key provider extension and Settings page.
- Creates a non-exportable, ephemeral package-signing key and deletes it immediately after signing.
- Downloads Microsoft Windows SDK Build Tools only when the SDK is absent, with a pinned SHA-256 check.
- Supports x64 and ARM64 Windows 11.
- Includes explicit uninstall and certificate cleanup.

## Requirements

- Windows 11 client, build `22621.4391` or later.
- A physical Copilot key, or a Windows build where `Win+C` invokes the same branded-key action.
- Windows PowerShell 5.1.
- Internet access on first install if the Windows SDK is not already installed.
- One UAC approval to trust the locally generated package certificate.

The Copilot hardware-key Group Policy is documented for Pro, Enterprise, Education, and IoT Enterprise. CopilotKeyBridge itself uses the user-facing Settings picker and does not write that policy.

## Quick start

1. Download or clone this repository.
2. Double-click `Setup.cmd`.
3. Select the target `.exe`.
4. Approve the certificate trust prompt.
5. In the Settings page that opens, choose **Open app** or **Custom**, then select `CopilotKeyBridge: <your app>`.

Command-line installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Target "C:\Program Files\WorkBuddy\WorkBuddy.exe" `
  -DisplayName "WorkBuddy"
```

## Reconfigure

Run `Setup.cmd` again and choose a different `.exe`. The installer creates a newer package version while preserving the package family and AUMID, so the existing Copilot key selection remains valid.

## Uninstall

Double-click `Uninstall.cmd`, or run:

```powershell
.\uninstall.ps1
```

If CopilotKeyBridge is currently selected, the uninstaller asks you to choose Search or another app before package removal. It removes the current user's package, the local private signing key, and the machine trust certificate when no user registrations remain.

For scripted cleanup, `uninstall.ps1 -Force` skips the selection check, but certificate cleanup can still show UAC. Windows may retain the old AUMID until the user chooses another key action, so normal interactive uninstall is preferred.

## How it works

```text
Copilot key / Win+C
        |
        v
Windows branded-key broker
        |
        v
Signed MSIX provider (CopilotKeyBridge)
        |
        +--> matching top-level window exists -> restore + focus
        |
        `--> no matching window -> launch configured absolute .exe path
```

The package manifest registers:

```xml
<uap3:AppExtension
  Name="com.microsoft.windows.copilotkeyprovider"
  Id="Bridge"
  DisplayName="CopilotKeyBridge: My App"
  Description="Launch or activate My App"
  PublicFolder="Public" />
```

The installer keeps the provider visible in the Windows app catalog. Current Settings builds filter out providers whose application uses `AppListEntry="none"`, even though those providers still appear in `AppExtensionCatalog`.

## Security model

Read [SECURITY.md](SECURITY.md) before deploying this in a managed environment.

- The target must be an existing absolute `.exe` path.
- The launcher stores no arguments and does not invoke `cmd.exe` or PowerShell.
- Existing windows are matched by canonical executable path in the current user session, not by process name.
- The package-signing private key is generated as non-exportable and deleted immediately after the package is signed.
- Only the public certificate is added to `LocalMachine\TrustedPeople`.
- The generated certificate is an end-entity code-signing certificate (`CA=false`), not a root CA.
- Machine certificate ownership is recorded under administrator-protected `HKLM\SOFTWARE\CopilotKeyBridge`; the user-writable state file is never trusted for elevated certificate deletion.
- The launcher runs at medium integrity and cannot activate an elevated target reliably.
- The package is not timestamped; the retained MSIX is diagnostic material, not a long-term recovery artifact.

The installer builds locally because each configuration embeds its target path in the signed package. Every reconfiguration creates a new public certificate and immediately destroys its private key. Historical public certificates remain trusted so another Windows user cannot be stranded on an older per-user package; the uninstaller attempts to remove all project-owned public certificates after the final user package is gone. If the all-user package query is denied, cleanup aborts and retains trust rather than breaking another user's package; an administrator must complete cleanup manually. A future pre-signed release could move configuration into package-owned state, but that requires a different distribution trust model.

## Limitations

- Window activation is best effort. Tray-only, console, elevated, multi-instance, and unusual multi-process apps may be cold-started or may not be focusable.
- Windows restricts foreground activation; another process can sometimes retain focus.
- The provider remains visible in Start/All Apps because current Settings builds require that for picker eligibility. Launching that entry invokes the configured target.
- The project intentionally supports one target and no command-line arguments in v1.
- Network executable paths are intentionally not supported.
- Selection is intentionally completed by the user in Windows Settings. CopilotKeyBridge does not automate or write private Settings state.
- Enterprise GPO/MDM assignment can override a user's Settings choice.

## Troubleshooting

### The provider is not in the picker

Check that it is installed and visible:

```powershell
Get-AppxPackage CopilotKeyBridge
Get-StartApps | Where-Object AppID -match CopilotKeyBridge
```

Then reopen:

```powershell
Start-Process 'ms-settings:personalization-textinput-copilot-hardwarekey'
```

### The key opens Search or Start

Confirm the current selection:

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\BrandedKey'
```

`BrandedKeyChoiceType` should be `App`, and `AppAumid` should end in `!Bridge`.

### Package deployment failed

PowerShell usually prints an AppX Activity ID. Retrieve the detailed log with:

```powershell
Get-AppPackageLog -ActivityID '<activity-id>'
```

Also inspect **Event Viewer > Applications and Services Logs > Microsoft > Windows > AppxDeployment-Server**.

### The target did not start

Review:

```text
%LOCALAPPDATA%\CopilotKeyBridge\CopilotKeyBridge.log
```

Re-run `Setup.cmd` if the application moved or was upgraded into a different path.

## Building and tests

The installer compiles `src/Launcher.cs` with the inbox .NET Framework compiler and packages it with Microsoft's `MakeAppx.exe` and `SignTool.exe`.

Run static checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
```

Run the integration test on a disposable Windows machine:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Integration.Tests.ps1 `
  -Target "C:\Path\YourApp.exe"
```

The integration test installs/reconfigures the bridge and validates AUMID activation. Physical-key validation remains a manual release gate.

The full manual gate is in [docs/release-checklist.md](docs/release-checklist.md).

Repository publication and source-release instructions are in [docs/publishing.md](docs/publishing.md).

## Project history

The original WorkBuddy debugging incident and the design corrections are documented in [docs/postmortem.md](docs/postmortem.md).

## References

- [Microsoft Copilot hardware key providers](https://learn.microsoft.com/windows/apps/develop/windows-integration/microsoft-copilot-key-provider)
- [End-user settings for the Copilot key](https://learn.microsoft.com/windows/client-management/manage-windows-copilot#end-user-settings-for-the-copilot-key)
- [SetCopilotHardwareKey policy](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-windowsai#setcopilothardwarekey)
- [MSIX package signing](https://learn.microsoft.com/windows/msix/package/signing-package-overview)
- [Find an installed application's AUMID](https://learn.microsoft.com/windows/configuration/store/find-aumid)

## License

[MIT](LICENSE)

Windows and Microsoft Copilot are trademarks of Microsoft Corporation. CopilotKeyBridge is an independent project and is not affiliated with or endorsed by Microsoft.
