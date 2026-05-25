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
    - Removes leftover McAfee program files (x86 and x64)
    - Removes McAfee scheduled tasks
    - Removes McAfee services
    - Unregisters McAfee from Windows Security Center (CIMInstance)
    - Removes McAfee browser extensions (Edge + Chrome) for all users
    - Post-removal registry verification
    - Windows Defender status check
    - Cleans up working files, preserving log
.OUTPUTS
    C:\ProgramData\Debloat\McAfeeRemoval.log
.NOTES
    Original script by Andrew Taylor - andrewstaylor.com - https://github.com/andrew-s-taylor/public/blob/main/De-Bloat/RemoveBloat.ps1
    Run as Administrator
.VERSION
    1.2.1 - 2026-05-25
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

$LogFile = "C:\ProgramData\Debloat\McAfeeRemoval.log"
Start-Transcript -Path $LogFile

############################################################################################################
#                                         Logging Helper                                                   #
############################################################################################################

function Write-Log {
    param([string]$Message)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

Write-Log "======================================================"
Write-Log "  McAfee Removal Script v1.2.1"
Write-Log "  Run on: $($env:COMPUTERNAME) by: $($env:USERNAME)"
Write-Log "======================================================"

############################################################################################################
#                                  Grab Uninstall Strings (needed for Win32 removal)                       #
############################################################################################################

Write-Log "Building uninstall string list..."
$allstring = @()

$registryPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

foreach ($path in $registryPaths) {
    $apps = Get-ChildItem -Path $path | Get-ItemProperty | Select-Object -Property DisplayName, UninstallString
    foreach ($app in $apps) {

        # Skip entries missing a name or uninstall string
        if ([string]::IsNullOrWhiteSpace($app.DisplayName) -or [string]::IsNullOrWhiteSpace($app.UninstallString)) {
            continue
        }

        $string1 = $app.UninstallString.Trim()
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

Write-Log "Removing McAfee AppX packages..."

$McAfeeAppX = @(
    "5A894077.McAfeeSecurity"
    "5A894077.McAfeeSecurity_2.1.27.0_x64__wafk5atnkzcwy"
    "McAfeeWPSSparsePackage_0j6k21vdgrmfw"
    "McAfeeWPSSparsePackage"
)

foreach ($app in $McAfeeAppX) {
    if (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app) {
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app | Remove-AppxProvisionedPackage -Online
        Write-Log "Removed provisioned AppX: $app"
    }
    if (Get-AppxPackage -AllUsers -Name $app) {
        Get-AppxPackage -AllUsers -Name $app | Remove-AppxPackage -AllUsers
        Write-Log "Removed AppX package: $app"
    }
}

# Belt-and-braces removal of WPS sparse package by exact display name
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq "McAfeeWPSSparsePackage" | Remove-AppxProvisionedPackage -Online -AllUsers

############################################################################################################
#                                  Detect McAfee Installation                                              #
############################################################################################################

Write-Log "Detecting McAfee..."
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
    Write-Log "McAfee detected. Starting removal..."

    # Expected SHA256 hashes for downloaded ZIPs
    $expectedHash1 = "CBFCD1CE6C2CCF6B297CB7C46B916EEAA9165CAB701E4C2F26A381173596256F"
    $expectedHash2 = "231264F76973F7F9A27AD7A3BD9FEDE8451584968511F320E7FF3B5378E231B4"

    ### Tool 1: mcafeeclean.zip ###
    Write-Log "Downloading McAfee Removal Tool (mcafeeclean)..."
    $url1  = 'https://raw.githubusercontent.com/A1-Technologies/McAfee-Uninstall/main/mcafeeclean.zip'
    $dest1 = 'C:\ProgramData\Debloat\mcafee.zip'

    Invoke-WebRequest -Uri $url1 -OutFile $dest1

    if (-not (Test-Path $dest1) -or (Get-Item $dest1).Length -eq 0) {
        Write-Log "WARNING: Download failed or file is empty for $url1. Skipping Tool 1."
    } else {
        $hash1 = (Get-FileHash -Path $dest1 -Algorithm SHA256).Hash
        if ($hash1 -ne $expectedHash1) {
            Write-Log "ERROR: Hash mismatch for mcafee.zip! Expected: $expectedHash1 | Got: $hash1 — Skipping Tool 1 for safety."
        } else {
            Write-Log "Hash verified for mcafee.zip. Extracting..."
            Expand-Archive $dest1 -DestinationPath "C:\ProgramData\Debloat" -Force

            Write-Log "Running McAfee Removal Tool (mcafeeclean)..."
            Start-Process "C:\ProgramData\Debloat\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUEFWDRIVER,Redir,MSHR,WPS,MSSPlus -v -s" -Wait
            Write-Log "McAfee Removal Tool (mcafeeclean) finished. Exit code: $LASTEXITCODE"
        }
    }

    ### Tool 2: mccleanup.zip (newer version) ###
    Write-Log "Downloading McAfee Removal Tool (mccleanup - newer)..."
    $url2  = 'https://raw.githubusercontent.com/A1-Technologies/McAfee-Uninstall/main/mccleanup.zip'
    $dest2 = 'C:\ProgramData\Debloat\mcafeenew.zip'

    Invoke-WebRequest -Uri $url2 -OutFile $dest2

    if (-not (Test-Path $dest2) -or (Get-Item $dest2).Length -eq 0) {
        Write-Log "WARNING: Download failed or file is empty for $url2. Skipping Tool 2."
    } else {
        $hash2 = (Get-FileHash -Path $dest2 -Algorithm SHA256).Hash
        if ($hash2 -ne $expectedHash2) {
            Write-Log "ERROR: Hash mismatch for mcafeenew.zip! Expected: $expectedHash2 | Got: $hash2 — Skipping Tool 2 for safety."
        } else {
            Write-Log "Hash verified for mcafeenew.zip. Extracting..."
            $newPath = "C:\ProgramData\Debloat\mcnew"
            New-Item -Path $newPath -ItemType Directory -Force | Out-Null
            Expand-Archive $dest2 -DestinationPath $newPath -Force

            Write-Log "Running McAfee Removal Tool (mccleanup - newer)..."
            Start-Process "$newPath\Mccleanup.exe" -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s" -Wait
            Write-Log "McAfee Removal Tool (mccleanup - newer) finished. Exit code: $LASTEXITCODE"
        }
    }

    ############################################################################################################
    #                                   Uninstall Remaining McAfee Win32 Apps                                  #
    ############################################################################################################

    Write-Log "Uninstalling remaining McAfee Win32 apps via registry uninstall strings..."
    $InstalledPrograms = $allstring | Where-Object { ($_.Name -like "*McAfee*") -and ($_.Name -notlike "*WebAdvisor*") }

    $InstalledPrograms | ForEach-Object {
        $entryName        = $_.Name
        $uninstallcommand = $_.String

        if ([string]::IsNullOrWhiteSpace($entryName) -or [string]::IsNullOrWhiteSpace($uninstallcommand)) {
            Write-Log "WARNING: Skipping entry with missing name or uninstall string."
            return
        }

        Write-Log "Attempting to uninstall: [$entryName]..."

        try {
            if ($uninstallcommand -match "msiexec") {
                $msiArgs = $uninstallcommand -replace "msiexec\.exe", "" -replace "msiexec", ""
                $msiArgs = $msiArgs -replace "/I", "/X"
                $msiArgs += " /quiet /norestart"
                Start-Process "msiexec.exe" -ArgumentList $msiArgs -NoNewWindow -Wait
            } else {
                # Split exe and arguments — handles quoted and unquoted paths
                if ($uninstallcommand -match '^"([^"]+)"\s*(.*)$') {
                    $exe     = $Matches[1].Trim()
                    $argList = $Matches[2].Trim()
                } elseif ($uninstallcommand -match '^([^\s]+)\s*(.*)$') {
                    $exe     = $Matches[1].Trim()
                    $argList = $Matches[2].Trim()
                } else {
                    $exe     = $uninstallcommand
                    $argList = ""
                }

                # Validate the exe exists before attempting to run it
                if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path $exe)) {
                    Write-Log "WARNING: Uninstaller executable not found or invalid, skipping [$entryName]: '$exe'"
                    return
                }

                if ($argList) {
                    Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait
                } else {
                    Start-Process -FilePath $exe -NoNewWindow -Wait
                }
            }
            Write-Log "Successfully uninstalled: [$entryName]"
        }
        catch {
            Write-Log "WARNING: Failed to uninstall: [$entryName] — $_"
        }
    }

    ############################################################################################################
    #                                        Remove McAfee Safe Connect                                        #
    ############################################################################################################

    Write-Log "Removing McAfee Safe Connect..."
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

    Write-Log "Cleaning up leftover McAfee Start Menu entries and registry keys..."

    if (Test-Path -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee") {
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee" -Recurse -Force
        Write-Log "Removed McAfee Start Menu folder."
    }

    if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS") {
        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS" -Recurse -Force
        Write-Log "Removed McAfee.WPS registry key."
    }

    ############################################################################################################
    #                                      Remove McAfee WebAdvisor / SiteAdvisor                              #
    ############################################################################################################

    Write-Log "Removing McAfee WebAdvisor / SiteAdvisor..."

    if (Test-Path "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor\Uninstall.exe") {
        Start-Process -FilePath "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor\Uninstall.exe" -ArgumentList "/s" -WorkingDirectory "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor" -Wait -NoNewWindow
        Write-Log "SiteAdvisor uninstaller run."
    }

    Start-Sleep -Seconds 5

    ############################################################################################################
    #                                    Remove McAfee Program Files Folders                                   #
    ############################################################################################################

    Write-Log "Removing leftover McAfee program files folders..."

    $mcafeeProgramDirs = @(
        "${env:ProgramFiles(x86)}\McAfee",
        "${env:ProgramFiles(x86)}\McAfee.com",
        "$env:ProgramFiles\McAfee",
        "$env:ProgramFiles\McAfee.com"
    )

    foreach ($dir in $mcafeeProgramDirs) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force
                Write-Log "Removed: $dir"
            } catch {
                Write-Log "WARNING: Could not fully remove $dir — $_"
            }
        }
    }

    ############################################################################################################
    #                                      Remove McAfee Scheduled Tasks                                       #
    ############################################################################################################

    Write-Log "Removing McAfee scheduled tasks..."
    $mcafeeTasks = Get-ScheduledTask | Where-Object { $_.TaskName -like "*McAfee*" }
    if ($mcafeeTasks) {
        foreach ($task in $mcafeeTasks) {
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false
                Write-Log "Removed scheduled task: $($task.TaskPath)$($task.TaskName)"
            } catch {
                Write-Log "WARNING: Could not remove scheduled task: $($task.TaskName) — $_"
            }
        }
    } else {
        Write-Log "No McAfee scheduled tasks found."
    }

    ############################################################################################################
    #                                       Remove McAfee Services                                             #
    ############################################################################################################

    Write-Log "Removing McAfee services..."
    $mcafeeServices = Get-Service | Where-Object { $_.DisplayName -like "*McAfee*" }
    if ($mcafeeServices) {
        foreach ($svc in $mcafeeServices) {
            try {
                Stop-Service -Name $svc.Name -Force
                Write-Log "Stopped service: $($svc.Name)"
            } catch {
                Write-Log "WARNING: Could not stop service: $($svc.Name) — $_"
            }
            try {
                sc.exe delete $svc.Name | Out-Null
                Write-Log "Deleted service: $($svc.Name)"
            } catch {
                Write-Log "WARNING: Could not delete service: $($svc.Name) — $_"
            }
        }
    } else {
        Write-Log "No McAfee services found."
    }

    ############################################################################################################
    #                             Unregister McAfee from Windows Security Center (CIM)                         #
    ############################################################################################################

    Write-Log "Unregistering McAfee from Windows Security Center (CIMInstance)..."

    $cimNamespace = "root\SecurityCenter2"

    $cimAV = Get-CimInstance -Namespace $cimNamespace -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -like "*McAfee*" }

    if ($cimAV) {
        foreach ($av in $cimAV) {
            try {
                Remove-CimInstance -InputObject $av
                Write-Log "Unregistered AV from Security Center: $($av.displayName) [instanceGuid: $($av.instanceGuid)]"
            } catch {
                Write-Log "WARNING: Could not remove AV CIMInstance '$($av.displayName)' — $_"
            }
        }
    } else {
        Write-Log "No McAfee AntiVirusProduct CIMInstance entries found."
    }

    $cimFW = Get-CimInstance -Namespace $cimNamespace -ClassName FirewallProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -like "*McAfee*" }

    if ($cimFW) {
        foreach ($fw in $cimFW) {
            try {
                Remove-CimInstance -InputObject $fw
                Write-Log "Unregistered Firewall from Security Center: $($fw.displayName) [instanceGuid: $($fw.instanceGuid)]"
            } catch {
                Write-Log "WARNING: Could not remove Firewall CIMInstance '$($fw.displayName)' — $_"
            }
        }
    } else {
        Write-Log "No McAfee FirewallProduct CIMInstance entries found."
    }

    $cimAS = Get-CimInstance -Namespace $cimNamespace -ClassName AntiSpywareProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -like "*McAfee*" }

    if ($cimAS) {
        foreach ($as in $cimAS) {
            try {
                Remove-CimInstance -InputObject $as
                Write-Log "Unregistered AntiSpyware from Security Center: $($as.displayName) [instanceGuid: $($as.instanceGuid)]"
            } catch {
                Write-Log "WARNING: Could not remove AntiSpyware CIMInstance '$($as.displayName)' — $_"
            }
        }
    } else {
        Write-Log "No McAfee AntiSpywareProduct CIMInstance entries found."
    }

    ############################################################################################################
    #                              Remove McAfee Browser Extensions (Edge + Chrome)                            #
    ############################################################################################################

    $edgeExtensionId   = "fdhgeoginicibhagdmblfikbgbkahibd"   # McAfee WebAdvisor - Edge
    $chromeExtensionId = "fheoggkfdfchfphceeifdbepaooicaho"   # McAfee WebAdvisor - Chrome

    Write-Log "Removing McAfee browser extensions for all user profiles..."

    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
    }

    foreach ($profile in $userProfiles) {

        # --- Microsoft Edge ---
        $edgeExtPath = Join-Path $profile.FullName "AppData\Local\Microsoft\Edge\User Data"
        if (Test-Path $edgeExtPath) {
            $edgeProfiles = @("Default") + (Get-ChildItem $edgeExtPath -Directory -Filter "Profile*" | Select-Object -ExpandProperty Name)
            foreach ($ep in $edgeProfiles) {
                $extFolder = Join-Path $edgeExtPath "$ep\Extensions\$edgeExtensionId"
                if (Test-Path $extFolder) {
                    Remove-Item -Path $extFolder -Recurse -Force
                    Write-Log "Removed Edge McAfee extension for user '$($profile.Name)' profile '$ep'."
                }
            }
        }

        # --- Google Chrome ---
        $chromeExtPath = Join-Path $profile.FullName "AppData\Local\Google\Chrome\User Data"
        if (Test-Path $chromeExtPath) {
            $chromeProfiles = @("Default") + (Get-ChildItem $chromeExtPath -Directory -Filter "Profile*" | Select-Object -ExpandProperty Name)
            foreach ($cp in $chromeProfiles) {
                $extFolder = Join-Path $chromeExtPath "$cp\Extensions\$chromeExtensionId"
                if (Test-Path $extFolder) {
                    Remove-Item -Path $extFolder -Recurse -Force
                    Write-Log "Removed Chrome McAfee extension for user '$($profile.Name)' profile '$cp'."
                }
            }
        }
    }

    # Remove HKLM policy force-install entries for both browsers
    $edgePolicyPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
    $chromePolicyPath = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"

    foreach ($policyPath in @($edgePolicyPath, $chromePolicyPath)) {
        if (Test-Path $policyPath) {
            $entries = Get-ItemProperty -Path $policyPath
            $entries.PSObject.Properties | Where-Object {
                $_.Value -like "*$edgeExtensionId*" -or $_.Value -like "*$chromeExtensionId*"
            } | ForEach-Object {
                Remove-ItemProperty -Path $policyPath -Name $_.Name -Force
                Write-Log "Removed policy force-install entry '$($_.Name)' from $policyPath"
            }
        }
    }

    # Remove HKLM extension registry keys
    $browserExtRegPaths = @(
        "HKLM:\SOFTWARE\Google\Chrome\Extensions\$chromeExtensionId",
        "HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\Extensions\$chromeExtensionId",
        "HKLM:\SOFTWARE\Microsoft\Edge\Extensions\$edgeExtensionId",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions\$edgeExtensionId"
    )

    foreach ($regPath in $browserExtRegPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force
            Write-Log "Removed browser extension registry key: $regPath"
        }
    }

    Write-Log "Browser extension cleanup complete."

    ############################################################################################################
    #                                     Post-Removal Verification                                            #
    ############################################################################################################

    Write-Log "Running post-removal verification..."
    $remaining = @()

    $registryPaths | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem -Path $_ | Get-ItemProperty | Where-Object { $_.DisplayName -like "*McAfee*" } | ForEach-Object {
                $remaining += $_.DisplayName
            }
        }
    }

    if ($remaining.Count -gt 0) {
        Write-Log "WARNING: The following McAfee entries were still found in the registry after removal:"
        $remaining | ForEach-Object { Write-Log "  - $_" }
    } else {
        Write-Log "Verification passed — no McAfee registry entries remain."
    }

    ############################################################################################################
    #                                     Windows Defender Status Check                                        #
    ############################################################################################################

    Write-Log "Checking Windows Defender status..."
    try {
        $defenderStatus = Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled
        Write-Log "  AntivirusEnabled         : $($defenderStatus.AntivirusEnabled)"
        Write-Log "  RealTimeProtectionEnabled: $($defenderStatus.RealTimeProtectionEnabled)"

        if ($defenderStatus.AntivirusEnabled -and $defenderStatus.RealTimeProtectionEnabled) {
            Write-Log "Windows Defender is active and real-time protection is enabled. System is protected."
        } elseif ($defenderStatus.AntivirusEnabled -and -not $defenderStatus.RealTimeProtectionEnabled) {
            Write-Log "WARNING: Windows Defender is enabled but real-time protection is OFF. Consider enabling it."
        } else {
            Write-Log "WARNING: Windows Defender does not appear to be active. Manual review recommended."
        }
    } catch {
        Write-Log "WARNING: Could not retrieve Windows Defender status — $_"
    }

    Write-Log "McAfee removal complete."

} else {
    Write-Log "No McAfee installation detected. Nothing to remove."
}

############################################################################################################
#                                        Clean Up Debloat Working Files                                    #
############################################################################################################

Write-Log "Cleaning up working files from $DebloatFolder (preserving log)..."

$zipFiles = @(
    'C:\ProgramData\Debloat\mcafee.zip',
    'C:\ProgramData\Debloat\mcafeenew.zip'
)
foreach ($zip in $zipFiles) {
    if (Test-Path $zip) {
        Remove-Item -Path $zip -Force
        Write-Log "Removed: $zip"
    }
}

# Remove extracted files in $DebloatFolder, excluding the log
Get-ChildItem -Path $DebloatFolder -File | Where-Object { $_.FullName -ne $LogFile } | ForEach-Object {
    Remove-Item -Path $_.FullName -Force
    Write-Log "Removed file: $($_.FullName)"
}

# Remove all subdirectories
Get-ChildItem -Path $DebloatFolder -Directory | ForEach-Object {
    Remove-Item -Path $_.FullName -Recurse -Force
    Write-Log "Removed directory: $($_.FullName)"
}

Write-Log "Cleanup complete. Log preserved at: $LogFile"

############################################################################################################
#                                             Done                                                         #
############################################################################################################

Write-Log "Script finished. Check $LogFile for details."
Stop-Transcript
