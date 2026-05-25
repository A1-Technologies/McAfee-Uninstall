<#
.SYNOPSIS
    Removes McAfee products from Windows
.DESCRIPTION
    Extracted from andrew-s-taylor/public RemoveBloat.ps1
    - Removes McAfee AppX packages (provisioned and installed)
    - Runs McAfee Consumer Product Removal Tool (mcafeeclean.zip)
    - Runs updated MCCleanup tool (mccleanup.zip)
    - Uninstalls any remaining McAfee Win32 apps via registry uninstall strings
    - Removes McAfee Safe Connect
    - Cleans up leftover Start Menu entries and registry keys
    - Removes McAfee WebAdvisor / SiteAdvisor
    - Removes leftover McAfee program files
.OUTPUTS
    C:\ProgramData\Debloat\McAfeeRemoval.log
.NOTES
    Original script by Andrew Taylor - andrewstaylor.com
    Run as Administrator
#>

############################################################################################################
#                                         Initial Setup                                                    #
############################################################################################################

# Elevate if needed
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Output "Not running as Administrator. Re-launching elevated..."
    Start-Process powershell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) -Verb RunAs
    Exit
}

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Create log folder
$DebloatFolder = "C:\ProgramData\Debloat"
If (!(Test-Path $DebloatFolder)) {
    New-Item -Path $DebloatFolder -ItemType Directory | Out-Null
}

Start-Transcript -Path "C:\ProgramData\Debloat\McAfeeRemoval.log"

############################################################################################################
#                                  Grab Uninstall Strings (needed for Win32 removal)                       #
############################################################################################################

Write-Output "Building uninstall string list..."
$allstring = @()

$registryPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

foreach ($path in $registryPaths) {
    $apps = Get-ChildItem -Path $path | Get-ItemProperty | Select-Object -Property DisplayName, UninstallString
    foreach ($app in $apps) {
        $string1 = $app.UninstallString
        if ($string1 -match "^\s*(C:\\Windows\\System32\\)?msiexec(\.exe)?\s+\S*") {
            $string2 = $string1 + " /quiet /norestart"
            $string2 = $string2 -replace "/I", "/X "
        } else {
            $string2 = $string1
        }
        $allstring += New-Object -TypeName PSObject -Property @{
            Name   = $app.DisplayName
            String = $string2
        }
    }
}

############################################################################################################
#                                     Remove McAfee AppX Packages                                          #
############################################################################################################

Write-Output "Removing McAfee AppX packages..."

$McAfeeAppX = @(
    "5A894077.McAfeeSecurity"
    "5A894077.McAfeeSecurity_2.1.27.0_x64__wafk5atnkzcwy"
    "McAfeeWPSSparsePackage_0j6k21vdgrmfw"
    "McAfeeWPSSparsePackage"
)

foreach ($app in $McAfeeAppX) {
    if (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app) {
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app | Remove-AppxProvisionedPackage -Online
        Write-Output "Removed provisioned AppX: $app"
    }
    if (Get-AppxPackage -AllUsers -Name $app) {
        Get-AppxPackage -AllUsers -Name $app | Remove-AppxPackage -AllUsers
        Write-Output "Removed AppX package: $app"
    }
}

# Belt-and-braces removal of WPS sparse package by exact display name
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq "McAfeeWPSSparsePackage" | Remove-AppxProvisionedPackage -Online -AllUsers

############################################################################################################
#                                  Detect McAfee Installation                                              #
############################################################################################################

Write-Output "Detecting McAfee..."
$mcafeeinstalled = $false

$InstalledSoftware = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj in $InstalledSoftware) {
    if ($obj.GetValue('DisplayName') -like "*McAfee*") { $mcafeeinstalled = $true }
}

$InstalledSoftware32 = Get-ChildItem "HKLM:\Software\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($obj32 in $InstalledSoftware32) {
    if ($obj32.GetValue('DisplayName') -like "*McAfee*") { $mcafeeinstalled = $true }
}

############################################################################################################
#                                      Run McAfee Removal Tools                                            #
############################################################################################################

