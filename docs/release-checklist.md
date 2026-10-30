# Release checklist

## Source

- [ ] Update `CHANGELOG.md`.
- [ ] Run `tests/Static.Tests.ps1` on Windows PowerShell 5.1.
- [ ] Review the pinned Microsoft SDK Build Tools version and SHA-256.
- [ ] Confirm no generated MSIX, certificate, executable, log, or state file is tracked.
- [ ] Create an annotated source tag such as `v0.1.0`.
- [ ] Publish a source archive and SHA-256 checksums. Do not publish a target-specific generated MSIX.

## Platform matrix

- [ ] Windows 11 x64, current production build.
- [ ] Windows 11 ARM64, current production build.
- [ ] At least English and Simplified Chinese display languages.
- [ ] Standard user with over-the-shoulder administrator approval.
- [ ] Pro and Home where available; document edition-specific results.

## Functional gates

- [ ] Provider appears in `AppExtensionCatalog`.
- [ ] Provider AUMID appears in `Get-StartApps`.
- [ ] Provider appears in the Windows Copilot key app picker.
- [ ] Cold activation starts from zero target processes.
- [ ] Warm activation restores a minimized target without increasing process count.
- [ ] No bridge process remains after activation.
- [ ] Reconfiguration preserves Package Family Name and AUMID.
- [ ] Signing private key count is zero after install.
- [ ] Install failure before trust leaves no private key or temporary build directory.
- [ ] Uninstall removes package, project-owned public certificates, HKLM ownership state, and per-user state.

## Security gates

- [ ] Relative paths, directories ending in `.exe`, registry-provider paths, UNC paths, and mapped network drives are rejected.
- [ ] Display names with controls or excessive length are rejected before certificate creation.
- [ ] User-editable `state.json` cannot influence elevated certificate deletion.
- [ ] Existing GPO/MDM Copilot policy is warned about and never modified.
- [ ] UAC cancellation fails cleanly.
- [ ] AppLocker/WDAC behavior is documented if tested.
