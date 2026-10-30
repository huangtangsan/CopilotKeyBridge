[CmdletBinding()]
param(
    [string]$Target,
    [string]$DisplayName,
    [switch]$KeepBuildFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\Common.ps1')
$sourceVersion = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'VERSION')).Trim()

$workRoot = Join-Path $env:TEMP ("CopilotKeyBridge-{0}" -f [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $env:LOCALAPPDATA 'CopilotKeyBridge'
$certificate = $null
$certificateThumbprint = $null
$machineTrustAdded = $false
$packageInstalled = $false
$freshPackageRemoved = $false
$existingPackage = $null

try {
    Write-BridgeStep 'Checking Windows and target application'
    Assert-SupportedWindows
    $resolvedTarget = Resolve-BridgeTarget -Target $Target
    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = Get-DefaultDisplayName -Target $resolvedTarget
    }
    Assert-ValidDisplayName -DisplayName $DisplayName
    Write-Host "Target: $resolvedTarget"
    Write-Host "Name:   $DisplayName"

    $existingPolicy = Get-CopilotPolicySummary
    if ($null -ne $existingPolicy) {
        Write-Warning 'A Copilot hardware key policy already exists. CopilotKeyBridge will not modify it, but an administrator policy can override your Settings choice.'
    }

    New-Item -ItemType Directory -Path $workRoot, $installRoot -Force | Out-Null
    $certificatePath = Join-Path $workRoot 'CopilotKeyBridge.cer'

    $existingPackage = Get-AppxPackage -Name $script:BridgePackageName -ErrorAction SilentlyContinue
    if ($null -ne $existingPackage -and $existingPackage.Publisher -ne $script:BridgePublisher) {
        throw "A package named $($script:BridgePackageName) is installed with an unexpected publisher. Remove it manually before continuing."
    }

    Write-BridgeStep 'Preparing the local package signing certificate'
    $certificate = New-EphemeralSigningCertificate -CertificatePath $certificatePath
    $certificateThumbprint = $certificate.Thumbprint

    $architecture = Get-BridgeArchitecture
    $version = Get-NextPackageVersion
    $tools = Get-WindowsSdkTools -Architecture $architecture -WorkRoot $workRoot

    Write-BridgeStep "Building CopilotKeyBridge $version"
    $packagePath = New-BridgePackage `
        -RepositoryRoot $repositoryRoot `
        -WorkRoot $workRoot `
        -Target $resolvedTarget `
        -DisplayName $DisplayName `
        -Architecture $architecture `
        -Version $version `
        -Certificate $certificate `
        -SdkTools $tools

    Add-MachineCertificateTrust -Certificate $certificate -CertificatePath $certificatePath
    $machineTrustAdded = $true
    $packageSignature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($packageSignature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "Package trust validation failed: $($packageSignature.StatusMessage)"
    }

    Write-BridgeStep 'Installing the Copilot key provider for the current user'
    Add-AppxPackage -Path $packagePath -ForceApplicationShutdown
    $packageInstalled = $true
    $package = Get-AppxPackage -Name $script:BridgePackageName -ErrorAction Stop
    $aumid = "$($package.PackageFamilyName)!$($script:BridgeApplicationId)"

    $startEntry = $null
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $startEntry = Get-StartApps | Where-Object AppID -eq $aumid
        if ($null -eq $startEntry) { Start-Sleep -Milliseconds 250 }
    } while ($null -eq $startEntry -and (Get-Date) -lt $deadline)
    if ($null -eq $startEntry) {
        Write-Warning 'The provider is installed but has not appeared in the Windows app catalog yet. Reopen Settings after a few seconds.'
    }

    try {
        Copy-Item -LiteralPath $packagePath -Destination (Join-Path $installRoot 'CopilotKeyBridge.msix') -Force
        Copy-Item -LiteralPath $certificatePath -Destination (Join-Path $installRoot 'CopilotKeyBridge.cer') -Force
        $state = [ordered]@{
            target = $resolvedTarget
            displayName = $DisplayName
            sourceVersion = $sourceVersion
            packageFamilyName = $package.PackageFamilyName
            packageFullName = $package.PackageFullName
            aumid = $aumid
            certificateThumbprint = $certificate.Thumbprint
            installedAt = (Get-Date).ToString('o')
        }
        $statePath = Join-Path $installRoot 'state.json'
        $temporaryStatePath = "$statePath.tmp"
        [IO.File]::WriteAllText(
            $temporaryStatePath,
            ($state | ConvertTo-Json),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
    }
    catch {
        Write-Warning "Diagnostic artifact persistence failed: $($_.Exception.Message)"
    }

    Write-BridgeStep 'Opening the Windows Copilot key settings'
    try {
        Open-CopilotKeySettings
        Write-Host 'Choose Open app/Custom, then select:' -ForegroundColor Yellow
        Write-Host "  CopilotKeyBridge: $DisplayName" -ForegroundColor White
    }
    catch {
        Write-Warning "Windows Settings could not be opened automatically: $($_.Exception.Message)"
    }

    Write-Host "`nInstalled AUMID: $aumid"
    try {
        $selection = Get-CopilotKeySelection
        if ($selection.AppAumid -eq $aumid -and $selection.ChoiceType -in @('App', 'AppEnforcedByPolicy')) {
            Write-Host 'Copilot key mapping is active.' -ForegroundColor Green
        } else {
            Write-Warning 'Provider installation succeeded, but manual selection is still required in Settings.'
        }
    }
    catch {
        Write-Warning "Provider installation succeeded, but the current Settings selection could not be read: $($_.Exception.Message)"
    }
}
catch {
    $failure = $_
    if ($packageInstalled -and $null -eq $existingPackage) {
        $failedPackage = Get-AppxPackage -Name $script:BridgePackageName -ErrorAction SilentlyContinue
        if ($null -ne $failedPackage) {
            Remove-AppxPackage -Package $failedPackage.PackageFullName -ErrorAction SilentlyContinue
            $freshPackageRemoved = $true
        }
    }
    if ($machineTrustAdded -and (-not $packageInstalled -or $freshPackageRemoved) -and -not [string]::IsNullOrWhiteSpace($certificateThumbprint)) {
        try {
            Remove-OwnedMachineCertificateTrust -Thumbprints @($certificateThumbprint) -SkipAllUserPackageCheck
        } catch {
            Write-Warning "Automatic certificate rollback failed: $($_.Exception.Message)"
        }
    }
    throw $failure
}
finally {
    try {
        Remove-PrivateSigningCertificate -Thumbprint $certificateThumbprint
    }
    finally {
        if ((Test-Path -LiteralPath $workRoot) -and -not $KeepBuildFiles) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $workRoot) {
            Write-Host "Build files retained at: $workRoot"
        }
    }
}
