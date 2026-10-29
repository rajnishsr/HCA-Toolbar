# Configure DPI awareness before Windows Forms creates any window handles.
# PS2EXE may set process DPI awareness through its embedded manifest already.
# In that case ERROR_ACCESS_DENIED means the existing process setting is locked.
$script:DpiAwarenessResult = 'Not attempted'
if (-not ('HcaEarlyDpiAwareness' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HcaEarlyDpiAwareness {
    [DllImport("user32.dll", EntryPoint="SetProcessDpiAwarenessContext", SetLastError=true)]
    private static extern bool SetContext(IntPtr value);
    [DllImport("shcore.dll", EntryPoint="SetProcessDpiAwareness", PreserveSig=true)]
    private static extern int SetAwareness(int awareness);
    [DllImport("user32.dll", EntryPoint="SetProcessDPIAware", SetLastError=true)]
    private static extern bool SetLegacy();
    public static string Initialize() {
        try {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            if (SetContext(new IntPtr(-4))) return "PerMonitorV2";
            int error = Marshal.GetLastWin32Error();
            if (error == 5) return "Already configured by host or manifest (error 5)";
        } catch (EntryPointNotFoundException) {}
          catch (DllNotFoundException) {}
        try {
            // PROCESS_PER_MONITOR_DPI_AWARE = 2
            int hr = SetAwareness(2);
            if (hr == 0) return "PerMonitorV1";
            if ((uint)hr == 0x80070005) return "Already configured by host or manifest (E_ACCESSDENIED)";
        } catch (EntryPointNotFoundException) {}
          catch (DllNotFoundException) {}
        try {
            if (SetLegacy()) return "SystemDpiAware";
        } catch (EntryPointNotFoundException) {}
          catch (DllNotFoundException) {}
        return "Could not change process DPI awareness";
    }
}
'@
}
$script:DpiAwarenessResult = [HcaEarlyDpiAwareness]::Initialize()

#requires -Version 5.1

<#
.SYNOPSIS
    Reserves the top portion of the monitor containing a specified application.

.DESCRIPTION
    Finds a pinned application's top-level window, determines which
    monitor contains it, and reserves an area at the top of that monitor.

    Other top-level application windows on that monitor are adjusted
    vertically only.

    Rules:
      - Window X position is preserved.
      - Window width is preserved.
      - Window height is preserved whenever it fits.
      - Windows overlapping the reserved area are pushed down.
      - If the preserved height no longer fits, height is reduced.
      - Full-monitor-height windows are resized to the maximum height
        available below the pinned application.
      - Windows on other monitors are untouched.
#>


# This version is based directly on the last working script.
# Console messages are suppressed; file logging is retained.
function Write-SilentMessage {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Message)
}

# Resolve the application folder for both direct .ps1 execution and PS2EXE.
# In a compiled EXE, $PSScriptRoot can be empty; use the actual process path.
$AppDirectory = $null
try {
    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $processName = [System.IO.Path]::GetFileName($processPath)
    if ($processName -notmatch '^(?i:powershell|pwsh|powershell_ise)\.exe$') {
        $AppDirectory = [System.IO.Path]::GetDirectoryName($processPath)
    }
} catch { }

if ([string]::IsNullOrWhiteSpace($AppDirectory) -and
    -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $AppDirectory = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($AppDirectory) -and
    -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $AppDirectory = [System.IO.Path]::GetDirectoryName($PSCommandPath)
}
if ([string]::IsNullOrWhiteSpace($AppDirectory)) {
    throw 'Cannot determine application directory. Run as a .ps1 or compile with PS2EXE.'
}
$AppDirectory = [System.IO.Path]::GetFullPath($AppDirectory)

# =====================================================================
# CONFIGURATION
# =====================================================================

# Process name without ".exe"
$PinnedProcessName = "Toolbar"

# Height reserved at top of monitor
# Configuration always lives alongside this script.
$ConfigPath = Join-Path -Path $AppDirectory -ChildPath 'Config.json'
$PinnedHeight = 45  # Safe fallback if Config.json cannot be read

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $settings = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $entry = @($settings.Config | Where-Object { $_.Name -eq 'Rows' })
    if ($entry.Count -ne 1) {
        throw "Expected exactly one 'Rows' entry; found $($entry.Count)."
    }
    [int]$rowCount = 0
    if (-not [int]::TryParse(([string]$entry[0].Value).Trim(), [ref]$rowCount) -or
        $rowCount -notin @(1, 2)) {
        throw "'Rows' must be 1 or 2."
    }
    $PinnedHeight = if ($rowCount -eq 1) { 45 } else { 66 }
    $ConfigHeightStatus = "Loaded Rows=$rowCount; PinnedHeight=$PinnedHeight from $ConfigPath"
} catch {
    $ConfigHeightStatus = "Unable to load toolbar height from $ConfigPath; using fallback 45 (Rows=1). $($_.Exception.Message)"
}

