[CmdletBinding()]
param(
    [switch]$KeepCertificate,
    [switch]$KeepState,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\Common.ps1')

$installRoot = Join-Path $env:LOCALAPPDATA 'CopilotKeyBridge'

$packages = @(Get-AppxPackage -Name $script:BridgePackageName -ErrorAction SilentlyContinue)
$unexpectedPackages = @($packages | Where-Object Publisher -ne $script:BridgePublisher)
if ($unexpectedPackages.Count -gt 0) {
    throw 'A package named CopilotKeyBridge is installed with an unexpected publisher. Refusing to remove it.'
}
$ownedPackages = @($packages | Where-Object Publisher -eq $script:BridgePublisher)
if ($ownedPackages.Count -gt 1) {
    throw 'More than one owned CopilotKeyBridge package was returned for the current user.'
}
$package = $ownedPackages | Select-Object -First 1
if ($null -ne $package) {
    $aumid = "$($package.PackageFamilyName)!$($script:BridgeApplicationId)"
    $selection = Get-CopilotKeySelection
    if ($selection.AppAumid -eq $aumid -and $selection.ChoiceType -in @('App', 'AppEnforcedByPolicy')) {
        Write-Warning 'CopilotKeyBridge is currently selected for the Copilot key.'
        Open-CopilotKeySettings
        if (-not $Force) {
            [void](Read-Host 'Choose Search or another target in Windows Settings, then press Enter to continue uninstalling')
            $selection = Get-CopilotKeySelection
            if ($selection.AppAumid -eq $aumid -and $selection.ChoiceType -in @('App', 'AppEnforcedByPolicy')) {
                throw 'CopilotKeyBridge is still selected. Choose another key action, or rerun with -Force to remove it anyway.'
            }
        }
    }

    Write-BridgeStep 'Removing the current user package'
    Remove-AppxPackage -Package $package.PackageFullName
}

if (-not $KeepCertificate) {
    $thumbprints = @(Get-OwnedMachineCertificateThumbprints)
    if ($thumbprints.Count -gt 0) {
        Write-Host 'Windows may request administrator approval to remove the unused package certificate.' -ForegroundColor Yellow
        Remove-OwnedMachineCertificateTrust -All
    }
}

if ((Test-Path -LiteralPath $installRoot) -and -not $KeepState) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}

Write-Host 'CopilotKeyBridge was removed for the current user.' -ForegroundColor Green
