$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Common.ps1')

$workRoot = Join-Path $env:TEMP ("CopilotKeyBridge-ci-{0}" -f [Guid]::NewGuid().ToString('N'))
$certificate = $null
try {
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $certificatePath = Join-Path $workRoot 'CopilotKeyBridge.cer'
    $certificate = New-EphemeralSigningCertificate -CertificatePath $certificatePath
    $tools = Get-WindowsSdkTools -Architecture 'x64' -WorkRoot $workRoot
    $packagePath = New-BridgePackage `
        -RepositoryRoot $root `
        -WorkRoot $workRoot `
        -Target (Join-Path $env:SystemRoot 'System32\notepad.exe') `
        -DisplayName 'CI package smoke test' `
        -Architecture 'x64' `
        -Version ([Version]'1.0.0.0') `
        -Certificate $certificate `
        -SdkTools $tools

    $signature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
        throw 'Smoke package was not signed by the expected certificate.'
    }

    $unpackRoot = Join-Path $workRoot 'Unpacked'
    $output = & $tools.MakeAppx @('unpack', '/o', '/p', $packagePath, '/d', $unpackRoot) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | Out-Host
        throw 'MakeAppx could not unpack the smoke package.'
    }
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $unpackRoot 'AppxManifest.xml')
    if ($manifest.Package.Identity.Name -ne 'CopilotKeyBridge') {
        throw 'Smoke package identity was incorrect.'
    }
    Write-Host 'MSIX package smoke build passed.' -ForegroundColor Green
}
finally {
    if ($null -ne $certificate) {
        Remove-PrivateSigningCertificate -Thumbprint $certificate.Thumbprint
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
