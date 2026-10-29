# ToolbarApp.ps1
# Windows PowerShell 5.1+ / PowerShell 7+ on Windows
# Reads Buttons.json as the master catalog and ToolbarConfig.json as the user's selection.

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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Single-instance guard: shared by .ps1 and compiled .exe instances in the
# same interactive Windows session. The first process owns the mutex until exit.
$script:ToolbarInstanceMutex = $null
$script:ToolbarOwnsMutex = $false
try {
    $script:ToolbarInstanceMutex = New-Object System.Threading.Mutex(
        $false, 'Local\HCA_ToolbarApp_SingleInstance'
    )
    try {
        $script:ToolbarOwnsMutex = $script:ToolbarInstanceMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # The prior owner terminated unexpectedly; we now own the mutex.
        $script:ToolbarOwnsMutex = $true
    }
    if (-not $script:ToolbarOwnsMutex) {
        # A toolbar is already running. Do not start another copy.
        $script:ToolbarInstanceMutex.Dispose()
        return
    }
} catch {
    if ($script:ToolbarInstanceMutex) {
        $script:ToolbarInstanceMutex.Dispose()
    }
    throw "Unable to establish toolbar single-instance protection: $($_.Exception.Message)"
}

#$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Get the folder where the script or compiled EXE is located.
if ($PSScriptRoot) {
    # Running as a .ps1 script
    $AppDir = $PSScriptRoot
}
else {
    # Running from a packaged executable
    $AppDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Config.json is the single source for deployment settings.

# Shared visibility signal read by Reserve-Top.exe. The PID prevents stale
# state left by an earlier run from hiding a different toolbar instance.
$script:VisibilityDirectory = Join-Path $AppDir 'logs'
$script:VisibilityStateFile = Join-Path $script:VisibilityDirectory 'ToolbarVisibility.json'
function Publish-ToolbarVisibility {
    param([bool]$Visible)
    try {
        if (-not (Test-Path -LiteralPath $script:VisibilityDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:VisibilityDirectory -Force -ErrorAction Stop | Out-Null
        }
        $currentScreen = [System.Windows.Forms.Screen]::FromControl($form)
        $monitorBounds = $currentScreen.Bounds
        $payload = @{
            ProcessId = $PID
            ReserveSpace = $Visible
            Monitor = $currentScreen.DeviceName
            MonitorBounds = @{
                X = $monitorBounds.X
                Y = $monitorBounds.Y
                Width = $monitorBounds.Width
                Height = $monitorBounds.Height
            }
        } | ConvertTo-Json -Compress
        $tempFile = "$($script:VisibilityStateFile).$PID.tmp"
        [System.IO.File]::WriteAllText($tempFile, $payload)
        Move-Item -LiteralPath $tempFile -Destination $script:VisibilityStateFile -Force
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Could not publish toolbar visibility: {0}" -f $_.Exception.Message)
    }
}

function Remove-ToolbarVisibilityState {
    try {
        if (-not (Test-Path -LiteralPath $script:VisibilityStateFile -PathType Leaf)) { return }
        $state = Get-Content -LiteralPath $script:VisibilityStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.ProcessId -eq $PID) {
            Remove-Item -LiteralPath $script:VisibilityStateFile -Force -ErrorAction Stop
        }
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Visibility-state cleanup failed: {0}" -f $_.Exception.Message)
    }
}

# Reserve desktop space only when the toolbar is visible AND docked.
# Reserve-Top reads the same state file used by Hide / Unhide.
function Publish-ToolbarReservationState {
    $isDocked = -not $script:ToolbarHasBeenParked
    $isVisible = $form.Visible -and -not $script:ToolbarAutoHidden
    $reserve = $isDocked -and $isVisible
    Publish-ToolbarVisibility -Visible $reserve
    Write-ToolbarLog -Message ("RESERVATION_STATE Docked={0} Visible={1} ReserveSpace={2}" -f $isDocked, $isVisible, $reserve)
}

$SettingsFile = Join-Path $AppDir 'Config.json'
if (-not (Test-Path -LiteralPath $SettingsFile -PathType Leaf)) {
    throw "Toolbar settings file not found: $SettingsFile"
}
try {
    $settingsDocument = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Cannot read Config.json at '$SettingsFile'. Check JSON syntax. $($_.Exception.Message)"
}
$settings = @{}
foreach ($entry in @($settingsDocument.Config)) {
    $name = [string]$entry.Name
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $settings[$name] = [string]$entry.Value
    }
}
function Get-RequiredToolbarSetting {
    param([string]$Name)
    if (-not $settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($settings[$Name])) {
        throw "Config.json is missing a value for '$Name'."
    }
    return $settings[$Name]
}
function Resolve-ToolbarSettingPath {
    param([string]$Value)
    $path = [Environment]::ExpandEnvironmentVariables($Value)
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $AppDir $path
    }
    return $path
}
$ConfigFile = Resolve-ToolbarSettingPath (Get-RequiredToolbarSetting 'User Button File')
# Read the registry location from Config.json ("Genshare Registry").
# Expected: HKLM\SOFTWARE\SSOProvider\ISXAgent:Type
# For compatibility, also accept the older log-format string in Config.json.
$genshareRegistrySetting = (Get-RequiredToolbarSetting 'Genshare Registry').Trim()
$registrySpecification = $genshareRegistrySetting
if ($registrySpecification -match "['""]((?:HKLM|HKEY_LOCAL_MACHINE|Registry::HKEY_LOCAL_MACHINE)\\[^'""]+:[^'""]+)['""]") {
    $registrySpecification = $Matches[1]
}
$separator = $registrySpecification.LastIndexOf(':')
if ($separator -le 0 -or $separator -eq $registrySpecification.Length - 1) {
    throw "Invalid 'Genshare Registry' setting. Expected HKLM\SOFTWARE\SSOProvider\ISXAgent:Type."
}
$registryKey = $registrySpecification.Substring(0, $separator)
$registryValueName = $registrySpecification.Substring($separator + 1)
if ($registryKey -match '^HKLM\\') {
    $registryKey = 'Registry::HKEY_LOCAL_MACHINE\' + $registryKey.Substring(5)
} elseif ($registryKey -match '^HKEY_LOCAL_MACHINE\\') {
    $registryKey = 'Registry::' + $registryKey
} elseif ($registryKey -notmatch '^Registry::HKEY_LOCAL_MACHINE\\') {
    throw "Genshare Registry must specify an HKLM registry key."
}
$script:MasterSelectionReason = 'Registry value not found'
$script:SSOProviderType = $null
$masterSettingName = 'Master Button File'
try {
    $registryValue = Get-ItemPropertyValue -LiteralPath $registryKey -Name $registryValueName -ErrorAction Stop
    $script:SSOProviderType = [string]$registryValue
    if ([string]$registryValue -eq '2') {
        $masterSettingName = 'Master Button Genshare File'
        $script:MasterSelectionReason = 'Registry Type=2'
    } else {
        $script:MasterSelectionReason = "Registry Type=$registryValue (not 2)"
    }
} catch {
    $script:MasterSelectionReason = "Registry unavailable: $($_.Exception.Message)"
}
$script:GenshareRegistryLocation = "$($registryKey):$registryValueName"
$MasterFile = Resolve-ToolbarSettingPath (Get-RequiredToolbarSetting $masterSettingName)
$IconFolder = Join-Path $AppDir 'icon'
[int]$buttonLimit = 0
if (-not [int]::TryParse((Get-RequiredToolbarSetting 'Button Limit'), [ref]$buttonLimit) -or $buttonLimit -lt 1) {
    throw "Config.json 'Button Limit' must be a positive integer."
}
$MaxSelectedButtons = $buttonLimit
# Rows defaults to 1. Only an explicit value of 2 enables two-row mode.
$rowsValue = if ($settings.ContainsKey('Rows')) { ([string]$settings['Rows']).Trim() } else { '' }
[int]$toolbarRows = if ($rowsValue -eq '2') { 2 } else { 1 }
$script:RowsSettingSource = if (-not $settings.ContainsKey('Rows')) {
    'Missing; defaulted to 1'
} elseif ($rowsValue -eq '2') {
    'Configured as 2'
} elseif ($rowsValue -eq '1') {
    'Configured as 1'
} else {
    "Unsupported value '$rowsValue'; defaulted to 1"
}
$topSpace = if ($toolbarRows -eq 2) { 66 } else { 45 }
$ToolbarHeight = $topSpace
$script:TwoRowMode = ($toolbarRows -eq 2)
$FileValuePath = Resolve-ToolbarSettingPath (Get-RequiredToolbarSetting 'Logged In User')
# Section 4 third control: Kill, LogOff, or None (case-insensitive).
$ThirdButtonMode = (Get-RequiredToolbarSetting 'Third Button').Trim()
if ($ThirdButtonMode -notin @('Kill', 'LogOff', 'None')) {
    $message = "Invalid 'Third Button' in Config.json: '$ThirdButtonMode'. Only Kill, LogOff, or None are allowed."
    [System.Windows.Forms.MessageBox]::Show(
        $message, 'HCA Toolbar Configuration Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    throw $message
}
$ThirdButtonMode = switch ($ThirdButtonMode.ToLowerInvariant()) {
    'kill' { 'Kill' }
    'logoff' { 'LogOff' }
    'none' { 'None' }
}
# Require a clear Yes/No setting for Windows logoff confirmation.
$LogOffConfirmation = (Get-RequiredToolbarSetting 'LogOff Confirmation').Trim()
if ($LogOffConfirmation -notin @('Yes', 'No')) {
    $message = "Invalid 'LogOff Confirmation' in Config.json: '$LogOffConfirmation'. Only Yes or No are allowed."
    [System.Windows.Forms.MessageBox]::Show(
        $message, 'HCA Toolbar Configuration Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    throw $message
}
$LogOffConfirmation = if ($LogOffConfirmation -ieq 'Yes') { 'Yes' } else { 'No' }
$PasswordResetUrl = (Get-RequiredToolbarSetting 'PRT URL').Trim()
if (-not [Uri]::IsWellFormedUriString($PasswordResetUrl, [UriKind]::Absolute) -or
    -not ($PasswordResetUrl -match '^https?://')) {
    throw "Config.json 'PRT URL' must be a valid HTTP or HTTPS URL."
}

# Optional startup visibility setting (defaults to visible for older configs).
$startHiddenSetting = 'No'
if ($settings.ContainsKey('Start Hidden')) {
    $startHiddenSetting = ([string]$settings['Start Hidden']).Trim()
}
if ($startHiddenSetting -notin @('Yes', 'No')) {
    throw "Config.json 'Start Hidden' must be 'Yes' or 'No'."
}
$script:StartToolbarHidden = ($startHiddenSetting -ieq 'Yes')

$ToolbarTitle = 'Top Toolbar'
# Select the toolbar theme from Config.json. Default to Light Mode if omitted.
$darkModeSetting = 'No'
if ($settings.ContainsKey('Dark Mode')) {
    $darkModeSetting = ([string]$settings['Dark Mode']).Trim()
}
if ($darkModeSetting -notin @('Yes', 'No', 'Windows')) {
    throw "Config.json 'Dark Mode' must be 'Yes', 'No', or 'Windows'."
}
$IsDarkMode = $darkModeSetting -ieq 'Yes'
if ($darkModeSetting -ieq 'Windows') {
    try {
        $windowsLightTheme = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop
        if ($windowsLightTheme -notin @(0, 1)) {
            throw "Unexpected SystemUsesLightTheme value: $windowsLightTheme"
        }
        $IsDarkMode = [int]$windowsLightTheme -eq 0
    } catch {
        # If the Windows setting is unavailable, use Light Mode.
        Write-Warning "Unable to read Windows theme; using Light Mode. $($_.Exception.Message)"
        $IsDarkMode = $false
    }
}
if ($IsDarkMode) {
    $BackColor = [System.Drawing.Color]::FromArgb(32, 34, 39)
    $ButtonColor = [System.Drawing.Color]::FromArgb(53, 57, 64)
    $TextColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $HoverColor = [System.Drawing.Color]::FromArgb(75, 81, 91)
    # High-contrast border so rounded buttons remain visible on dark surfaces.
    $ButtonBorderColor = [System.Drawing.Color]::FromArgb(190, 202, 219)
    $WatermarkThemeColor = [System.Drawing.Color]::FromArgb(188, 207, 235)
    $ToolbarThemeBorderColor = [System.Drawing.Color]::FromArgb(91, 136, 190)
} else {
    $BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $ButtonColor = [System.Drawing.Color]::White
    $TextColor = [System.Drawing.Color]::FromArgb(35,35,35)
    $HoverColor = [System.Drawing.Color]::FromArgb(232,232,232)
    $ButtonBorderColor = [System.Drawing.Color]::Black
    $WatermarkThemeColor = [System.Drawing.Color]::FromArgb(9,34,64)
    $ToolbarThemeBorderColor = [System.Drawing.Color]::FromArgb(3,45,108)
}

# ToolbarConfig logging. The active log is appended to until it reaches 5 MB.
# Up to five files are retained: ToolbarAppLog.log through ToolbarAppLog.4.log.
$LogFolder = Join-Path (Split-Path -Parent $SettingsFile) 'logs'
$LogFile = Join-Path $LogFolder 'ToolbarAppLog.log'
$LogMaxBytes = 5MB
$LogMaxFiles = 5
$LogSource = 'ToolbarConfig'

function Initialize-ToolbarLog {
    try {
        if (-not (Test-Path -LiteralPath $LogFolder -PathType Container)) {
            New-Item -ItemType Directory -Path $LogFolder -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        # Logging must never prevent the toolbar from starting.
    }
}

function Invoke-ToolbarLogRotation {
    try {
        if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) { return }
        $length = (Get-Item -LiteralPath $LogFile -ErrorAction Stop).Length
        if ($length -lt $LogMaxBytes) { return }

        # Delete the oldest retained file, then shift the remaining files upward.
        $oldest = Join-Path $LogFolder ("ToolbarAppLog.{0}.log" -f ($LogMaxFiles - 1))
        if (Test-Path -LiteralPath $oldest) {
            Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop
        }

        for ($i = $LogMaxFiles - 2; $i -ge 1; $i--) {
            $source = Join-Path $LogFolder ("ToolbarAppLog.{0}.log" -f $i)
            $destination = Join-Path $LogFolder ("ToolbarAppLog.{0}.log" -f ($i + 1))
            if (Test-Path -LiteralPath $source) {
                Move-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            }
        }

        $firstArchive = Join-Path $LogFolder 'ToolbarAppLog.1.log'
        Move-Item -LiteralPath $LogFile -Destination $firstArchive -Force -ErrorAction Stop
    } catch {
        # Do not recurse into Write-ToolbarLog from rotation failures.
    }
}

function Write-ToolbarLog {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO'
    )

    try {
        Initialize-ToolbarLog
        Invoke-ToolbarLogRotation
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $entry = '{0} [{1}] [{2}] {3}' -f $timestamp, $LogSource, $Level, $Message
        Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging failures are intentionally non-fatal.
    }
}

Initialize-ToolbarLog
Write-ToolbarLog -Message ("DPI_AWARENESS Startup={0}" -f $script:DpiAwarenessResult)
Write-ToolbarLog -Message ("Starting toolbar. AppDir='{0}'" -f $AppDir)

# Audit the effective settings after Config.json has been parsed and validated.
# Logging is initialized here, so all values are written to the configured logs folder.
Write-ToolbarLog -Message ("CONFIG Name='User Button File' Value='{0}' ResolvedPath='{1}'" -f $settings['User Button File'], $ConfigFile)
Write-ToolbarLog -Message ("MASTER_SELECTION Registry='{3}' RegistryValue='{0}' Reason='{1}' SelectedSetting='{2}'" -f $script:SSOProviderType, $script:MasterSelectionReason, $masterSettingName, $script:GenshareRegistryLocation)
Write-ToolbarLog -Message ("CONFIG Name='{0}' Value='{1}' ResolvedPath='{2}'" -f $masterSettingName, $settings[$masterSettingName], $MasterFile)
Write-ToolbarLog -Message ("CONFIG Name='Genshare Registry' Value='{0}' Resolved='{1}'" -f $genshareRegistrySetting, $script:GenshareRegistryLocation)
Write-ToolbarLog -Message ("CONFIG Name='PRT URL' Value='{0}'" -f $PasswordResetUrl)
Write-ToolbarLog -Message ("CONFIG Name='Third Button' Value='{0}'" -f $ThirdButtonMode)
Write-ToolbarLog -Message ("CONFIG Name='LogOff Confirmation' Value='{0}'" -f $LogOffConfirmation)
Write-ToolbarLog -Message ("CONFIG Name='Button Limit' Value='{0}' MaxSelectedButtons={1}" -f $settings['Button Limit'], $MaxSelectedButtons)
Write-ToolbarLog -Message ("CONFIG Name='Rows' EffectiveValue='{0}' Source='{1}' TopSpace={2} ToolbarHeight={3}" -f $toolbarRows, $script:RowsSettingSource, $topSpace, $ToolbarHeight)
Write-ToolbarLog -Message ("CONFIG Name='Dark Mode' Value='{0}' Theme='{1}'" -f $darkModeSetting, $(if ($IsDarkMode) { 'Dark' } else { 'Light' }))
Write-ToolbarLog -Message ("CONFIG Name='Logged In User' Value='{0}' ResolvedPath='{1}'" -f $settings['Logged In User'], $FileValuePath)

# Validate the selected master catalog before constructing the toolbar UI.
# Do not silently fall back to the standard master when registry Type=2:
# that could show applications from the wrong catalog.
if (-not (Test-Path -LiteralPath $MasterFile -PathType Leaf)) {
    $message = "The selected master button file was not found.`n`n" +
               "Configuration: $masterSettingName`n" +
               "Expected file: $MasterFile`n`n" +
               "The HCA Toolbar will now exit."
    Write-ToolbarLog -Level ERROR -Message (
        "STARTUP_ABORT Master button file missing. Setting='{0}' Path='{1}' RegistryType='{2}'" -f
        $masterSettingName, $MasterFile, $script:SSOProviderType
    )
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'HCA Toolbar - Missing Master File',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    # Startup exits before Application.Run(), so release the mutex here.
    if ($script:ToolbarOwnsMutex -and $script:ToolbarInstanceMutex) {
        try { $script:ToolbarInstanceMutex.ReleaseMutex() } catch {}
        $script:ToolbarOwnsMutex = $false
    }
    if ($script:ToolbarInstanceMutex) {
        $script:ToolbarInstanceMutex.Dispose()
        $script:ToolbarInstanceMutex = $null
    }
    return
}


# When the number of selected application buttons is greater than this value,
# the application buttons are resized to equal widths.
$EqualWidthThreshold = 19
$WatermarkText = 'HCA Toolbar'
# HCA Healthcare brand-inspired watermark: navy HCA sans-serif,
# followed by navy Toolbar in a bold serif similar to Healthcare.
$WatermarkColor = $WatermarkThemeColor
$WatermarkMarkPath = Join-Path $IconFolder 'HCA_OrangeMark.png'
$WatermarkHCAFont = New-Object System.Drawing.Font('Arial', 17, [System.Drawing.FontStyle]::Bold)
$WatermarkToolbarFont = New-Object System.Drawing.Font('Georgia', 16, [System.Drawing.FontStyle]::Bold)

# Hoverable information icon displayed immediately after the Toolbar word.
$ToolbarInfoMarkdown = if ($settings.ContainsKey('Toolbar Info')) { [string]$settings['Toolbar Info'] } else { '' }
$script:ToolbarInfoBounds = [System.Drawing.RectangleF]::Empty
# Use a native WinForms ToolTip instead of a ToolStripDropDown.
# Native ToolTips dismiss themselves; dropdown windows can remain open.
$script:ToolbarInfoVisible = $false
$script:ToolbarInfoToolTip = New-Object System.Windows.Forms.ToolTip
$script:ToolbarInfoToolTip.IsBalloon = $false
$script:ToolbarInfoToolTip.ShowAlways = $true
$script:ToolbarInfoToolTip.InitialDelay = 0
$script:ToolbarInfoToolTip.ReshowDelay = 100
$script:ToolbarInfoToolTip.AutoPopDelay = 5000
$script:ToolbarInfoToolTip.UseAnimation = $true
$script:ToolbarInfoToolTip.UseFading = $true
# Standard ToolTip supports plain text, so remove Markdown bold markers.
$script:ToolbarInfoPlainText = ($ToolbarInfoMarkdown -replace '\*\*', '' -replace "`r`n", "`n")
$ToolbarInfoFont = New-Object System.Drawing.Font('Georgia', 8, [System.Drawing.FontStyle]::Bold)

# Wrap tooltip text to no more than half the width of the monitor
# containing the information icon. Recalculate on each hover so it also
# works when the toolbar is moved to a different display.
function Format-ToolbarInfoForScreen {
    param([string]$Text, [System.Windows.Forms.Control]$Anchor)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $screen = [System.Windows.Forms.Screen]::FromControl($Anchor)
    $maxWidth = [Math]::Max(120, [int][Math]::Floor($screen.WorkingArea.Width / 2) - 36)
    $font = [System.Drawing.SystemFonts]::DefaultFont
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($paragraph in ($Text -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($paragraph)) {
            [void]$result.Add('')
            continue
        }
        $line = ''
        foreach ($word in ($paragraph.Trim() -split '\s+')) {
            $candidate = if ($line.Length -eq 0) { $word } else { "$line $word" }
            $size = [System.Windows.Forms.TextRenderer]::MeasureText($candidate, $font, [System.Drawing.Size]::Empty, $flags)
            if ($line.Length -gt 0 -and $size.Width -gt $maxWidth) {
                [void]$result.Add($line)
                $line = $word
            } else {
                $line = $candidate
            }
        }
        if ($line.Length -gt 0) { [void]$result.Add($line) }
    }
    return ($result -join "`n")
}

function Show-ToolbarInfoPopup {
    if ($script:ToolbarInfoVisible -or [string]::IsNullOrWhiteSpace($script:ToolbarInfoPlainText)) { return }
    if (-not $flow -or -not $flow.IsHandleCreated) { return }
    $script:ToolbarInfoVisible = $true
    # Explicit 5-second lifetime guarantees the tip cannot remain indefinitely.
    $wrappedInfo = Format-ToolbarInfoForScreen -Text $script:ToolbarInfoPlainText -Anchor $flow

    # Estimate the rendered width of the wrapped tooltip and center it beneath
    # the mouse pointer. ToolTip.Show expects coordinates relative to $flow.
    $font = [System.Drawing.SystemFonts]::DefaultFont
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
    $textWidth = 0
    foreach ($line in ($wrappedInfo -split "`n")) {
        $lineWidth = [System.Windows.Forms.TextRenderer]::MeasureText($line, $font, [System.Drawing.Size]::Empty, $flags).Width
        $textWidth = [Math]::Max($textWidth, $lineWidth)
    }
    $tipWidth = $textWidth + 24 # Allow for the native tooltip border and padding.
    $mouseScreen = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($mouseScreen)
    $workArea = $screen.WorkingArea
    $tipLeft = [int]($mouseScreen.X - [Math]::Floor($tipWidth / 2))
    $tipLeft = [Math]::Max($workArea.Left + 4, [Math]::Min($tipLeft, $workArea.Right - $tipWidth - 4))
    $tipTop = [int]($mouseScreen.Y + 20)
    $anchorPoint = $flow.PointToClient((New-Object System.Drawing.Point($tipLeft, $tipTop)))
    $script:ToolbarInfoToolTip.Show($wrappedInfo, $flow, $anchorPoint.X, $anchorPoint.Y, 5000)
}

function Hide-ToolbarInfoPopup {
    $script:ToolbarInfoVisible = $false
    if ($script:ToolbarInfoToolTip -and $flow) { $script:ToolbarInfoToolTip.Hide($flow) }
}

function Draw-HCABrandWatermark {
    param([System.Drawing.Graphics]$Graphics, [System.Drawing.RectangleF]$Area)
    $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $format = New-Object System.Drawing.StringFormat
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $brush = New-Object System.Drawing.SolidBrush($WatermarkColor)
    try {
        $hca = 'HCA'
        $toolbar = ' Toolbar'
        $hcaSize = $Graphics.MeasureString($hca, $WatermarkHCAFont, 1000, $format)
        $toolbarSize = $Graphics.MeasureString($toolbar, $WatermarkToolbarFont, 1000, $format)
        $markWidth = 19.0
        $markGap = 2.0
        $infoGap = 3.0
        $infoWidth = 14.0
        $totalWidth = $hcaSize.Width + $markWidth + $markGap + $toolbarSize.Width + $infoGap + $infoWidth
        $x = $Area.Left + ($Area.Width - $totalWidth) / 2
        $hcaY = $Area.Top + ($Area.Height - $hcaSize.Height) / 2
        $toolbarY = $Area.Top + ($Area.Height - $toolbarSize.Height) / 2
        $Graphics.DrawString($hca, $WatermarkHCAFont, $brush,
            ([System.Drawing.PointF]::new([float]$x, [float]$hcaY)), $format)
        if (Test-Path -LiteralPath $WatermarkMarkPath -PathType Leaf) {
            $markImage = $null
            try {
                $markImage = [System.Drawing.Image]::FromFile($WatermarkMarkPath)
                $markRect = [System.Drawing.RectangleF]::new(
                    [float]($x + $hcaSize.Width), [float]($Area.Top + ($Area.Height - 19) / 2),
                    [float]$markWidth, [float]19)
                $Graphics.DrawImage($markImage, $markRect)
            } finally {
                if ($markImage) { $markImage.Dispose() }
            }
        }
        $Graphics.DrawString($toolbar, $WatermarkToolbarFont, $brush,
            ([System.Drawing.PointF]::new([float]($x + $hcaSize.Width + $markWidth + $markGap), [float]$toolbarY)), $format)
        $infoX = [float]($x + $hcaSize.Width + $markWidth + $markGap + $toolbarSize.Width + $infoGap)
        # Superscript-style info symbol: 50% of the original 18px circle,
        # raised to the top-right of "Toolbar" (similar to x-squared).
        $infoY = [float]($toolbarY + 1)
        $infoDiameter = 9.0
        # Keep a larger hover target so the tiny symbol remains usable.
        $script:ToolbarInfoBounds = [System.Drawing.RectangleF]::new($infoX - 2, $infoY - 2, 18.0, 18.0)
        if (-not [string]::IsNullOrWhiteSpace($ToolbarInfoMarkdown)) {
            $infoPen = New-Object System.Drawing.Pen($WatermarkColor, 1.4)
            try {
                $Graphics.DrawEllipse($infoPen, $infoX, $infoY, $infoDiameter, $infoDiameter)
                $infoFormat = New-Object System.Drawing.StringFormat
                try {
                    $infoFormat.Alignment = [System.Drawing.StringAlignment]::Center
                    $infoFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
                    $iconDrawBounds = [System.Drawing.RectangleF]::new($infoX, $infoY, $infoDiameter, $infoDiameter)
                    $Graphics.DrawString('i', $ToolbarInfoFont, $brush, $iconDrawBounds, $infoFormat)
                } finally { $infoFormat.Dispose() }
            } finally { $infoPen.Dispose() }
        }
    } finally {
        $brush.Dispose()
        $format.Dispose()
    }
}
# Toolbar branding image and border. The logo is expected in the icon folder.
$ToolbarLogoFile = 'HCA-Toolbar.png'
$ToolbarLogoPath = Join-Path $IconFolder $ToolbarLogoFile
$ToolbarBorderColor = $ToolbarThemeBorderColor
$ToolbarBorderWidth = 2
$buttonToolTip = New-Object System.Windows.Forms.ToolTip
$buttonToolTip.AutoPopDelay = 8000
$buttonToolTip.InitialDelay = 400
$buttonToolTip.ReshowDelay = 100
$buttonToolTip.ShowAlways = $true

function Read-MasterButtons {
    try {
        Write-ToolbarLog -Message ("Reading master button configuration from '{0}'." -f $MasterFile)
        if (-not (Test-Path $MasterFile)) {
            throw "Master button file not found: $MasterFile"
        }
        $raw = Get-Content -LiteralPath $MasterFile -Raw -Encoding UTF8 -ErrorAction Stop
        $items = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($items -isnot [System.Collections.IEnumerable]) { $items = @($items) }
        Write-ToolbarLog -Message ("Loaded {0} master button entries." -f @($items).Count)
        return @($items)
    } catch {
        Write-ToolbarLog -Level ERROR -Message ("Failed to read/parse Buttons.json: {0}" -f $_.Exception.Message)
        throw
    }
}

function Read-Config {
    try {
        if (-not (Test-Path $ConfigFile)) {
            Write-ToolbarLog -Level WARNING -Message ("ToolbarConfig.json was not found. Creating default file at '{0}'." -f $ConfigFile)
            $default = @{ SelectedButtonIds = @() }
            ($default | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8 -ErrorAction Stop
        }
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-ToolbarLog -Level WARNING -Message 'ToolbarConfig.json is empty; using an empty selection.'
            return @{ SelectedButtonIds = @() }
        }
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
        return $cfg
    } catch {
        Write-ToolbarLog -Level ERROR -Message ("Failed to read/parse ToolbarConfig.json: {0}" -f $_.Exception.Message)
        throw
    }
}

function Get-SelectedButtons {
    $master = Read-MasterButtons
    $config = Read-Config
    $ids = @($config.SelectedButtonIds | ForEach-Object { [string]$_ })
    $lookup = @{}
    foreach ($item in $master) { $lookup[[string]$item.Id] = $item }
    $result = New-Object System.Collections.ArrayList
    foreach ($id in ($ids | Select-Object -First $MaxSelectedButtons)) {
        if ($lookup.ContainsKey($id)) { [void]$result.Add($lookup[$id]) }
    }
    return @($result)
}

function Save-SelectedIds {
    param([string[]]$Ids)

    if ($null -eq $Ids) { $Ids = @() }
    $Ids = @($Ids | Select-Object -First $MaxSelectedButtons)

    $payload = [ordered]@{ SelectedButtonIds = @($Ids) }
    try {
        ($payload | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8 -ErrorAction Stop
        Write-ToolbarLog -Message ("Saved ToolbarConfig.json with {0} selected button(s)." -f @($Ids).Count)
    } catch {
        Write-ToolbarLog -Level ERROR -Message ("Failed to save ToolbarConfig.json: {0}" -f $_.Exception.Message)
        throw
    }
}

function Resolve-WindowsPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    $resolved = [regex]::Replace($resolved, '\$env:([A-Za-z_][A-Za-z0-9_]*)', {
        param($m)
        $name = $m.Groups[1].Value
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $value) { $m.Value } else { $value }
    })
    return $resolved
}