if ($mcafeeinstalled) {
    Write-Output "McAfee detected. Starting removal..."

    ### Tool 1: mcafeeclean.zip ###
    Write-Output "Downloading McAfee Removal Tool (mcafeeclean)..."
    $URL = 'https://github.com/A1-Technologies/McAfee-Uninstall/raw/main/mcafeeclean.zip'
    $destination = 'C:\ProgramData\Debloat\mcafee.zip'
    Invoke-WebRequest -Uri $URL -OutFile $destination -Method Get
    Expand-Archive $destination -DestinationPath "C:\ProgramData\Debloat" -Force

    Write-Output "Running McAfee Removal Tool (mcafeeclean)..."
    Start-Process "C:\ProgramData\Debloat\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUEFWDRIVER,Redir,MSHR,WPS,MSSPlus -v -s" -Wait
    Write-Output "McAfee Removal Tool (mcafeeclean) complete."

    ### Tool 2: mccleanup.zip (newer version) ###
    Write-Output "Downloading McAfee Removal Tool (mccleanup - newer)..."
    $URL = 'https://github.com/A1-Technologies/McAfee-Uninstall/raw/main/mccleanup.zip'
    $destination = 'C:\ProgramData\Debloat\mcafeenew.zip'
    Invoke-WebRequest -Uri $URL -OutFile $destination -Method Get
    New-Item -Path "C:\ProgramData\Debloat\mcnew" -ItemType Directory -Force | Out-Null
    Expand-Archive $destination -DestinationPath "C:\ProgramData\Debloat\mcnew" -Force

    Write-Output "Running McAfee Removal Tool (mccleanup - newer)..."
    Start-Process "C:\ProgramData\Debloat\mcnew\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s" -Wait
    Write-Output "McAfee Removal Tool (mccleanup - newer) complete."

    ############################################################################################################
    #                                   Uninstall Remaining McAfee Win32 Apps                                  #
    ############################################################################################################

    Write-Output "Uninstalling remaining McAfee Win32 apps via registry uninstall strings..."
    $InstalledPrograms = $allstring | Where-Object { ($_.Name -like "*McAfee*") -and ($_.Name -notlike "*WebAdvisor*") }

    $InstalledPrograms | ForEach-Object {
        Write-Output "Attempting to uninstall: [$($_.Name)]..."
        $uninstallcommand = $_.String
        Try {
            if ($uninstallcommand -match "^msiexec*") {
                $uninstallcommand = $uninstallcommand -replace "msiexec.exe", ""
                $uninstallcommand = $uninstallcommand + " /quiet /norestart"
                $uninstallcommand = $uninstallcommand -replace "/I", "/X "
                Start-Process 'msiexec.exe' -ArgumentList $uninstallcommand -NoNewWindow -Wait
            } else {
                Start-Process $uninstallcommand
            }
            Write-Output "Successfully uninstalled: [$($_.Name)]"
        }
        Catch { Write-Warning "Failed to uninstall: [$($_.Name)]" }
    }

    ############################################################################################################
    #                                        Remove McAfee Safe Connect                                        #
    ############################################################################################################

    Write-Output "Removing McAfee Safe Connect..."
    $safeconnects = Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall, HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall |
        Get-ItemProperty |
        Where-Object { $_.DisplayName -match "McAfee Safe Connect" } |
        Select-Object -Property UninstallString

    ForEach ($sc in $safeconnects) {
        If ($sc.UninstallString) {
            cmd.exe /c $sc.UninstallString /quiet /norestart
        }
    }

    ############################################################################################################
    #                                   Clean Up Leftover McAfee Entries                                       #
    ############################################################################################################

    Write-Output "Cleaning up leftover McAfee Start Menu entries and registry keys..."

    if (Test-Path -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee") {
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee" -Recurse -Force
        Write-Output "Removed McAfee Start Menu folder."
    }

    if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS") {
        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS" -Recurse -Force
        Write-Output "Removed McAfee.WPS registry key."
    }

    ############################################################################################################
    #                                      Remove McAfee WebAdvisor / SiteAdvisor                              #
    ############################################################################################################

    Write-Output "Removing McAfee WebAdvisor / SiteAdvisor..."

    if (Test-Path "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor\Uninstall.exe") {
        Start-Process -FilePath "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor\Uninstall.exe" -ArgumentList "/s" -WorkingDirectory "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor" -Wait -NoNewWindow
        Write-Output "SiteAdvisor uninstaller run."
    }

    Start-Sleep -Seconds 5

    if (Test-Path "${env:ProgramFiles(x86)}\McAfee") {
        Remove-Item -Path "${env:ProgramFiles(x86)}\McAfee" -Recurse -Force
        Write-Output "Removed leftover McAfee program files folder."
    }

    Write-Output "McAfee removal complete."

} else {
    Write-Output "No McAfee installation detected. Nothing to remove."
}

############################################################################################################
#                                             Done                                                         #
############################################################################################################

Write-Output "Script finished. Check C:\ProgramData\Debloat\McAfeeRemoval.log for details."
Stop-Transcript
