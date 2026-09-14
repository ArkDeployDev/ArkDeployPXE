#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds a UEFI-only BCD store for PXE-booting a custom WinPE image over TFTP,
    with no WDS involved.

.DESCRIPTION
    Generates Boot\BCD inside your TFTP root, wired to boot a WinPE boot.wim as a
    ramdisk. All paths in the resulting BCD are relative to the TFTP root and use
    the "boot" device alias, meaning Boot Manager fetches boot.sdi/boot.wim from
    whichever TFTP server it was itself PXE-booted from - no server IP is baked
    into the BCD.

    Run this AFTER bootmgr.efi, boot.sdi, and boot.wim are already staged in
    your TFTP root; this script only builds the BCD file that ties them together.

.PARAMETER TftpRoot
    Root folder your TFTP server serves (e.g. D:\PXERoot). The BCD is written to
    <TftpRoot>\Boot\BCD.

.PARAMETER BootWimRelativePath
    Path to boot.wim, relative to the TFTP root, using backslashes, starting with \.
    Must match wherever you actually staged the file.

.PARAMETER BootSdiRelativePath
    Path to boot.sdi, relative to the TFTP root. Copy this from your ADK WinPE
    media folder (created by copype) - it's not something you build yourself.

.PARAMETER TimeoutSeconds
    Boot Manager menu timeout. 0 = boot immediately with no menu, which is normal
    for unattended/automated deployment scenarios.

.PARAMETER Description
    Display name written into both the {bootmgr} entry and the OS loader entry
    (what you'd see on a boot menu, and what shows up in `bcdedit /enum`).

.PARAMETER Force
    Overwrite an existing BCD file at the target path instead of failing.

.EXAMPLE
    .\New-PxeBcd.ps1 -TftpRoot D:\PXERoot -BootWimRelativePath '\sources\boot.wim' -BootSdiRelativePath '\boot\boot.sdi' -Description 'ARK Deploy' -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TftpRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^\\')]
    [string]$BootWimRelativePath,

    [Parameter(Mandatory)]
    [ValidatePattern('^\\')]
    [string]$BootSdiRelativePath,

    [int]$TimeoutSeconds = 0,

    [string]$Description = 'ARK Deploy',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Invoke-BcdEdit {
    param([string[]]$Arguments)
    Write-Verbose "bcdedit $($Arguments -join ' ')"
    $output = & bcdedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit failed (exit $LASTEXITCODE): bcdedit $($Arguments -join ' ')`n$output"
    }
    return $output
}

function Get-BcdGuidFromOutput {
    param([string[]]$Output)
    $match = ($Output -join "`n") | Select-String -Pattern '(\{[0-9a-fA-F\-]{30,40}\})' | Select-Object -First 1
    if (-not $match) { throw "Could not parse a GUID out of bcdedit output:`n$($Output -join "`n")" }
    return $match.Matches[0].Groups[1].Value
}

# --- Validate inputs -------------------------------------------------------

if (-not (Test-Path $TftpRoot)) {
    throw "TFTP root '$TftpRoot' does not exist."
}


#$bootWimFull = Join-Path $TftpRoot $BootWimRelativePath.TrimStart('\')
#$bootSdiFull = Join-Path $TftpRoot $BootSdiRelativePath.TrimStart('\')

#if (-not (Test-Path $bootWimFull)) {
#    throw "boot.wim not found at '$bootWimFull'. Stage it there first, or fix -BootWimRelativePath."
#}
#if (-not (Test-Path $bootSdiFull)) {
#    throw "boot.sdi not found at '$bootSdiFull'. Copy it from your ADK WinPE media folder (copype output), or fix -BootSdiRelativePath."
#}

$bcdDir = Join-Path $TftpRoot 'Boot'
$bcdPath = Join-Path $bcdDir 'BCD'

if (-not (Test-Path $bcdDir)) {
    New-Item -ItemType Directory -Path $bcdDir | Out-Null
}

if (Test-Path $bcdPath) {
    if (-not $Force) {
        throw "BCD store already exists at '$bcdPath'. Re-run with -Force to overwrite it."
    }
    Remove-Item $bcdPath -Force
}

# --- Build the store ---------------------------------------------------------

Write-Host "Creating BCD store at '$bcdPath'..." -ForegroundColor Cyan
Invoke-BcdEdit -Arguments @('/createstore', $bcdPath) | Out-Null

Write-Host 'Configuring ramdisk options ({ramdiskoptions})...' -ForegroundColor Cyan
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/create', '{ramdiskoptions}', '/d', 'Ramdisk Options') | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', '{ramdiskoptions}', 'ramdisksdidevice', 'boot') | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', '{ramdiskoptions}', 'ramdisksdipath', $BootSdiRelativePath) | Out-Null

Write-Host 'Creating the WinPE OS loader entry...' -ForegroundColor Cyan
$createOutput = Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/create', '/d', $Description, '/application', 'osloader')
$osLoaderGuid = Get-BcdGuidFromOutput -Output $createOutput
Write-Host "  Loader GUID: $osLoaderGuid" -ForegroundColor DarkGray

$ramdiskArg = "ramdisk=[boot]$BootWimRelativePath,{ramdiskoptions}"
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'device', $ramdiskArg) | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'osdevice', $ramdiskArg) | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'path', '\windows\system32\winload.efi') | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'systemroot', '\windows') | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'winpe', 'yes') | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', $osLoaderGuid, 'detecthal', 'yes') | Out-Null

Write-Host 'Configuring {bootmgr}...' -ForegroundColor Cyan
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/create', '{bootmgr}', '/d', $Description) | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', '{bootmgr}', 'timeout', $TimeoutSeconds) | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', '{bootmgr}', 'displayorder', $osLoaderGuid) | Out-Null
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/set', '{bootmgr}', 'default', $osLoaderGuid) | Out-Null

Write-Host "`nBCD store built successfully at '$bcdPath'." -ForegroundColor Green
Write-Host "Loader GUID $osLoaderGuid boots '$BootWimRelativePath' via ramdisk, sdi at '$BootSdiRelativePath'." -ForegroundColor Green

Write-Host "`n--- Full store contents (bcdedit /enum all) ---" -ForegroundColor Cyan
Invoke-BcdEdit -Arguments @('/store', $bcdPath, '/enum', 'all') | Write-Host