function Start-ToolbarCommand {
    param(
        [string]$Command,
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            throw 'The button Command is empty in Buttons.json.'
        }

        $filePath = Resolve-WindowsPath -Path $Command.Trim()
        $startParams = @{ FilePath = $filePath }

        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $startParams.ArgumentList = $Arguments
        }

        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startParams.WorkingDirectory = Resolve-WindowsPath -Path $WorkingDirectory.Trim()
        }

        Write-ToolbarLog -Message ("Launching command '{0}' with arguments '{1}'." -f $filePath, $Arguments)
        Start-Process @startParams -ErrorAction Stop | Out-Null
        Write-ToolbarLog -Message ("Launch request succeeded for '{0}'." -f $filePath)
    } catch {
        Write-ToolbarLog -Level ERROR -Message ("Could not start command '{0}': {1}" -f $Command, $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            "Could not start '$Command'.`n`n$($_.Exception.Message)",
            $ToolbarTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

# Native Windows monitor positioning. The toolbar uses GetMonitorInfo and
# SetWindowPos in the same Win32 coordinate space, avoiding discrepancies
# between Windows Forms layout and the native window rectangle.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HcaMonitorPosition {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    public struct MONITORINFO {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }
    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT point, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y,
        int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("gdi32.dll", SetLastError=true)]
    public static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int SetWindowRgn(IntPtr hwnd, IntPtr region, bool redraw);
    public delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr data);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hwnd,
        System.Text.StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    public static string InspectPoint(int x, int y) {
        POINT p = new POINT(); p.X = x; p.Y = y;
        IntPtr child = WindowFromPoint(p);
        if (child == IntPtr.Zero) return "No window at point";
        // GA_ROOT = 2: attribute nested controls to their top-level owner.
        IntPtr root = GetAncestor(child, 2);
        if (root == IntPtr.Zero) root = child;
        uint pid;
        GetWindowThreadProcessId(root, out pid);
        RECT rect;
        if (!GetWindowRect(root, out rect)) return "GetWindowRect failed";
        var title = new System.Text.StringBuilder(256);
        GetWindowText(root, title, title.Capacity);
        return string.Format("HWND=0x{0:X} PID={1} Visible={2} Rect=({3},{4},{5},{6}) Title='{7}'",
            root.ToInt64(), pid, IsWindowVisible(root), rect.Left, rect.Top,
            rect.Right, rect.Bottom, title.ToString().Replace("\r", " ").Replace("\n", " "));
    }

    public static string[] ListProcessWindows(uint targetPid) {
        var results = new System.Collections.Generic.List<string>();
        EnumWindows((hwnd, data) => {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid != targetPid) return true;
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return true;
            var title = new System.Text.StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            string safeTitle = title.ToString().Replace("\r", " ").Replace("\n", " ");
            results.Add(string.Format(
                "HWND=0x{0:X} Visible={1} Rect=({2},{3},{4},{5}) Title='{6}'",
                hwnd.ToInt64(), IsWindowVisible(hwnd),
                r.Left, r.Top, r.Right, r.Bottom, safeTitle));
            return true;
        }, IntPtr.Zero);
        return results.ToArray();
    }
}
'@

