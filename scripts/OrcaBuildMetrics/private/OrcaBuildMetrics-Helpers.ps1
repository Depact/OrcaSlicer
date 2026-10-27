# Private helpers for OrcaBuildMetrics. Not exported.
#
# These mirror the logic in scripts/build_win_steps/build_metrics.py (CPU /
# cores / RAM stacked ASCII chart) but are implemented in pure PowerShell so
# the renderer has no dependency on Python or the 'rich' package.
#
# NOTE: all glyphs are ASCII (built from [char] constants) so this file parses
# cleanly under PowerShell 5.1, which reads .ps1 files in the system codepage
# unless a UTF-8 BOM is present.

# ── number parsing ────────────────────────────────────────────────────────────

function Get-OrcaBuildNumber {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0.0 }
    $v = 0.0
    if ([double]::TryParse($Value, [Globalization.NumberStyles]::Any,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        return $v
    }
    return 0.0
}

# ── data model ────────────────────────────────────────────────────────────────

$script:OrcaBuildTools = @('compiler', 'linker', 'build', 'ccache')

# ASCII-only glyphs (avoid non-ASCII bytes so PS 5.1 parses this file).
$script:OrcaBuildGlyphFull = [char]0x23   # '#'
$script:OrcaBuildGlyphLight = [char]0x2E  # '.'
$script:OrcaBuildGlyphTee   = [char]0x7C  # '|'
$script:OrcaBuildGlyphBase  = [char]0x2B  # '+'
$script:OrcaBuildGlyphLine  = [char]0x2D  # '-'

function New-OrcaBuildSeries {
    $t = @(); $cpu = @(); $cores = @(); $rss = @()
    $perTool = @{}
    foreach ($metric in @('cores', 'cpu', 'rss')) {
        $perTool[$metric] = @{}
        foreach ($tool in $script:OrcaBuildTools) {
            $perTool[$metric][$tool] = @()
        }
    }
    [pscustomobject]@{
        t        = $t
        cpu      = $cpu
        cores    = $cores
        rss      = $rss
        per_tool = $perTool
    }
}

function ConvertFrom-OrcaBuildCsv {
    param([string]$Path)

    $series = New-OrcaBuildSeries
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $series
    }

    $rows = Import-Csv -Path $Path -Encoding UTF8
    foreach ($row in $rows) {
        $series.t      += $row.timestamp
        $series.cpu    += Get-OrcaBuildNumber ($row.build_cpu_percent)
        $series.cores  += Get-OrcaBuildNumber ($row.build_cores)
        $series.rss    += Get-OrcaBuildNumber ($row.build_rss_gb)
        foreach ($tool in $script:OrcaBuildTools) {
            $series.per_tool.cores[$tool] += Get-OrcaBuildNumber ($row."cores_$tool")
            $series.per_tool.cpu[$tool]   += Get-OrcaBuildNumber ($row."cpu_$tool")
            $series.per_tool.rss[$tool]   += Get-OrcaBuildNumber ($row."ram_$tool")
        }
    }
    return $series
}

# ── downsample / residual / axis ──────────────────────────────────────────────

function Downsample-OrcaBuildValues {
    param([array]$Values, [int]$Columns)
    if ($null -eq $Values -or $Values.Count -eq 0 -or $Columns -le 0) {
        return @()
    }
    if ($Values.Count -le $Columns) {
        return @($Values)
    }
    $step = [double]$Values.Count / $Columns
    $out = @()
    for ($i = 0; $i -lt $Columns; $i++) {
        $start = [int]($i * $step)
        $end   = [int]($start + $step)
        if ($end -le $start) { $end = $start + 1 }
        $bucket = @($Values[$start..($end - 1)])
        $out += ($bucket | Measure-Object -Sum).Sum / $bucket.Count
    }
    return $out
}

function Residual-OrcaBuildSeries {
    param([hashtable]$Named, [array]$Totals)
    $out = @()
    for ($i = 0; $i -lt $Totals.Count; $i++) {
        $sum = 0.0
        foreach ($tool in $script:OrcaBuildTools) {
            $vals = $Named[$tool]
            if ($vals -and $i -lt $vals.Count) {
                $sum += $vals[$i]
            }
        }
        $tot = if ($i -lt $Totals.Count) { $Totals[$i] } else { 0.0 }
        $out += [math]::Max(0.0, $tot - $sum)
    }
    return $out
}

function Format-OrcaBuildTick {
    param([double]$Value, [string]$Unit)
    if ($Unit -eq '%') {
        return ('{0:g}%' -f $Value)
    }
    if ($Unit -eq ' GB') {
        return ('{0:g}G' -f $Value)
    }
    return ('{0:g}' -f $Value)
}

