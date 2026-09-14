#Requires -Version 7.0
<#
.SYNOPSIS
    Loads the PxeTftp.dll async TFTP server and runs it for PXE boot file serving.

.DESCRIPTION
    Thin PowerShell control layer around the compiled .NET 6 TftpServer class.
    PowerShell 7+ is required because PxeTftp.dll targets net6.0 (Windows
    PowerShell 5.1 runs on .NET Framework and cannot load it).

.PARAMETER DllPath
    Path to the built PxeTftp.dll (see README for the `dotnet build` command).

.PARAMETER RootPath
    Directory containing your PXE boot files (bootmgr.efi, boot\bcd, boot.wim, etc.).

.PARAMETER Port
    UDP port to listen on. 69 is the standard TFTP port and requires an elevated/
    admin PowerShell session on Windows.

.EXAMPLE
    .\Start-TftpServer.ps1 -DllPath .\PxeTftp\bin\Release\net6.0\PxeTftp.dll -RootPath D:\PXERoot
#>
[CmdletBinding()]
param(

    [Parameter(Mandatory)]
    [string]$RootPath,

    [string]$DllPath,
    [int]$Port = 69,
    [int]$MaxBlockSize = 1428,
    [int]$MaxWindowSize = 4,
    [int]$TimeoutSeconds = 3,
    [int]$MaxRetries = 5,

    # Forces plain RFC 1350 behavior (512-byte blocks, no windowing, no OACK ever sent),
    # even if a client requests options. Try this if a file transfers fine standalone but
    # a chained boot loader that requests it internally fails to find/load it.
    [switch]$DisableOptions,

    # Optional log file; console logging always happens via Write-Host/Write-Warning.
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DllPath)) {
    throw "PxeTftp.dll not found at '$DllPath'. Build it first: dotnet build .\PxeTftp\PxeTftp.csproj -c Release"
}
if (-not (Test-Path $RootPath)) {
    throw "TFTP root path '$RootPath' does not exist."
}

# --- Pre-start file validation ----------------------------------------------------
# Refuse to start on an incomplete PXERoot - a client silently failing partway through
# a boot chain (as we found out the hard way) is a much worse debugging experience
# than catching a missing file here, before anything even tries to PXE boot.

function Test-PxeRootReady {
    param([string]$RootPath)

    $infraFiles = @('ipxe.efi', 'wimboot', 'autoexec.ipxe', 'Boot\BCD', 'Boot\boot.sdi')
    $bootWimRelative = 'sources\boot.wim'

    $missingInfra = $infraFiles | Where-Object { -not (Test-Path (Join-Path $RootPath $_)) }
    $missingBootWim = -not (Test-Path (Join-Path $RootPath $bootWimRelative))

    if ($missingInfra.Count -eq 0 -and -not $missingBootWim) {
        return $true
    }

    Write-Host "TFTP root '$RootPath' is missing required files - refusing to start.`n" -ForegroundColor Red

    if ($missingInfra.Count -gt 0) {
        Write-Host "Missing infrastructure files:" -ForegroundColor Yellow
        $missingInfra | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "`nRun New-PxeRoot.ps1 to fetch/generate these:" -ForegroundColor Yellow
        Write-Host "  .\New-PxeRoot.ps1 -PxeRoot '$RootPath'`n" -ForegroundColor Yellow
    }

    if ($missingBootWim) {
        Write-Host "Missing boot.wim:" -ForegroundColor Yellow
        Write-Host "  $(Join-Path $RootPath $bootWimRelative)" -ForegroundColor Yellow
        Write-Host "`nCopy the ArkDeploy Toolkit boot.wim into that location, then re-run.`n" -ForegroundColor Yellow
    }

    return $false
}

if (-not (Test-PxeRootReady -RootPath $RootPath)) {
    throw "TFTP root is incomplete - see messages above."
}
Write-Host "All required PXE files present in '$RootPath'.`n" -ForegroundColor Green

Add-Type -Path (Resolve-Path $DllPath)

# Defensive cleanup: if a previous run in this session was interrupted before its
# `finally` block finished (e.g. a hard Ctrl+C), stale subscriptions can be left
# behind and cause "subscriber already exists" on the next run. Clear them first.
Get-EventSubscriber -SourceIdentifier 'PxeTftp.*' -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue

