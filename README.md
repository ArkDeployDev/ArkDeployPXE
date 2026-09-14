# ArkDeploy PXE

**Lightweight network boot for ArkDeploy Toolkit.**

ArkDeploy PXE is a lightweight PXE and TFTP server designed to work with
[ArkDeploy Toolkit](https://github.com/ArkDeployDev/ArkDeployToolkit), allowing Toolkit-generated
Windows PE environments to boot directly over the network instead of
USB.

It provides the network bootstrap layer while keeping the deployment
workflow simple:

``` text
PXE → iPXE → Windows PE → ArkDeploy Toolkit
```

ArkDeploy PXE is intentionally focused. It is not intended to replace a
full deployment or endpoint-management platform. Its job is to provide
the network boot functionality required to launch an ArkDeploy WinPE
environment, after which ArkDeploy Toolkit handles the deployment
workflow.

## Why ArkDeploy PXE?

ArkDeploy Toolkit provides the tools to build bootable Windows PE media
and deploy or capture Windows images.

ArkDeploy PXE adds another way to boot that environment.

Instead of:

``` text
USB → WinPE → ArkDeploy Toolkit
```

you can use:

``` text
Network PXE → WinPE → ArkDeploy Toolkit
```

The PXE root can be located wherever suits your environment and
populated using the included `New-PxeRoot.ps1` script.

## Quick Start

Create the PXE root:

``` powershell
.\New-PxeRoot.ps1 -PxeRoot .\PXERoot
```

Copy the `boot.wim` created with ArkDeploy Toolkit to:

``` text
.\PXERoot\sources\boot.wim
```

ArkDeploy Toolkit **v1.1.1 or later** is recommended for PXE booting.
Version 1.1.1 introduced an embedded configuration fallback, allowing
ArkDeploy WinPE to operate without configuration files stored on USB
media.

Start ArkDeploy PXE:

``` powershell
.\Start-TftpServer.ps1 -RootPath .\PXERoot
```

See [FIRSTRUN.md](FIRSTRUN.md) for the complete first-run setup,
including DHCP configuration.

## PXE Root Layout

After running `New-PxeRoot.ps1`, the PXE root should contain:

``` text
PXERoot\
├── ipxe.efi
├── wimboot
├── boot.ipxe
├── Boot\
│   ├── BCD
│   └── boot.sdi
└── sources\
    └── boot.wim
```

The PXE root does not need to remain inside the ArkDeploy PXE directory.
It can be moved elsewhere and supplied using `-RootPath` when starting
the server.

## Technical Overview

ArkDeploy PXE includes a read-only RFC 1350 TFTP server written in C#
(.NET 6) and driven from PowerShell.

The implementation is deliberately small and focused on serving the
files required to bootstrap Windows PE. DHCP remains the responsibility
of your existing network infrastructure.

The TFTP implementation uses only the .NET Base Class Library and has no
external NuGet package dependencies.

## What's Implemented

-   RRQ (read) only. WRQ is refused with an access-violation error.
-   TFTP option negotiation using OACK.
-   `blksize` support (RFC 2348).
-   `timeout` support (RFC 2349).
-   `tsize` support (RFC 2349).
-   `windowsize` support (RFC 7440, go-back-N).
-   Fully asynchronous I/O using `UdpClient` and `async`/`await`.
-   One ephemeral-port socket per transfer, allowing multiple PXE
    clients to boot concurrently.
-   Block-number wraparound handling for files larger than 32 MB at
    512-byte blocks, or correspondingly larger files with a negotiated
    block size.
-   Path-traversal protection. Requested filenames are resolved against
    the configured TFTP root and requests attempting to escape the root
    are rejected.

TFTP uses a 16-bit block counter. ArkDeploy PXE treats the counter as
wrapping modulo 65536 rather than as a hard transfer limit, which is
required for multi-hundred-megabyte Windows PE images when appropriate
block sizes are used.

## What's Deliberately Not Implemented

ArkDeploy PXE is intentionally narrow in scope.

-   **DHCP / proxy-DHCP** --- handled elsewhere on the network.
-   **WRQ / uploads** --- ArkDeploy PXE is read-only.
-   **Authentication** --- TFTP does not provide authentication in the
    protocol.
-   **netascii translation** --- the mode is accepted but treated as
    octet, which is appropriate for the binary files used during PXE
    boot.

Because TFTP has no authentication, ArkDeploy PXE should be used on an
appropriate trusted or provisioning network.

## Requirements

Running the server requires:

-   Windows
-   PowerShell 7+
-   .NET 6 runtime
-   An elevated PowerShell session to bind UDP port 69
-   An existing DHCP service configured to direct PXE clients to
    ArkDeploy PXE
-   A Windows PE `boot.wim`, preferably created with ArkDeploy Toolkit
    v1.1.1 or later

Windows PowerShell 5.1 uses .NET Framework and cannot load the .NET 6
assembly.

## Running ArkDeploy PXE

For normal use:

``` powershell
.\Start-TftpServer.ps1 -RootPath .\PXERoot
```

The root can be located elsewhere:

``` powershell
.\Start-TftpServer.ps1 -RootPath "D:\ArkDeploy\PXERoot"
```

ArkDeploy PXE listens for TFTP requests and serves files from the
specified root.

Press `Ctrl+C` to stop the server.

## DHCP

ArkDeploy PXE does not provide DHCP.

Your existing DHCP infrastructure must direct PXE clients to the
ArkDeploy PXE server. For the standard ArkDeploy PXE configuration, the
boot filename is:

``` text
ipxe.efi
```

See [FIRSTRUN.md](FIRSTRUN.md) for the first-run DHCP configuration and
setup process.

## Boot Process

The standard ArkDeploy PXE boot process is:

``` text
UEFI PXE
   ↓
ipxe.efi
   ↓
boot.ipxe
   ↓
wimboot
   ↓
BCD + boot.sdi + boot.wim
   ↓
Windows PE
   ↓
ArkDeploy Toolkit
```

ArkDeploy PXE provides the bootstrap path into Windows PE. Once WinPE
has started, ArkDeploy Toolkit can use its normal deployment methods to
access and deploy Windows images.

## Building from Source

The TFTP server can be built from the included C# project:

``` powershell
dotnet build .\PxeTftp\PxeTftp.csproj -c Release
```

Output:

``` text
.\PxeTftp\bin\Release\net6.0\PxeTftp.dll
```

To run the server while explicitly specifying the built DLL:

``` powershell
.\Start-TftpServer.ps1 `
    -DllPath .\PxeTftp\bin\Release\net6.0\PxeTftp.dll `
    -RootPath D:\PXERoot `
    -Port 69
```

The C# implementation is BCL-only and does not require external NuGet
packages.

## Testing

Before deploying ArkDeploy PXE more widely, test the complete boot path
in your environment.

1.  Point a TFTP client at the server and confirm that a small boot file
    can be retrieved.
2.  Test a large transfer using your actual `boot.wim` to exercise
    block-number wraparound and windowing.
3.  Test against a VM with PXE boot enabled before moving to physical
    hardware.
4.  Watch the console log, or `-LogFile` if used, for `FAILED` transfer
    events to identify client, file or timeout issues.

Hyper-V and VMware can both be useful for validating PXE behaviour
before testing against physical UEFI firmware.

## Running as a Background Service

PowerShell scripts do not survive logoff or reboot by themselves.

Two common approaches are:

-   **NSSM (Non-Sucking Service Manager)** --- wrap
    `pwsh.exe -File Start-TftpServer.ps1 ...` as a Windows service.
-   **Scheduled Task** --- trigger the server at startup and run it
    under an appropriate account such as SYSTEM.

Keep `-RootPath` pointed at the location where your PXE files and
`boot.wim` are maintained. Files are opened fresh per request, so
replacing a WinPE image does not require rebuilding the TFTP service
itself.

## Tuning

### MaxBlockSize

The default `MaxBlockSize` is `1428`.

Keep the block size at or below the network MTU minus the TFTP, UDP and
IP headers to avoid fragmentation. A value of 1428 is suitable for
standard 1500-byte Ethernet.

### MaxWindowSize

The default `MaxWindowSize` is `4`.

Higher values can reduce round trips significantly when transferring
large WIM files, but the benefit depends on the PXE/iPXE client
supporting RFC 7440.

Negotiation is performed per client, allowing clients that do not
support windowing to fall back appropriately.

If a PXE implementation behaves unexpectedly with negotiated options,
reducing the block/window configuration can be useful when testing
classic RFC 1350 behaviour.

## Security

ArkDeploy PXE deliberately provides a small attack surface, but TFTP
itself has no authentication.

The server:

-   Provides read-only access.
-   Rejects write requests.
-   Restricts requests to the configured PXE root.
-   Rejects path traversal attempts.

It should still be operated only on a trusted deployment or provisioning
network where access to the PXE root is appropriate.

## ArkDeploy Toolkit

ArkDeploy PXE is designed specifically to complement ArkDeploy Toolkit.

ArkDeploy Toolkit provides the WinPE environment and Windows image
deployment/capture tooling. ArkDeploy PXE provides a lightweight network
boot path into that environment.

For ArkDeploy PXE booting, use **ArkDeploy Toolkit v1.1.1 or later**.

Learn more at [arkdeploy.com](https://arkdeploy.com/).

## Credits

ArkDeploy PXE uses components from the [iPXE
project](https://ipxe.org/):

-   `ipxe.efi` --- iPXE UEFI network bootloader
-   `wimboot` --- Windows Imaging Format bootloader for iPXE

Thanks to the iPXE project and its contributors for making these
components available.

## License

See the repository `LICENSE` file for ArkDeploy PXE licensing
information.

Third-party components such as iPXE and wimboot remain subject to their
respective licences.
