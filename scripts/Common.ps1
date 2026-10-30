Set-StrictMode -Version Latest

$script:BridgePackageName = 'CopilotKeyBridge'
$script:BridgeApplicationId = 'Bridge'
$script:BridgePublisher = 'CN=CopilotKeyBridge Local Package'
$script:BridgeCertificateFriendlyName = 'CopilotKeyBridge ephemeral package signing'
$script:BridgeMachineStateKey = 'SOFTWARE\CopilotKeyBridge'
$script:BridgeSettingsUri = 'ms-settings:personalization-textinput-copilot-hardwarekey'
$script:SdkBuildToolsVersion = '10.0.26100.3916'
$script:SdkBuildToolsSha256 = '9CB064E5815CD3F3AE89EE223C82F7091BE0CAA07507E38B871137E4EA3D5D33'
$script:SdkBuildToolsUrl = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/10.0.26100.3916/microsoft.windows.sdk.buildtools.10.0.26100.3916.nupkg'

function Write-BridgeStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-SupportedWindows {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.ProductType -ne 1) {
        throw 'CopilotKeyBridge supports Windows client editions only.'
    }

    $versionKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$versionKey.CurrentBuildNumber
    $ubr = [int]$versionKey.UBR
    if ($build -lt 22621) {
        throw "Windows build $build.$ubr is too old. Windows 11 build 22621.4391 or later is required."
    }
    if (($build -eq 22621 -or $build -eq 22631) -and $ubr -lt 4391) {
        throw "Windows build $build.$ubr is too old. Install KB5044380 or a later cumulative update."
    }
    if ($build -eq 26100 -and $ubr -lt 2161) {
        throw "Windows build $build.$ubr is too old. Install KB5044384 or a later cumulative update."
    }
}

function Get-TargetFromDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose the application for the Copilot key'
    $dialog.Filter = 'Applications (*.exe)|*.exe'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw 'No target application was selected.'
    }
    return $dialog.FileName
}

function Resolve-BridgeTarget {
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = Get-TargetFromDialog
    }

    if ($Target -notmatch '^[A-Za-z]:\\') {
        throw 'The target must be a fully qualified local drive path.'
    }
    $item = Get-Item -LiteralPath $Target -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer) {
        throw 'The target must be a local executable file.'
    }
    $resolved = $item.FullName
    if ([IO.Path]::GetExtension($resolved) -ne '.exe') {
        throw 'The target must be an .exe file. Arguments and shell commands are intentionally not supported.'
    }
    if (-not [IO.File]::Exists($resolved)) {
        throw 'The target executable does not exist.'
    }
    if ($resolved.StartsWith('\\')) {
        throw 'Network executable paths are intentionally not supported.'
    }
    $root = [IO.Path]::GetPathRoot($resolved)
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -eq [IO.DriveType]::Network) {
        throw 'Network executable paths are intentionally not supported.'
    }
    return [IO.Path]::GetFullPath($resolved)
}

function Get-DefaultDisplayName {
    param([Parameter(Mandatory = $true)][string]$Target)

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Target)
    if (-not [string]::IsNullOrWhiteSpace($versionInfo.ProductName)) {
        return $versionInfo.ProductName
    }
    if (-not [string]::IsNullOrWhiteSpace($versionInfo.FileDescription)) {
        return $versionInfo.FileDescription
    }
    return [IO.Path]::GetFileNameWithoutExtension($Target)
}

function Assert-ValidDisplayName {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        throw 'The display name cannot be empty.'
    }
    if ($DisplayName.IndexOfAny([char[]](0..31)) -ge 0) {
        throw 'The display name cannot contain control characters.'
    }
    if (("CopilotKeyBridge: $DisplayName").Length -gt 256) {
        throw 'The display name is too long for an MSIX app extension.'
    }
    if (("Launch or activate $DisplayName").Length -gt 256) {
        throw 'The display name produces an app-extension description longer than 256 characters.'
    }
}

function Get-BridgeArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ($architecture -eq 'ARM64') {
        return 'arm64'
    }
    if ($architecture -eq 'AMD64') {
        return 'x64'
    }
    throw "Unsupported Windows architecture: $architecture"
}

