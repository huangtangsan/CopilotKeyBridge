# Publishing the GitHub project

The repository intentionally does not publish a prebuilt MSIX because every generated package embeds one user's target executable path and is signed by that machine's ephemeral certificate.

## First publication

1. Review `README.md`, `README.zh-CN.md`, `SECURITY.md`, and `docs/release-checklist.md`.
2. Set the desired source version in `VERSION`, for example `0.1.0`.
3. Move the matching section in `CHANGELOG.md` out of `Unreleased`.
4. Run:

   ```powershell
   .\tests\Static.Tests.ps1
   .\tests\PackageBuild.Tests.ps1
   ```

5. Create the repository on GitHub without adding generated README or license files.
6. Configure your Git identity, then publish:

   ```powershell
   git add .
   git commit -m "Initial open-source release"
   git remote add origin https://github.com/<owner>/CopilotKeyBridge.git
   git push -u origin main
   git tag -a v0.1.0 -m "CopilotKeyBridge v0.1.0"
   git push origin v0.1.0
   ```

The tag triggers `.github/workflows/release.yml`, which verifies that the tag matches `VERSION`, reruns tests, and publishes a source ZIP plus SHA-256 checksum.

## Suggested repository metadata

Description:

> Map the Windows Copilot key to any Win32 app, with cold launch and no resident hotkey process.

Topics:

```text
windows-11 copilot-key win32 msix powershell keyboard-remapping
```

Enable:

- Issues and Discussions.
- Private vulnerability reporting.
- Branch protection requiring the `CI / static-tests` check.
- Dependabot alerts for GitHub Actions.

## Release policy

- Publish source releases only.
- Never upload a `.pfx`, private key, generated `.cer`, target-specific MSIX, `state.json`, or log.
- Document the Windows builds, architectures, languages, and target-app types tested for each release.
- Keep the SDK Build Tools version and hash pinned together.