# Process exclusions from Config.json (comma-separated executable names).
# Windows Get-Process returns process names without the .exe extension.
$settings = $null
$script:ExcludedProcesses = @()
$ConfigExclusionStatus = 'No App Exclusion configured.'
try {
    if (-not $settings) {
        $settings = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    $exclusionEntries = @($settings.Config | Where-Object { $_.Name -eq 'App Exclusion' })
    if ($exclusionEntries.Count -gt 1) { throw 'Duplicate App Exclusion entries found.' }
    if ($exclusionEntries.Count -eq 1) {
        $script:ExcludedProcesses = @(
            ([string]$exclusionEntries[0].Value -split ',') | ForEach-Object {
                $name = $_.Trim()
                if ($name -match '(?i)\.exe$') { $name = $name.Substring(0, $name.Length - 4) }
                if ($name) { $name.ToLowerInvariant() }
            } | Select-Object -Unique
        )
    }
    $ConfigExclusionStatus = 'App Exclusion loaded: ' + ($script:ExcludedProcesses -join ', ')
} catch {
    $ConfigExclusionStatus = 'Unable to read App Exclusion; no processes excluded. ' + $_.Exception.Message
}

# Ignore minimized windows
$IgnoreMinimizedWindows = $true

# Display diagnostic output
$VerboseOutput = $false

# How often to check for newly opened or repositioned windows (milliseconds)
$MonitorIntervalMilliseconds = 750

# The toolbar publishes whether the desktop space should be reserved.
$script:VisibilityStateFile = Join-Path (Join-Path $AppDirectory 'logs') 'ToolbarVisibility.json'
$script:ReservationSuspended = $false
function Test-ToolbarReservationRequested {
    param([int]$ToolbarPid)
    try {
        if (-not (Test-Path -LiteralPath $script:VisibilityStateFile -PathType Leaf)) {
            return $true  # Backward-compatible if running an older toolbar.
        }
        $state = Get-Content -LiteralPath $script:VisibilityStateFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.ProcessId -ne $ToolbarPid) {
            return $true  # Ignore a stale signal from a different process.
        }
        return ($state.ReserveSpace -eq $true)
    } catch {
        return $true
    }
}



# =====================================================================
# LOGGING
# =====================================================================

$LogDirectory = Join-Path -Path $AppDirectory -ChildPath 'logs'
$LogBaseName = 'ReserveTopLog.log'
$MaxLogFiles = 5
$MaxLogBytes = 5MB

function Write-LogFailure {
    param([string]$Message)
    # Independent fallback: never display a message box or console prompt.
    try {
        $fallback = Join-Path -Path $AppDirectory -ChildPath 'Reserve-Top-log-errors.log'
        [System.IO.File]::AppendAllText(
            $fallback,
            ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine)
        )
    } catch {
        # Last resort: Windows Application event log is not guaranteed writable.
    }
}

function Initialize-Logging {
    try {
        [void][System.IO.Directory]::CreateDirectory($LogDirectory)
        $probe = Join-Path $LogDirectory ('.reserve-top-write-test-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok')
        [System.IO.File]::Delete($probe)
    } catch {
        Write-LogFailure ("Cannot initialize log directory '{0}': {1}" -f $LogDirectory, $_.Exception.ToString())
    }
}

function Get-LogPath { Join-Path $LogDirectory $LogBaseName }

function Rotate-Logs {
    param([long]$IncomingBytes)
    $base = Get-LogPath
    if (-not [System.IO.File]::Exists($base)) { return }
    $length = (Get-Item -LiteralPath $base -ErrorAction Stop).Length
    if (($length + $IncomingBytes) -le $MaxLogBytes) { return }
    $oldest = "$base.$($MaxLogFiles - 1)"
    if ([System.IO.File]::Exists($oldest)) { [System.IO.File]::Delete($oldest) }
    for ($i = $MaxLogFiles - 2; $i -ge 1; $i--) {
        $from = "$base.$i"
        if ([System.IO.File]::Exists($from)) {
            [System.IO.File]::Move($from, "$base.$($i + 1)")
        }
    }
    [System.IO.File]::Move($base, "$base.1")
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level='INFO'
    )
    try {
        $line = '[{0}] [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message, [Environment]::NewLine
        $bytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes($line)
        if ($bytes.Length -gt $MaxLogBytes) { return }
        $path = Get-LogPath
        Rotate-Logs -IncomingBytes $bytes.Length
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    } catch {
        Write-LogFailure ("Write-Log failed: {0}" -f $_.Exception.ToString())
    }
}

Initialize-Logging
Write-Log -Message 'Reserve-Top starting.'
Write-Log -Message ("DPI_AWARENESS Startup={0}" -f $script:DpiAwarenessResult)
Write-Log -Message $ConfigHeightStatus
Write-Log -Message $ConfigExclusionStatus
Write-Log -Message ("Actual ConfigPath={0}; LogDirectory={1}; ScriptPath={2}" -f $ConfigPath, $LogDirectory, $AppDirectory)
Write-Log -Message ("Configuration: PinnedProcessName='{0}', PinnedHeight={1}, MonitorIntervalMilliseconds={2}, IgnoreMinimizedWindows={3}" -f $PinnedProcessName, $PinnedHeight, $MonitorIntervalMilliseconds, $IgnoreMinimizedWindows)