$script:LastMonitorEdgeDiagnostic = ''
$script:LastWindowDiagnosticSignature = ''
function Write-ToolbarWindowDiagnostics {
    param([string]$Reason = 'CHECK')
    try {
        $windows = @([HcaMonitorPosition]::ListProcessWindows([uint32]$PID))
        $signature = $windows -join '|'
        if ($signature -eq $script:LastWindowDiagnosticSignature -and $Reason -eq 'MONITOR_SYNC') { return }
        $script:LastWindowDiagnosticSignature = $signature
        Write-ToolbarLog -Message ("WINDOW_DIAGNOSTICS Reason='{0}' PID={1} WindowCount={2}" -f $Reason, $PID, $windows.Count)
        foreach ($window in $windows) {
            Write-ToolbarLog -Message ("WINDOW_DIAGNOSTIC {0}" -f $window)
        }
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Window diagnostics failed: {0}" -f $_.Exception.Message)
    }
}

# Check which top-level window owns pixels immediately inside and outside
# the docked monitor boundary. Sample after docking, not continuously.
function Write-ToolbarBoundaryOwners {
    param([System.Windows.Forms.Screen]$Screen, [string]$Reason = 'DOCKED')
    try {
        $bounds = $Screen.Bounds
        $sampleY = [int]($bounds.Top + [Math]::Min(15, [Math]::Max(1, $ToolbarHeight - 2)))
        foreach ($offset in @(-3, -1, 0, 1, 3)) {
            $x = [int]($bounds.Right + $offset)
            $owner = [HcaMonitorPosition]::InspectPoint($x, $sampleY)
            Write-ToolbarLog -Message ("BOUNDARY_CHECK Reason='{0}' Monitor='{1}' Right={2} Point=({3},{4}) Offset={5} {6}" -f
                $Reason, $Screen.DeviceName, $bounds.Right, $x, $sampleY, $offset, $owner)
        }
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("BOUNDARY_CHECK failed: {0}" -f $_.Exception.Message)
    }
}

# Apply a native window region in client-independent window coordinates.
# Windows owns the region after successful SetWindowRgn; do not free it.
function Set-ToolbarClipRegion {
    param([System.Windows.Forms.Form]$Form, [bool]$Enable = $true)
    if ($Form.IsDisposed -or -not $Form.IsHandleCreated) { return }
    if (-not $Enable) {
        [void][HcaMonitorPosition]::SetWindowRgn($Form.Handle, [IntPtr]::Zero, $true)
        return
    }
    $windowRect = New-Object HcaMonitorPosition+RECT
    if (-not [HcaMonitorPosition]::GetWindowRect($Form.Handle, [ref]$windowRect)) { return }
    $width = $windowRect.Right - $windowRect.Left
    $height = $windowRect.Bottom - $windowRect.Top
    if ($width -le 0 -or $height -le 0) { return }
    $region = [HcaMonitorPosition]::CreateRectRgn(0, 0, $width, $height)
    if ($region -eq [IntPtr]::Zero) { return }
    $result = [HcaMonitorPosition]::SetWindowRgn($Form.Handle, $region, $true)
    if ($result -eq 0) {
        [void][HcaMonitorPosition]::DeleteObject($region)
        Write-ToolbarLog -Level WARNING -Message 'CLIP_REGION_FAILED'
    } else {
        Write-ToolbarLog -Message ("CLIP_REGION_APPLIED Width={0} Height={1}" -f $width, $height)
    }
}

function Set-ToolbarBounds {
    param(
        [System.Windows.Forms.Form]$Form,
        [System.Windows.Forms.Screen]$Screen = [System.Windows.Forms.Screen]::PrimaryScreen
    )
    $bounds = $Screen.Bounds
    $point = New-Object HcaMonitorPosition+POINT
    $point.X = [int]($bounds.Left + [Math]::Floor($bounds.Width / 2))
    $point.Y = [int]($bounds.Top + [Math]::Floor($bounds.Height / 2))
    $monitor = [HcaMonitorPosition]::MonitorFromPoint($point, 2)
    $info = New-Object HcaMonitorPosition+MONITORINFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'HcaMonitorPosition+MONITORINFO')
    if ($monitor -eq [IntPtr]::Zero -or
        -not [HcaMonitorPosition]::GetMonitorInfo($monitor, [ref]$info)) {
        Write-ToolbarLog -Level WARNING -Message 'Native monitor query failed; using Screen.Bounds.'
        $Form.SetBounds($bounds.Left, $bounds.Top, $bounds.Width, $ToolbarHeight,
            [System.Windows.Forms.BoundsSpecified]::All)
        return
    }
    $native = $info.rcMonitor
    $width = $native.Right - $native.Left
    $height = [int]$ToolbarHeight
    if (-not $Form.IsHandleCreated) {
        $Form.SetBounds($bounds.Left, $bounds.Top, $bounds.Width, $height,
            [System.Windows.Forms.BoundsSpecified]::All)
        return
    }
    # SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER
    $flags = [uint32](0x0004 -bor 0x0010 -bor 0x0200)
    $ok = [HcaMonitorPosition]::SetWindowPos($Form.Handle, [IntPtr]::Zero,
        $native.Left, $native.Top, $width, $height, $flags)
    if (-not $ok) {
        Write-ToolbarLog -Level WARNING -Message 'Native SetWindowPos failed.'
        return
    }
    Set-ToolbarClipRegion -Form $Form
    $actual = New-Object HcaMonitorPosition+RECT
    if ([HcaMonitorPosition]::GetWindowRect($Form.Handle, [ref]$actual)) {
        $diagnostic = "MONITOR_EDGE Monitor='$($Screen.DeviceName)' Native=($($native.Left),$($native.Top),$($native.Right),$($native.Bottom)) Actual=($($actual.Left),$($actual.Top),$($actual.Right),$($actual.Bottom)) WinForms=($($Form.Left),$($Form.Top),$($Form.Right),$($Form.Bottom))"
        if ($diagnostic -ne $script:LastMonitorEdgeDiagnostic) {
            Write-ToolbarLog -Message $diagnostic
            $script:LastMonitorEdgeDiagnostic = $diagnostic
        }
    }
}

