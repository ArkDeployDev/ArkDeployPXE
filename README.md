# PxeTftp — minimal async TFTP server for PXE boot

A read-only, RFC 1350 TFTP server in C# (.NET 6), driven from PowerShell.
Built for serving `bootmgr.efi` / `pxeboot.n12` / `bcd` / `boot.wim` to PXE
clients — no DHCP, no write support, no auth, on purpose.

**Not compile-tested in this environment** (no .NET SDK available in the
sandbox that produced this code). It's plain BCL-only C# with no external
NuGet packages, so `dotnet build` should not need network access — but build
it and test against real firmware before relying on it.

## What's implemented

- RRQ (read) only — WRQ is refused with an access-violation error, as intended.
- Option negotiation (OACK): `blksize` (RFC 2348), `timeout` (RFC 2349),
  `tsize` (RFC 2349), `windowsize` (RFC 7440, go-back-N).
- Fully async I/O (`UdpClient` + `async`/`await`), one ephemeral-port socket
  per transfer so multiple PXE clients can boot concurrently.
- Block-number wraparound handling for files >32MB at 512-byte blocks (or
  correspondingly larger with a negotiated blksize) — TFTP's 16-bit block
  counter is treated as wrapping modulo 65536 rather than as a hard limit,
  which is what real-world TFTP boot loaders expect for multi-hundred-MB WIMs.
- Path-traversal protection: requested filenames are resolved against the
  TFTP root and anything that escapes it (`../..`, absolute paths, etc.) is
  rejected.

## What's deliberately NOT implemented

- DHCP / proxy-DHCP (per your setup, that's handled elsewhere on the network).
- WRQ / uploads.
- netascii translation (mode is accepted but treated as octet — fine for
  binary boot files, which is all PXE ever transfers).
- Any authentication — TFTP has none in the spec; keep this on a
  provisioning VLAN.

## Build

```powershell
dotnet build .\PxeTftp\PxeTftp.csproj -c Release
# Output: .\PxeTftp\bin\Release\net6.0\PxeTftp.dll
```

## Run

Requires **PowerShell 7+** (Windows PowerShell 5.1 is .NET Framework and
cannot load a net6.0 assembly). Also requires an elevated session to bind
UDP/69 on Windows.

```powershell
.\Start-TftpServer.ps1 `
    -DllPath .\PxeTftp\bin\Release\net6.0\PxeTftp.dll `
    -RootPath D:\PXERoot `
    -Port 69
```

Lay out `D:\PXERoot` exactly like a WinPE/ADK boot media folder — same
`bootmgr.efi`, `Boot\BCD`, `Boot\boot.sdi`, and your custom `boot.wim` you
already generate with `copype`/DISM. Point DHCP option 66/67 (or your
proxy-DHCP layer) at this box and at the right entry file for the client's
architecture (`bootmgr.efi` for UEFI, `pxeboot.n12` chaining to `bootmgr.exe`
for BIOS).

## Testing before touching real hardware

1. Point a TFTP *client* (e.g. `tftp -i <server> get bootmgr.efi`, or curl
   with `tftp://` support) at the server and confirm small files round-trip.
2. Test a large file transfer (your actual `boot.wim`) to exercise block-number
   wraparound and windowing.
3. Test against a VM's PXE ROM (Hyper-V/VMware both support PXE boot in
   firmware settings) before real hardware — firmware PXE stacks are where
   RFC-compliance quirks show up first.
4. Watch the console log (or `-LogFile`) for `FAILED` transfer events —
   they'll show which client/file/step timed out.

## Running as a background service

PowerShell scripts don't survive logoff/reboot on their own. Two common options:

- **NSSM** (Non-Sucking Service Manager) — wrap
  `pwsh.exe -File Start-TftpServer.ps1 -DllPath ... -RootPath ...` as a
  Windows service. Simplest path, no code changes needed.
- **Scheduled Task** triggered "At startup," running as SYSTEM, same command
  line as above.

Either way, keep `-RootPath` pointed at wherever your DISM build pipeline
already stages boot.wim/BCD, so publishing a new WinPE image is just a file
copy — no service restart needed, since the file is opened fresh per request.

## Tuning notes

- `MaxBlockSize` (default 1428): keep at or under your network's MTU minus
  TFTP/UDP/IP headers to avoid fragmentation. 1428 is safe for standard
  1500-byte Ethernet.
- `MaxWindowSize` (default 4): higher values cut round-trips dramatically on
  large WIM transfers, but only help if the client's PXE ROM/UEFI network
  stack actually implements RFC 7440. Older BIOS PXE stacks may ignore the
  `windowsize` option entirely — the server falls back gracefully to
  stop-and-wait in that case since negotiation is per-client.
- If a firmware PXE stack behaves oddly with options negotiated at all, drop
  `MaxBlockSize`/`MaxWindowSize` to 1 to force classic RFC-1350-only behavior
  for a quick compatibility check.
