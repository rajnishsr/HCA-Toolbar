# ToolbarApp.ps1
# Windows PowerShell 5.1+ / PowerShell 7+ on Windows
# Reads Buttons.json as the master catalog and ToolbarConfig.json as the user's selection.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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
$MasterFile = Resolve-ToolbarSettingPath (Get-RequiredToolbarSetting 'Master Button File')
$IconFolder = Join-Path $AppDir 'icon'
[int]$buttonLimit = 0
if (-not [int]::TryParse((Get-RequiredToolbarSetting 'Button Limit'), [ref]$buttonLimit) -or $buttonLimit -lt 1) {
    throw "Config.json 'Button Limit' must be a positive integer."
}
$MaxSelectedButtons = $buttonLimit
[int]$topSpace = 0
if (-not [int]::TryParse((Get-RequiredToolbarSetting 'Top Space for Toolbar'), [ref]$topSpace) -or $topSpace -lt 2) {
    throw "Config.json 'Top Space for Toolbar' must be an integer of at least 2."
}
$ToolbarHeight = $topSpace - 1
$FileValuePath = Resolve-ToolbarSettingPath (Get-RequiredToolbarSetting 'Logged In User')

$ToolbarTitle = 'Top Toolbar'
$BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
$ButtonColor = [System.Drawing.Color]::White
$TextColor = [System.Drawing.Color]::FromArgb(35,35,35)
$HoverColor = [System.Drawing.Color]::FromArgb(232,232,232)

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
Write-ToolbarLog -Message ("Starting toolbar. AppDir='{0}'" -f $AppDir)

# Audit the effective settings after Config.json has been parsed and validated.
# Logging is initialized here, so all values are written to the configured logs folder.
Write-ToolbarLog -Message ("CONFIG Name='User Button File' Value='{0}' ResolvedPath='{1}'" -f $settings['User Button File'], $ConfigFile)
Write-ToolbarLog -Message ("CONFIG Name='Master Button File' Value='{0}' ResolvedPath='{1}'" -f $settings['Master Button File'], $MasterFile)
Write-ToolbarLog -Message ("CONFIG Name='Button Limit' Value='{0}' MaxSelectedButtons={1}" -f $settings['Button Limit'], $MaxSelectedButtons)
Write-ToolbarLog -Message ("CONFIG Name='Top Space for Toolbar' Value='{0}' ToolbarHeight={1}" -f $settings['Top Space for Toolbar'], $ToolbarHeight)
Write-ToolbarLog -Message ("CONFIG Name='Logged In User' Value='{0}' ResolvedPath='{1}'" -f $settings['Logged In User'], $FileValuePath)


# When the number of selected application buttons is greater than this value,
# the application buttons are resized to equal widths.
$EqualWidthThreshold = 19
$WatermarkText = 'HCA Toolbar'
# HCA Healthcare brand-inspired watermark: navy HCA sans-serif,
# followed by navy Toolbar in a bold serif similar to Healthcare.
$WatermarkColor = [System.Drawing.Color]::FromArgb(9,34,64)
$WatermarkMarkPath = Join-Path $IconFolder 'HCA_OrangeMark.png'
$WatermarkHCAFont = New-Object System.Drawing.Font('Arial', 17, [System.Drawing.FontStyle]::Bold)
$WatermarkToolbarFont = New-Object System.Drawing.Font('Georgia', 16, [System.Drawing.FontStyle]::Bold)

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
        $totalWidth = $hcaSize.Width + $markWidth + $markGap + $toolbarSize.Width
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
    } finally {
        $brush.Dispose()
        $format.Dispose()
    }
}
# Toolbar branding image and border. The logo is expected in the icon folder.
$ToolbarLogoFile = 'HCA-Toolbar.png'
$ToolbarLogoPath = Join-Path $IconFolder $ToolbarLogoFile
$ToolbarBorderColor = [System.Drawing.Color]::FromArgb(3,45,108)
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