function Get-ScaledImage {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Width = 20,
        [int]$Height = 20
    )

    $source = $null
    try {
        $source = [System.Drawing.Image]::FromFile($Path)
        return New-Object System.Drawing.Bitmap($source, $Width, $Height)
    } finally {
        if ($source) { $source.Dispose() }
    }
}

# Application button drag-and-drop state. Buttons can be reordered directly on the toolbar.
$script:IsDraggingButton = $false
$script:DragButton = $null
$script:DragButtonMoved = $false
$script:DragButtonStartMouse = [System.Drawing.Point]::Empty
$script:SuppressNextButtonClick = $false
$script:DragThreshold = 4

function Save-ToolbarButtonOrder {
    $orderedIds = New-Object System.Collections.Generic.List[string]
    foreach ($control in $flow.Controls) {
        if ($null -ne $control.Tag -and $null -ne $control.Tag.Id) {
            [void]$orderedIds.Add([string]$control.Tag.Id)
        }
    }

    if ($orderedIds.Count -gt $MaxSelectedButtons) {
        $limitedIds = @($orderedIds.ToArray() | Select-Object -First $MaxSelectedButtons)
        $orderedIds = New-Object System.Collections.Generic.List[string]
        foreach ($id in $limitedIds) { [void]$orderedIds.Add([string]$id) }
    }

    Save-SelectedIds -Ids $orderedIds.ToArray()
}

function Start-ApplicationButtonDrag {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Windows.Forms.MouseEventArgs]$EventArgs
    )

    if ($EventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

    $script:IsDraggingButton = $true
    $script:DragButton = $Button
    $script:DragButtonMoved = $false
    $script:DragButtonStartMouse = [System.Windows.Forms.Control]::MousePosition

    # Capture the mouse so dragging continues even when the pointer leaves the
    # button while crossing over neighboring buttons.
    $Button.Capture = $true
}

function Move-ApplicationButtonDrag {
    if (-not $script:IsDraggingButton -or $null -eq $script:DragButton) { return }

    $mouse = [System.Windows.Forms.Control]::MousePosition
    $dx = [Math]::Abs($mouse.X - $script:DragButtonStartMouse.X)
    $dy = [Math]::Abs($mouse.Y - $script:DragButtonStartMouse.Y)

    if (-not $script:DragButtonMoved -and $dx -lt $script:DragThreshold -and $dy -lt $script:DragThreshold) {
        return
    }

    $script:DragButtonMoved = $true

    $appControls = @($flow.Controls | Where-Object {
        $null -ne $_.Tag -and $null -ne $_.Tag.Id
    })

    if ($appControls.Count -le 1) { return }

    $point = $flow.PointToClient($mouse)
    $targetOrdinal = 0

    if ($script:TwoRowMode) {
        $firstRow = if ($appControls.Count -le 40) {
            [Math]::Min(20, $appControls.Count)
        } else { [int][Math]::Ceiling($appControls.Count / 2.0) }
        $secondRow = $appControls.Count - $firstRow
        $onSecond = ($secondRow -gt 0 -and $point.Y -ge $appControls[$firstRow].Top)
        $start = if ($onSecond) { $firstRow } else { 0 }
        $end = if ($onSecond) { $appControls.Count } else { $firstRow }
        $targetOrdinal = $start
        for ($i = $start; $i -lt $end; $i++) {
            $control = $appControls[$i]
            if ($point.X -ge ($control.Left + [int]($control.Width / 2))) {
                $targetOrdinal = $i + 1
            } else { break }
        }
    } else {
        for ($i = 0; $i -lt $appControls.Count; $i++) {
            $control = $appControls[$i]
            $centerX = $control.Left + [int]($control.Width / 2)
            if ($point.X -ge $centerX) {
                $targetOrdinal = $i + 1
            } else { break }
        }
    }

    # Clamp to the end of the application-button range.
    if ($targetOrdinal -gt $appControls.Count - 1) {
        $targetOrdinal = $appControls.Count - 1
    }

    $currentOrdinal = -1
    for ($i = 0; $i -lt $appControls.Count; $i++) {
        if ($appControls[$i] -eq $script:DragButton) {
            $currentOrdinal = $i
            break
        }
    }

    if ($currentOrdinal -lt 0 -or $targetOrdinal -eq $currentOrdinal) { return }

    # The toolbar order is: logo, BM, application buttons, close.
    # Application buttons therefore start at child index 2.
    $targetFlowIndex = $targetOrdinal
    [void]$flow.Controls.SetChildIndex($script:DragButton, $targetFlowIndex)
    if ($script:TwoRowMode) { Update-ApplicationWidths }
    $flow.PerformLayout()
}

function Finish-ApplicationButtonDrag {
    if (-not $script:IsDraggingButton) { return }

    $button = $script:DragButton

    if ($button) {
        $button.Capture = $false
    }

    if ($script:DragButtonMoved) {
        $script:SuppressNextButtonClick = $true
        # Persist the exact visual order of the application buttons.
        # Newly selected buttons are appended by Show-ButtonManager rather than
        # inserted into an existing sequence.
        Save-ToolbarButtonOrder
        Update-ToolbarDropdown
    }

    $script:IsDraggingButton = $false
    $script:DragButton = $null
    $script:DragButtonMoved = $false
}

function Set-SingleLineButtonText {
    param([System.Windows.Forms.Button]$Button)
    if ($null -eq $Button.Tag) { return }
    $fullName = [string]$Button.Tag.Name
    $reserved = if ($null -ne $Button.Image) { 30 } else { 8 }
    $available = [Math]::Max(0, $Button.ClientSize.Width - $reserved)
    $flags = [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
             [System.Windows.Forms.TextFormatFlags]::NoPadding
    $display = $fullName
    while ($display.Length -gt 0 -and
           [System.Windows.Forms.TextRenderer]::MeasureText($display, $Button.Font,
               (New-Object System.Drawing.Size(32767, 32767)), $flags).Width -gt $available) {
        $display = $display.Substring(0, $display.Length - 1)
    }
    $Button.Text = $display.TrimEnd()
}

# Give buttons rounded corners and preserve their existing border styles.
function Enable-RoundedButton {
    param([System.Windows.Forms.Button]$Button, [int]$Radius = 7, [bool]$ShowOutline = $true)
    $Button.FlatAppearance.BorderSize = 0
    $shape = {
        $w = $this.Width - 1; $h = $this.Height - 1
        if ($w -lt 4 -or $h -lt 4) { return }
        $d = 2 * [Math]::Min($Radius, [int]([Math]::Min($w,$h) / 2))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            $path.AddArc(0,0,$d,$d,180,90)
            $path.AddArc($w-$d,0,$d,$d,270,90)
            $path.AddArc($w-$d,$h-$d,$d,$d,0,90)
            $path.AddArc(0,$h-$d,$d,$d,90,90)
            $path.CloseFigure()
            $old = $this.Region
            $this.Region = New-Object System.Drawing.Region($path)
            if ($old) { $old.Dispose() }
        } finally { $path.Dispose() }
        $this.Invalidate()
    }.GetNewClosure()
    $Button.Add_SizeChanged($shape)
    $Button.Add_HandleCreated($shape)
    if ($ShowOutline) {
        # Capture the active theme's border color for this button.
        $outlineColor = $ButtonBorderColor
        $paint = {
            param($sender,$e)
            $w = $sender.ClientSize.Width - 2; $h = $sender.ClientSize.Height - 2
            if ($w -lt 4 -or $h -lt 4) { return }
            $d = 2 * [Math]::Min($Radius, [int]([Math]::Min($w,$h) / 2))
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $pen = New-Object System.Drawing.Pen($outlineColor, 1.2)
            try {
                $path.AddArc(1,1,$d,$d,180,90)
                $path.AddArc($w-$d,1,$d,$d,270,90)
                $path.AddArc($w-$d,$h-$d,$d,$d,0,90)
                $path.AddArc(1,$h-$d,$d,$d,90,90)
                $path.CloseFigure()
                $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $e.Graphics.DrawPath($pen,$path)
            } finally { $pen.Dispose(); $path.Dispose() }
        }.GetNewClosure()
        $Button.Add_Paint($paint)
    }
}

