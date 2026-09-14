#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stages a complete PXERoot folder: downloads ipxe.efi + wimboot, copies boot.sdi
    from the installed Windows ADK, and builds the BCD store.

.DESCRIPTION
    Produces this layout under -PxeRoot:
        ipxe.efi
        autoexec.ipxe
        wimboot
        Boot\BCD
        Boot\boot.sdi
        Sources\boot.wim (not produced by this script - drop your own in here)

    boot.sdi is copied directly from the ADK's WinPE add-on install path:
      ...\Assessment and Deployment Kit\Windows Preinstallation Environment\<arch>\Media\Boot\boot.sdi
    boot.wim is NOT produced by this script - drop your own custom-built boot.wim into
    <PxeRoot>\sources\boot.wim yourself before booting. The BCD-generation step (5) will
    skip itself with a clear message if it doesn't find one yet.

    Requires the Windows ADK and the WinPE add-on already installed (this script does
    NOT install them - see https://learn.microsoft.com/windows-hardware/get-started/adk-install
    if boot.sdi can't be found).

.PARAMETER PxeRoot
    Destination folder for the TFTP root. Created if it doesn't exist.

.PARAMETER Architecture
    WinPE architecture used to locate boot.sdi in the ADK: amd64, x86, or arm64.

.PARAMETER Description
    Passed through to New-PxeBcd.ps1 as the boot menu / loader description.

.PARAMETER IpxeEfiUrl
    Override if you want a specific/custom iPXE build instead of the stock one.

.PARAMETER WimbootUrl
    Override if you want a specific wimboot release instead of latest.

.PARAMETER Force
    Re-download/re-copy/re-generate each file even if it already exists (ipxe.efi,
    wimboot, boot.sdi, the BCD), updating them in place. Never deletes the folder or
    touches anything not managed by this script - existing files (like your own
    sources\boot.wim, or anything else you've added) are always left alone.

.EXAMPLE
    .\New-PxeRoot.ps1 -PxeRoot D:\PXERoot
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PxeRoot,
    
    [ValidateSet('amd64', 'x86', 'arm64')]
    [string]$Architecture = 'amd64',

    [string]$Description = 'ARK Deploy',
    [string]$IpxeEfiUrl,
    [string]$WimbootUrl = 'https://github.com/ipxe/wimboot/releases/latest/download/wimboot',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $IpxeEfiUrl) {
    # boot.ipxe.org organizes prebuilt binaries by architecture folder; map our
    # architecture names onto iPXE's folder naming.
    $ipxeArchFolder = switch ($Architecture) {
        'amd64' { 'x86_64-efi' }
        'x86'   { 'i386-efi' }
        'arm64' { 'arm64-efi' }
    }
    $IpxeEfiUrl = "https://boot.ipxe.org/$ipxeArchFolder/ipxe.efi"
    Write-Host "Using iPXE EFI URL: $IpxeEfiUrl" -ForegroundColor DarkGray
}

function Write-Section {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

# --- 1. Create folder structure ------------------------------------------------

Write-Section 'Creating folder structure'

$bootDir = Join-Path $PxeRoot 'Boot'
$sourcesDir = Join-Path $PxeRoot 'sources'
foreach ($dir in @($PxeRoot, $bootDir, $sourcesDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
        Write-Host "Created $dir"
    }
}

# --- 2. Download ipxe.efi and wimboot -------------------------------------------

Write-Section 'Downloading ipxe.efi and wimboot'

$ipxeEfiPath = Join-Path $PxeRoot 'ipxe.efi'
$wimbootPath = Join-Path $PxeRoot 'wimboot'

if ((Test-Path $ipxeEfiPath) -and -not $Force) {
    Write-Host "ipxe.efi already present, skipping (use -Force to re-download)." -ForegroundColor DarkGray
} else {
    Write-Host "Downloading $IpxeEfiUrl ..."
    Invoke-WebRequest -Uri $IpxeEfiUrl -OutFile $ipxeEfiPath -UseBasicParsing
    Write-Host "  -> $ipxeEfiPath ($((Get-Item $ipxeEfiPath).Length) bytes)" -ForegroundColor Green
}

if ((Test-Path $wimbootPath) -and -not $Force) {
    Write-Host "wimboot already present, skipping (use -Force to re-download)." -ForegroundColor DarkGray
} else {
    Write-Host "Downloading $WimbootUrl ..."
    Invoke-WebRequest -Uri $WimbootUrl -OutFile $wimbootPath -UseBasicParsing
    Write-Host "  -> $wimbootPath ($((Get-Item $wimbootPath).Length) bytes)" -ForegroundColor Green
}

# --- 3. Write the iPXE autoexec script ------------------------------------------

Write-Section 'Writing autoexec.ipxe'

$autoexecPath = Join-Path $PxeRoot 'autoexec.ipxe'
$autoexecContent = @"
#!ipxe
kernel wimboot
initrd Boot/BCD BCD
initrd Boot/boot.sdi boot.sdi
initrd sources/boot.wim boot.wim
boot
"@
Set-Content -Path $autoexecPath -Value $autoexecContent -NoNewline
Write-Host "  -> $autoexecPath" -ForegroundColor Green

# --- 4. Copy boot.sdi from the installed ADK -------------------------------------

Write-Section 'Locating boot.sdi in the installed ADK'

$adkWinPeMedia = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\$Architecture\Media"
$sourceBootSdi = Join-Path $adkWinPeMedia 'Boot\boot.sdi'

if (-not (Test-Path $sourceBootSdi)) {
    throw @"
Could not find boot.sdi at '$sourceBootSdi'.
Install the Windows ADK and the WinPE add-on for $Architecture first:
  https://learn.microsoft.com/windows-hardware/get-started/adk-install
Then re-run this script.
"@
}

Write-Host "Found boot.sdi at: $sourceBootSdi" -ForegroundColor DarkGray

$bootSdiTarget = Join-Path $bootDir 'boot.sdi'
if ((Test-Path $bootSdiTarget) -and -not $Force) {
    Write-Host "boot.sdi already present in Boot\, skipping (use -Force to re-copy)." -ForegroundColor Yellow
} else {
    Copy-Item $sourceBootSdi $bootSdiTarget -Force
    Write-Host "  -> $bootSdiTarget" -ForegroundColor Green
}

# --- 5. Build the BCD store ------------------------------------------------------

Write-Section 'Building BCD store'

$bootWimTarget = Join-Path $sourcesDir 'boot.wim'
$bcdScript = Join-Path $PSScriptRoot 'New-PxeBcd.ps1'
if (-not (Test-Path $bcdScript)) {
    Write-Host "New-PxeBcd.ps1 not found next to this script ($PSScriptRoot) - skipping BCD generation." -ForegroundColor Yellow
    Write-Host "Run it manually once you have it: .\New-PxeBcd.ps1 -TftpRoot '$PxeRoot' -BootWimRelativePath '\sources\boot.wim' -BootSdiRelativePath '\boot\boot.sdi' -Description '$Description' -Force" -ForegroundColor Yellow
} else {
    & $bcdScript -TftpRoot $PxeRoot -BootWimRelativePath '\sources\boot.wim' -BootSdiRelativePath '\boot\boot.sdi' -Description $Description -Force
}


# --- 6. Summary -------------------------------------------------------------------

Write-Section 'Done'
Write-Host "PXERoot is ready at '$PxeRoot':" -ForegroundColor Green
Get-ChildItem $PxeRoot -Recurse | Select-Object @{N='Path';E={$_.FullName.Substring($PxeRoot.Length)}}, Length | Format-Table -AutoSize

Write-Host @"
Next steps:
  1. Copy your own custom-built boot.wim into '$bootWimTarget' (if you haven't
     already), then re-run this script to generate the BCD - it won't touch
     anything else that's already in place.
  2. Point DHCP (option 66/67, or your controller's TFTP Server/Boot Filename
     fields) at this server's IP and 'ipxe.efi'.
  3. Start your TFTP server with -RootPath '$PxeRoot'.
"@ -ForegroundColor Cyan
