# =============================================================================
# Get-CrashLogs.ps1
# Consolidates system crash and critical error logs from Windows Event Viewer
# into a single timestamped text report.
#
# Usage:
#   Run as Administrator in PowerShell:
#   .\Get-CrashLogs.ps1
#
#   Optional parameters:
#   .\Get-CrashLogs.ps1 -DaysBack 30 -OutputPath "C:\Logs\CrashReport.txt"
# =============================================================================

param (
    [int]$DaysBack   = 7,
    [string]$OutputPath = "$env:USERPROFILE\Desktop\CrashLogs_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').txt"
)

# --- Privilege Check ----------------------------------------------------------
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script should be run as Administrator to access all event logs."
    Write-Warning "Some logs may be missing or incomplete."
    Write-Host ""
}

# --- Configuration ------------------------------------------------------------
$startTime  = (Get-Date).AddDays(-$DaysBack)
$reportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Event sources and IDs that indicate crashes, BSODs, or critical failures
$eventSources = @(
    # --- System Log ---
    @{
        LogName = "System"
        Sources = @(
            # Kernel-Power: unexpected shutdown / power loss
            @{ ProviderName = "Microsoft-Windows-Kernel-Power"; Id = 41  },
            # BugCheck: BSOD / kernel crash
            @{ ProviderName = "Microsoft-Windows-WER-SystemErrorReporting"; Id = 1001 },
            # Unexpected reboot
            @{ ProviderName = "EventLog"; Id = 6008 },
            # Windows Error Reporting
            @{ ProviderName = "Microsoft-Windows-WER-Diag"; Id = 1001 }
        )
    },
    # --- Application Log ---
    @{
        LogName = "Application"
        Sources = @(
            # Application crashes (Windows Error Reporting)
            @{ ProviderName = "Windows Error Reporting"; Id = 1001 },
            # .NET runtime errors
            @{ ProviderName = ".NET Runtime"; Id = 1026 },
            # Application hang
            @{ ProviderName = "Application Hang"; Id = 1002 }
        )
    }
)

# --- Helpers ------------------------------------------------------------------
function Write-Section {
    param([string]$Title, [System.IO.StreamWriter]$Writer)
    $line = "=" * 80
    $Writer.WriteLine($line)
    $Writer.WriteLine("  $Title")
    $Writer.WriteLine($line)
    $Writer.WriteLine()
}

function Write-EventEntry {
    param(
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,
        [System.IO.StreamWriter]$Writer
    )

    $Writer.WriteLine("  Time        : $($Event.TimeCreated)")
    $Writer.WriteLine("  Log         : $($Event.LogName)")
    $Writer.WriteLine("  Event ID    : $($Event.Id)")
    $Writer.WriteLine("  Level       : $($Event.LevelDisplayName)")
    $Writer.WriteLine("  Source      : $($Event.ProviderName)")
    $Writer.WriteLine("  Computer    : $($Event.MachineName)")

    # Attempt to get the formatted message
    try {
        $msg = $Event.FormatDescription()
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = "(No message available — may require provider DLL)"
        }
    } catch {
        $msg = "(Could not retrieve message: $($_.Exception.Message))"
    }

    # Wrap long lines for readability
    $wrapped = ($msg -split "`r?`n") | ForEach-Object { "    $_" }
    $Writer.WriteLine("  Message     :")
    $wrapped | ForEach-Object { $Writer.WriteLine($_) }
    $Writer.WriteLine("  " + ("-" * 76))
    $Writer.WriteLine()
}

# --- Collect Events -----------------------------------------------------------
Write-Host "`nCollecting crash/critical events from the last $DaysBack day(s)..." -ForegroundColor Cyan
$allEvents = [System.Collections.Generic.List[object]]::new()

foreach ($source in $eventSources) {
    foreach ($entry in $source.Sources) {
        try {
            $filter = @{
                LogName      = $source.LogName
                ProviderName = $entry.ProviderName
                Id           = $entry.Id
                StartTime    = $startTime
            }
            $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
            foreach ($e in $events) { $allEvents.Add($e) }
            Write-Host "  [OK] $($source.LogName) / $($entry.ProviderName) (ID $($entry.Id)): $($events.Count) event(s)" -ForegroundColor Green
        } catch [System.Exception] {
            if ($_.Exception.Message -like "*No events were found*") {
                Write-Host "  [--] $($source.LogName) / $($entry.ProviderName) (ID $($entry.Id)): No events in range" -ForegroundColor DarkGray
            } else {
                Write-Host "  [!!] $($source.LogName) / $($entry.ProviderName) (ID $($entry.Id)): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# Sort all collected events newest-first
$allEvents = $allEvents | Sort-Object TimeCreated -Descending

# --- Write Report -------------------------------------------------------------
Write-Host "`nWriting report to: $OutputPath" -ForegroundColor Cyan

$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.Encoding]::UTF8)

try {
    # Report header
    Write-Section -Title "SYSTEM CRASH LOG REPORT" -Writer $writer
    $writer.WriteLine("  Generated   : $reportTime")
    $writer.WriteLine("  Computer    : $env:COMPUTERNAME")
    $writer.WriteLine("  User        : $env:USERNAME")
    $writer.WriteLine("  Period      : Last $DaysBack day(s)  (from $($startTime.ToString('yyyy-MM-dd HH:mm:ss')))")
    $writer.WriteLine("  Total Events: $($allEvents.Count)")
    $writer.WriteLine()

    if ($allEvents.Count -eq 0) {
        $writer.WriteLine("  No crash or critical events found in the specified time period.")
        $writer.WriteLine()
    } else {
        # Summary table
        Write-Section -Title "SUMMARY" -Writer $writer
        $summary = $allEvents | Group-Object Id, ProviderName | Sort-Object Count -Descending
        $writer.WriteLine("  {0,-10} {1,-50} {2}" -f "Event ID", "Source", "Count")
        $writer.WriteLine("  " + "-" * 76)
        foreach ($g in $summary) {
            $parts   = $g.Name -split ", ", 2
            $eventId = $parts[0].Trim()
            $source  = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "Unknown" }
            $writer.WriteLine("  {0,-10} {1,-50} {2}" -f $eventId, $source, $g.Count)
        }
        $writer.WriteLine()

        # Detailed entries
        Write-Section -Title "DETAILED EVENT LOG (newest first)" -Writer $writer
        foreach ($event in $allEvents) {
            Write-EventEntry -Event $event -Writer $writer
        }
    }

    # Footer
    $writer.WriteLine("=" * 80)
    $writer.WriteLine("  END OF REPORT")
    $writer.WriteLine("=" * 80)

} finally {
    $writer.Close()
    $writer.Dispose()
}

# --- Done ---------------------------------------------------------------------
Write-Host "`nDone! Found $($allEvents.Count) event(s)." -ForegroundColor Cyan
Write-Host "Report saved to: $OutputPath`n" -ForegroundColor Green

# Open the file automatically
if (Test-Path $OutputPath) {
    Start-Process notepad.exe $OutputPath
}