function New-ToolbarButton {
    param(
        $Item,
        [int]$ButtonWidth = 0
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = [string]$Item.Name
    $button.Tag = $Item
    $button.Height = 32
    $button.Width = if ($ButtonWidth -gt 0) { $ButtonWidth } else { [Math]::Max(92, ([string]$Item.Name).Length * 8 + 42) }
    $button.AutoEllipsis = $false  # Custom Name + Description tooltip is used instead
    $button.Margin = New-Object System.Windows.Forms.Padding(0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $ButtonBorderColor
    $button.FlatAppearance.MouseOverBackColor = $HoverColor
    $button.BackColor = $ButtonColor
    $button.ForeColor = $TextColor
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
    $button.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    # Show the application Name and Description when the mouse hovers over the button.
    $tooltipName = [string]$Item.Name
    $tooltipDescription = [string]$Item.Description
    $tooltipText = if ([string]::IsNullOrWhiteSpace($tooltipDescription)) {
        $tooltipName
    } else {
        "$tooltipName`n$tooltipDescription"
    }
    $buttonToolTip.SetToolTip($button, $tooltipText)

    # Use the catalog icon when available; otherwise use the HCA Toolbar logo.
    $iconPath = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.Icon)) {
        $candidate = Join-Path $IconFolder ([string]$Item.Icon)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $iconPath = $candidate
        }
    }
    if ($null -eq $iconPath) { $iconPath = $ToolbarLogoPath }

    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        try {
            $button.Image = Get-ScaledImage -Path $iconPath -Width 20 -Height 20
        } catch {
            Write-ToolbarLog -Level WARNING -Message ("Could not load toolbar icon '{0}': {1}" -f $iconPath, $_.Exception.Message)
            # If the requested icon is corrupt, attempt the fallback logo.
            if ($iconPath -ne $ToolbarLogoPath -and (Test-Path -LiteralPath $ToolbarLogoPath -PathType Leaf)) {
                try {
                    $button.Image = Get-ScaledImage -Path $ToolbarLogoPath -Width 20 -Height 20
                } catch {
                    Write-ToolbarLog -Level WARNING -Message ("Could not load fallback logo: {0}" -f $_.Exception.Message)
                }
            }
        }
    }

    $button.Add_Click({
        if ($script:SuppressNextButtonClick) {
            $script:SuppressNextButtonClick = $false
            return
        }

        $data = $this.Tag
        Write-ToolbarLog -Message ("BUTTON_CLICK Name='{0}' Id='{1}' Command='{2}'" -f ([string]$data.Name), ([string]$data.Id), ([string]$data.Command))
        Start-ToolbarCommand `
            -Command ([string]$data.Command) `
            -Arguments ([string]$data.Arguments) `
            -WorkingDirectory ([string]$data.WorkingDirectory)
    })

    $button.Add_MouseDown({ Start-ApplicationButtonDrag -Button $this -EventArgs $_ })
    $button.Add_MouseMove({ Move-ApplicationButtonDrag })
    $button.Add_MouseUp({ Finish-ApplicationButtonDrag })
    $button.Add_MouseEnter({ $this.BackColor = $HoverColor })
    $button.Add_MouseLeave({ $this.BackColor = $ButtonColor })
    $button.Add_SizeChanged({ Set-SingleLineButtonText -Button $this })
    Set-SingleLineButtonText -Button $button
    Enable-RoundedButton -Button $button -Radius 7 -ShowOutline $true
    return $button
}

function Show-ButtonManager {
    param(
        [System.Windows.Forms.Form]$Owner,
        [scriptblock]$OnSaved
    )

    $master = Read-MasterButtons
    $config = Read-Config
    $selected = @($config.SelectedButtonIds | ForEach-Object { [string]$_ })

    if ($selected.Count -gt $MaxSelectedButtons) {
        [System.Windows.Forms.MessageBox]::Show(
            "ToolbarConfig.json contains $($selected.Count) selected buttons, but the configured maximum is $MaxSelectedButtons. Only the first $MaxSelectedButtons can be used.",
            $ToolbarTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $selected = @($selected | Select-Object -First $MaxSelectedButtons)
    }

    $manager = New-Object System.Windows.Forms.Form
    $manager.Text = 'Toolbar Button Manager'
    $manager.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $manager.Size = New-Object System.Drawing.Size(620,520)
    $manager.MinimizeBox = $false
    $manager.MaximizeBox = $false
    $manager.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $manager.BackColor = $BackColor
    $manager.ForeColor = $TextColor

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    $layout.Padding = New-Object System.Windows.Forms.Padding(10)
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48)))
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
    $manager.Controls.Add($layout)
    $layout.BackColor = $BackColor

    $title = New-Object System.Windows.Forms.Label
    $title.Text = ('Available applications: {0}' -f $master.Count)
    $title.Dock = [System.Windows.Forms.DockStyle]::Fill
    $title.Padding = New-Object System.Windows.Forms.Padding(4,8,0,0)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $layout.Controls.Add($title, 0, 0)
    $title.BackColor = $BackColor
    $title.ForeColor = $TextColor

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = ("Buttons shown on toolbar: {0}.`nMaximum buttons allowed on toolbar: {1}." -f ([Math]::Min($selected.Count, $MaxSelectedButtons)), $MaxSelectedButtons)
    $hint.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hint.Padding = New-Object System.Windows.Forms.Padding(4,0,4,4)
    $layout.Controls.Add($hint, 0, 1)
    $hint.BackColor = $BackColor
    $hint.ForeColor = $TextColor

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.IntegralHeight = $false
    $list.CheckOnClick = $true
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $list.BackColor = $ButtonColor
    $list.ForeColor = $TextColor

    $idByIndex = @{}
    for ($i = 0; $i -lt $master.Count; $i++) {
        $item = $master[$i]
        $description = [string]$item.Description
        $displayText = if ([string]::IsNullOrWhiteSpace($description)) {
            [string]$item.Name
        } else {
            '{0}  -  {1}' -f [string]$item.Name, $description
        }
        $index = $list.Items.Add($displayText)
        $idByIndex[$index] = [string]$item.Id
        if ($selected -contains [string]$item.Id) {
            $list.SetItemChecked($index, $true)
        }
    }

    $listPanel = New-Object System.Windows.Forms.Panel
    $listPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listPanel.Padding = New-Object System.Windows.Forms.Padding(0)
    $listPanel.Controls.Add($list)
    $layout.Controls.Add($listPanel, 0, 2)
    $listPanel.BackColor = $BackColor

    $buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonsPanel.Height = 52
    $buttonsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttonsPanel.WrapContents = $false
    $buttonsPanel.Padding = New-Object System.Windows.Forms.Padding(0,8,0,0)
    $layout.Controls.Add($buttonsPanel, 0, 3)
    $buttonsPanel.BackColor = $BackColor

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Width = 90
    $cancel.Height = 32
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonsPanel.Controls.Add($cancel)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.Width = 90
    $save.Height = 32
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonsPanel.Controls.Add($save)

    $selectAll = New-Object System.Windows.Forms.Button
    $selectAll.Text = 'Select All'
    $selectAll.Width = 90
    $selectAll.Height = 32
    $selectAll.Add_Click({
        if ($list.Items.Count -gt $MaxSelectedButtons) {
            [System.Windows.Forms.MessageBox]::Show(
                "Too many applications to select all. The maximum is $MaxSelectedButtons.",
                $ToolbarTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            $list.SetItemChecked($i, $true)
        }
    })
    $buttonsPanel.Controls.Add($selectAll)

    $clearAll = New-Object System.Windows.Forms.Button
    $clearAll.Text = 'Clear All'
    $clearAll.Width = 90
    $clearAll.Height = 32
    $clearAll.Add_Click({
        for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) }
    })
    $buttonsPanel.Controls.Add($clearAll)

    # Black borders for all action buttons in the Button Manager.
    foreach ($actionButton in @($cancel, $save, $selectAll, $clearAll)) {
        $actionButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $actionButton.FlatAppearance.BorderSize = 1
        $actionButton.FlatAppearance.BorderColor = $ButtonBorderColor
        $actionButton.FlatAppearance.MouseOverBackColor = $HoverColor
        $actionButton.BackColor = $ButtonColor
        $actionButton.ForeColor = $TextColor
    }


    # Never allow more than the configured maximum number of selected buttons.
    $list.Add_ItemCheck({
        param($sender, $e)

        if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked -and
            $sender.CheckedItems.Count -ge $MaxSelectedButtons -and
            $e.CurrentValue -ne [System.Windows.Forms.CheckState]::Checked) {
            $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked
            [System.Windows.Forms.MessageBox]::Show(
                "A maximum of $MaxSelectedButtons applications can be selected.",
                $ToolbarTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    })

    $manager.AcceptButton = $save
    $manager.CancelButton = $cancel

    $save.Add_Click({
        $checkedSet = @{}
        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            if ($list.GetItemChecked($i)) {
                $checkedSet[$idByIndex[$i]] = $true
            }
        }

        if ($checkedSet.Count -gt $MaxSelectedButtons) {
            [System.Windows.Forms.MessageBox]::Show(
                "Too many buttons selected. Please select no more than $MaxSelectedButtons applications.",
                $ToolbarTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        # Preserve the current ToolbarConfig.json order for buttons that remain
        # selected, then append any newly selected buttons using Buttons.json order.
        $newIds = New-Object System.Collections.Generic.List[string]
        foreach ($id in $selected) {
            if ($checkedSet.ContainsKey($id)) {
                [void]$newIds.Add($id)
                $checkedSet.Remove($id)
            }
        }
        for ($i = 0; $i -lt $master.Count; $i++) {
            $id = [string]$master[$i].Id
            if ($checkedSet.ContainsKey($id)) {
                [void]$newIds.Add($id)
                $checkedSet.Remove($id)
            }
        }

        Save-SelectedIds -Ids $newIds.ToArray()
        & $OnSaved
        $manager.Close()
    })

    [void]$manager.ShowDialog($Owner)
    $manager.Dispose()
}

# -----------------------------
# Toolbar dragging / parking
# -----------------------------
$script:IsDraggingToolbar = $false
$script:DragStartMouse = [System.Drawing.Point]::Empty
$script:DragStartForm = [System.Drawing.Point]::Empty
$script:ToolbarHasBeenParked = $false
$script:DockedScreen = [System.Windows.Forms.Screen]::PrimaryScreen
$script:DockSnapDistance = 28

function Get-FloatingToolbarWidth {
    param([System.Windows.Forms.Form]$Form)

    $leftWidth = 0
    foreach ($control in $flow.Controls) {
        $leftWidth += $control.Width + $control.Margin.Left + $control.Margin.Right
    }
    $width = $leftWidth + $section1.Width + $userPanel.Width + $section4.Width + $flow.Padding.Horizontal + 12
    $screen = [System.Windows.Forms.Screen]::FromControl($Form)
    $maxWidth = $screen.WorkingArea.Width

    if ($script:TwoRowMode) { return $maxWidth }
    return [Math]::Min([Math]::Max(460, $width), $maxWidth)
}

function Start-ToolbarDrag {
    param([System.Windows.Forms.MouseEventArgs]$EventArgs)

    if ($EventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

    $script:IsDraggingToolbar = $true
    $script:DragStartMouse = [System.Windows.Forms.Control]::MousePosition
    $script:DragStartForm = $form.Location

    # The toolbar starts full-width at the top. On the first drag, convert it
    # to a compact floating toolbar and center it under the mouse before moving.
    if (-not $script:ToolbarHasBeenParked) {
        $newWidth = Get-FloatingToolbarWidth -Form $form
        $screen = [System.Windows.Forms.Screen]::FromControl($form)
        $mouse = [System.Windows.Forms.Control]::MousePosition
        $newX = $mouse.X - [int]($newWidth / 2)
        $newX = [Math]::Max($screen.WorkingArea.Left, [Math]::Min($newX, $screen.WorkingArea.Right - $newWidth))

        $form.Size = New-Object System.Drawing.Size($newWidth, $ToolbarHeight)
        $form.Location = New-Object System.Drawing.Point($newX, $form.Top)
        $script:DragStartForm = $form.Location
        $script:ToolbarHasBeenParked = $true
    }
}

function Move-ToolbarDrag {
    if (-not $script:IsDraggingToolbar) { return }

    $mouse = [System.Windows.Forms.Control]::MousePosition
    $dx = $mouse.X - $script:DragStartMouse.X
    $dy = $mouse.Y - $script:DragStartMouse.Y

    $form.Location = New-Object System.Drawing.Point(
        ($script:DragStartForm.X + $dx),
        ($script:DragStartForm.Y + $dy))
}

function Stop-ToolbarDrag {
    if (-not $script:IsDraggingToolbar) { return }
    $script:IsDraggingToolbar = $false

    # Dock when released close to the top of the monitor under the cursor.
    # Use screen coordinates so monitors above/left of the primary also work.
    $mouse = [System.Windows.Forms.Control]::MousePosition
    $targetScreen = [System.Windows.Forms.Screen]::FromPoint($mouse)
    $bounds = $targetScreen.Bounds
    if ($mouse.X -ge $bounds.Left -and $mouse.X -lt $bounds.Right -and
        [Math]::Abs($mouse.Y - $bounds.Top) -le $script:DockSnapDistance) {
        $script:DockedScreen = $targetScreen
        $script:ToolbarHasBeenParked = $false
        Set-ToolbarBounds -Form $form -Screen $targetScreen
        $script:LastMonitorSignature = ''
        $toolbarGrid.PerformLayout()
        Update-ApplicationWidths
        Write-ToolbarLog -Message ("TOOLBAR_DOCKED Monitor='{0}' X={1} Y={2} Width={3} ReservationRequested=True" -f $targetScreen.DeviceName, $bounds.Left, $bounds.Top, $bounds.Width)
    } else {
        $script:ToolbarHasBeenParked = $true
        Set-ToolbarClipRegion -Form $form -Enable $false
        Write-ToolbarLog -Message ("TOOLBAR_UNDOCKED Monitor='{0}' X={1} Y={2} Width={3} ReservationReleased=True" -f $targetScreen.DeviceName, $form.Left, $form.Top, $form.Width)
    }
    Publish-ToolbarReservationState
}

# -----------------------------
# Main toolbar
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $ToolbarTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
# Prevent WinForms font/DPI autoscaling from expanding the borderless form
# beyond the monitor width after docking or layout updates.
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $BackColor
# No outer horizontal padding. This allows the right-side panel to reach the screen edge.
$form.Padding = if ($script:TwoRowMode) { New-Object System.Windows.Forms.Padding(0,1,0,1) } else { New-Object System.Windows.Forms.Padding(0,5,0,5) }
$form.AutoSize = $false
$form.MinimumSize = New-Object System.Drawing.Size(0, 0)
$form.MaximumSize = New-Object System.Drawing.Size(0, 0)

# Watermark. This is painted on the form background so it remains behind
# application buttons and the right-side controls.
$form.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen($ToolbarBorderColor, $ToolbarBorderWidth)
    try {
        $half = [float]($ToolbarBorderWidth / 2)
        # Draw fully inside the client area (including the stroke thickness).
        $borderWidth = [Math]::Max(0.0, [float]($sender.ClientSize.Width - $ToolbarBorderWidth - 1))
        $borderHeight = [Math]::Max(0.0, [float]($sender.ClientSize.Height - $ToolbarBorderWidth - 1))
        $e.Graphics.DrawRectangle($pen, $half, $half, $borderWidth, $borderHeight)
    } finally { $pen.Dispose() }
})

# Drag handle. Pull this handle to detach the toolbar from the top and park it
# anywhere on the desktop. The handle is separate from application buttons.
$dragHandle = New-Object System.Windows.Forms.Panel
$dragHandle.Dock = [System.Windows.Forms.DockStyle]::Left
$dragHandle.Width = 18
$dragHandle.BackColor = $BackColor
$dragHandle.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$dragHandle.Margin = New-Object System.Windows.Forms.Padding(0)

$dragGrip = New-Object System.Windows.Forms.Label
$dragGrip.Text = '::'
$dragGrip.Dock = [System.Windows.Forms.DockStyle]::Fill
$dragGrip.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$dragGrip.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$dragGrip.ForeColor = $TextColor
$dragGrip.BackColor = $BackColor
$dragGrip.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$dragHandle.Controls.Add($dragGrip)

# Left-side application area.
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = [System.Windows.Forms.DockStyle]::Fill
$flow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flow.WrapContents = $script:TwoRowMode
$flow.AutoScroll = $false
$flow.BackColor = $BackColor

# Draw the watermark on Section 2 itself. The four-section TableLayoutPanel
# covers the form's background, so painting only on $form is not visible.
# Drawing here leaves application buttons interactive and unobstructed.
# Show the complete watermark only when there is an unobstructed region.
# Prefer the space to the right of the last application button.
$flow.Add_Paint({
    param($sender, $e)
    $rightmost = $sender.Padding.Left
    foreach ($ctrl in $sender.Controls) {
        if ($ctrl.Visible) {
            $rightmost = [Math]::Max($rightmost, $ctrl.Right + $ctrl.Margin.Right)
        }
    }
    $remaining = $sender.ClientSize.Width - $rightmost - $sender.Padding.Right
    # Width of HCA + orange symbol + Toolbar, with a little breathing room.
    $script:ToolbarInfoBounds = [System.Drawing.RectangleF]::Empty
    $needed = 250
    if ($remaining -ge $needed) {
        $rect = [System.Drawing.RectangleF]::new(
            [float]$rightmost, [float]0,
            [float]$remaining, [float]$sender.ClientSize.Height)
        Draw-HCABrandWatermark -Graphics $e.Graphics -Area $rect
    }
})

$flow.Padding = New-Object System.Windows.Forms.Padding(6,0,0,0)
$flow.Margin = New-Object System.Windows.Forms.Padding(0)

# The info icon is painted alongside the watermark; hit-test it on mouse movement.
$flow.Add_MouseMove({
    $point = [System.Drawing.PointF]::new([float]$_.X, [float]$_.Y)
    if (-not $script:ToolbarInfoBounds.IsEmpty -and $script:ToolbarInfoBounds.Contains($point)) {
        $flow.Cursor = [System.Windows.Forms.Cursors]::Help
        Show-ToolbarInfoPopup
    } else {
        $flow.Cursor = [System.Windows.Forms.Cursors]::Default
        Hide-ToolbarInfoPopup
    }
})
$flow.Add_MouseLeave({
    $flow.Cursor = [System.Windows.Forms.Cursors]::Default
    Hide-ToolbarInfoPopup
})

# Four exclusive columns: fixed icons, applications, username, and lock/kill.
$toolbarGrid = New-Object System.Windows.Forms.TableLayoutPanel
$toolbarGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarGrid.Margin = New-Object System.Windows.Forms.Padding(0)
$toolbarGrid.Padding = New-Object System.Windows.Forms.Padding(0)
$toolbarGrid.ColumnCount = 4
$toolbarGrid.AutoSize = $false
$toolbarGrid.GrowStyle = [System.Windows.Forms.TableLayoutPanelGrowStyle]::FixedSize
$toolbarGrid.MinimumSize = New-Object System.Drawing.Size(0, 0)
# In 63-pixel two-row mode, keep user and utility icons in row 1.
# Only the application panel spans both rows.
$toolbarGrid.RowCount = if ($script:TwoRowMode) { 2 } else { 1 }
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 260)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 116)))
if ($script:TwoRowMode) {
    [void]$toolbarGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 33)))
    [void]$toolbarGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
} else {
    [void]$toolbarGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
}
$form.Controls.Add($toolbarGrid)
$section1 = New-Object System.Windows.Forms.FlowLayoutPanel
$section1.Dock = [System.Windows.Forms.DockStyle]::Fill
$section1.WrapContents = $false
$section1.Margin = New-Object System.Windows.Forms.Padding(0)
$section1.Padding = New-Object System.Windows.Forms.Padding(0)
$section1.BackColor = $BackColor
$toolbarGrid.Controls.Add($section1, 0, 0)
$flow.Dock = [System.Windows.Forms.DockStyle]::Fill
$flow.Padding = New-Object System.Windows.Forms.Padding(0)
# Section 2 lives in its own clipped viewport, like a flexible HTML frame.
# It cannot paint or place buttons over the fixed user/utility sections.
$appViewport = New-Object System.Windows.Forms.Panel
$appViewport.Dock = [System.Windows.Forms.DockStyle]::Fill
$appViewport.Margin = New-Object System.Windows.Forms.Padding(0)
$appViewport.Padding = New-Object System.Windows.Forms.Padding(0)
$appViewport.AutoScroll = $false
$appViewport.BackColor = $BackColor
$flow.Dock = [System.Windows.Forms.DockStyle]::Fill
$flow.AutoSize = $false
$flow.MinimumSize = New-Object System.Drawing.Size(0, 0)
$appViewport.Controls.Add($flow)
$toolbarGrid.Controls.Add($appViewport, 1, 0)
if ($script:TwoRowMode) {
    $toolbarGrid.SetRowSpan($appViewport, 2)
}
$dragHandle.Dock = [System.Windows.Forms.DockStyle]::None
$dragHandle.Height = 32
$section1.Controls.Add($dragHandle)

