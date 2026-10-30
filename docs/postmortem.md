# Postmortem: when a valid AppUserModelID was not launchable

## Incident

The initial goal was to remap a laptop's Copilot hardware key from Microsoft 365 Copilot to WorkBuddy, an unpackaged Electron desktop application.

`Get-StartApps` returned:

```text
WorkBuddy    WorkBuddy.WorkBuddy
```

Writing that ID as the Copilot target appeared successful. While WorkBuddy was running, the key brought its window forward. After WorkBuddy was fully closed, the same key opened Start instead.

## Root cause

`WorkBuddy.WorkBuddy` was a Win32 shortcut AppUserModelID. It grouped and identified an existing WorkBuddy window, but it was not the AUMID of an installed packaged application with an activation entry. Windows could switch to a matching live window, but could not cold-launch that ID.

The Copilot key picker has a stricter contract than a generic Start menu shortcut:

1. The target application must have package identity.
2. Its package must be signed and trusted.
3. Its application manifest must register `com.microsoft.windows.copilotkeyprovider`.
4. The corresponding application entry must be launchable and visible to the Windows app catalog.

## Investigation mistakes

### Mistake 1: treating `Get-StartApps` output as proof of cold-launch support

An AppUserModelID is an identity, not a guarantee that `shell:AppsFolder\<id>` can create a new process. The correct test is to stop the app completely and invoke the ID through AppsFolder.

### Mistake 2: validating only the warm path

The first test was run while WorkBuddy already had a window. That tested window switching, not activation. The cold path must start with zero matching processes.

### Mistake 3: trusting one registry schema across Windows builds

Current Microsoft documentation defines `SetCopilotHardwareKey` as a `REG_SZ` AUMID. A prerelease legacy schema used a `DWORD SetCopilotHardwareKey=1` plus `REG_SZ EnterAppAumid`. Mixing schemas can expose an option in Settings without producing a stable mapping. CopilotKeyBridge avoids policy writes in its default flow and uses the Settings picker.

### Mistake 4: hiding the provider too early

The first bridge package used `AppListEntry="none"`. The extension appeared in `AppExtensionCatalog`, but Windows Settings filtered it out of the app picker. Keeping the provider visible fixed eligibility.

### Mistake 5: underestimating MSIX trust scope

A self-signed package certificate in `CurrentUser\TrustedPeople` was insufficient on the tested machine. AppX deployment validated against machine trust. The final workflow imports only the public end-entity certificate into `LocalMachine\TrustedPeople` with a narrowly scoped UAC operation.

## Correct design

CopilotKeyBridge creates a tiny packaged provider whose AUMID is genuinely activatable. The provider embeds one absolute target executable path. When activated, it:

1. Serializes concurrent key activations with a named mutex.
2. Enumerates top-level windows in the current session.
3. Matches their owning executable by canonical full path.
4. Restores and focuses a matching window when possible.
5. Otherwise launches the target with its installation directory as the working directory.
6. Exits immediately.

No hotkey hook or background process is required because Windows owns the physical key routing.

## Verification gates

A fix is not complete until all of these pass:

- Provider exists in `AppExtensionCatalog`.
- Provider AUMID exists in `Get-StartApps`.
- Provider is visible in the Copilot app picker.
- Shell selection reports `BrandedKeyChoiceType=App` and the expected AUMID.
- Cold test starts with zero target processes and produces the target main window.
- Warm test restores a minimized target without increasing its process count.
- Launcher has no resident process after activation.
- Uninstall removes package state and removes certificate trust only when unused.

## General lessons

- Test identity, activation, and window switching as separate capabilities.
- Always test both cold and warm paths.
- Prefer documented platform integration over simulated hotkeys.
- Prefer visible user confirmation in Settings over UI Automation or private registry writes.
- Do not hide an extension provider unless the host explicitly supports hidden providers.
- Keep elevated work minimal; package registration and user choice belong to the interactive user.
