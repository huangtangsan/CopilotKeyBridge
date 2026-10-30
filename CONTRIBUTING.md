# Contributing

## Development principles

- Keep the launcher non-resident.
- Prefer documented Windows integration points.
- Do not add shell-command execution or unstructured arguments.
- Keep elevated code narrow and auditable.
- Preserve manual Settings selection as a reliable fallback.
- Test cold activation and warm window restoration separately.

## Local checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
```

Integration tests modify the current user's package registration and can show UAC and Settings UI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Integration.Tests.ps1 `
  -Target "C:\Path\TestApp.exe"
```

Use a disposable Windows 11 VM for package lifecycle changes.

## Pull requests

Include:

- Windows build, edition, architecture, and language tested.
- Cold-launch result from zero target processes.
- Warm activation result from a minimized target.
- Package update and uninstall result.
- Security impact for any change involving elevation, certificates, configuration, or process launch.
