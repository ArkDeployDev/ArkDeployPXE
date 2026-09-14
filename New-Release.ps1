
# set the current directory to the script directory
Set-Location -Path $PSScriptRoot

# Build the PxeTftp.dll
dotnet build .\PxeTftp.csproj -c Release

# Create Build Folder
$null =New-Item -ItemType Directory -Force -Path .\Release

# create build\bin folder
$null = New-Item -ItemType Directory -Force -Path .\Release\bin

# Create PXERoot folder
$null = New-Item -ItemType Directory -Force -Path .\Release\PXERoot

# copy .\PxeTftp\bin\Release\net6.0\PxeTftp.dll .\Release\bin\PxeTftp.dll
$null = copy-item -Path .\bin\Release\net6.0\PxeTftp.dll -Destination .\Release\bin\PxeTftp.dll -Force

# copy all powershell scripts to Release folder (Exclude New-Release.ps1)
$null = copy-item -Path .\*.ps1 -Destination .\Release -Exclude New-Release.ps1 -Force

# Set [string]$DllPath parameter in Start-TftpServer.ps1 to ./bin/PxeTftp.dll
$null = (Get-Content .\Release\Start-TftpServer.ps1) | 
    ForEach-Object { $_ -replace '\[string\]\$DllPath,', '[string]$$DllPath = "./bin/PxeTftp.dll",' } | 
        Set-Content .\Release\Start-TftpServer.ps1

# Copy firstrun.md to Release folder
$null = copy-item -Path .\FirstRun.md -Destination .\Release\FirstRun.md -Force