function Get-NextPackageVersion {
    $now = Get-Date
    $candidate = [Version]('1.{0}.{1}.{2}' -f `
        ($now.Year - 2000),
        (($now.Month * 100) + $now.Day),
        [int]($now.TimeOfDay.TotalSeconds / 2))

    $installed = Get-AppxPackage -Name $script:BridgePackageName -ErrorAction SilentlyContinue
    if ($null -eq $installed) {
        return $candidate
    }

    $current = [Version]$installed.Version
    if ($candidate.CompareTo($current) -gt 0) {
        return $candidate
    }

    if ($current.Revision -lt 65535) {
        return [Version]('{0}.{1}.{2}.{3}' -f `
            $current.Major, $current.Minor, $current.Build, ($current.Revision + 1))
    }
    if ($current.Build -lt 65535) {
        return [Version]('{0}.{1}.{2}.0' -f `
            $current.Major, $current.Minor, ($current.Build + 1))
    }
    throw 'Unable to generate a package version newer than the installed package.'
}

function New-EphemeralSigningCertificate {
    param([Parameter(Mandatory = $true)][string]$CertificatePath)

    $certificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $script:BridgePublisher `
        -FriendlyName $script:BridgeCertificateFriendlyName `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable `
        -TextExtension @('2.5.29.19={text}false', '2.5.29.37={text}1.3.6.1.5.5.7.3.3') `
        -NotAfter (Get-Date).AddYears(5)

    Export-Certificate -Cert $certificate -FilePath $CertificatePath -Force | Out-Null
    return $certificate
}

function Remove-PrivateSigningCertificate {
    param([string]$Thumbprint)
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return
    }
    $path = "Cert:\CurrentUser\My\$Thumbprint"
    if (Test-Path -LiteralPath $path) {
        $certificate = Get-Item -LiteralPath $path
        $keyName = $null
        $rsa = $null
        try {
            $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
            if ($rsa -is [Security.Cryptography.RSACng]) {
                $keyName = $rsa.Key.UniqueName
            }
        }
        finally {
            if ($null -ne $rsa) {
                $rsa.Dispose()
            }
            $certificate.Reset()
        }

        Remove-Item -LiteralPath $path -DeleteKey -Force

        if (-not [string]::IsNullOrWhiteSpace($keyName)) {
            $orphanedKey = $null
            try {
                $orphanedKey = [Security.Cryptography.CngKey]::Open(
                    $keyName,
                    [Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider)
                throw "The private signing key still exists after certificate removal: $keyName"
            }
            catch [Security.Cryptography.CryptographicException] {
            }
            finally {
                if ($null -ne $orphanedKey) {
                    $orphanedKey.Dispose()
                }
            }
        }
    }
}

function Invoke-ElevatedPowerShell {
    param([Parameter(Mandatory = $true)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process `
        -FilePath $powerShell `
        -Verb RunAs `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated operation failed with exit code $($process.ExitCode)."
    }
}

function Add-MachineCertificateTrust {
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$CertificatePath
    )

    Write-Host 'Windows will request administrator approval to trust this local package certificate.' -ForegroundColor Yellow
    $certificateBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($CertificatePath))
    $thumbprint = $Certificate.Thumbprint
    $elevatedScript = @"
