# Security policy

## Supported versions

Security fixes are applied to the latest commit and latest tagged release.

## Reporting a vulnerability

Use GitHub private vulnerability reporting when enabled. If it is unavailable, open an issue asking for a private contact channel without publishing exploit details.

## Trust and privilege boundaries

CopilotKeyBridge performs one machine-wide action: it adds the public half of a locally generated package-signing certificate to `LocalMachine\TrustedPeople`. This requires UAC. The private key is ephemeral: it is generated as non-exportable, used to sign one bridge package, and deleted in a `finally` block before the installer exits.

Each certificate is:

- An end-entity certificate with `CA=false`.
- Restricted to digital signatures and code signing.
- Recorded in an administrator-protected `HKLM\SOFTWARE\CopilotKeyBridge` ownership ledger.
- Retained while any user may still have a package signed by it, then removed together with all project-owned public certificates when an elevated all-user query confirms no CopilotKeyBridge package remains. Query failures retain trust and require manual administrator cleanup.

The package and launcher run as the interactive user at medium integrity. CopilotKeyBridge does not install a service, driver, scheduled task, startup item, keyboard hook, or network listener.

## Target validation

The installer accepts one existing `.exe` path. It does not support arguments, URLs, scripts, shell commands, or relative paths. The launcher invokes the absolute executable directly and sets its parent directory as the working directory.

Existing windows are matched by exact executable path and current session. This avoids process-name spoofing but does not make an untrusted target executable safe. Users must choose software they already trust.

## Downloaded build tools

When the Windows SDK is absent, the installer downloads `Microsoft.Windows.SDK.BuildTools` directly from NuGet's HTTPS flat-container endpoint. The exact version and SHA-256 are pinned in `scripts/Common.ps1`. A hash mismatch aborts installation.

The generated package is not timestamped. Its installed copy continues to run after certificate expiry, but the retained MSIX is intended for diagnostics, not long-term recovery. Re-run the installer to produce a fresh package if reinstallation is needed.

## Managed environments

Organizations should review these controls before deployment:

- MSIX sideloading and certificate trust policy.
- AppLocker or WDAC rules for the generated package.
- Whether local package compilation is permitted.
- Existing GPO/MDM ownership of the Copilot hardware key.
- Multi-user certificate lifecycle.

CopilotKeyBridge intentionally does not overwrite Copilot Group Policy, MDM state, or private Windows Settings state. Users complete provider selection in the documented Settings page.

Do not create WDAC or AppLocker allow rules for the generic `CN=CopilotKeyBridge Local Package` publisher. Trust is scoped to package deployment, and publisher-wide execution rules would be broader than this project's design.
