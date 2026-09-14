# ArkDeploy PXE – First Run

This guide will get ArkDeploy PXE up and running for the first time.

ArkDeploy PXE provides a lightweight TFTP service for booting a Windows PE environment over the network using iPXE and wimboot.

## 1. Create the PXE Root

From the ArkDeploy PXE directory, run:

```powershell
.\New-PxeRoot.ps1 -PxeRoot .\PXERoot
```

This downloads and prepares the files required to PXE boot Windows PE.

After running the script, your PXE root should look like this:

```text
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

## 2. Add Your ArkDeploy WinPE Image

Create your WinPE environment using the ArkDeploy Toolkit.

Copy the resulting `boot.wim` to:

```text
.\PXERoot\sources\boot.wim
```

ArkDeploy Toolkit **v1.1.1 or later** is recommended for PXE booting.

Version 1.1.1 introduced an embedded configuration fallback, allowing ArkDeploy WinPE to operate when no ArkDeploy USB media is present.

## 3. Configure DHCP

Your DHCP server must direct PXE clients to the machine running ArkDeploy PXE.

Configure:

```text
DHCP Option 66 (TFTP / Next Server)
    IP address of the ArkDeploy PXE server

DHCP Option 67 (Boot Filename)
    ipxe.efi
```

For example:

```text
Option 66: 192.168.0.49
Option 67: ipxe.efi
```

The ArkDeploy PXE server will display these settings as a reminder when it starts.

> The machine running ArkDeploy PXE should have a stable IP address.

## 4. Start ArkDeploy PXE

Start the TFTP server with:

```powershell
.\Start-TftpServer.ps1 -RootPath .\PXERoot
```

ArkDeploy PXE will begin listening for TFTP requests.

You should see:

```text
ArkDeploy PXE. Press Ctrl+C to stop.
        arkdeploy.com
```

You can now PXE boot a compatible UEFI system.

Press `Ctrl+C` to stop the server.

## Moving the PXE Root

The `PXERoot` directory does not need to remain inside the ArkDeploy PXE directory.

You can move it wherever you like and specify its location when starting the server:

```powershell
.\Start-TftpServer.ps1 -RootPath "D:\ArkDeploy\PXERoot"
```

## How It Works

The PXE boot process is intentionally simple:

```text
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

TFTP is used to bootstrap the Windows PE environment. Once WinPE has started, ArkDeploy can use its normal deployment methods for accessing and deploying Windows images.

## Credits

ArkDeploy PXE uses components from the iPXE project:

- `ipxe.efi` – iPXE UEFI network bootloader
- `wimboot` – Windows Imaging Format bootloader for iPXE

Many thanks to the iPXE project and its contributors for making these components available.

iPXE: [https://ipxe.org/](https://ipxe.org/)

## More ArkDeploy

ArkDeploy PXE is designed to work alongside the ArkDeploy Toolkit for capturing and deploying Windows images.

Visit:

https://github.com/ArkDeployDev/ArkDeployToolkit
https://arkdeploy.com/