function Set-ToolbarBounds {
    param(
        [System.Windows.Forms.Form]$Form,
        [System.Windows.Forms.Screen]$Screen = [System.Windows.Forms.Screen]::PrimaryScreen
    )
    # Use monitor bounds, not WorkingArea, to span the entire top edge.
    $bounds = $Screen.Bounds
    $Form.SetBounds($bounds.Left, $bounds.Top, $bounds.Width, $ToolbarHeight)
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

    for ($i = 0; $i -lt $appControls.Count; $i++) {
        $control = $appControls[$i]
        $centerX = $control.Left + [int]($control.Width / 2)
        if ($point.X -ge $centerX) {
            $targetOrdinal = $i + 1
        } else {
            break
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
        $paint = {
            param($sender,$e)
            $w = $sender.ClientSize.Width - 2; $h = $sender.ClientSize.Height - 2
            if ($w -lt 4 -or $h -lt 4) { return }
            $d = 2 * [Math]::Min($Radius, [int]([Math]::Min($w,$h) / 2))
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
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
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
    $button.FlatAppearance.MouseOverBackColor = $HoverColor
    $button.BackColor = $ButtonColor
    $button.ForeColor = $TextColor
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9)
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

    $title = New-Object System.Windows.Forms.Label
    $title.Text = ('Available applications: {0}' -f $master.Count)
    $title.Dock = [System.Windows.Forms.DockStyle]::Fill
    $title.Padding = New-Object System.Windows.Forms.Padding(4,8,0,0)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $layout.Controls.Add($title, 0, 0)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = ("Buttons shown on toolbar: {0}.`nMaximum buttons allowed on toolbar: {1}." -f ([Math]::Min($selected.Count, $MaxSelectedButtons)), $MaxSelectedButtons)
    $hint.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hint.Padding = New-Object System.Windows.Forms.Padding(4,0,4,4)
    $layout.Controls.Add($hint, 0, 1)

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.IntegralHeight = $false
    $list.CheckOnClick = $true
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)

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

    $buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonsPanel.Height = 52
    $buttonsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttonsPanel.WrapContents = $false
    $buttonsPanel.Padding = New-Object System.Windows.Forms.Padding(0,8,0,0)
    $layout.Controls.Add($buttonsPanel, 0, 3)

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
        $actionButton.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
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
        Write-ToolbarLog -Message ("Toolbar docked to monitor '{0}' at X={1}, Y={2}, Width={3}." -f $targetScreen.DeviceName, $bounds.Left, $bounds.Top, $bounds.Width)
    } else {
        $script:ToolbarHasBeenParked = $true
    }
}

# -----------------------------
# Main toolbar
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $ToolbarTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $BackColor
# No outer horizontal padding. This allows the right-side panel to reach the screen edge.
$form.Padding = New-Object System.Windows.Forms.Padding(0,5,0,5)
$form.AutoSize = $false

# Watermark. This is painted on the form background so it remains behind
# application buttons and the right-side controls.
$form.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen($ToolbarBorderColor, $ToolbarBorderWidth)
    try {
        $half = [float]($ToolbarBorderWidth / 2)
        $e.Graphics.DrawRectangle($pen, $half, $half,
            ([float]$sender.ClientSize.Width - $ToolbarBorderWidth),
            ([float]$sender.ClientSize.Height - $ToolbarBorderWidth))
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
$flow.WrapContents = $false
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
    $needed = 220
    if ($remaining -ge $needed) {
        $rect = [System.Drawing.RectangleF]::new(
            [float]$rightmost, [float]0,
            [float]$remaining, [float]$sender.ClientSize.Height)
        Draw-HCABrandWatermark -Graphics $e.Graphics -Area $rect
    }
})

$flow.Padding = New-Object System.Windows.Forms.Padding(6,0,0,0)
$flow.Margin = New-Object System.Windows.Forms.Padding(0)
# Four exclusive columns: fixed icons, applications, username, and lock/kill.
$toolbarGrid = New-Object System.Windows.Forms.TableLayoutPanel
$toolbarGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarGrid.Margin = New-Object System.Windows.Forms.Padding(0)
$toolbarGrid.Padding = New-Object System.Windows.Forms.Padding(0)
$toolbarGrid.ColumnCount = 4
$toolbarGrid.RowCount = 1
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 64)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 260)))
[void]$toolbarGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 126)))
[void]$toolbarGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
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
$toolbarGrid.Controls.Add($flow, 1, 0)
$dragHandle.Dock = [System.Windows.Forms.DockStyle]::None
$dragHandle.Height = 32
$section1.Controls.Add($dragHandle)

# Right-side area: LoggedInUser value, Lock icon, Kill icon.
# FileValuePath is loaded from Config.json ('Logged In User').

$rightPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.Width = 126
$rightPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$rightPanel.WrapContents = $false
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
        [int]$Width = 42
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width,32)
    $button.Margin = New-Object System.Windows.Forms.Padding(0)
    $button.Padding = New-Object System.Windows.Forms.Padding(0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
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
    Enable-RoundedButton -Button $button -Radius 7 -ShowOutline $false
    return $button
}

# Password Reset is the first control in Section 4.
$passwordResetButton = New-RightToolbarButton -Text '' -IconFile '' -Width 42
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
    Start-ToolbarCommand -Command 'msedge.exe' -Arguments 'https://passwordreset.app.medcity.net/'
})
$rightPanel.Controls.Add($passwordResetButton)

$lockButton = New-RightToolbarButton -Text '' -IconFile 'lock.png' -Width 42
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
$rightPanel.Controls.Add($lockButton)

$exitToolbarButton = New-RightToolbarButton -Text '' -IconFile 'kill.png' -Width 42
$exitToolbarButton.AccessibleName = 'Exit Toolbar'
$buttonToolTip.SetToolTip($exitToolbarButton, 'Exit Toolbar')
$rightPanel.Controls.Add($exitToolbarButton)

