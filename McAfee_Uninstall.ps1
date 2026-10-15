<#
.SYNOPSIS
    Removes McAfee products from Windows
.DESCRIPTION
    Extracted from andrew-s-taylor/public RemoveBloat.ps1
.OUTPUTS
    C:\ProgramData\Debloat\McAfeeRemoval.log
.NOTES
    Original script by Andrew Taylor - andrewstaylor.com
    Run as Administrator
.VERSION
    1.3.1 - 2026-10-15
#>

############################################################################################################
#                                         Initial Setup                                                    #
############################################################################################################

If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Output "Not running as Administrator. Re-launching elevated..."
    Start-Process powershell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) -Verb RunAs
    Exit
}

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$DebloatFolder = "C:\ProgramData\Debloat"

if (!(Test-Path $DebloatFolder)) {
    New-Item -Path $DebloatFolder -ItemType Directory | Out-Null
}

$LogFile = Join-Path $DebloatFolder "McAfeeRemoval.log"
Start-Transcript -Path $LogFile -Append

function Write-Log {
    param([string]$Message)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

function Start-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string]$ArgumentList = "",
        [int]$TimeoutSeconds = 120
    )

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $ArgumentList
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false

        $proc = [System.Diagnostics.Process]::Start($psi)

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Log "WARNING: Process '$FilePath' exceeded timeout of ${TimeoutSeconds}s — killing."
            $proc.Kill()
            return -1
        }

        return $proc.ExitCode
    } catch {
        Write-Log "WARNING: Start-ProcessWithTimeout failed for '$FilePath' — $_"
        return -1
    }
}

Write-Log "======================================================"
Write-Log "  McAfee Removal Script v1.3.1"
Write-Log "  Run on: $($env:COMPUTERNAME) by: $($env:USERNAME)"
Write-Log "======================================================"

############################################################################################################
#                                  Registry Paths and Uninstall Strings                                    #
############################################################################################################

$registryPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

Write-Log "Building uninstall string list..."
$allstring = @()

foreach ($path in $registryPaths) {
    if (-not (Test-Path $path)) {
        continue
    }

    Get-ChildItem -Path $path | ForEach-Object {
        $entry = Get-ItemProperty -Path $_.PSPath

        if ([string]::IsNullOrWhiteSpace($entry.DisplayName) -or [string]::IsNullOrWhiteSpace($entry.UninstallString)) {
            return
        }

        $uninstallString = $entry.UninstallString.Trim()

        if ($uninstallString -match "^\s*(C:\\Windows\\System32\\)?msiexec(\.exe)?\s+\S*") {
            $uninstallString = $uninstallString + " /quiet /norestart"
            $uninstallString = $uninstallString -replace "/I", "/X "
        }

        $allstring += New-Object -TypeName PSObject -Property @{
            Name   = $entry.DisplayName
            String = $uninstallString
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
    Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -like $app } |
        ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null
            Write-Log "Removed provisioned AppX: $app"
        }

    Get-AppxPackage -AllUsers -Name $app |
        ForEach-Object {
            Remove-AppxPackage -AllUsers -Package $_.PackageFullName
            Write-Log "Removed AppX package: $app"
        }
}

Get-AppxProvisionedPackage -Online |
    Where-Object { $_.DisplayName -eq "McAfeeWPSSparsePackage" } |
    ForEach-Object {
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null
    }

############################################################################################################
#                                  Detect McAfee Installation                                              #
############################################################################################################

Write-Log "Detecting McAfee installation or leftover registry entries..."
$mcafeeinstalled = $false

foreach ($path in $registryPaths) {
    if (-not (Test-Path -Path $path)) {
        continue
    }

    Get-ChildItem -Path $path | ForEach-Object {
        $uninstallKey = $_
        $entry = Get-ItemProperty -Path $uninstallKey.PSPath

        $displayName = [string]$entry.DisplayName
        $keyName = [string]$uninstallKey.PSChildName

        if ($displayName -match '(?i)McAfee' -or $keyName -match '(?i)McAfee') {
            $mcafeeinstalled = $true

            Write-Log (
                "McAfee registry entry detected: " +
                "DisplayName='$displayName'; " +
                "KeyName='$keyName'; " +
                "Path='$($uninstallKey.PSPath)'"
            )
        }
    }
}

if (-not $mcafeeinstalled) {
    Write-Log "No McAfee installation or McAfee uninstall-registry entries detected."
}

############################################################################################################
#                                      Run McAfee Removal Tools                                            #
############################################################################################################

