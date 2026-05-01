# ==============================================================================
# Set-WindowsUpdate.ps1
# Installs approved Windows updates while enforcing a hard version ceiling.
# Machines are locked to Windows 11 24H2 via registry policy so the OS-level
# Windows Update stack itself will never offer 25H2, regardless of how updates
# are triggered. Script-level title filtering acts as a secondary safety net.
# ==============================================================================

# ------------------------------------------------------------------------------
# STEP 1 — Require elevated privileges
# The registry writes, module install, and WU operations all need admin rights.
# ------------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal]
[Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
Write-Error "This script must be run as Administrator."
exit 1
}

# ------------------------------------------------------------------------------
# STEP 2 — Set up logging
# Creates the log directory if it doesn't exist, then captures all output.
# ------------------------------------------------------------------------------
$LogPath = "C:\Logs\WindowsUpdate.log"
$LogDir = Split-Path $LogPath

if (!(Test-Path $LogDir)) {
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath -Append

# ------------------------------------------------------------------------------
# STEP 3 — Enforce version ceiling via registry (Recommendation 1)
#
# Writing TargetReleaseVersion to the Windows Update policy hive instructs the
# Windows Update stack to treat 24H2 as the highest permitted version. This is
# the same lever Group Policy uses and is respected even outside this script,
# so machines stay pinned even if WU runs via Automatic Updates or WSUS.
# ------------------------------------------------------------------------------
$WUPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

Write-Output "Applying TargetReleaseVersion registry policy..."

try {
if (!(Test-Path $WUPolicyPath)) {
New-Item -Path $WUPolicyPath -Force | Out-Null
}

# Enable the target version feature (must be 1 for the version strings below to take effect)
Set-ItemProperty -Path $WUPolicyPath -Name "TargetReleaseVersion" -Value 1 -Type DWord -ErrorAction Stop
# Lock the OS family to Windows 11 (distinguishes from Windows 10 policy keys)
Set-ItemProperty -Path $WUPolicyPath -Name "ProductVersion" -Value "Windows 11" -Type String -ErrorAction Stop
# Set the highest permitted feature version — change this when you approve 25H2
Set-ItemProperty -Path $WUPolicyPath -Name "TargetReleaseVersionInfo" -Value "24H2" -Type String -ErrorAction Stop

Write-Output "Registry policy applied: Windows 11 24H2 ceiling is now enforced."
} catch {
Write-Error "Failed to apply TargetReleaseVersion registry policy: $_"
Stop-Transcript
exit 1
}

# ------------------------------------------------------------------------------
# STEP 4 — Ensure PSWindowsUpdate module is available
# Only installs from PSGallery if the module isn't already present.
# Consider pointing -Repository to an internal NuGet feed for air-gapped or
# security-hardened environments.
# ------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
Write-Output "PSWindowsUpdate not found. Installing from PSGallery..."
try {
Install-Module -Name PSWindowsUpdate -Repository PSGallery -Force -Confirm:$false -ErrorAction Stop
Write-Output "PSWindowsUpdate installed successfully."
} catch {
Write-Error "Failed to install PSWindowsUpdate: $_"
Stop-Transcript
exit 1
}
}

Import-Module PSWindowsUpdate

# ------------------------------------------------------------------------------
# STEP 5 — Retrieve applicable updates, excluding feature upgrades
#
# The registry policy (Step 3) is the primary guard. The Where-Object filter
# below is a secondary defence: it drops any update whose title contains
# "Feature update" or "25H2" in case the policy hasn't propagated yet or a
# future Microsoft title change slips through.
# ------------------------------------------------------------------------------
Write-Output "Querying available updates..."

try {
$Updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop `
| Where-Object {
$_.Title -notmatch "Feature update" -and
$_.Title -notmatch "25H2"
}
} catch {
Write-Error "Failed to retrieve update list: $_"
Stop-Transcript
exit 1
}

# ------------------------------------------------------------------------------
# STEP 6 — Install updates (Recommendation 2)
# Wraps installation in try/catch so a partial failure surfaces clearly in the
# log rather than silently continuing to the reboot check.
# ------------------------------------------------------------------------------
if ($Updates.Count -eq 0) {
Write-Output "No applicable updates found. Nothing to install."
} else {
Write-Output "Installing $($Updates.Count) update(s)..."
try {
$Updates | Install-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop
Write-Output "Update installation completed successfully."
} catch {
Write-Error "Update installation failed: $_"
Stop-Transcript
exit 1
}
}

# ------------------------------------------------------------------------------
# STEP 7 — Reboot only if required
# Schedules a 60-second delayed reboot with a descriptive message so users
# aren't caught off-guard. The reboot is skipped entirely when not needed.
# ------------------------------------------------------------------------------
if (Get-WURebootStatus) {
Write-Output "Reboot required. Scheduling reboot in 60 seconds..."
shutdown.exe /r /t 60 /c "System reboot required to complete Windows Updates."
} else {
Write-Output "No reboot required."
}

Stop-Transcript