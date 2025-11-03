<#
.SYNOPSIS
    Offline version-aware installer for CloudDrive Mapper v3
    developed to assist with IAM Cloud curriculum deployments, to remove old version, install dependancies and install version 3

.AUTHOR
    Christian Jackson - ICT Hero 2025
.DESCRIPTION
    - Removes CloudDrive Mapper v2 if found
    - Detects installed versions of WebView2, .NET Framework, .NET 8 Runtime, and Desktop Runtime
    - Installs any missing or older versions from \\curric1\Install\App\IAMcloud
    - Installs CloudDrive Mapper v3 silently if not already current or newer
    - Logs all actions to C:\CloudDriveMapper.log
#>

# ================================
# Configurable Variables
# ================================
$logFile = "C:\CloudDriveMapper.log"
$sourcePath = "\\yourserver\Install\App\IAMcloud"
$cdmInstaller = Join-Path $sourcePath "CloudDriveMapper-3.21.0.25322.msi"
$licenseKey = "YOUR-LICENSE-KEY-HERE"
$appDir = "C:\Program Files\CloudDriveMapper"

# ================================
# Logging Function
# ================================
function Write-Log($msg, [string]$level = "INFO") {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts][$level] $msg"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

Write-Log "=== Starting CloudDrive Mapper deployment ==="

# ================================
# Extract target version from MSI filename
# ================================
$requiredVersion = [regex]::Match((Split-Path $cdmInstaller -Leaf), 'CloudDriveMapper-([\d\.]+)\.msi').Groups[1].Value
if (-not $requiredVersion) {
    $requiredVersion = "3.0.0.0"
    Write-Log "Warning: unable to parse version from filename, using fallback $requiredVersion" "WARN"
}
Write-Log "Target CloudDrive Mapper version (from filename): $requiredVersion"

# ================================
# Step 0 – Remove CloudDrive Mapper v2 if installed
# ================================
Write-Log "Checking for legacy Cloud Drive Mapper v2 installation..."

function Uninstall-LegacyCDM {
    param (
        [Parameter(Mandatory = $true)][object]$regEntry,
        [Parameter(Mandatory = $false)][string]$hive = "HKLM"
    )

    $displayName = $regEntry.DisplayName
    $version = $regEntry.DisplayVersion
    $uninstallString = $regEntry.UninstallString

    Write-Log "Found legacy CDM in $hive (Version: $version)"
    Write-Log "Registry uninstall command: $uninstallString"

    try {
        if ($uninstallString) {
            if ($uninstallString -notmatch "msiexec") {
                $uninstallString = "msiexec.exe /x $uninstallString"
            }

            if ($uninstallString -notmatch "/q") {
                $uninstallString += " /qn /norestart"
            }

            Write-Log "Executing uninstall command: $uninstallString"
            $process = Start-Process "cmd.exe" -ArgumentList "/c $uninstallString" -Wait -PassThru
            $exitCode = $process.ExitCode
            Write-Log "Uninstall process exit code: $exitCode"

            if ($exitCode -eq 0) {
                Write-Log "Legacy Cloud Drive Mapper (v2) uninstalled successfully."
            } else {
                Write-Log "Uninstall returned non-zero exit code ($exitCode). Manual check may be required." "WARN"
            }
        } else {
            Write-Log "No uninstall string found for legacy CDM in $hive." "ERROR"
        }
    } catch {
        Write-Log "Failed to uninstall legacy Cloud Drive Mapper (v2) from $hive. Error: $($_.Exception.Message)" "ERROR"
    }
}

$legacyCDM_HKLM = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "Cloud Drive Mapper" -and ($_.DisplayVersion -lt "3.0.0") }

$legacyCDM_HKCU = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "Cloud Drive Mapper" -and ($_.DisplayVersion -lt "3.0.0") }

if ($legacyCDM_HKLM) {
    foreach ($entry in $legacyCDM_HKLM) { Uninstall-LegacyCDM -regEntry $entry -hive "HKLM" }
}
elseif ($legacyCDM_HKCU) {
    foreach ($entry in $legacyCDM_HKCU) { Uninstall-LegacyCDM -regEntry $entry -hive "HKCU" }
}
else {
    Write-Log "No legacy Cloud Drive Mapper v2 installation found."
}

Start-Sleep -Seconds 5

# ================================
# Step 1 – Check for CloudDrive Mapper v3 already installed
# ================================
Write-Log "Checking for existing CloudDrive Mapper v3 installation..."

$cdmRegPath = "HKLM:\SOFTWARE\IAM Cloud\Cloud Drive Mapper"
$cdmV3Detected = $false
if (Test-Path $cdmRegPath) {
    try {
        $cdmV3 = Get-ItemProperty -Path $cdmRegPath -ErrorAction Stop
        $installedVersion = $cdmV3.Version
        if ($installedVersion) {
            Write-Log "Detected installed CloudDrive Mapper version $installedVersion"
            try {
                if ([version]$installedVersion -ge [version]$requiredVersion) {
                    Write-Log "CloudDrive Mapper v3 is up to date (Installed: $installedVersion, Required: $requiredVersion). Skipping installation."
                    Write-Log "=== Deployment complete ==="
                    exit
                }
                else {
                    Write-Log "Installed version ($installedVersion) is older than required ($requiredVersion). Proceeding with upgrade."
                }
            } catch {
                Write-Log "Error comparing versions. Forcing reinstall to ensure consistency." "WARN"
            }
        }
    } catch {
        Write-Log "Error reading CloudDrive Mapper registry: $($_.Exception.Message)" "WARN"
    }
}

