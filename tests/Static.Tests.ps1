$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object Collections.Generic.List[string]

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

Write-Host 'Parsing PowerShell files...'
$powerShellFiles = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1'
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        $failures.Add("PowerShell parse error in $($file.FullName): $($parseError.Message)")
    }
}

Write-Host 'Compiling the launcher...'
$compilerCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Assert-True ($null -ne $compiler) 'The inbox .NET Framework C# compiler was not found.'
if ($null -ne $compiler) {
    $output = Join-Path $env:TEMP ("CopilotKeyBridge-static-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
    try {
        $compilerOutput = & $compiler @(
            '/nologo',
            '/target:winexe',
            '/platform:anycpu',
            '/optimize+',
            '/warn:4',
            '/warnaserror+',
            "/out:$output",
            (Join-Path $root 'src\Launcher.cs')) 2>&1
        $compilerExitCode = $LASTEXITCODE
        if ($compilerExitCode -ne 0) {
            $compilerOutput | Out-Host
        }
        Assert-True ($compilerExitCode -eq 0) "Launcher compilation failed with exit code $compilerExitCode."
        Assert-True (Test-Path -LiteralPath $output) 'Launcher compiler did not produce an executable.'
    }
    finally {
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Validating the package manifest template...'
$manifestPath = Join-Path $root 'src\AppxManifest.xml'
$manifestText = [IO.File]::ReadAllText($manifestPath).
    Replace('{{VERSION}}', '1.0.0.0').
    Replace('{{ARCHITECTURE}}', 'x64').
    Replace('{{PROVIDER_NAME}}', 'CopilotKeyBridge: Test').
    Replace('{{PROVIDER_DESCRIPTION}}', 'Launch or activate Test')
try {
    [xml]$manifest = $manifestText
    Assert-True ($manifest.Package.Identity.Name -eq 'CopilotKeyBridge') 'Unexpected package identity name.'
    Assert-True ($manifest.Package.Applications.Application.Id -eq 'Bridge') 'Unexpected application ID.'
    $extension = $manifest.Package.Applications.Application.Extensions.Extension.AppExtension
    Assert-True ($extension.Name -eq 'com.microsoft.windows.copilotkeyprovider') 'Copilot key provider extension is missing.'
    Assert-True ($extension.PublicFolder -eq 'Public') 'Provider public folder is missing.'
    Assert-True ($manifest.Package.Properties.PackageIntegrity.Content.Enforcement -eq 'on') 'Runtime package integrity enforcement is missing.'
    $appListEntry = $manifest.Package.Applications.Application.VisualElements.GetAttribute('AppListEntry')
    Assert-True ([string]::IsNullOrWhiteSpace($appListEntry)) 'Provider must remain visible in the Windows app catalog.'
}
catch {
    $failures.Add("Manifest validation failed: $($_.Exception.Message)")
}

Write-Host 'Checking security invariants...'
$launcherSource = [IO.File]::ReadAllText((Join-Path $root 'src\Launcher.cs'))
$installSource = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
$commonSource = [IO.File]::ReadAllText((Join-Path $root 'scripts\Common.ps1'))
$uninstallSource = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
Assert-True ($launcherSource -notmatch '(?i)cmd\.exe|powershell\.exe') 'Launcher must not invoke a command shell.'
Assert-True ($launcherSource -match 'UseShellExecute = false') 'Launcher must create the configured executable directly.'
Assert-True ($launcherSource -match 'QueryFullProcessImageName') 'Launcher must match windows by executable path.'
Assert-True ($launcherSource -match 'CopilotKeyBridge\.Launcher') 'Launcher must serialize activation with a named mutex.'
Assert-True (($installSource + $commonSource) -notmatch 'SetCopilotHardwareKey|EnterAppAumid') 'Installer must not write Copilot policy values.'
Assert-True ($installSource -match 'Remove-PrivateSigningCertificate') 'Installer must destroy the ephemeral private signing key.'
Assert-True ($commonSource -match 'Remove-Item[^\r\n]+-DeleteKey') 'Certificate cleanup must delete the underlying private key container.'
Assert-True ($uninstallSource -notmatch 'state\.json|ConvertFrom-Json') 'Uninstaller must not trust the user-writable state file for certificate deletion.'
Assert-True ($commonSource -match 'BridgeMachineStateKey') 'Machine certificate ownership must be recorded under HKLM.'

if ($failures.Count -gt 0) {
    Write-Host "`nStatic tests failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nAll static tests passed." -ForegroundColor Green