# Right-side area: LoggedInUser value, Lock icon, Kill icon.
# FileValuePath is loaded from Config.json ('Logged In User').

# Use fixed cells instead of a FlowLayoutPanel: WinForms can otherwise
# clip the last icon after a DPI/row-height change.
$rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.ColumnCount = 4
$rightPanel.RowCount = 1
$rightPanel.GrowStyle = [System.Windows.Forms.TableLayoutPanelGrowStyle]::FixedSize
# Column 0 is flexible whitespace. The rightmost columns hold the icons.
[void]$rightPanel.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))
)
foreach ($i in 1..3) {
    [void]$rightPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 36))
    )
}
[void]$rightPanel.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))
)
$rightPanel.BackColor = [System.Drawing.Color]::Transparent
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$rightPanel.Margin = New-Object System.Windows.Forms.Padding(0)

$fileValueLabel = New-Object System.Windows.Forms.Label
$fileValueLabel.Width = 260
$fileValueLabel.Height = 32
$fileValueLabel.Margin = New-Object System.Windows.Forms.Padding(0)
$fileValueLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$fileValueLabel.AutoEllipsis = $true
$fileValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fileValueLabel.BackColor = $BackColor
$fileValueLabel.ForeColor = $TextColor
$fileValueLabel.Padding = New-Object System.Windows.Forms.Padding(8,0,8,0)
$userPanel = New-Object System.Windows.Forms.Panel
$userPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$userPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$userPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$fileValueLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$userPanel.Controls.Add($fileValueLabel)
$toolbarGrid.Controls.Add($userPanel, 2, 0)

function New-RightToolbarButton {
    param(
        [string]$Text,
        [string]$IconFile,
        [int]$Width = 36
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width,32)
    $button.Margin = New-Object System.Windows.Forms.Padding(0)
    $button.Padding = New-Object System.Windows.Forms.Padding(0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.BorderColor = $ButtonBorderColor
    $button.FlatAppearance.MouseOverBackColor = $HoverColor
    $button.BackColor = $ButtonColor
    $button.ForeColor = $TextColor
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TextImageRelation = [System.Windows.Forms.TextImageRelation]::Overlay
    $button.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    if (-not [string]::IsNullOrWhiteSpace($IconFile)) {
        $iconPath = Join-Path $IconFolder $IconFile
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            try {
                $button.Image = Get-ScaledImage -Path $iconPath -Width 24 -Height 24
                $button.AccessibleName = $Text
            } catch {
                Write-ToolbarLog -Level WARNING -Message ("Could not load right-side icon '{0}': {1}" -f $iconPath, $_.Exception.Message)
                # Keep the text fallback when the image cannot be loaded.
            }
        }
    }

    $button.Add_MouseEnter({ $this.BackColor = $HoverColor })
    $button.Add_MouseLeave({ $this.BackColor = $ButtonColor })
    # Utility image buttons remain borderless without a clipping Region.
    return $button
}

# Password Reset is the first control in Section 4.
$passwordResetButton = New-RightToolbarButton -Text '' -IconFile '' -Width 36
$passwordResetButton.AccessibleName = 'Password Reset'
$buttonToolTip.SetToolTip($passwordResetButton, 'Password Reset')
$passwordIconPath = Join-Path $IconFolder 'password-reset.ico'
if (Test-Path -LiteralPath $passwordIconPath -PathType Leaf) {
    try {
        $passwordIcon = New-Object System.Drawing.Icon($passwordIconPath)
        try {
            $passwordResetButton.Image = New-Object System.Drawing.Bitmap($passwordIcon.ToBitmap(), 24, 24)
        } finally {
            $passwordIcon.Dispose()
        }
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Could not load Password Reset icon: {0}" -f $_.Exception.Message)
        $passwordResetButton.Text = 'PW'
    }
} else {
    $passwordResetButton.Text = 'PW'
}
$passwordResetButton.Add_Click({
    Write-ToolbarLog -Message 'BUTTON_CLICK Name=Password Reset'
    Start-ToolbarCommand -Command 'msedge.exe' -Arguments $PasswordResetUrl
})
$passwordResetButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$passwordResetButton.Margin = New-Object System.Windows.Forms.Padding(0)
$passwordColumn = if ($ThirdButtonMode -eq 'None') { 2 } else { 1 }
$rightPanel.Controls.Add($passwordResetButton, $passwordColumn, 0)

$lockButton = New-RightToolbarButton -Text '' -IconFile 'lock.png' -Width 36
$lockButton.AccessibleName = 'Lock Workstation'
$buttonToolTip.SetToolTip($lockButton, 'Lock Workstation')
$lockButton.Add_Click({
    Write-ToolbarLog -Message 'BUTTON_CLICK Name=Lock Workstation'
    try {
        Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' | Out-Null
    } catch {
        Write-ToolbarLog -Level ERROR -Message ("Could not lock the workstation: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            "Could not lock the workstation.`n`n$($_.Exception.Message)",
            $ToolbarTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})
$lockButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$lockButton.Margin = New-Object System.Windows.Forms.Padding(0)
$lockColumn = if ($ThirdButtonMode -eq 'None') { 3 } else { 2 }
$rightPanel.Controls.Add($lockButton, $lockColumn, 0)

# Optional third button, always in the rightmost column.
$exitToolbarButton = $null
if ($ThirdButtonMode -ne 'None') {
    $thirdIcon = if ($ThirdButtonMode -eq 'LogOff') { 'LogOff.png' } else { 'kill.png' }
    $thirdTooltip = if ($ThirdButtonMode -eq 'LogOff') { 'Log Off Windows' } else { 'Exit Toolbar' }
    $exitToolbarButton = New-RightToolbarButton -Text '' -IconFile $thirdIcon -Width 36
    $exitToolbarButton.AccessibleName = $thirdTooltip
    $buttonToolTip.SetToolTip($exitToolbarButton, $thirdTooltip)
    $exitToolbarButton.Dock = [System.Windows.Forms.DockStyle]::Fill
    $exitToolbarButton.Margin = New-Object System.Windows.Forms.Padding(0)
    $rightPanel.Controls.Add($exitToolbarButton, 3, 0)
}

# Add the right-side panel after the left Fill panel so it remains at the extreme right.
$rightPanel.Width = 116
$section4 = $rightPanel
$toolbarGrid.Controls.Add($rightPanel, 3, 0)

$script:LastFileValueStatus = $null
$script:LastLoggedInUserValue = $null

function Get-CmdLoggedInUser {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/c echo %username%'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $process) { return $null }
        try {
            $username = $process.StandardOutput.ReadToEnd().Trim()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($username) -or $username -eq '%username%') {
                return $null
            }
            return $username
        } finally { $process.Dispose() }
    } catch { return $null }
}

function Update-FileValue {
    $value = 'No User was found'
    $status = 'FALLBACK_FAILED'
    $source = 'cmd.exe /c echo %username%'
    $fallbackReason = $null

    if (Test-Path -LiteralPath $FileValuePath -PathType Leaf) {
        try {
            $text = Get-Content -LiteralPath $FileValuePath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($text)) {
                $fallbackReason = 'EMPTY_FILE'
            } else {
                $value = $text.Trim()
                $status = 'OK'
                $source = $FileValuePath
            }
        } catch {
            $fallbackReason = 'READ_ERROR'
            if ($script:LastFileValueStatus -ne 'READ_ERROR' -and
                $script:LastFileValueStatus -ne 'READ_ERROR_CMD_FALLBACK' -and
                $script:LastFileValueStatus -ne 'READ_ERROR_FALLBACK_FAILED') {
                Write-ToolbarLog -Level ERROR -Message ("Could not read logged-in-user file '{0}': {1}" -f $FileValuePath, $_.Exception.Message)
            }
        }
    } else {
        $fallbackReason = 'MISSING_FILE'
    }

    if ($null -ne $fallbackReason) {
        $cmdUser = Get-CmdLoggedInUser
        if (-not [string]::IsNullOrWhiteSpace($cmdUser)) {
            $value = $cmdUser
            $status = "${fallbackReason}_CMD_FALLBACK"
        } else {
            $value = 'No User was found'
            $status = "${fallbackReason}_FALLBACK_FAILED"
        }
        if ($script:LastFileValueStatus -cne $status) {
            Write-ToolbarLog -Level WARNING -Message ("Logged-in-user file fallback reason='{0}' Path='{1}' Command='cmd.exe /c echo %username%'" -f $fallbackReason, $FileValuePath)
        }
    }

    $fileValueLabel.Text = $value
    if ($script:LastFileValueStatus -cne $status -or $script:LastLoggedInUserValue -cne $value) {
        Write-ToolbarLog -Message ("LOGGED_IN_USER Value='{0}' Source='{1}' Status='{2}'" -f ($value -replace "'", "''"), $source, $status)
    }
    $script:LastFileValueStatus = $status
    $script:LastLoggedInUserValue = $value
}

# Section 1: drag handle followed by Button Manager (no HCA logo control).
$manageButton = New-Object System.Windows.Forms.Button
$manageButton.Text = ''
$manageButton.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 12)
$manageButton.Size = New-Object System.Drawing.Size(38,32)
$manageButton.Margin = New-Object System.Windows.Forms.Padding(0,0,6,0)
$manageButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$manageButton.FlatAppearance.BorderSize = 0
$manageButton.FlatAppearance.BorderColor = $BackColor
$manageButton.FlatAppearance.MouseOverBackColor = $BackColor
$manageButton.FlatAppearance.MouseDownBackColor = $BackColor
$manageButton.BackColor = $BackColor
$manageButton.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$manageButton.Margin = New-Object System.Windows.Forms.Padding(0)
$manageButton.Padding = New-Object System.Windows.Forms.Padding(0)
$manageButton.ForeColor = $TextColor
$manageButton.Cursor = [System.Windows.Forms.Cursors]::Hand