# ================================
# Version Comparison Helper
# ================================
function Compare-Version($installed, $required) {
    try {
        [version]$v1 = $installed
        [version]$v2 = $required
        return ($v1 -ge $v2)
    } catch { return $false }
}

# ================================
# Step 2 – Prerequisite Checks
# ================================

# WebView2
$webview2Version = $null
$webview2Key = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients"
if (Test-Path $webview2Key) {
    $webview2Version = (Get-ChildItem $webview2Key -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).pv }) |
        Sort-Object -Descending | Select-Object -First 1
}

if ($webview2Version -and (Compare-Version $webview2Version "126.0.0.0")) {
    Write-Log "- WebView2 already installed (version $webview2Version)"
} else {
    Write-Log "Installing Microsoft Edge WebView2 Runtime..."
    Start-Process -FilePath (Join-Path $sourcePath "MicrosoftEdgeWebView2RuntimeInstallerX64.exe") -ArgumentList "/silent /install" -Wait
}

# .NET Framework 4.8
$fw = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
if ($fw -ge 528040) {
    Write-Log "- .NET Framework 4.8 or later already installed (Release $fw)"
} else {
    Write-Log "Installing .NET Framework 4.8..."
    Start-Process -FilePath (Join-Path $sourcePath "NDP48-x86-x64-AllOS-ENU.exe") -ArgumentList "/q /norestart" -Wait
}

# .NET 8 Runtime
$runtimePath = "C:\Program Files\dotnet\shared\Microsoft.NETCore.App"
$runtimeVersion = (Get-ChildItem $runtimePath -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1).Name
$requiredRuntime = "8.0.21"

if ($runtimeVersion -and (Compare-Version $runtimeVersion $requiredRuntime)) {
    Write-Log "- .NET Runtime version $runtimeVersion already installed"
} else {
    Write-Log "Installing .NET Runtime $requiredRuntime..."
    Start-Process -FilePath (Join-Path $sourcePath "dotnet-runtime-8.0.21-win-x64.exe") -ArgumentList "/quiet /norestart" -Wait
}

# .NET 8 Desktop Runtime
$desktopPath = "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App"
$desktopVersion = (Get-ChildItem $desktopPath -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1).Name
$requiredDesktop = "8.0.21"

if ($desktopVersion -and (Compare-Version $desktopVersion $requiredDesktop)) {
    Write-Log "- .NET Desktop Runtime version $desktopVersion already installed"
} else {
    Write-Log "Installing .NET Desktop Runtime $requiredDesktop..."
    Start-Process -FilePath (Join-Path $sourcePath "windowsdesktop-runtime-8.0.21-win-x64.exe") -ArgumentList "/quiet /norestart" -Wait
}

Write-Log "=== All prerequisites verified ==="

# ================================
# Step 3 – Ensure no active MSI processes
# ================================
Write-Log "Checking for active Windows Installer processes..."
if (Get-Process -Name msiexec -ErrorAction SilentlyContinue) {
    Write-Log "Waiting for existing Windows Installer operations to complete..."
    while (Get-Process -Name msiexec -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 3
    }
}
Write-Log "No active MSI operations detected."

# ================================
# Step 4 – Install CloudDrive Mapper
# ================================
Write-Log "Installing CloudDrive Mapper v3..."
$args = @(
    "/i `"$cdmInstaller`"",
    "/qn",
    "/norestart",
    "LICENSEKEY=$licenseKey",
    "DESKTOP_SHORTCUT=1",
    "STARTMENU_SHORTCUT=1",
    "STARTUP_SHORTCUT=1",
    "LAUNCHCDM=0",
    "CLEANDATA=1",
    "LogLevel=Debug",
    "APPDIR=`"$appDir`""
)
$argString = $args -join " "
Start-Process "msiexec.exe" -ArgumentList $argString -Wait
Write-Log "CloudDrive Mapper installation complete."

# ================================
# Step 5 – Post-Install Verification
# ================================
Write-Log "=== Starting post-install verification ==="

if (Test-Path $cdmRegPath) {
    $cdm = Get-ItemProperty -Path $cdmRegPath -ErrorAction SilentlyContinue
    Write-Log "Cloud Drive Mapper detected via IAM Cloud registry."
    Write-Log "  Version (registry): $($cdm.Version)"
    Write-Log "  Installer Version : $($cdm.InstallerVersion)"
    Write-Log "  Path              : $($cdm.Path)"
    Write-Log "  Core Executable   : $($cdm.CorePath)"

    if (Test-Path $cdm.CorePath) {
        Write-Log "Verified executable found at: $($cdm.CorePath)"
    } else {
        Write-Log "Warning: Core executable not found at expected path ($($cdm.CorePath))." "WARN"
    }
} else {
    Write-Log "Cloud Drive Mapper registry key not found under HKLM:\SOFTWARE\IAM Cloud\Cloud Drive Mapper" "ERROR"
}

Write-Log "=== Deployment complete ==="
Write-Log "Log file saved to: $logFile"