if ($mcafeeinstalled) {
    Write-Log "McAfee detected. Starting removal..."

    $expectedHash1 = "CBFCD1CE6C2CCF6B297CB7C46B916EEAA9165CAB701E4C2F26A381173596256F"
    $expectedHash2 = "231264F76973F7F9A27AD7A3BD9FEDE8451584968511F320E7FF3B5378E231B4"

    ############################################################################################################
    #                                      Tool 1: mcafeeclean.zip                                           #
    ############################################################################################################

    $url1 = "https://raw.githubusercontent.com/A1-Technologies/McAfee-Uninstall/main/mcafeeclean.zip"
    $dest1 = Join-Path $DebloatFolder "mcafee.zip"

    Write-Log "Downloading McAfee Removal Tool (mcafeeclean)..."
    Invoke-WebRequest -Uri $url1 -OutFile $dest1

    if (-not (Test-Path $dest1) -or (Get-Item $dest1).Length -eq 0) {
        Write-Log "WARNING: Download failed or file is empty for $url1. Skipping Tool 1."
    } else {
        $hash1 = (Get-FileHash -Path $dest1 -Algorithm SHA256).Hash

        if ($hash1 -ne $expectedHash1) {
            Write-Log "ERROR: Hash mismatch for mcafee.zip. Skipping Tool 1 for safety."
        } else {
            Write-Log "Hash verified for mcafee.zip. Extracting..."
            Expand-Archive -Path $dest1 -DestinationPath $DebloatFolder -Force

            $cleanupExe = Join-Path $DebloatFolder "Mccleanup.exe"

            if (Test-Path $cleanupExe) {
                Write-Log "Running McAfee Removal Tool (mcafeeclean)..."

                $proc1 = Start-Process $cleanupExe `
                    -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUEFWDRIVER,Redir,MSHR,WPS,MSSPlus -v -s" `
                    -PassThru -Wait

                Write-Log "McAfee Removal Tool (mcafeeclean) finished. Exit code: $($proc1.ExitCode)"
            } else {
                Write-Log "WARNING: Mccleanup.exe was not found after extracting mcafeeclean.zip."
            }
        }
    }

    ############################################################################################################
    #                                      Tool 2: mccleanup.zip                                             #
    ############################################################################################################

    $url2 = "https://raw.githubusercontent.com/A1-Technologies/McAfee-Uninstall/main/mccleanup.zip"
    $dest2 = Join-Path $DebloatFolder "mcafeenew.zip"
    $newPath = Join-Path $DebloatFolder "mcnew"

    Write-Log "Downloading McAfee Removal Tool (mccleanup - newer)..."
    Invoke-WebRequest -Uri $url2 -OutFile $dest2

    if (-not (Test-Path $dest2) -or (Get-Item $dest2).Length -eq 0) {
        Write-Log "WARNING: Download failed or file is empty for $url2. Skipping Tool 2."
    } else {
        $hash2 = (Get-FileHash -Path $dest2 -Algorithm SHA256).Hash

        if ($hash2 -ne $expectedHash2) {
            Write-Log "ERROR: Hash mismatch for mcafeenew.zip. Skipping Tool 2 for safety."
        } else {
            Write-Log "Hash verified for mcafeenew.zip. Extracting..."

            New-Item -Path $newPath -ItemType Directory -Force | Out-Null
            Expand-Archive -Path $dest2 -DestinationPath $newPath -Force

            $newCleanupExe = Join-Path $newPath "Mccleanup.exe"

            if (Test-Path $newCleanupExe) {
                Write-Log "Running McAfee Removal Tool (mccleanup - newer)..."

                $proc2 = Start-Process $newCleanupExe `
                    -ArgumentList "-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s" `
                    -PassThru -Wait

                Write-Log "McAfee Removal Tool (mccleanup - newer) finished. Exit code: $($proc2.ExitCode)"
            } else {
                Write-Log "WARNING: Mccleanup.exe was not found after extracting mccleanup.zip."
            }
        }
    }

    ############################################################################################################
    #                                   Uninstall Remaining McAfee Win32 Apps                                  #
    ############################################################################################################

    Write-Log "Uninstalling remaining McAfee Win32 apps via registry uninstall strings..."

    $InstalledPrograms = $allstring | Where-Object {
        $_.Name -like "*McAfee*" -and $_.Name -notlike "*WebAdvisor*"
    }

    $skipPatterns = @(
        "engine\.js"
        "McAfeeActiveProtection"
        "WPSUpdate"
        "ClientAnalytics"
        "bootstrap"
    )

    $InstalledPrograms | ForEach-Object {
        $entryName = $_.Name
        $uninstallCommand = $_.String

        foreach ($pattern in $skipPatterns) {
            if ($uninstallCommand -match $pattern) {
                Write-Log "SKIPPED [$entryName]: uninstall command matches '$pattern'."
                return
            }
        }

        try {
            if ($uninstallCommand -match "msiexec") {
                $msiArgs = $uninstallCommand -replace "msiexec\.exe", "" -replace "msiexec", ""
                $msiArgs = $msiArgs -replace "/I", "/X"
                $msiArgs += " /quiet /norestart"

                $procMsi = Start-Process "msiexec.exe" -ArgumentList $msiArgs -PassThru -Wait
                Write-Log "Uninstall attempt complete: [$entryName]. Exit code: $($procMsi.ExitCode)"
            } else {
                if ($uninstallCommand -match '^"([^"]+)"\s*(.*)$') {
                    $exe = $Matches[1].Trim()
                    $argList = $Matches[2].Trim()
                } elseif ($uninstallCommand -match '^([^\s]+)\s*(.*)$') {
                    $exe = $Matches[1].Trim()
                    $argList = $Matches[2].Trim()
                } else {
                    $exe = $uninstallCommand
                    $argList = ""
                }

                if (-not (Test-Path $exe)) {
                    Write-Log "WARNING: Uninstaller not found for [$entryName]: '$exe'"
                    return
                }

                $exitCode = Start-ProcessWithTimeout -FilePath $exe -ArgumentList $argList -TimeoutSeconds 120

                if ($exitCode -eq -1) {
                    Write-Log "WARNING: [$entryName] timed out and was killed."
                } else {
                    Write-Log "Uninstall attempt complete: [$entryName]. Exit code: $exitCode"
                }
            }
        } catch {
            Write-Log "WARNING: Failed to uninstall [$entryName] — $_"
        }
    }

    ############################################################################################################
    #                                        Remove McAfee Safe Connect                                        #
    ############################################################################################################

    Write-Log "Removing McAfee Safe Connect..."

    $safeConnectEntries = Get-ChildItem -Path $registryPaths |
        Get-ItemProperty |
        Where-Object { $_.DisplayName -match '(?i)McAfee Safe Connect' }

    foreach ($safeConnect in $safeConnectEntries) {
        if ($safeConnect.UninstallString) {
            cmd.exe /c "$($safeConnect.UninstallString) /quiet /norestart"
        }
    }

    ############################################################################################################
    #                                   Clean Up Leftover McAfee Entries                                       #
    ############################################################################################################

    Write-Log "Cleaning up leftover McAfee Start Menu entries and registry keys..."

    $startMenuPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\McAfee"

    if (Test-Path $startMenuPath) {
        Remove-Item -Path $startMenuPath -Recurse -Force
        Write-Log "Removed McAfee Start Menu folder."
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS") {
        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\McAfee.WPS" -Recurse -Force
        Write-Log "Removed McAfee.WPS registry key."
    }

    # Remove all McAfee uninstall entries. A McAfee product may have a blank
    # DisplayName, while GUID-keyed entries may only identify McAfee in DisplayName.
    Write-Log "Removing McAfee uninstall registry entries..."

    foreach ($hive in $registryPaths) {
        if (-not (Test-Path -Path $hive)) {
            continue
        }

        Get-ChildItem -Path $hive | ForEach-Object {
            $uninstallKey = $_
            $entry = Get-ItemProperty -Path $uninstallKey.PSPath

            $displayName = [string]$entry.DisplayName
            $keyName = [string]$uninstallKey.PSChildName

            if ($displayName -match '(?i)McAfee' -or $keyName -match '(?i)McAfee') {
                try {
                    Remove-Item -Path $uninstallKey.PSPath -Recurse -Force

                    Write-Log (
                        "Removed McAfee uninstall entry: " +
                        "DisplayName='$displayName'; " +
                        "KeyName='$keyName'; " +
                        "Path='$($uninstallKey.PSPath)'"
                    )
                } catch {
                    Write-Log (
                        "WARNING: Could not remove McAfee uninstall entry: " +
                        "DisplayName='$displayName'; KeyName='$keyName' — $_"
                    )
                }
            }
        }
    }

    ############################################################################################################
    #                                      Remove McAfee WebAdvisor / SiteAdvisor                              #
    ############################################################################################################

    Write-Log "Removing McAfee WebAdvisor / SiteAdvisor..."

    $siteAdvisorUninstaller = "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor\Uninstall.exe"

    if (Test-Path $siteAdvisorUninstaller) {
        $procSA = Start-Process -FilePath $siteAdvisorUninstaller `
            -ArgumentList "/s" `
            -WorkingDirectory "${env:ProgramFiles(x86)}\McAfee\SiteAdvisor" `
            -PassThru -Wait

        Write-Log "SiteAdvisor uninstaller finished. Exit code: $($procSA.ExitCode)"
    }

    Start-Sleep -Seconds 5

    ############################################################################################################
    #                                    Remove McAfee Program Files Folders                                   #
    ############################################################################################################

    $mcafeeProgramDirs = @(
        "${env:ProgramFiles(x86)}\McAfee"
        "${env:ProgramFiles(x86)}\McAfee.com"
        "$env:ProgramFiles\McAfee"
        "$env:ProgramFiles\McAfee.com"
    )

    foreach ($dir in $mcafeeProgramDirs) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force
                Write-Log "Removed: $dir"
            } catch {
                Write-Log "WARNING: Could not fully remove '$dir' — $_"
            }
        }
    }

    ############################################################################################################
    #                                      Remove McAfee Scheduled Tasks                                       #
    ############################################################################################################

    $mcafeeTasks = Get-ScheduledTask | Where-Object {
        $_.TaskName -like "*McAfee*"
    }

    foreach ($task in $mcafeeTasks) {
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false
            Write-Log "Removed scheduled task: $($task.TaskPath)$($task.TaskName)"
        } catch {
            Write-Log "WARNING: Could not remove scheduled task '$($task.TaskName)' — $_"
        }
    }

    ############################################################################################################
    #                                       Remove McAfee Services                                             #
    ############################################################################################################

    $mcafeeServices = Get-Service | Where-Object {
        $_.DisplayName -like "*McAfee*"
    }

    foreach ($svc in $mcafeeServices) {
        try {
            Stop-Service -Name $svc.Name -Force
            Write-Log "Stopped service: $($svc.Name)"
        } catch {
            Write-Log "WARNING: Could not stop service '$($svc.Name)' — $_"
        }

        try {
            sc.exe delete $svc.Name | Out-Null
            Write-Log "Deleted service: $($svc.Name)"
        } catch {
            Write-Log "WARNING: Could not delete service '$($svc.Name)' — $_"
        }
    }

    ############################################################################################################
    #                             Unregister McAfee from Windows Security Center (CIM)                         #
    ############################################################################################################

    $cimNamespace = "root\SecurityCenter2"

    foreach ($className in @("AntiVirusProduct", "FirewallProduct", "AntiSpywareProduct")) {
        Get-CimInstance -Namespace $cimNamespace -ClassName $className -ErrorAction SilentlyContinue |
            Where-Object { $_.displayName -like "*McAfee*" } |
            ForEach-Object {
                try {
                    Remove-CimInstance -InputObject $_
                    Write-Log "Unregistered Security Center entry: $($_.displayName)"
                } catch {
                    Write-Log "WARNING: Could not unregister Security Center entry '$($_.displayName)' — $_"
                }
            }
    }

    ############################################################################################################
    #                              Remove McAfee Browser Extensions (Edge + Chrome)                            #
    ############################################################################################################

    $edgeExtensionId = "fdhgeoginicibhagdmblfikbgbkahibd"
    $chromeExtensionId = "fheoggkfdfchfphceeifdbepaooicaho"

    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object {
        $_.Name -notin @("Public", "Default", "Default User", "All Users")
    }

    foreach ($profile in $userProfiles) {
        $edgeDataPath = Join-Path $profile.FullName "AppData\Local\Microsoft\Edge\User Data"

        if (Test-Path $edgeDataPath) {
            $edgeProfiles = @("Default") + (
                Get-ChildItem $edgeDataPath -Directory -Filter "Profile*" |
                Select-Object -ExpandProperty Name
            )

            foreach ($edgeProfile in $edgeProfiles) {
                $extensionPath = Join-Path $edgeDataPath "$edgeProfile\Extensions\$edgeExtensionId"

                if (Test-Path $extensionPath) {
                    Remove-Item -Path $extensionPath -Recurse -Force
                    Write-Log "Removed Edge McAfee extension for '$($profile.Name)' / '$edgeProfile'."
                }
            }
        }

        $chromeDataPath = Join-Path $profile.FullName "AppData\Local\Google\Chrome\User Data"

        if (Test-Path $chromeDataPath) {
            $chromeProfiles = @("Default") + (
                Get-ChildItem $chromeDataPath -Directory -Filter "Profile*" |
                Select-Object -ExpandProperty Name
            )

            foreach ($chromeProfile in $chromeProfiles) {
                $extensionPath = Join-Path $chromeDataPath "$chromeProfile\Extensions\$chromeExtensionId"

                if (Test-Path $extensionPath) {
                    Remove-Item -Path $extensionPath -Recurse -Force
                    Write-Log "Removed Chrome McAfee extension for '$($profile.Name)' / '$chromeProfile'."
                }
            }
        }
    }

    $policyPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
        "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"
    )

    foreach ($policyPath in $policyPaths) {
        if (Test-Path $policyPath) {
            $entries = Get-ItemProperty -Path $policyPath

            $entries.PSObject.Properties |
                Where-Object {
                    $_.Value -like "*$edgeExtensionId*" -or
                    $_.Value -like "*$chromeExtensionId*"
                } |
                ForEach-Object {
                    Remove-ItemProperty -Path $policyPath -Name $_.Name -Force
                    Write-Log "Removed browser extension policy '$($_.Name)' from '$policyPath'."
                }
        }
    }

    $browserExtensionRegistryPaths = @(
        "HKLM:\SOFTWARE\Google\Chrome\Extensions\$chromeExtensionId"
        "HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\Extensions\$chromeExtensionId"
        "HKLM:\SOFTWARE\Microsoft\Edge\Extensions\$edgeExtensionId"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions\$edgeExtensionId"
    )

    foreach ($regPath in $browserExtensionRegistryPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force
            Write-Log "Removed browser extension registry key: $regPath"
        }
    }

    ############################################################################################################
    #                                     Post-Removal Verification                                            #
    ############################################################################################################

    Write-Log "Running post-removal verification..."
    $remaining = @()

    foreach ($hive in $registryPaths) {
        if (-not (Test-Path -Path $hive)) {
            continue
        }

        Get-ChildItem -Path $hive | ForEach-Object {
            $uninstallKey = $_
            $entry = Get-ItemProperty -Path $uninstallKey.PSPath

            $displayName = [string]$entry.DisplayName
            $keyName = [string]$uninstallKey.PSChildName

            if ($displayName -match '(?i)McAfee' -or $keyName -match '(?i)McAfee') {
                $remaining += (
                    "DisplayName='$displayName'; " +
                    "KeyName='$keyName'; " +
                    "Path='$($uninstallKey.PSPath)'"
                )
            }
        }
    }

    if ($remaining.Count -gt 0) {
        Write-Log "WARNING: McAfee uninstall entries still remain:"

        $remaining | ForEach-Object {
            Write-Log "  - $_"
        }
    } else {
        Write-Log "Verification passed — no McAfee uninstall entries remain."
    }

    ############################################################################################################
    #                                     Windows Defender Status Check                                        #
    ############################################################################################################

    try {
        $defenderStatus = Get-MpComputerStatus |
            Select-Object AntivirusEnabled, RealTimeProtectionEnabled

        Write-Log "AntivirusEnabled: $($defenderStatus.AntivirusEnabled)"
        Write-Log "RealTimeProtectionEnabled: $($defenderStatus.RealTimeProtectionEnabled)"
    } catch {
        Write-Log "WARNING: Could not retrieve Windows Defender status — $_"
    }

    Write-Log "McAfee removal complete."
}

############################################################################################################
#                                        Clean Up Debloat Working Files                                    #
############################################################################################################

Write-Log "Cleaning up working files from $DebloatFolder (preserving log)..."

$zipFiles = @(
    (Join-Path $DebloatFolder "mcafee.zip")
    (Join-Path $DebloatFolder "mcafeenew.zip")
)

foreach ($zip in $zipFiles) {
    if (Test-Path $zip) {
        Remove-Item -Path $zip -Force
        Write-Log "Removed: $zip"
    }
}

Get-ChildItem -Path $DebloatFolder -File |
    Where-Object { $_.FullName -ne $LogFile } |
    ForEach-Object {
        Remove-Item -Path $_.FullName -Force
        Write-Log "Removed file: $($_.FullName)"
    }

Get-ChildItem -Path $DebloatFolder -Directory |
    ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
        Write-Log "Removed directory: $($_.FullName)"
    }

Write-Log "Cleanup complete. Log preserved at: $LogFile"
Write-Log "Script finished. Check $LogFile for details."

Stop-Transcript