# Image-only Button Manager control, using icon\ButtonManager.png.
# Keep BM text as a fallback if the image is missing or unreadable.
$managerIconPath = Join-Path $IconFolder 'ButtonManager.png'
if (Test-Path -LiteralPath $managerIconPath -PathType Leaf) {
    try {
        $manageButton.Image = Get-ScaledImage -Path $managerIconPath -Width 28 -Height 28
        $manageButton.Text = ''
        $manageButton.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $manageButton.TextImageRelation = [System.Windows.Forms.TextImageRelation]::Overlay
    } catch {
        $manageButton.Text = 'BM'
    }
}
$manageButton.AccessibleName = 'Button Manager'
$buttonToolTip.SetToolTip($manageButton, 'Manage Toolbar Buttons')
# Dropdown immediately before the Button Manager icon.
$script:ToolbarDropdownItems = @()
$toolbarDropdown = New-Object System.Windows.Forms.Button
$toolbarDropdown.Text = [string][char]0x25BC
$toolbarDropdown.Size = New-Object System.Drawing.Size(18,32)
$toolbarDropdown.Margin = New-Object System.Windows.Forms.Padding(0)
$toolbarDropdown.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$toolbarDropdown.FlatAppearance.BorderSize = 0
$toolbarDropdown.BackColor = $BackColor
$toolbarDropdown.ForeColor = $TextColor
$toolbarDropdown.Cursor = [System.Windows.Forms.Cursors]::Hand
$toolbarDropdown.AccessibleName = 'Toolbar buttons dropdown'
$buttonToolTip.SetToolTip($toolbarDropdown, 'Show all toolbar buttons')
$section1.Controls.Add($toolbarDropdown)

$toolbarDropdownMenu = New-Object System.Windows.Forms.ContextMenuStrip
$toolbarDropdownMenu.ShowImageMargin = $false
$toolbarDropdownMenu.Padding = New-Object System.Windows.Forms.Padding(0)
$toolbarDropdownList = New-Object System.Windows.Forms.ListBox
$toolbarDropdownList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$toolbarDropdownList.IntegralHeight = $false
$toolbarDropdownList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$toolbarDropdownList.BackColor = $ButtonColor
$toolbarDropdownList.ForeColor = $TextColor
$toolbarDropdownList.HorizontalScrollbar = $false
$toolbarDropdownList.SelectionMode = [System.Windows.Forms.SelectionMode]::One
$toolbarDropdownHost = New-Object System.Windows.Forms.ToolStripControlHost($toolbarDropdownList)
$toolbarDropdownHost.Margin = New-Object System.Windows.Forms.Padding(2)
$toolbarDropdownHost.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$toolbarDropdownMenu.Items.Add($toolbarDropdownHost)

function Update-ToolbarDropdown {
    $script:ToolbarDropdownItems = @($flow.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $null -ne $_.Tag -and $null -ne $_.Tag.Id })
    $toolbarDropdownList.BeginUpdate()
    try {
        $toolbarDropdownList.Items.Clear()
        foreach ($item in $script:ToolbarDropdownItems) {
            [void]$toolbarDropdownList.Items.Add([string]$item.Tag.Name)
        }
    } finally { $toolbarDropdownList.EndUpdate() }
    $maxRows = 12
    $visibleRows = [Math]::Max(1, [Math]::Min($maxRows, $script:ToolbarDropdownItems.Count))
    $toolbarDropdownList.Size = New-Object System.Drawing.Size(240, ($visibleRows * $toolbarDropdownList.ItemHeight + 4))
    $toolbarDropdownHost.Size = $toolbarDropdownList.Size
}
$toolbarDropdown.Add_Click({
    Update-ToolbarDropdown
    if ($script:ToolbarDropdownItems.Count -eq 0) { return }
    $toolbarDropdownList.ClearSelected()
    $toolbarDropdownMenu.Show($toolbarDropdown, (New-Object System.Drawing.Point(0, $toolbarDropdown.Height)))
})
$toolbarDropdownList.Add_MouseClick({
    $index = $toolbarDropdownList.IndexFromPoint($_.Location)
    if ($index -lt 0 -or $index -ge $script:ToolbarDropdownItems.Count) { return }
    $button = $script:ToolbarDropdownItems[$index]
    $toolbarDropdownMenu.Close()
    Write-ToolbarLog -Message ("DROPDOWN_CLICK Name='{0}' Id='{1}'" -f ([string]$button.Tag.Name), ([string]$button.Tag.Id))
    $button.PerformClick()
})
$toolbarDropdownList.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $toolbarDropdownMenu.Close(); return }
    if ($_.KeyCode -ne [System.Windows.Forms.Keys]::Enter) { return }
    $index = $toolbarDropdownList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:ToolbarDropdownItems.Count) { return }
    $button = $script:ToolbarDropdownItems[$index]
    $toolbarDropdownMenu.Close()
    $button.PerformClick()
    $_.Handled = $true
})

$section1.Controls.Add($manageButton)

# Section 3 sizes itself to the displayed value, leaving more room for apps.
function Update-UserSectionWidth {
    if ($null -eq $fileValueLabel -or $null -eq $toolbarGrid) { return }
    $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
        [string]$fileValueLabel.Text, $fileValueLabel.Font).Width
    $fixedLeft = 74
    $fixedRight = 116
    # On smaller laptop displays, protect space for the application frame.
    $maxUserWidth = [Math]::Max(60, [Math]::Min(260,
        $toolbarGrid.ClientSize.Width - $fixedLeft - $fixedRight - 160))
    $newWidth = [Math]::Min($maxUserWidth, [Math]::Max(110, $textWidth + 20))
    if ([int]$toolbarGrid.ColumnStyles[2].Width -ne $newWidth) {
        $toolbarGrid.ColumnStyles[2].Width = $newWidth
        $toolbarGrid.PerformLayout()
        Update-ApplicationWidths
    }
}

function Get-EqualApplicationButtonWidth {
    param([int]$SelectedCount)
    if ($SelectedCount -le $EqualWidthThreshold) { return 0 }
    $usable = $flow.ClientSize.Width - $flow.Padding.Horizontal - 2
    if ($usable -le 0) { return 0 }
    return [Math]::Max(1, [int][Math]::Floor($usable / $SelectedCount))
}

function Update-ApplicationWidths {
    if ($script:UpdatingWidths) { return }
    $script:UpdatingWidths = $true
    try {
        $apps = @($flow.Controls | Where-Object { $null -ne $_.Tag -and $null -ne $_.Tag.Id })
        if ($apps.Count -eq 0) { return }
        $usable = [Math]::Max(0, $flow.ClientSize.Width - $flow.Padding.Horizontal - 6)
        if ($usable -le 0) { return }
        if ($script:TwoRowMode) {
            # Up to 20 on row 1; then row 2. Above 40, split evenly
            # with the extra button on row 1.
            $row1Count = if ($apps.Count -le 40) {
                [Math]::Min(20, $apps.Count)
            } else { [int][Math]::Ceiling($apps.Count / 2.0) }
            $row2Count = $apps.Count - $row1Count
            $flow.SuspendLayout()
            try {
                for ($i = 0; $i -lt $apps.Count; $i++) {
                    $flow.SetFlowBreak($apps[$i], ($row2Count -gt 0 -and $i -eq ($row1Count - 1)))
                }
                for ($row = 0; $row -lt 2; $row++) {
                    $start = if ($row -eq 0) { 0 } else { $row1Count }
                    $count = if ($row -eq 0) { $row1Count } else { $row2Count }
                    if ($count -eq 0) { continue }
                    $preferred = @()
                    for ($i = $start; $i -lt ($start + $count); $i++) {
                        $preferred += [Math]::Max(92, ([string]$apps[$i].Tag.Name).Length * 8 + 42)
                    }
                    $sum = 0
                    foreach ($w in $preferred) { $sum += $w }
                    # More than 40: equal widths within each row. Otherwise
                    # retain name-based widths, scaling only if needed to fit.
                    $equal = ($apps.Count -gt 40)
                    $remaining = $usable
                    for ($j = 0; $j -lt $count; $j++) {
                        $i = $start + $j
                        if ($equal) {
                            $w = [int][Math]::Floor($usable / $count) + [int]($j -lt ($usable % $count))
                        } elseif ($sum -le $usable) {
                            $w = $preferred[$j]
                        } elseif ($j -eq ($count - 1)) {
                            $w = $remaining
                        } else {
                            $w = [int][Math]::Floor($usable * $preferred[$j] / $sum)
                        }
                        $w = [Math]::Max(1, [int]$w)
                        $apps[$i].Width = $w
                        $apps[$i].AutoEllipsis = $false
                        Set-SingleLineButtonText -Button $apps[$i]
                        $remaining -= $w
                    }
                }
            } finally { $flow.ResumeLayout($true) }
            return
        }
        $preferred = @($apps | ForEach-Object { [Math]::Max(92, ([string]$_.Tag.Name).Length * 8 + 42) })
        $widths = New-Object 'System.Collections.Generic.List[int]'
        if ($apps.Count -gt $EqualWidthThreshold) {
            $base = [int][Math]::Floor($usable / $apps.Count)
            $extra = $usable - $base * $apps.Count
            for ($i=0; $i -lt $apps.Count; $i++) {
                [void]$widths.Add([Math]::Max(1, $base + [int]($i -lt $extra)))
            }
        } else {
            $total = 0
            foreach ($w in $preferred) { $total += $w }
            if ($total -le $usable) {
                foreach ($w in $preferred) { [void]$widths.Add([int]$w) }
            } else {
                $remaining = $usable
                for ($i=0; $i -lt $apps.Count; $i++) {
                    $w = if ($i -eq $apps.Count-1) { $remaining } else {
                        [int][Math]::Floor($usable * $preferred[$i] / $total)
                    }
                    $w = [Math]::Max(1, $w)
                    [void]$widths.Add($w)
                    $remaining -= $w
                }
            }
        }
        $flow.SuspendLayout()
        try {
            for ($i=0; $i -lt $apps.Count; $i++) {
                $apps[$i].Width = $widths[$i]
                $apps[$i].AutoEllipsis = $false
                Set-SingleLineButtonText -Button $apps[$i]
            }
        } finally { $flow.ResumeLayout($true) }
    } finally { $script:UpdatingWidths = $false }
}

function Rebuild-ToolbarButtons {
    $flow.SuspendLayout()
    try {
        foreach ($control in @($flow.Controls)) {
            $flow.Controls.Remove($control)
            $control.Dispose()
        }
        $selectedItems = @(Get-SelectedButtons | Select-Object -First $MaxSelectedButtons)
        $width = 0
        foreach ($item in $selectedItems) {
            [void]$flow.Controls.Add((New-ToolbarButton -Item $item -ButtonWidth $width))
        }
    } finally { $flow.ResumeLayout($true) }
    Update-ApplicationWidths
    Update-ToolbarDropdown
    $flow.Invalidate()
    Write-ToolbarLog -Message ("Toolbar rebuilt with {0} application button(s)." -f $selectedItems.Count)

    # Reflow after Button Manager saves a changed selection.
    # The first rebuild occurs before the window handle exists.
    if ($form.IsHandleCreated -and -not $form.IsDisposed) {
        Refresh-ToolbarLayout
        $script:StartupLayoutTimer.Stop()
        $script:StartupLayoutTimer.Start()
        Write-ToolbarLog -Message 'Scheduled layout refresh after Button Manager changes.'
    }
}

$manageButton.Add_Click({
    Write-ToolbarLog -Message 'BUTTON_CLICK Name=Button Manager'
    Show-ButtonManager -Owner $form -OnSaved { Rebuild-ToolbarButtons }
})

Update-FileValue
Update-UserSectionWidth
$fileValueTimer = New-Object System.Windows.Forms.Timer
$fileValueTimer.Interval = 1000
$fileValueTimer.Add_Tick({ Update-FileValue; Update-UserSectionWidth })
$fileValueTimer.Start()

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = $ToolbarTitle
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayShow = $trayMenu.Items.Add('Hide Toolbar')
$trayManage = $trayMenu.Items.Add('Manage Buttons')
$trayExit = $trayMenu.Items.Add('Exit')
$trayShow.Add_Click({
    # The tray menu uses the same auto-hide state as the toolbar context menu.
    Set-ToolbarAutoHideState -Hide (-not $script:ToolbarAutoHidden)
})
$trayManage.Add_Click({ Show-ButtonManager -Owner $form -OnSaved { Rebuild-ToolbarButtons } })
$trayExit.Add_Click({ $notifyIcon.Visible = $false; $notifyIcon.Dispose(); $form.Close() })
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Add_DoubleClick({
    Set-ToolbarAutoHideState -Hide (-not $script:ToolbarAutoHidden)
    if (-not $script:ToolbarAutoHidden) { $form.Activate() }
})