# =====================================================================
# LOAD WINDOWS FORMS
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms



# =====================================================================
# WIN32 API
# =====================================================================

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ReserveTopWin32ChromiumV2
{
    public delegate bool EnumWindowsProc(
        IntPtr hWnd,
        IntPtr lParam
    );


    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }


    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(
        EnumWindowsProc lpEnumFunc,
        IntPtr lParam
    );


    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(
        IntPtr hWnd
    );


    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(
        IntPtr hWnd
    );


    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsZoomed(
        IntPtr hWnd
    );


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    public static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder lpString,
        int nMaxCount
    );


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    public static extern int GetWindowTextLength(
        IntPtr hWnd
    );


    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint lpdwProcessId
    );


    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(
        IntPtr hWnd,
        out RECT lpRect
    );


    [DllImport(
        "user32.dll",
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool MoveWindow(
        IntPtr hWnd,
        int X,
        int Y,
        int nWidth,
        int nHeight,
        bool bRepaint
    );


    [DllImport(
        "user32.dll",
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags
    );


    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(
        IntPtr hWnd,
        uint uCmd
    );


    public static readonly IntPtr HWND_TOPMOST =
        new IntPtr(-1);


    public const uint SWP_NOSIZE     = 0x0001;
    public const uint SWP_NOMOVE     = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW  = 0x0040;

    public const int SW_RESTORE = 9;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(
        IntPtr hWnd,
        int nCmdShow
    );

    public const uint GW_OWNER = 4;
}
"@



# =====================================================================
# HELPER FUNCTIONS
# =====================================================================

function Get-WindowTitle {

    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $Length =
        [ReserveTopWin32ChromiumV2]::GetWindowTextLength($Handle)

    if ($Length -le 0) {
        return ""
    }

    $Builder =
        New-Object System.Text.StringBuilder ($Length + 1)

    [void][ReserveTopWin32ChromiumV2]::GetWindowText(
        $Handle,
        $Builder,
        $Builder.Capacity
    )

    return $Builder.ToString()
}



function Get-WindowProcessInfo {

    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    [uint32]$ProcessId = 0

    [void][ReserveTopWin32ChromiumV2]::GetWindowThreadProcessId(
        $Handle,
        [ref]$ProcessId
    )

    if ($ProcessId -eq 0) {
        return $null
    }

    try {

        $Process =
            Get-Process `
                -Id $ProcessId `
                -ErrorAction Stop

        return [PSCustomObject]@{
            Id          = $ProcessId
            ProcessName = $Process.ProcessName
            Process     = $Process
        }

    }
    catch {

        return $null
    }
}



function Get-WindowRectangle {

    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $Rect =
        New-Object ReserveTopWin32ChromiumV2+RECT

    $Result =
        [ReserveTopWin32ChromiumV2]::GetWindowRect(
            $Handle,
            [ref]$Rect
        )

    if (-not $Result) {
        return $null
    }

    return [PSCustomObject]@{
        Left   = $Rect.Left
        Top    = $Rect.Top
        Right  = $Rect.Right
        Bottom = $Rect.Bottom
        Width  = $Rect.Right - $Rect.Left
        Height = $Rect.Bottom - $Rect.Top
    }
}



function Write-Detail {

    param(
        [string]$Message
    )

    if ($VerboseOutput) {
        Write-SilentMessage $Message
    }
}



# =====================================================================
# DISPLAY MONITORS
# =====================================================================

Write-SilentMessage ""
Write-SilentMessage "============================================================"
Write-SilentMessage " Reserve Top"
Write-SilentMessage "============================================================"
Write-SilentMessage ""

Write-SilentMessage "Detected displays:"
Write-SilentMessage ""

foreach ($Display in [System.Windows.Forms.Screen]::AllScreens) {

    $PrimaryText = ""

    if ($Display.Primary) {
        $PrimaryText = " [PRIMARY]"
    }

    Write-SilentMessage "  $($Display.DeviceName)$PrimaryText"

    Write-SilentMessage (
        "      WorkingArea : {0},{1}  {2}x{3}" -f
        $Display.WorkingArea.Left,
        $Display.WorkingArea.Top,
        $Display.WorkingArea.Width,
        $Display.WorkingArea.Height
    )

    Write-SilentMessage ""
}



# =====================================================================
# FIND PINNED APPLICATION
# =====================================================================

$script:PinnedHwnd  = [IntPtr]::Zero
$script:PinnedPid   = 0
$script:PinnedTitle = ""


$FindPinnedCallback =
    [ReserveTopWin32ChromiumV2+EnumWindowsProc] {

        param(
            [IntPtr]$hWnd,
            [IntPtr]$lParam
        )


        if (-not [ReserveTopWin32ChromiumV2]::IsWindowVisible($hWnd)) {
            return $true
        }


        $Title =
            Get-WindowTitle -Handle $hWnd


        if ([string]::IsNullOrWhiteSpace($Title)) {
            return $true
        }


        $ProcessInfo =
            Get-WindowProcessInfo -Handle $hWnd


        if ($null -eq $ProcessInfo) {
            return $true
        }


        if (
            $ProcessInfo.ProcessName -ieq
            $script:PinnedProcessName
        ) {

            $script:PinnedHwnd  = $hWnd
            $script:PinnedPid   = $ProcessInfo.Id
            $script:PinnedTitle = $Title

            return $false
        }


        return $true
    }



[void][ReserveTopWin32ChromiumV2]::EnumWindows(
    $FindPinnedCallback,
    [IntPtr]::Zero
)



# =====================================================================
# VERIFY PINNED WINDOW / INITIAL STATE
# =====================================================================

# The monitor is allowed to start while the pinned application is absent.
# In that state it only watches for the application and does not resize any
# other windows.
$script:PinnedApplicationPresent = ($script:PinnedHwnd -ne [IntPtr]::Zero)

if (-not $script:PinnedApplicationPresent) {
    Write-Log -Message "Pinned application '$PinnedProcessName' is not currently present. Monitoring only; no application windows will be resized until it appears."
    
}


# =====================================================================
# INITIALIZE PINNED APPLICATION STATE
# =====================================================================

$script:TargetScreen = $null
$script:LastValidTargetScreen = $null
$script:LastValidWorkingArea = $null
$script:ApplicationTop = 0
$script:ApplicationBottom = 0
$script:MaximumApplicationHeight = 0

$TopMostFlags =
    [ReserveTopWin32ChromiumV2]::SWP_NOSIZE -bor
    [ReserveTopWin32ChromiumV2]::SWP_NOMOVE -bor
    [ReserveTopWin32ChromiumV2]::SWP_NOACTIVATE

# Verify the toolbar geometry only while its reservation is active.
# This does not attempt to fix compositor or DPI rendering artifacts.
function Assert-PinnedToolbarBounds {
    if ($script:PinnedHwnd -eq [IntPtr]::Zero) { return }
    $screen = [System.Windows.Forms.Screen]::FromHandle($script:PinnedHwnd)
    $bounds = $screen.Bounds
    $rect = Get-WindowRectangle -Handle $script:PinnedHwnd
    if ($null -eq $rect) { return }
    $expectedWidth = [int]$bounds.Width
    $expectedHeight = [int]$PinnedHeight
    if ($rect.Left -eq $bounds.Left -and $rect.Top -eq $bounds.Top -and
        $rect.Width -eq $expectedWidth -and $rect.Height -eq $expectedHeight) {
        return
    }
    $ok = [ReserveTopWin32ChromiumV2]::MoveWindow(
        $script:PinnedHwnd, $bounds.Left, $bounds.Top,
        $expectedWidth, $expectedHeight, $true
    )
    $after = Get-WindowRectangle -Handle $script:PinnedHwnd
    Write-Log -Message ("TOOLBAR_BOUNDS_ENFORCED Monitor='{0}' Old=({1},{2},{3},{4}) Expected=({5},{6},{7},{8}) Success={9} Actual=({10},{11},{12},{13})" -f
        $screen.DeviceName, $rect.Left, $rect.Top, $rect.Width, $rect.Height,
        $bounds.Left, $bounds.Top, $expectedWidth, $expectedHeight, $ok,
        $after.Left, $after.Top, $after.Width, $after.Height)
}

function Initialize-PinnedApplication {
    if ($script:PinnedHwnd -eq [IntPtr]::Zero) { return $false }

    $PinnedRect = Get-WindowRectangle -Handle $script:PinnedHwnd
    if ($null -eq $PinnedRect) { return $false }

    $script:TargetScreen = [System.Windows.Forms.Screen]::FromHandle($script:PinnedHwnd)
    $WorkingArea = $script:TargetScreen.WorkingArea

    if ($PinnedHeight -le 0 -or $PinnedHeight -ge $WorkingArea.Height) {
        Write-Log -Level ERROR -Message "PinnedHeight is invalid for the target monitor."
        return $false
    }

    $script:LastValidTargetScreen = $script:TargetScreen
    $script:LastValidWorkingArea = $WorkingArea
    $script:ApplicationTop = $WorkingArea.Top + $PinnedHeight
    $script:ApplicationBottom = $WorkingArea.Bottom
    $script:MaximumApplicationHeight = $WorkingArea.Height - $PinnedHeight

    # Use the target monitor's full width, not the toolbar's previous width.
    Assert-PinnedToolbarBounds

    [void][ReserveTopWin32ChromiumV2]::SetWindowPos(
        $script:PinnedHwnd, [ReserveTopWin32ChromiumV2]::HWND_TOPMOST,
        0, 0, 0, 0, $TopMostFlags
    )

    $script:PinnedApplicationPresent = $true
    Write-Log -Message "Pinned application active. PID: $($script:PinnedPid). Resizing is enabled."
    return $true
}

if ($script:PinnedApplicationPresent) {
    if (Test-ToolbarReservationRequested -ToolbarPid $script:PinnedPid) {
        [void](Initialize-PinnedApplication)
    } else {
        $script:ReservationSuspended = $true
        Write-Log -Message 'Toolbar initially hidden; reservation will begin when unhidden.'
    }
}


# =====================================================================
# ENUMERATE APPLICATION WINDOWS
# =====================================================================

$script:WindowsExamined = 0
$script:WindowsMoved    = 0
$script:WindowsResized  = 0
$script:WindowsUnchanged = 0
$script:WindowsSkipped  = 0


$ResizeCallback =
    [ReserveTopWin32ChromiumV2+EnumWindowsProc] {

        param(
            [IntPtr]$hWnd,
            [IntPtr]$lParam
        )


        $script:WindowsExamined++


        # -------------------------------------------------------------
        # IGNORE PINNED WINDOW
        # -------------------------------------------------------------

        if ($hWnd -eq $script:PinnedHwnd) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # IGNORE INVISIBLE WINDOWS
        # -------------------------------------------------------------

        if (-not [ReserveTopWin32ChromiumV2]::IsWindowVisible($hWnd)) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # IGNORE MINIMIZED WINDOWS
        # -------------------------------------------------------------

        if (
            $script:IgnoreMinimizedWindows -and
            [ReserveTopWin32ChromiumV2]::IsIconic($hWnd)
        ) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # GET TITLE
        # -------------------------------------------------------------

        $Title =
            Get-WindowTitle -Handle $hWnd


        if ([string]::IsNullOrWhiteSpace($Title)) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # IGNORE OWNED WINDOWS / DIALOGS
        # -------------------------------------------------------------

        $Owner =
            [ReserveTopWin32ChromiumV2]::GetWindow(
                $hWnd,
                [ReserveTopWin32ChromiumV2]::GW_OWNER
            )


        if ($Owner -ne [IntPtr]::Zero) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # DETERMINE MONITOR
        # -------------------------------------------------------------

        try {

            $WindowScreen =
                [System.Windows.Forms.Screen]::FromHandle(
                    $hWnd
                )

        }
        catch {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # ONLY MODIFY WINDOWS ON PINNED APPLICATION'S MONITOR
        # -------------------------------------------------------------

        if (
            $WindowScreen.DeviceName -ne
            $script:TargetScreen.DeviceName
        ) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # PROCESS INFORMATION
        # -------------------------------------------------------------

        $ProcessInfo =
            Get-WindowProcessInfo -Handle $hWnd


        if ($null -eq $ProcessInfo) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # IGNORE OTHER WINDOWS BELONGING TO PINNED PROCESS
        # -------------------------------------------------------------

        if (
            $ProcessInfo.ProcessName -ieq
            $script:PinnedProcessName
        ) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # SKIP CONFIGURED APPLICATIONS ON THE TOOLBAR MONITOR
        # -------------------------------------------------------------
        # Monitor selection was checked above; match the owning process,
        # not the window title, so every window of that application is skipped.
        $normalizedProcess = ([string]$ProcessInfo.ProcessName).Trim().ToLowerInvariant()
        $isExcluded = $script:ExcludedProcesses -contains $normalizedProcess
        # Windows Calculator may have an ApplicationFrameHost-owned top-level window.
        # For that host only, use the window title to identify Calculator.
        if (-not $isExcluded -and
            $normalizedProcess -eq 'applicationframehost' -and
            $script:ExcludedProcesses -contains 'calculator' -and
            $Title -match '(?i)^calculator(?:\s|$)') {
            $isExcluded = $true
        }
        if ($isExcluded) {
            Write-Log -Message ("EXCLUDED [{0}] {1}" -f $ProcessInfo.ProcessName, $Title)
            $script:WindowsSkipped++
            return $true
        }

        # -------------------------------------------------------------
        # GET CURRENT WINDOW RECTANGLE
        # -------------------------------------------------------------

        $Rect =
            Get-WindowRectangle -Handle $hWnd


        if ($null -eq $Rect) {

            $script:WindowsSkipped++

            return $true
        }


        # -------------------------------------------------------------
        # SAVE ORIGINAL DIMENSIONS
        # -------------------------------------------------------------

        $OriginalLeft   = $Rect.Left
        $OriginalTop    = $Rect.Top
        $OriginalWidth  = $Rect.Width
        $OriginalHeight = $Rect.Height
        $OriginalBottom = $Rect.Bottom


        # -------------------------------------------------------------
        # DEFAULT:
        #
        # Preserve EVERYTHING.
        # -------------------------------------------------------------

        $NewLeft   = $OriginalLeft
        $NewTop    = $OriginalTop
        $NewWidth  = $OriginalWidth
        $NewHeight = $OriginalHeight



        # =============================================================
        # RULE 1
        #
        # If the window starts inside the reserved area,
        # push it down.
        # =============================================================

        if ($NewTop -lt $script:ApplicationTop) {

            $NewTop =
                $script:ApplicationTop
        }



        # =============================================================
        # RULE 2
        #
        # Determine whether the window was effectively full-height.
        #
        # A few pixels of tolerance are allowed because window borders,
        # DWM and maximized windows can produce slightly different
        # dimensions.
        # =============================================================

        $HeightTolerance = 10


        $IsFullHeight =
            (
                $OriginalHeight -ge
                ($script:TargetScreen.WorkingArea.Height - $HeightTolerance)
            )



        # =============================================================
        # RULE 3
        #
        # If it was full monitor height, make its new height equal
        # to all available space beneath the pinned application.
        #
        # WIDTH IS NOT CHANGED.
        # =============================================================

        if ($IsFullHeight) {

            $NewTop =
                $script:ApplicationTop

            $NewHeight =
                $script:MaximumApplicationHeight
        }



        # =============================================================
        # RULE 4
        #
        # Normal-sized window:
        #
        # Preserve its original height unless that would cause the
        # bottom to extend beyond the monitor.
        # =============================================================

        else {

            $NewBottom =
                $NewTop + $NewHeight


            if (
                $NewBottom -gt
                $script:ApplicationBottom
            ) {

                $NewHeight =
                    $script:ApplicationBottom -
                    $NewTop
            }
        }



        # =============================================================
        # SAFETY
        #
        # Do not attempt invalid window dimensions.
        # =============================================================

        if ($NewHeight -le 0) {

            Write-Detail (
                "SKIP  No usable vertical space: $Title"
            )

            $script:WindowsSkipped++

            return $true
        }



        # =============================================================
        # DETERMINE WHETHER ANYTHING ACTUALLY CHANGED
        # =============================================================

        $PositionChanged =
            ($NewTop -ne $OriginalTop)


        $HeightChanged =
            ($NewHeight -ne $OriginalHeight)



        if (
            -not $PositionChanged -and
            -not $HeightChanged
        ) {

            Write-Detail (
                "KEEP  [$($ProcessInfo.ProcessName)] $Title"
            )

            $script:WindowsUnchanged++

            return $true
        }



        # =============================================================
        # DISPLAY CHANGE
        # =============================================================

        Write-SilentMessage ""
        Write-Log -Message ("ADJUST [{0}] {1}" -f $ProcessInfo.ProcessName, $Title)

        Write-SilentMessage (
            "  Position : ({0},{1}) -> ({0},{2})" -f
            $OriginalLeft,
            $OriginalTop,
            $NewTop
        )

        Write-SilentMessage (
            "  Width    : {0} -> {0}  [UNCHANGED]" -f
            $OriginalWidth
        )

        Write-SilentMessage (
            "  Height   : {0} -> {1}" -f
            $OriginalHeight,
            $NewHeight
        )


        if ($IsFullHeight) {

            Write-Log -Message "  Reason: Full-height window"

        }
        elseif ($HeightChanged) {

            Write-Log -Message "  Reason: Moved below pinned window and shortened to fit"

        }
        else {

            Write-Log -Message "  Reason: Moved below pinned window; original size preserved"
        }



        # =============================================================
        # APPLY NEW POSITION / HEIGHT
        #
        # Notice:
        #
        #     X     = original
        #     Width = original
        #
        # Only Y and Height can change.
        # =============================================================

        # Chromium browsers (Edge/Chrome) can immediately reapply their
        # maximized placement after MoveWindow. Restore a maximized window
        # first, then explicitly place it in the usable area. This also works
        # for other applications that maintain a maximized state.
        $WasMaximized = [ReserveTopWin32ChromiumV2]::IsZoomed($hWnd)

        if ($WasMaximized) {
            [void][ReserveTopWin32ChromiumV2]::ShowWindow(
                $hWnd,
                [ReserveTopWin32ChromiumV2]::SW_RESTORE
            )

            # Give the application a moment to finish its restore transition
            # before applying the final coordinates.
            Start-Sleep -Milliseconds 25
        }

        $SetPosFlags =
            [ReserveTopWin32ChromiumV2]::SWP_NOACTIVATE -bor
            [ReserveTopWin32ChromiumV2]::SWP_SHOWWINDOW

        $Result =
            [ReserveTopWin32ChromiumV2]::SetWindowPos(
                $hWnd,
                [IntPtr]::Zero,
                $OriginalLeft,
                $NewTop,
                $OriginalWidth,
                $NewHeight,
                $SetPosFlags
            )


        if ($Result) {

            Write-Log -Message ("  Geometry: ({0},{1}) {2}x{3} -> ({4},{5}) {6}x{7}" -f $OriginalLeft,$OriginalTop,$OriginalWidth,$OriginalHeight,$OriginalLeft,$NewTop,$OriginalWidth,$NewHeight)
            Write-Log -Message ("WINDOW_ADJUSTED Process='{0}' Title='{1}' Handle='{2}' Monitor='{3}' Old=({4},{5},{6},{7}) New=({8},{9},{10},{11}) Action='{12}'" -f $ProcessInfo.ProcessName, ($Title -replace "'", "''"), $hWnd, $script:TargetScreen.DeviceName, $OriginalLeft, $OriginalTop, $OriginalWidth, $OriginalHeight, $OriginalLeft, $NewTop, $OriginalWidth, $NewHeight, $(if ($HeightChanged) { 'RESIZED' } else { 'MOVED' }))

            if ($HeightChanged) {
                $script:WindowsResized++
            }
            else {
                $script:WindowsMoved++
            }

        }
        else {

            Write-Log -Level WARN -Message (
                "Could not adjust: {0} - {1}" -f
                $ProcessInfo.ProcessName,
                $Title
            )
        }


        return $true
    }



# =====================================================================
# RELEASE MANAGED WINDOWS
# =====================================================================

function Restore-ManagedWindows {
    if ($null -eq $script:LastValidTargetScreen -or $null -eq $script:LastValidWorkingArea) { return }

    $script:ReleaseScreen = $script:LastValidTargetScreen
    $script:ReleaseWorkingArea = $script:LastValidWorkingArea
    $script:ReleaseTop = $script:ReleaseWorkingArea.Top
    $script:ReleaseBottom = $script:ReleaseWorkingArea.Bottom
    $script:ManagedBoundaryTop = $script:ReleaseWorkingArea.Top + $PinnedHeight

    $ReleaseCallback = [ReserveTopWin32ChromiumV2+EnumWindowsProc] {
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [ReserveTopWin32ChromiumV2]::IsWindowVisible($hWnd)) { return $true }
        if ($script:IgnoreMinimizedWindows -and [ReserveTopWin32ChromiumV2]::IsIconic($hWnd)) { return $true }
        $Title = Get-WindowTitle -Handle $hWnd
        if ([string]::IsNullOrWhiteSpace($Title)) { return $true }
        $Owner = [ReserveTopWin32ChromiumV2]::GetWindow($hWnd, [ReserveTopWin32ChromiumV2]::GW_OWNER)
        if ($Owner -ne [IntPtr]::Zero) { return $true }

        try { $WindowScreen = [System.Windows.Forms.Screen]::FromHandle($hWnd) } catch { return $true }
        if ($WindowScreen.DeviceName -ne $script:ReleaseScreen.DeviceName) { return $true }

        $Rect = Get-WindowRectangle -Handle $hWnd
        if ($null -eq $Rect) { return $true }

        # Restore only windows that are still aligned to the boundary created
        # by MyApplication. This is a one-time reversal of our own layout.
        if ([Math]::Abs($Rect.Top - $script:ManagedBoundaryTop) -le 32) {
            $NewTop = $script:ReleaseTop
            $NewHeight = $Rect.Height

            if ([Math]::Abs($Rect.Bottom - $script:ReleaseBottom) -le 32) {
                $NewHeight = [Math]::Min($Rect.Height + $PinnedHeight, $script:ReleaseWorkingArea.Height)
            }

            if ([ReserveTopWin32ChromiumV2]::IsZoomed($hWnd)) {
                [void][ReserveTopWin32ChromiumV2]::ShowWindow($hWnd, [ReserveTopWin32ChromiumV2]::SW_RESTORE)
                Start-Sleep -Milliseconds 25
            }

            $Flags = [ReserveTopWin32ChromiumV2]::SWP_NOACTIVATE -bor [ReserveTopWin32ChromiumV2]::SWP_SHOWWINDOW
            $restored = [ReserveTopWin32ChromiumV2]::SetWindowPos(
                $hWnd, [IntPtr]::Zero, $Rect.Left, $NewTop, $Rect.Width, $NewHeight, $Flags
            )
            $processInfo = Get-WindowProcessInfo -Handle $hWnd
            $processName = if ($null -ne $processInfo) { [string]$processInfo.ProcessName } else { 'Unknown' }
            if ($restored) {
                Write-Log -Message ("WINDOW_RESTORED Process='{0}' Title='{1}' Handle='{2}' Monitor='{3}' Old=({4},{5},{6},{7}) New=({8},{9},{10},{11}) Action='{12}'" -f $processName, ($Title -replace "'", "''"), $hWnd, $script:ReleaseScreen.DeviceName, $Rect.Left, $Rect.Top, $Rect.Width, $Rect.Height, $Rect.Left, $NewTop, $Rect.Width, $NewHeight, $(if ($NewHeight -ne $Rect.Height) { 'RESIZED' } else { 'MOVED' }))
            } else {
                Write-Log -Level WARN -Message ("WINDOW_RESTORE_FAILED Process='{0}' Title='{1}' Handle='{2}'" -f $processName, ($Title -replace "'", "''"), $hWnd)
            }
        }
        return $true
    }

    [void][ReserveTopWin32ChromiumV2]::EnumWindows($ReleaseCallback, [IntPtr]::Zero)
}


# =====================================================================
# CONTINUOUS STATE-BASED MONITORING
# =====================================================================

Write-SilentMessage ""
Write-Log -Message "Monitoring for $PinnedProcessName."
Write-SilentMessage "Press Ctrl+C to stop."
Write-SilentMessage ""

try {
    while ($true) {
        if ($script:PinnedApplicationPresent) {
            # Only enforce application resizing while MyApplication exists.
            $PinnedRectNow = Get-WindowRectangle -Handle $script:PinnedHwnd

            if ($null -eq $PinnedRectNow) {
                Write-Log -Level WARN -Message "Pinned application window closed. Restoring managed windows once; resizing is now disabled."

                # PRESENT -> ABSENT transition: undo the reserved area exactly once.
                Restore-ManagedWindows

                $script:PinnedApplicationPresent = $false
                $script:PinnedHwnd = [IntPtr]::Zero
                $script:PinnedPid = 0
                $script:PinnedTitle = ""
				
				Write-Log -Message "Managed windows restored. Reserve-Top is exiting."

				break
            }
            elseif (-not (Test-ToolbarReservationRequested -ToolbarPid $script:PinnedPid)) {
                # Hide transition: release applications once; do not move the
                # toolbar itself, which manages its own auto-hide position.
                if (-not $script:ReservationSuspended) {
                    Restore-ManagedWindows
                    $script:ReservationSuspended = $true
                    Write-Log -Message 'RESERVATION_RELEASED Reason=ToolbarHiddenOrUndocked; see WINDOW_RESTORED entries above.'
                }
            }
            else {
                if ($script:ReservationSuspended) {
                    $script:ReservationSuspended = $false
                    [void](Initialize-PinnedApplication)
                    Write-Log -Message 'RESERVATION_APPLIED Reason=ToolbarUnhiddenOrRedocked; see WINDOW_ADJUSTED entries.'
                }
                # Visibility JSON includes Monitor and MonitorBounds for
                # diagnostics. Actual window handle determines monitor.
                # On a monitor transition, restore the previous monitor
                # BEFORE overwriting LastValidTargetScreen / WorkingArea.
                $nextScreen = [System.Windows.Forms.Screen]::FromHandle($script:PinnedHwnd)
                if ($null -ne $script:LastValidTargetScreen -and
                    $nextScreen.DeviceName -ne $script:LastValidTargetScreen.DeviceName) {
                    Write-Log -Message ("MONITOR_CHANGED From='{0}' To='{1}'" -f
                        $script:LastValidTargetScreen.DeviceName, $nextScreen.DeviceName)
                    Restore-ManagedWindows
                    [void](Initialize-PinnedApplication)
                }
                # Refresh valid geometry and enforce the reserved area.
                $script:TargetScreen = [System.Windows.Forms.Screen]::FromHandle($script:PinnedHwnd)
                $WorkingArea = $script:TargetScreen.WorkingArea
                $script:LastValidTargetScreen = $script:TargetScreen
                $script:LastValidWorkingArea = $WorkingArea
                $script:ApplicationTop = $WorkingArea.Top + $PinnedHeight
                $script:ApplicationBottom = $WorkingArea.Bottom
                $script:MaximumApplicationHeight = $WorkingArea.Height - $PinnedHeight

                Assert-PinnedToolbarBounds
                [void][ReserveTopWin32ChromiumV2]::EnumWindows($ResizeCallback, [IntPtr]::Zero)
            }
        }
        else {
            # ABSENT state: discovery only. Do NOT enumerate ResizeCallback and
            # do NOT alter any other application windows.
            $script:PinnedHwnd = [IntPtr]::Zero
            [void][ReserveTopWin32ChromiumV2]::EnumWindows($FindPinnedCallback, [IntPtr]::Zero)

            if ($script:PinnedHwnd -ne [IntPtr]::Zero) {
                if (-not (Test-ToolbarReservationRequested -ToolbarPid $script:PinnedPid)) {
                    # Toolbar was found, but is currently hidden.
                    $script:PinnedApplicationPresent = $true
                    $script:ReservationSuspended = $true
                    Write-Log -Message 'Toolbar detected in hidden mode. Reservation is suspended.'
                }
                elseif (Initialize-PinnedApplication) {
                    Write-Log -Message "Pinned application detected. Reserved-area resizing is enabled."
                    # Apply the layout immediately instead of waiting one interval.
                    [void][ReserveTopWin32ChromiumV2]::EnumWindows($ResizeCallback, [IntPtr]::Zero)
                }
                else {
                    $script:PinnedHwnd = [IntPtr]::Zero
                    $script:PinnedPid = 0
                    $script:PinnedTitle = ""
                    $script:PinnedApplicationPresent = $false
                }
            }
        }

        Start-Sleep -Milliseconds $MonitorIntervalMilliseconds
    }
}
finally {
    # Do not remove state while a toolbar process still owns it.
    try {
        if (Test-Path -LiteralPath $script:VisibilityStateFile -PathType Leaf) {
            $state = Get-Content -LiteralPath $script:VisibilityStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $owner = Get-Process -Id ([int]$state.ProcessId) -ErrorAction SilentlyContinue
            if ($null -eq $owner) {
                Remove-Item -LiteralPath $script:VisibilityStateFile -Force -ErrorAction Stop
                Write-Log -Message 'Removed orphaned ToolbarVisibility.json during Reserve-Top shutdown.'
            }
        }
    } catch {
        Write-Log -Level WARNING -Message ("Visibility-state cleanup failed: {0}" -f $_.Exception.Message)
    }
    Write-SilentMessage ""
    Write-SilentMessage "============================================================"
    Write-Log -Message "Monitoring stopped."
    Write-SilentMessage " Monitoring stopped"
    Write-SilentMessage "============================================================"
    Write-SilentMessage ""
}