`$ErrorActionPreference = 'Stop'
`$bytes = [Convert]::FromBase64String('$certificateBase64')
`$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,`$bytes)
if (`$certificate.Thumbprint -ne '$thumbprint') { exit 2 }
`$key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('$($script:BridgeMachineStateKey)')
`$store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
try {
    `$publisher = [string]`$key.GetValue('Publisher', '')
    if (`$publisher -and `$publisher -ne '$($script:BridgePublisher)') { exit 3 }
    `$owned = @(`$key.GetValue('OwnedCertificateThumbprints', @()))
    `$legacy = [string]`$key.GetValue('CertificateThumbprint', '')
    if (`$legacy) { `$owned += `$legacy }
    `$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    `$store.Add(`$certificate)
    `$owned = @(`$owned + '$thumbprint' | Where-Object { `$_ } | Select-Object -Unique)
    `$key.SetValue('OwnedCertificateThumbprints', [string[]]`$owned, [Microsoft.Win32.RegistryValueKind]::MultiString)
    `$key.SetValue('Publisher', '$($script:BridgePublisher)', [Microsoft.Win32.RegistryValueKind]::String)
    `$key.DeleteValue('CertificateThumbprint', `$false)
} catch {
    try {
        `$matches = @(`$store.Certificates | Where-Object Thumbprint -eq '$thumbprint')
        foreach (`$match in `$matches) { `$store.Remove(`$match) }
    } catch {}
    throw
} finally {
    `$store.Close()
    `$key.Close()
}
"@
    Invoke-ElevatedPowerShell -Script $elevatedScript

    $trusted = Get-ChildItem -Path Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -eq $Certificate.Thumbprint
    if ($null -eq $trusted) {
        throw 'The package signing certificate was not added to LocalMachine\TrustedPeople.'
    }
}

function Get-OwnedMachineCertificateThumbprints {
    $path = "HKLM:\$($script:BridgeMachineStateKey)"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $state = Get-ItemProperty -LiteralPath $path
    $thumbprintsProperty = $state.PSObject.Properties['OwnedCertificateThumbprints']
    $legacyThumbprintProperty = $state.PSObject.Properties['CertificateThumbprint']
    $publisherProperty = $state.PSObject.Properties['Publisher']
    if ($null -eq $publisherProperty) {
        return $null
    }
    if ([string]$publisherProperty.Value -ne $script:BridgePublisher) {
        return $null
    }
    $thumbprints = @()
    if ($null -ne $thumbprintsProperty) {
        $thumbprints += @($thumbprintsProperty.Value)
    }
    if ($null -ne $legacyThumbprintProperty -and -not [string]::IsNullOrWhiteSpace([string]$legacyThumbprintProperty.Value)) {
        $thumbprints += [string]$legacyThumbprintProperty.Value
    }
    return @($thumbprints | Where-Object { $_ -match '^[A-Fa-f0-9]{40}$' } | Select-Object -Unique)
}

function Remove-OwnedMachineCertificateTrust {
    param(
        [string[]]$Thumbprints,
        [switch]$All,
        [switch]$SkipAllUserPackageCheck
    )

    if (-not $All -and @($Thumbprints).Count -eq 0) {
        return
    }
    foreach ($thumbprint in @($Thumbprints)) {
        if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
            throw "Invalid certificate thumbprint: $thumbprint"
        }
    }
    $requested = @($Thumbprints | ForEach-Object { "'$_'" }) -join ', '
    $removeAll = if ($All) { '$true' } else { '$false' }
    $skipCheck = if ($SkipAllUserPackageCheck) { '$true' } else { '$false' }
    $elevatedScript = @"
`$ErrorActionPreference = 'Stop'
`$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('$($script:BridgeMachineStateKey)', `$true)
if (`$null -eq `$key) { exit 3 }
try {
    `$ownedPublisher = [string]`$key.GetValue('Publisher', '')
    if (`$ownedPublisher -ne '$($script:BridgePublisher)') { exit 4 }
    `$owned = @(`$key.GetValue('OwnedCertificateThumbprints', @()))
    `$legacy = [string]`$key.GetValue('CertificateThumbprint', '')
    if (`$legacy) { `$owned += `$legacy }
    `$owned = @(`$owned | Where-Object { `$_ } | Select-Object -Unique)
    `$requested = @($requested)
    `$toRemove = if ($removeAll) { @(`$owned) } else { @(`$requested) }
    foreach (`$thumbprint in `$toRemove) {
        if (`$thumbprint -notin `$owned) { exit 6 }
    }
    if (-not $skipCheck) {
        `$remaining = @(Get-AppxPackage -AllUsers -Name '$($script:BridgePackageName)' -ErrorAction Stop)
        if (`$remaining.Count -gt 0) { exit 0 }
    }
    `$store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
    try {
        `$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        foreach (`$thumbprint in `$toRemove) {
            `$matches = @(`$store.Certificates | Where-Object {
                `$_.Thumbprint -eq `$thumbprint -and `$_.Subject -eq '$($script:BridgePublisher)'
            })
            foreach (`$certificate in `$matches) { `$store.Remove(`$certificate) }
        }
    } finally {
        `$store.Close()
    }
    `$remainingOwned = @(`$owned | Where-Object { `$_ -notin `$toRemove })
    if (`$remainingOwned.Count -gt 0) {
        `$key.SetValue('OwnedCertificateThumbprints', [string[]]`$remainingOwned, [Microsoft.Win32.RegistryValueKind]::MultiString)
        `$key.DeleteValue('CertificateThumbprint', `$false)
    }
} finally {
    `$key.Close()
}

if ($removeAll -or `$remainingOwned.Count -eq 0) {
    [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey('$($script:BridgeMachineStateKey)', `$false)
}
"@
    Invoke-ElevatedPowerShell -Script $elevatedScript
}

function Find-WindowsSdkTools {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitsRoot)) {
        return $null
    }

    $versions = Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } |
        Sort-Object { [Version]$_.Name } -Descending
    foreach ($version in $versions) {
        $toolDirectory = Join-Path $version.FullName $Architecture
        $makeAppx = Join-Path $toolDirectory 'makeappx.exe'
        $signTool = Join-Path $toolDirectory 'signtool.exe'
        if ((Test-Path -LiteralPath $makeAppx) -and (Test-Path -LiteralPath $signTool)) {
            return [pscustomobject]@{
                Directory = $toolDirectory
                MakeAppx = $makeAppx
                SignTool = $signTool
                Downloaded = $false
            }
        }
    }
    return $null
}

function Get-WindowsSdkTools {
    param(
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )

    $installed = Find-WindowsSdkTools -Architecture $Architecture
    if ($null -ne $installed) {
        return $installed
    }

    Write-BridgeStep 'Downloading Microsoft Windows SDK Build Tools'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $packagePath = Join-Path $WorkRoot 'Microsoft.Windows.SDK.BuildTools.nupkg'
    Invoke-WebRequest -Uri $script:SdkBuildToolsUrl -OutFile $packagePath -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    if ($actualHash -ne $script:SdkBuildToolsSha256) {
        throw "Windows SDK Build Tools hash mismatch. Expected $($script:SdkBuildToolsSha256), got $actualHash."
    }

    $zipPath = Join-Path $WorkRoot 'Microsoft.Windows.SDK.BuildTools.zip'
    Copy-Item -LiteralPath $packagePath -Destination $zipPath -Force
    $sdkRoot = Join-Path $WorkRoot 'Sdk'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $sdkRoot -Force
    $toolDirectory = Join-Path $sdkRoot "bin\10.0.26100.0\$Architecture"
    $makeAppx = Join-Path $toolDirectory 'makeappx.exe'
    $signTool = Join-Path $toolDirectory 'signtool.exe'
    if (-not (Test-Path -LiteralPath $makeAppx) -or -not (Test-Path -LiteralPath $signTool)) {
        throw 'Microsoft Windows SDK Build Tools did not contain the expected packaging tools.'
    }

    return [pscustomobject]@{
        Directory = $toolDirectory
        MakeAppx = $makeAppx
        SignTool = $signTool
        Downloaded = $true
    }
}

function New-BridgeLogo {
    param(
        [Parameter(Mandatory = $true)][int]$Size,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap($Size, $Size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::FromArgb(17, 24, 39))
        $barWidth = [Math]::Max(3, [int]($Size * 0.12))
        $margin = [int]($Size * 0.20)
        $cyan = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(34, 211, 238))
        $orange = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(251, 146, 60))
        try {
            $graphics.FillRectangle($cyan, $margin, $margin, $barWidth, ($Size - (2 * $margin)))
            $graphics.FillRectangle($orange, ($Size - $margin - $barWidth), $margin, $barWidth, ($Size - (2 * $margin)))
            $bridgeY = [int]($Size * 0.43)
            $graphics.FillRectangle($cyan, $margin, $bridgeY, ($Size - (2 * $margin)), $barWidth)
        } finally {
            $cyan.Dispose()
            $orange.Dispose()
        }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw 'The .NET Framework C# compiler was not found.'
}

function ConvertTo-XmlText {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Security.SecurityElement]::Escape($Value)
}

function New-BridgePackage {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][Version]$Version,
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)]$SdkTools
    )

    $staging = Join-Path $WorkRoot 'Package'
    $assets = Join-Path $staging 'Assets'
    $public = Join-Path $staging 'Public'
    New-Item -ItemType Directory -Path $staging, $assets, $public -Force | Out-Null

    $compiler = Get-CSharpCompiler
    $launcherSource = Join-Path $RepositoryRoot 'src\Launcher.cs'
    $launcherOutput = Join-Path $staging 'CopilotKeyBridge.exe'
    $compilerOutput = & $compiler @(
        '/nologo',
        '/target:winexe',
        '/platform:anycpu',
        '/optimize+',
        '/warn:4',
        '/warnaserror+',
        "/out:$launcherOutput",
        $launcherSource
    ) 2>&1
    $compilerExitCode = $LASTEXITCODE
    $compilerOutput | ForEach-Object { Write-Verbose $_ }
    if ($compilerExitCode -ne 0) {
        $compilerOutput | Out-Host
        throw "C# compiler failed with exit code $compilerExitCode."
    }

    $targetBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Target))
    [IO.File]::WriteAllText((Join-Path $staging 'target.b64'), $targetBase64, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $public 'provider.txt'), 'CopilotKeyBridge provider', [Text.Encoding]::ASCII)

    New-BridgeLogo -Size 44 -Path (Join-Path $assets 'Square44x44Logo.png')
    New-BridgeLogo -Size 150 -Path (Join-Path $assets 'Square150x150Logo.png')
    New-BridgeLogo -Size 50 -Path (Join-Path $assets 'StoreLogo.png')

    $manifestTemplate = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'src\AppxManifest.xml'))
    $providerName = "CopilotKeyBridge: $DisplayName"
    $providerDescription = "Launch or activate $DisplayName"
    $manifest = $manifestTemplate.
        Replace('{{VERSION}}', $Version.ToString()).
        Replace('{{ARCHITECTURE}}', $Architecture).
        Replace('{{PROVIDER_NAME}}', (ConvertTo-XmlText $providerName)).
        Replace('{{PROVIDER_DESCRIPTION}}', (ConvertTo-XmlText $providerDescription))
    [IO.File]::WriteAllText((Join-Path $staging 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding($false)))

    $packagePath = Join-Path $WorkRoot 'CopilotKeyBridge.msix'
    $makeAppxOutput = & $SdkTools.MakeAppx @('pack', '/o', '/d', $staging, '/p', $packagePath) 2>&1
    $makeAppxExitCode = $LASTEXITCODE
    $makeAppxOutput | ForEach-Object { Write-Verbose $_ }
    if ($makeAppxExitCode -ne 0) {
        $makeAppxOutput | Out-Host
        throw "MakeAppx failed with exit code $makeAppxExitCode."
    }

    $signToolOutput = & $SdkTools.SignTool @(
        'sign',
        '/fd', 'SHA256',
        '/sha1', $Certificate.Thumbprint,
        '/s', 'My',
        $packagePath
    ) 2>&1
    $signToolExitCode = $LASTEXITCODE
    $signToolOutput | ForEach-Object { Write-Verbose $_ }
    if ($signToolExitCode -ne 0) {
        $signToolOutput | Out-Host
        throw "SignTool failed with exit code $signToolExitCode."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint) {
        throw 'The generated package was not signed by the expected local certificate.'
    }
    return $packagePath
}

function Get-CopilotKeySelection {
    $path = 'HKCU:\Software\Microsoft\Windows\Shell\BrandedKey'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ ChoiceType = $null; AppAumid = $null }
    }
    $value = Get-ItemProperty -LiteralPath $path
    $choiceProperty = $value.PSObject.Properties['BrandedKeyChoiceType']
    $aumidProperty = $value.PSObject.Properties['AppAumid']
    return [pscustomobject]@{
        ChoiceType = if ($null -eq $choiceProperty) { $null } else { [string]$choiceProperty.Value }
        AppAumid = if ($null -eq $aumidProperty) { $null } else { [string]$aumidProperty.Value }
    }
}

function Open-CopilotKeySettings {
    Start-Process $script:BridgeSettingsUri
}

function Get-CopilotPolicySummary {
    $path = 'HKCU:\Software\Policies\Microsoft\Windows\CopilotKey'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return Get-ItemProperty -LiteralPath $path
}