if ($ThirdButtonMode -eq 'Kill') {
    $exitToolbarButton.Add_Click({
        Write-ToolbarLog -Message 'BUTTON_CLICK Name=Kill Toolbar'
        if ($notifyIcon) {
            $notifyIcon.Visible = $false
            $notifyIcon.Dispose()
        }
        $form.Close()
    })
} elseif ($ThirdButtonMode -eq 'LogOff') {
    $exitToolbarButton.Add_Click({
        Write-ToolbarLog -Message 'BUTTON_CLICK Name=LogOff'
        $proceed = $true
        if ($LogOffConfirmation -eq 'Yes') {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'Do you want to LogOff?',
                'Confirm LogOff',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            $proceed = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
        }
        if ($proceed) {
            Write-ToolbarLog -Message ("LOGOFF_REQUESTED ConfirmationSetting='{0}'" -f $LogOffConfirmation)
            try {
                Start-Process -FilePath 'shutdown.exe' -ArgumentList '/l' -ErrorAction Stop | Out-Null
            } catch {
                Write-ToolbarLog -Level ERROR -Message ("Windows logoff failed: {0}" -f $_.Exception.Message)
                [System.Windows.Forms.MessageBox]::Show(
                    "Could not log off Windows.`n$($_.Exception.Message)",
                    'HCA Toolbar',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            }
        } else {
            Write-ToolbarLog -Message 'LOGOFF_CANCELLED'
        }
    })
}

# Drag events are limited to the dedicated handle so application buttons keep
# their normal click behavior.
$dragHandle.Add_MouseDown({ Start-ToolbarDrag -EventArgs $_ })
$dragHandle.Add_MouseMove({ Move-ToolbarDrag })
$dragHandle.Add_MouseUp({ Stop-ToolbarDrag })
$dragGrip.Add_MouseDown({ Start-ToolbarDrag -EventArgs $_ })
$dragGrip.Add_MouseMove({ Move-ToolbarDrag })
$dragGrip.Add_MouseUp({ Stop-ToolbarDrag })
# Auto-hide: the form remains alive and slides just above its docked monitor.
# Moving the pointer to the top edge temporarily reveals it; Unhide pins it open.
$script:ToolbarAutoHidden = $false
$script:ToolbarPeekVisible = $false
$script:ToolbarLastHover = [DateTime]::MinValue
$toolbarRightClickMenu = New-Object System.Windows.Forms.ContextMenuStrip
$toolbarHideItem = $toolbarRightClickMenu.Items.Add('Hide Toolbar')
$toolbarUnhideItem = $toolbarRightClickMenu.Items.Add('Unhide Toolbar')
$toolbarUnhideItem.Visible = $false

# When the third utility button is LogOff or None, offer an exit action
# on the toolbar's existing right-click menu.
if ($ThirdButtonMode -ne 'Kill') {
    [void]$toolbarRightClickMenu.Items.Add(
        (New-Object System.Windows.Forms.ToolStripSeparator)
    )
    $toolbarKillLaunchpadItem = $toolbarRightClickMenu.Items.Add('Kill Launchpad')
    $toolbarKillLaunchpadItem.Add_Click({
        Write-ToolbarLog -Message 'CONTEXT_MENU_CLICK Name=Kill Launchpad'
        # Closing the form invokes its existing cleanup handlers and releases
        # the toolbar's single-instance mutex.
        $form.Close()
    })
}
function Set-ToolbarAutoHideState {
    param([bool]$Hide)
    $script:ToolbarAutoHidden = $Hide
    Publish-ToolbarReservationState
    $script:ToolbarPeekVisible = $false
    $toolbarHideItem.Visible = -not $Hide
    $toolbarUnhideItem.Visible = $Hide
    $trayShow.Text = if ($Hide) { 'Unhide Toolbar' } else { 'Hide Toolbar' }
    if ($Hide) {
        $form.Top = $script:DockedScreen.Bounds.Top - $form.Height + 1
        Write-ToolbarLog -Message 'TOOLBAR_HIDDEN Reason=AutoHide ReservationReleased=True'
    } else {
        $form.Top = $script:DockedScreen.Bounds.Top
        Write-ToolbarLog -Message 'TOOLBAR_UNHIDDEN Reason=AutoHide ReservationRequested=True'
    }
}
$toolbarHideItem.Add_Click({ Set-ToolbarAutoHideState -Hide $true })
$toolbarUnhideItem.Add_Click({ Set-ToolbarAutoHideState -Hide $false })
# Context menus on empty toolbar surfaces; keep existing button right-click actions.
foreach ($surface in @($form, $toolbarGrid, $appViewport, $flow, $section1, $dragHandle, $dragGrip)) {
    $surface.ContextMenuStrip = $toolbarRightClickMenu
}
$autoHideTimer = New-Object System.Windows.Forms.Timer
$autoHideTimer.Interval = 100
$autoHideTimer.Add_Tick({
    if (-not $script:ToolbarAutoHidden -or $form.IsDisposed) { return }
    $pointer = [System.Windows.Forms.Control]::MousePosition
    $screenBounds = $script:DockedScreen.Bounds
    $atTop = ($pointer.X -ge $screenBounds.Left -and $pointer.X -lt $screenBounds.Right -and
              $pointer.Y -ge $screenBounds.Top -and $pointer.Y -le ($screenBounds.Top + 2))
    if (-not $script:ToolbarPeekVisible -and $atTop) {
        $form.Top = $screenBounds.Top
        $script:ToolbarPeekVisible = $true
        $script:ToolbarLastHover = [DateTime]::Now
    }
    if ($script:ToolbarPeekVisible) {
        $within = $form.Bounds.Contains($pointer)
        if ($within -or $toolbarRightClickMenu.Visible -or $toolbarDropdownMenu.Visible) {
            $script:ToolbarLastHover = [DateTime]::Now
        } elseif (([DateTime]::Now - $script:ToolbarLastHover).TotalMilliseconds -gt 650) {
            $form.Top = $screenBounds.Top - $form.Height + 1
            $script:ToolbarPeekVisible = $false
        }
    }
})
$autoHideTimer.Start()

$form.Add_MouseMove({ Move-ToolbarDrag })
$form.Add_MouseUp({ Stop-ToolbarDrag })
$form.Add_Resize({ $form.Invalidate(); Update-ApplicationWidths })
$flow.Add_SizeChanged({ Update-ApplicationWidths; $flow.Invalidate() })
$appViewport.Add_SizeChanged({ Update-ApplicationWidths })

# Refresh the four-column layout after the window handle exists. This fixes
# occasional startup clipping of the last (Kill) icon.
function Refresh-ToolbarLayout {
    if ($form.IsDisposed -or -not $form.IsHandleCreated) { return }
    try {
        # Section 4 contains three 36-pixel icon buttons plus 8 pixels of right padding.
        $toolbarGrid.ColumnStyles[3].Width = 116
        $rightPanel.MinimumSize = New-Object System.Drawing.Size(0, 0)
        $toolbarGrid.PerformLayout()
        $appViewport.PerformLayout()
        $flow.PerformLayout()
        $rightPanel.PerformLayout()
        Update-UserSectionWidth
        $utilityNames = if ($ThirdButtonMode -eq 'None') { 'Password Reset, Lock' } else { "Password Reset, Lock, $ThirdButtonMode" }
        Write-ToolbarLog -Message (
            "UTILITY_LAYOUT Mode='{0}' Buttons='{1}' GridWidth={2} PanelWidth={3} RightmostButtonRight={4}" -f
            $ThirdButtonMode, $utilityNames, $toolbarGrid.ColumnStyles[3].Width,
            $rightPanel.ClientSize.Width,
            $(if ($exitToolbarButton) { $exitToolbarButton.Right } else { $lockButton.Right })
        )
        Update-ApplicationWidths
        $form.Invalidate($true)
        $viewportRect = $appViewport.RectangleToScreen($appViewport.ClientRectangle)
        $rightRect = $rightPanel.RectangleToScreen($rightPanel.ClientRectangle)
        Write-ToolbarLog -Message ("RESPONSIVE_LAYOUT Form=({0},{1},{2},{3}) LeftWidth={4} AppViewport=({5},{6},{7},{8}) UserWidth={9} Utility=({10},{11},{12},{13})" -f
            $form.Left, $form.Top, $form.Width, $form.Height,
            $toolbarGrid.ColumnStyles[0].Width,
            $viewportRect.Left, $viewportRect.Top, $viewportRect.Width, $viewportRect.Height,
            $toolbarGrid.ColumnStyles[2].Width,
            $rightRect.Left, $rightRect.Top, $rightRect.Width, $rightRect.Height)

    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Toolbar layout refresh failed: {0}" -f $_.Exception.Message)
    }
}

$script:StartupLayoutTimer = New-Object System.Windows.Forms.Timer
$script:StartupLayoutTimer.Interval = 500
$script:StartupLayoutTimer.Add_Tick({
    $script:StartupLayoutTimer.Stop()
    Refresh-ToolbarLayout
    if (-not $script:ToolbarHasBeenParked -and -not $script:ToolbarAutoHidden) {
        Set-ToolbarBounds -Form $form -Screen $script:DockedScreen
    }
    Write-ToolbarWindowDiagnostics -Reason 'STARTUP_DELAYED'
    if (-not $script:ToolbarHasBeenParked) {
        Write-ToolbarBoundaryOwners -Screen $script:DockedScreen -Reason 'STARTUP_DELAYED'
    }
    # Re-publish only after WinForms has completed the delayed layout.
    Publish-ToolbarReservationState
})
$form.Add_Shown({
    if (-not $script:ToolbarHasBeenParked) {
        Set-ToolbarBounds -Form $form -Screen $script:DockedScreen
    }
    Refresh-ToolbarLayout
    Sync-ToolbarMonitor
    # Apply the configured startup state after WinForms has created the form.
    # Keep the form running so the tray icon and top-edge auto-hide still work.
    if ($script:StartToolbarHidden) {
        Set-ToolbarAutoHideState -Hide $true
    }
    # Form.Visible is now reliable; the previous pre-Run publish was false.
    Publish-ToolbarReservationState
    $script:StartupLayoutTimer.Start()
})
# Re-query Screen.AllScreens rather than holding on to an obsolete Screen object.
# Windows may change the bounds and DPI layout when a monitor is disconnected,
# reconnected, rearranged, or its resolution changes.
$script:LastMonitorSignature = ''
function Sync-ToolbarMonitor {
    if ($form.IsDisposed -or -not $form.IsHandleCreated -or $script:IsDraggingToolbar -or $script:ToolbarAutoHidden) { return }

    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -eq 0) { return }

    if (-not $script:ToolbarHasBeenParked) {
        # Keep the same physical monitor by DeviceName, but use its CURRENT bounds.
        $live = $null
        foreach ($candidate in $screens) {
            if ($candidate.DeviceName -eq $script:DockedScreen.DeviceName) {
                $live = $candidate
                break
            }
        }
        # If the old monitor disappeared, dock to the monitor containing the form.
        if ($null -eq $live) {
            $live = [System.Windows.Forms.Screen]::FromControl($form)
        }
        $script:DockedScreen = $live
        $bounds = $live.Bounds
        $signature = '{0}|{1}|{2}|{3}|{4}|{5}' -f $live.DeviceName, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, $ToolbarHeight
        $outOfDate = ($form.Left -ne $bounds.Left -or $form.Top -ne $bounds.Top -or
                      $form.Width -ne $bounds.Width -or $form.Height -ne $ToolbarHeight)
        if ($signature -ne $script:LastMonitorSignature -or $outOfDate) {
            $script:LastMonitorSignature = $signature
            Set-ToolbarBounds -Form $form -Screen $live
            $toolbarGrid.PerformLayout()
            Refresh-ToolbarLayout
            Write-ToolbarLog -Message ("Monitor layout synchronized: {0}, X={1}, Y={2}, Width={3}, Height={4}, ActualRight={5}, MonitorRight={6}, NativeBounds=True." -f $live.DeviceName, $bounds.Left, $bounds.Top, $bounds.Width, $ToolbarHeight, $form.Right, $bounds.Right)
            Write-ToolbarWindowDiagnostics -Reason 'MONITOR_SYNC'
            Write-ToolbarBoundaryOwners -Screen $live -Reason 'MONITOR_SYNC'
        }
    } else {
        # A parked/floating toolbar should not jump back to the top on a
        # monitor change. Only move it if it is completely off every display.
        $visible = $false
        foreach ($candidate in $screens) {
            if ($candidate.Bounds.IntersectsWith($form.Bounds)) { $visible = $true; break }
        }
        if (-not $visible) {
            $live = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Control]::MousePosition)
            $area = $live.WorkingArea
            $newWidth = [Math]::Min($form.Width, $area.Width)
            $form.SetBounds($area.Left, $area.Top, $newWidth, $ToolbarHeight)
            Refresh-ToolbarLayout
        }
    }
}

$screenTimer = New-Object System.Windows.Forms.Timer
$screenTimer.Interval = 1000
$screenTimer.Add_Tick({ Sync-ToolbarMonitor })
$screenTimer.Start()


Set-ToolbarBounds -Form $form -Screen $script:DockedScreen
$toolbarGrid.PerformLayout()
Rebuild-ToolbarButtons
$form.Add_FormClosed({
    Remove-ToolbarVisibilityState
    Write-ToolbarLog -Message 'Toolbar is closing.'
    $script:StartupLayoutTimer.Stop()
    $script:StartupLayoutTimer.Dispose()
    $screenTimer.Stop()
    $screenTimer.Dispose()
    $autoHideTimer.Stop()
    $autoHideTimer.Dispose()
    $toolbarRightClickMenu.Dispose()
    if ($fileValueTimer) {
        $fileValueTimer.Stop()
        $fileValueTimer.Dispose()
    }
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($script:ToolbarInfoToolTip) { $script:ToolbarInfoToolTip.Dispose() }
    if ($buttonToolTip) {
        $buttonToolTip.Dispose()
    }
})

try {
    # Do not publish before Application.Run: Form.Visible is false here.
    [System.Windows.Forms.Application]::Run($form)
} finally {
    Remove-ToolbarVisibilityState
    if ($script:ToolbarOwnsMutex -and $script:ToolbarInstanceMutex) {
        try { $script:ToolbarInstanceMutex.ReleaseMutex() } catch {}
    }
    if ($script:ToolbarInstanceMutex) {
        $script:ToolbarInstanceMutex.Dispose()
    }
}