function Axis-OrcaBuildTicks {
    param([double]$Peak, [int]$Rows, [string]$Unit)
    if ($Rows -le 0) { return @() }
    if ($Peak -le 0 -or $Rows -eq 1) {
        $labels = @()
        for ($r = 0; $r -lt $Rows; $r++) {
            $tickValue = if ($r -eq 0) { $Peak } else { 0.0 }
            $labels += (Format-OrcaBuildTick -Value $tickValue -Unit $Unit)
        }
        return $labels
    }

    $gaps = $Rows - 1
    $rawStep = $Peak / $gaps
    $mag = if ($rawStep -gt 0) { [math]::Pow(10, [math]::Floor([math]::Log10($rawStep))) } else { 1.0 }
    $step = $rawStep
    foreach ($m in @(1, 2, 2.5, 5, 10)) {
        $cand = $m * $mag
        if ($Peak / $cand -le $gaps + 1e-9) {
            $step = $cand
            break
        }
    }

    $vals = @()
    for ($i = 0; $i -lt $gaps; $i++) { $vals += ($i * $step) }
    $vals += $Peak

    $labels = @()
    foreach ($v in $vals) { $labels += (Format-OrcaBuildTick -Value $v -Unit $Unit) }

    # Bump precision until labels are unique.
    if (($labels | Select-Object -Unique).Count -ne $labels.Count) {
        for ($prec = 1; $prec -le 4; $prec++) {
            $labels = @()
            foreach ($v in $vals) {
                if ($Unit -eq ' GB') {
                    $labels += ('{0:f{1}}G' -f $v, $prec)
                } elseif ($Unit -eq '%') {
                    $labels += ('{0:f{1}}%' -f $v, $prec)
                } else {
                    $labels += ('{0:f{1}}' -f $v, $prec)
                }
            }
            if (($labels | Select-Object -Unique).Count -eq $labels.Count) {
                break
            }
        }
    }

    # Top-first: last value is peak, first is 0.
    $result = @()
    for ($i = $labels.Count - 1; $i -ge 0; $i--) { $result += $labels[$i] }
    return $result
}

# ── drawing ───────────────────────────────────────────────────────────────────

$script:OrcaBuildHeightRows = 5

function Cells-OrcaBuildValue {
    param([double]$Value, [double]$Peak)
    $Peak = if ($Peak -le 0) { 1.0 } else { $Peak }
    if ($Value -le 0) { return 0 }
    return [math]::Max(1, [int]([math]::Round($Value / $Peak * $script:OrcaBuildHeightRows)))
}

function Render-OrcaBuildBars {
    param(
        [hashtable]$SeriesByTool,   # tool -> [double]
        [array]  $Totals,
        [int]    $Columns,
        [double] $Peak,
        [string] $Unit,
        [int]    $GutterWidth
    )

    $Peak = if ($Peak -le 0) { 1.0 } else { $Peak }
    $cols = @{}
    foreach ($tool in $script:OrcaBuildTools) {
        $vals = $SeriesByTool[$tool]
        $cols[$tool] = Downsample-OrcaBuildValues -Values $vals -Columns $Columns
    }
    $totalsDown = Downsample-OrcaBuildValues -Values $Totals -Columns $Columns
    $resid = Residual-OrcaBuildSeries -Named $cols -Totals $totalsDown

    # Grid: rows x columns, each cell is [glyph, style].
    $grid = @()
    for ($r = 0; $r -lt $script:OrcaBuildHeightRows; $r++) {
        $row = @()
        for ($c = 0; $c -lt $Columns; $c++) {
            # Comma operator prevents PowerShell from unwrapping the nested array.
            $row += ,(@(' ', $script:OrcaBuildTrackStyle))
        }
        $grid += ,$row
    }

    $toolStyles = @{
        compiler = 'bright_green'
        linker   = 'bright_cyan'
        build    = 'bright_yellow'
        ccache   = 'magenta'
        other    = 'grey50'
    }
    $toolGlyphs = @{
        compiler = $script:OrcaBuildGlyphFull
        linker   = $script:OrcaBuildGlyphFull
        build    = $script:OrcaBuildGlyphFull
        ccache   = $script:OrcaBuildGlyphFull
        other    = $script:OrcaBuildGlyphLight
    }

    for ($c = 0; $c -lt $Columns; $c++) {
        $row = $script:OrcaBuildHeightRows - 1
        foreach ($tool in $script:OrcaBuildTools) {
            $vals = $cols[$tool]
            if ($null -eq $vals -or $c -ge $vals.Count) { continue }
            $cells = Cells-OrcaBuildValue -Value $vals[$c] -Peak $Peak
            for ($k = 0; $k -lt $cells; $k++) {
                if ($row -lt 0) { break }
                $grid[$row][$c] = @($toolGlyphs[$tool], $toolStyles[$tool])
                $row--
            }
        }
        if ($c -lt $resid.Count) {
            $cells = Cells-OrcaBuildValue -Value $resid[$c] -Peak $Peak
            for ($k = 0; $k -lt $cells; $k++) {
                if ($row -lt 0) { break }
                $grid[$row][$c] = @($toolGlyphs['other'], $toolStyles['other'])
                $row--
            }
        }
    }

    $labels = Axis-OrcaBuildTicks -Peak $Peak -Rows $script:OrcaBuildHeightRows -Unit $Unit

    $sb = New-Object System.Text.StringBuilder
    for ($r = 0; $r -lt $script:OrcaBuildHeightRows; $r++) {
        $label = $labels[$r]
        $pad = $GutterWidth - $label.Length - 1
        if ($pad -lt 0) { $pad = 0 }
        $sb.Append(' ' * $pad) | Out-Null
        $sb.Append($label) | Out-Null
        $sb.Append(' ' + $script:OrcaBuildGlyphTee) | Out-Null
        for ($c = 0; $c -lt $Columns; $c++) {
            $sb.Append($grid[$r][$c][0]) | Out-Null
        }
        if ($r -ne $script:OrcaBuildHeightRows - 1) {
            $sb.AppendLine() | Out-Null
        }
    }
    $sb.AppendLine() | Out-Null
    $sb.Append(' ' * ($GutterWidth - 1)) | Out-Null
    $sb.Append(' ' + $script:OrcaBuildGlyphBase) | Out-Null
    $sb.Append([string]::new($script:OrcaBuildGlyphLine, $Columns)) | Out-Null

    return $sb.ToString()
}