# Add the right-side panel after the left Fill panel so it remains at the extreme right.
$rightPanel.Width = 126
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
#$manageButton.ForeColor = $TextColor
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
$section1.Controls.Add($manageButton)

# Section 3 sizes itself to the displayed value, leaving more room for apps.
function Update-UserSectionWidth {
    if ($null -eq $fileValueLabel -or $null -eq $toolbarGrid) { return }
    $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
        [string]$fileValueLabel.Text, $fileValueLabel.Font).Width
    $newWidth = [Math]::Min(260, [Math]::Max(110, $textWidth + 20))
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
$trayShow = $trayMenu.Items.Add('Show / Hide Toolbar')
$trayManage = $trayMenu.Items.Add('Manage Buttons')
$trayExit = $trayMenu.Items.Add('Exit')
$trayShow.Add_Click({ $form.Visible = -not $form.Visible })
$trayManage.Add_Click({ Show-ButtonManager -Owner $form -OnSaved { Rebuild-ToolbarButtons } })
$trayExit.Add_Click({ $notifyIcon.Visible = $false; $notifyIcon.Dispose(); $form.Close() })
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Add_DoubleClick({ $form.Visible = -not $form.Visible; if ($form.Visible) { $form.Activate() } })

$exitToolbarButton.Add_Click({
    Write-ToolbarLog -Message 'BUTTON_CLICK Name=Kill Toolbar'
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    $form.Close()
})

# Drag events are limited to the dedicated handle so application buttons keep
# their normal click behavior.
$dragHandle.Add_MouseDown({ Start-ToolbarDrag -EventArgs $_ })
$dragHandle.Add_MouseMove({ Move-ToolbarDrag })
$dragHandle.Add_MouseUp({ Stop-ToolbarDrag })
$dragGrip.Add_MouseDown({ Start-ToolbarDrag -EventArgs $_ })
$dragGrip.Add_MouseMove({ Move-ToolbarDrag })
$dragGrip.Add_MouseUp({ Stop-ToolbarDrag })
$form.Add_MouseMove({ Move-ToolbarDrag })
$form.Add_MouseUp({ Stop-ToolbarDrag })
$form.Add_Resize({ $form.Invalidate(); Update-ApplicationWidths })
$flow.Add_SizeChanged({ Update-ApplicationWidths; $flow.Invalidate() })

# Refresh the four-column layout after the window handle exists. This fixes
# occasional startup clipping of the last (Kill) icon.
function Refresh-ToolbarLayout {
    if ($form.IsDisposed -or -not $form.IsHandleCreated) { return }
    try {
        # Section 4 contains three 42-pixel icon buttons.
        $toolbarGrid.ColumnStyles[3].Width = 126
        $rightPanel.MinimumSize = New-Object System.Drawing.Size(126, 0)
        $toolbarGrid.PerformLayout()
        $rightPanel.PerformLayout()
        Update-ApplicationWidths
        $form.Invalidate($true)
    } catch {
        Write-ToolbarLog -Level WARNING -Message ("Toolbar layout refresh failed: {0}" -f $_.Exception.Message)
    }
}

$script:StartupLayoutTimer = New-Object System.Windows.Forms.Timer
$script:StartupLayoutTimer.Interval = 500
$script:StartupLayoutTimer.Add_Tick({
    $script:StartupLayoutTimer.Stop()
    Refresh-ToolbarLayout
})
$form.Add_Shown({
    if (-not $script:ToolbarHasBeenParked) {
        Set-ToolbarBounds -Form $form -Screen $script:DockedScreen
    }
    Refresh-ToolbarLayout
    Sync-ToolbarMonitor
    $script:StartupLayoutTimer.Start()
})
# Re-query Screen.AllScreens rather than holding on to an obsolete Screen object.
# Windows may change the bounds and DPI layout when a monitor is disconnected,
# reconnected, rearranged, or its resolution changes.
$script:LastMonitorSignature = ''
function Sync-ToolbarMonitor {
    if ($form.IsDisposed -or -not $form.IsHandleCreated -or $script:IsDraggingToolbar) { return }

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
            Write-ToolbarLog -Message ("Monitor layout synchronized: {0}, X={1}, Y={2}, Width={3}, Height={4}." -f $live.DeviceName, $bounds.Left, $bounds.Top, $bounds.Width, $ToolbarHeight)
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
    Write-ToolbarLog -Message 'Toolbar is closing.'
    $script:StartupLayoutTimer.Stop()
    $script:StartupLayoutTimer.Dispose()
    $screenTimer.Stop()
    $screenTimer.Dispose()
    if ($fileValueTimer) {
        $fileValueTimer.Stop()
        $fileValueTimer.Dispose()
    }
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($buttonToolTip) {
        $buttonToolTip.Dispose()
    }
})

[System.Windows.Forms.Application]::Run($form)