function Global:Write-TftpLog {
    param($EventArgs)
    $line = "[{0:HH:mm:ss.fff}] [{1}] {2}" -f $EventArgs.TimestampUtc.ToLocalTime(), $EventArgs.Level, $EventArgs.Message
    switch ($EventArgs.Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warning' { Write-Host $line -ForegroundColor Yellow }
        default   { Write-Host $line -ForegroundColor Gray }
    }
    if ($LogFile) { Add-Content -Path $LogFile -Value $line }
}

$tftp = [PxeTftp.TftpServer]::new($RootPath, $MaxBlockSize, $MaxWindowSize, $TimeoutSeconds, $MaxRetries, [bool]$DisableOptions)

Register-ObjectEvent -InputObject $tftp -EventName LogMessage -Action {
    Write-TftpLog -EventArgs $Event.SourceEventArgs
} -SourceIdentifier 'PxeTftp.Log' | Out-Null

Register-ObjectEvent -InputObject $tftp -EventName TransferComplete -Action {
    $a = $Event.SourceEventArgs
    Write-Host ("Completed: {0} -> {1} ({2} bytes)" -f $a.FileName, $a.Client, $a.BytesSent) -ForegroundColor Green
} -SourceIdentifier 'PxeTftp.Complete' | Out-Null

Register-ObjectEvent -InputObject $tftp -EventName TransferFailed -Action {
    $a = $Event.SourceEventArgs
    Write-Host ("FAILED: {0} -> {1}: {2}" -f $a.FileName, $a.Client, $a.ErrorMessage) -ForegroundColor Red
} -SourceIdentifier 'PxeTftp.Failed' | Out-Null

try {
	Clear
	Write-Host "======================================" -ForegroundColor Cyan
	Write-Host " ArkDeploy PXE - Press Ctrl+C to stop."
	Write-Host " arkdeploy.com "
	Write-Host "======================================" -ForegroundColor Cyan
    

    # Best-effort detection of the server's own LAN IP, so the DHCP reminder below
    # is copy-paste ready instead of a placeholder. Picks the address on whichever
    # interface currently has a default gateway (i.e. the "real" active NIC), and
    # falls back to a generic message if that can't be determined.
    $serverIp = (Get-NetIPConfiguration | Where-Object {
        $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up'
    } | Select-Object -First 1).IPv4Address.IPAddress

    Write-Host "`n--- DHCP configuration reminder ---" -ForegroundColor Yellow
    if ($serverIp) {
        Write-Host "  Set DHCP Option 66 (TFTP/Next Server) = $serverIp" -ForegroundColor Yellow
        Write-Host "  Set DHCP Option 67 (Boot Filename)    = ipxe.efi" -ForegroundColor Yellow
    } else {
        Write-Host "  Could not auto-detect this machine's IP - check 'ipconfig' for it." -ForegroundColor Yellow
        Write-Host "  Set DHCP Option 66 (TFTP/Next Server) = <this machine's IP>" -ForegroundColor Yellow
        Write-Host "  Set DHCP Option 67 (Boot Filename)    = ipxe.efi" -ForegroundColor Yellow
    }
    Write-Host "-----------------------------------`n" -ForegroundColor Yellow

    $tftp.Start($Port)
    
    # Register-ObjectEvent (not a raw add_CancelKeyPress delegate) is required here:
    # its action block runs through PowerShell's own eventing/runspace machinery,
    # whereas a manually attached CancelKeyPress delegate fires on .NET's signal
    # thread with no runspace available and crashes the process on anything nontrivial.
    $Global:PxeTftpStopRequested = $false
    Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -SourceIdentifier 'PxeTftp.CancelKey' -Action {
            $Event.SourceEventArgs.Cancel = $true   # stop .NET from killing the process outright
            $Global:PxeTftpStopRequested = $true
        } | Out-Null

    while (-not $Global:PxeTftpStopRequested) {
        Wait-Event -Timeout 1 | Out-Null
    }
}
finally {
    Write-Host "Stopping TFTP server..." -ForegroundColor Cyan
    $tftp.StopAsync().GetAwaiter().GetResult()
    Get-EventSubscriber -SourceIdentifier 'PxeTftp.*' -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
    $tftp.Dispose()
}