function Render-OrcaBuildBlock {
    param(
        [string]   $Label,
        [string]   $Unit,
        [hashtable]$SeriesByTool,
        [array]    $Totals,
        [int]      $Columns,
        [double]   $Peak,
        [int]      $Precision,
        [int]      $GutterWidth
    )
    $Peak = if ($Peak -le 0) { 1.0 } else { $Peak }
    $avg = if ($Totals.Count -gt 0) { ($Totals | Measure-Object -Sum).Sum / $Totals.Count } else { 0.0 }

    $format = if ($Precision -ge 0) { "F$Precision" } else { 'G' }

    $sb = New-Object System.Text.StringBuilder
    $sb.Append(($Label + '  ')) | Out-Null
    $peakFmt = 'peak {0:' + $format + '}{1}'
    $sb.Append(($peakFmt -f $Peak, $Unit)) | Out-Null
    $sb.Append('  ') | Out-Null
    $avgFmt = 'avg {0:' + $format + '}{1}'
    $sb.Append(($avgFmt -f $avg, $Unit)) | Out-Null
    $sb.AppendLine() | Out-Null

    $bars = Render-OrcaBuildBars -SeriesByTool $SeriesByTool -Totals $Totals `
        -Columns $Columns -Peak $Peak -Unit $Unit -GutterWidth $GutterWidth
    $sb.Append($bars) | Out-Null
    $sb.AppendLine() | Out-Null

    return $sb.ToString()
}

function Shared-OrcaBuildXAxis {
    param([pscustomobject]$Series, [int]$Columns)

    if ($null -eq $Series.t -or $Series.t.Count -eq 0) {
        return ''
    }
    try {
        $timeStart = [datetime]::Parse($Series.t[0])
        $timeEnd   = [datetime]::Parse($Series.t[$Series.t.Count - 1])
        $dur = ($timeEnd - $timeStart).TotalSeconds
    } catch {
        return ''
    }

    function Fmt-Duration([double]$Sec) {
        $sec = [int]([math]::Round($Sec))
        $m = [math]::Floor($sec / 60)
        $s = $sec % 60
        if ($s -eq 0 -and $m -gt 0) { return ("{0}m" -f $m) }
        if ($m -gt 0) { return ("{0}m{1:D2}s" -f $m, $s) }
        return ("{0}s" -f $s)
    }

    $posThird = [int]($Columns / 3)
    $posTwoThirds = [int]((2 * $Columns) / 3)
    $posLast = $Columns - 1
    $positions = @(0, $posThird, $posTwoThirds, $posLast)

    $fracThird = 1 / 3
    $fracTwoThirds = 2 / 3
    $fractions = @(0.0, $fracThird, $fracTwoThirds, 1.0)
    $labels = @()
    foreach ($f in $fractions) { $labels += (Fmt-Duration -Sec ($dur * $f)) }

    $sb = New-Object System.Text.StringBuilder
    $prev = 0
    for ($i = 0; $i -lt $positions.Count; $i++) {
        $pos = [int]$positions[$i]
        $lbl = $labels[$i]
        if ($pos -le $prev) { continue }
        $gap = $pos - $prev
        if ($gap -lt $lbl.Length + 1) {
            $sb.Append(' ' * $gap) | Out-Null
        } else {
            $sb.Append(' ' * ($gap - $lbl.Length)) | Out-Null
            $sb.Append($lbl) | Out-Null
        }
        $prev = $pos
    }
    if ($prev -lt $Columns) {
        $sb.Append(' ' * ($Columns - $prev)) | Out-Null
    }
    return $sb.ToString()
}

# ── public-facing report builder (returns a string, no host dependency) ───────

function Get-OrcaBuildMetricsReport {
    param(
        [string] $CsvPath,
        [string] $Title = 'Build resource usage'
    )

    $series = ConvertFrom-OrcaBuildCsv -Path $CsvPath
    if ($null -eq $series.t -or $series.t.Count -eq 0) {
        return 'No samples collected.'
    }

    $gutterWidth = 7
    $columns = [math]::Max(20, 80 - $gutterWidth - 2)

    $cpuPeak  = if (($series.cpu | Measure-Object -Maximum).Maximum -gt 0) { ($series.cpu | Measure-Object -Maximum).Maximum } else { 1.0 }
    $corePeak = if (($series.cores | Measure-Object -Maximum).Maximum -gt 0) { ($series.cores | Measure-Object -Maximum).Maximum } else { 1.0 }
    $rssPeak  = if (($series.rss | Measure-Object -Maximum).Maximum -gt 0) { ($series.rss | Measure-Object -Maximum).Maximum } else { 1.0 }

    $blocks = @()
    $blocks += Render-OrcaBuildBlock -Label 'CPU %' -Unit '%'   -SeriesByTool $series.per_tool.cpu   -Totals $series.cpu   -Columns $columns -Peak $cpuPeak  -Precision 0 -GutterWidth $gutterWidth
    $blocks += Render-OrcaBuildBlock -Label 'Cores' -Unit ''    -SeriesByTool $series.per_tool.cores -Totals $series.cores -Columns $columns -Peak $corePeak -Precision 2 -GutterWidth $gutterWidth
    $blocks += Render-OrcaBuildBlock -Label 'RAM'   -Unit ' GB' -SeriesByTool $series.per_tool.rss   -Totals $series.rss   -Columns $columns -Peak $rssPeak  -Precision 1 -GutterWidth $gutterWidth

    $xAxis = Shared-OrcaBuildXAxis -Series $series -Columns $columns

    $legend = New-Object System.Text.StringBuilder
    $legend.Append('stacked: ') | Out-Null
    $entries = @(
        @{ name='compiler'; glyph=$script:OrcaBuildGlyphFull },
        @{ name='linker';   glyph=$script:OrcaBuildGlyphFull },
        @{ name='build';    glyph=$script:OrcaBuildGlyphFull },
        @{ name='ccache';   glyph=$script:OrcaBuildGlyphFull },
        @{ name='other';    glyph=$script:OrcaBuildGlyphLight }
    )
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($i -gt 0) { $legend.Append('  ') | Out-Null }
        $legend.Append(($entries[$i].glyph + ' ')) | Out-Null
        $legend.Append($entries[$i].name) | Out-Null
    }

    try {
        $timeStart = [datetime]::Parse($series.t[0])
        $timeEnd   = [datetime]::Parse($series.t[$series.t.Count - 1])
        $dur = ($timeEnd - $timeStart).TotalSeconds
        $m = [math]::Floor($dur / 60); $s = [int]($dur % 60)
        if ($s -eq 0 -and $m -gt 0) { $durStr = ("{0}m" -f $m) }
        elseif ($m -gt 0) { $durStr = ("{0}m{1:D2}s" -f $m, $s) }
        else { $durStr = ("{0}s" -f $s) }
    } catch {
        $durStr = '?'
    }

    $sb = New-Object System.Text.StringBuilder
    $sb.Append(($durStr + '  |  ' + $series.t.Count + ' samples')) | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine() | Out-Null
    foreach ($b in $blocks) {
        $sb.Append($b) | Out-Null
    }
    $sb.Append($xAxis) | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.Append($legend.ToString()) | Out-Null
    $sb.AppendLine() | Out-Null

    return $sb.ToString()
}

# Track style placeholder (kept for grid structure; not used for color output).
$script:OrcaBuildTrackStyle = 'default'
