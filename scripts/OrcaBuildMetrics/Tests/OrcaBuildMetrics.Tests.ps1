# Pester v3 tests for the OrcaBuildMetrics module.
# Run:  Invoke-Pester -Script scripts\OrcaBuildMetrics\Tests\OrcaBuildMetrics.Tests.ps1

$moduleRoot = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $moduleRoot 'OrcaBuildMetrics.psd1') -Force -ErrorAction Stop

$csvHeader = 'timestamp,build_cpu_percent,build_cores,build_rss_gb,' +
    'cores_compiler,cores_linker,cores_build,cores_ccache,' +
    'cpu_compiler,cpu_linker,cpu_build,cpu_ccache,' +
    'ram_compiler,ram_linker,ram_build,ram_ccache'

# Note: Pester 3.4.0's InModuleScope runs in the module scope, so test-script
# variables are NOT visible inside InModuleScope blocks. Paths are therefore
# recomputed with $env:TEMP + a literal filename inside each InModuleScope block.

Describe 'OrcaBuildMetrics - number parsing' -Tag 'CI' {
    InModuleScope OrcaBuildMetrics {
        It 'parses a plain integer' {
            Get-OrcaBuildNumber -Value '42' | Should Be 42.0
        }
        It 'parses a decimal' {
            Get-OrcaBuildNumber -Value '3.14' | Should Be 3.14
        }
        It 'parses a negative value' {
            Get-OrcaBuildNumber -Value '-1.5' | Should Be -1.5
        }
        It 'returns zero for empty string' {
            Get-OrcaBuildNumber -Value '' | Should Be 0.0
        }
        It 'returns zero for whitespace' {
            Get-OrcaBuildNumber -Value '   ' | Should Be 0.0
        }
        It 'returns zero for non-numeric junk' {
            Get-OrcaBuildNumber -Value 'abc' | Should Be 0.0
        }
        It 'returns zero for null' {
            Get-OrcaBuildNumber -Value $null | Should Be 0.0
        }
    }
}

Describe 'OrcaBuildMetrics - CSV loading' -Tag 'CI' {
    $csvPath = Join-Path $env:TEMP 'orca_build_metrics_test.csv'

    It 'loads two samples' {
        $row1 = '2026-10-27T01:00:00,50.0,8.0,4.0,4.0,2.0,1.0,0.5,40.0,20.0,10.0,5.0,2.0,1.0,0.5,0.25'
        $row2 = '2026-10-27T01:00:01,75.0,12.0,6.0,6.0,3.0,2.0,0.0,60.0,30.0,15.0,0.0,3.0,1.5,1.0,0.0'
        Set-Content -Path $csvPath -Value ($csvHeader + "`n" + $row1 + "`n" + $row2) -Encoding UTF8
        try {
            InModuleScope OrcaBuildMetrics {
                $s = ConvertFrom-OrcaBuildCsv -Path (Join-Path $env:TEMP 'orca_build_metrics_test.csv')
                $s.t.Count | Should Be 2
                $s.cpu.Count | Should Be 2
                $s.cores[0] | Should Be 8.0
                $s.cores[1] | Should Be 12.0
            }
        } finally {
            if (Test-Path $csvPath) { Remove-Item $csvPath -Force }
        }
    }

    It 'loads per-tool cores' {
        $row1 = '2026-10-27T01:00:00,50.0,8.0,4.0,4.0,2.0,1.0,0.5,40.0,20.0,10.0,5.0,2.0,1.0,0.5,0.25'
        Set-Content -Path $csvPath -Value ($csvHeader + "`n" + $row1) -Encoding UTF8
        try {
            InModuleScope OrcaBuildMetrics {
                $s = ConvertFrom-OrcaBuildCsv -Path (Join-Path $env:TEMP 'orca_build_metrics_test.csv')
                $s.per_tool.cores.compiler[0] | Should Be 4.0
                $s.per_tool.cores.linker[0] | Should Be 2.0
                $s.per_tool.cores.build[0] | Should Be 1.0
                $s.per_tool.cores.ccache[0] | Should Be 0.5
            }
        } finally {
            if (Test-Path $csvPath) { Remove-Item $csvPath -Force }
        }
    }

    It 'returns empty series for missing file' {
        InModuleScope OrcaBuildMetrics {
            $s = ConvertFrom-OrcaBuildCsv -Path (Join-Path $env:TEMP 'does_not_exist.csv')
            $s.t.Count | Should Be 0
        }
    }

    It 'returns empty series for file with only header' {
        $onlyHeader = Join-Path $env:TEMP 'orca_build_metrics_header_only.csv'
        Set-Content -Path $onlyHeader -Value $csvHeader -Encoding UTF8
        try {
            InModuleScope OrcaBuildMetrics {
                $s = ConvertFrom-OrcaBuildCsv -Path (Join-Path $env:TEMP 'orca_build_metrics_header_only.csv')
                $s.t.Count | Should Be 0
            }
        } finally {
            if (Test-Path $onlyHeader) { Remove-Item $onlyHeader -Force }
        }
    }
}

Describe 'OrcaBuildMetrics - downsample' -Tag 'CI' {
    InModuleScope OrcaBuildMetrics {
        It 'returns empty for empty input' {
            $out = Downsample-OrcaBuildValues -Values @() -Columns 5
            $out.Count | Should Be 0
        }
        It 'returns input unchanged when fewer values than columns' {
            $in = @(1.0, 2.0)
            $out = Downsample-OrcaBuildValues -Values $in -Columns 5
            $out | Should Be $in
        }
        It 'averages into fewer columns' {
            $in = @(1.0, 2.0, 3.0, 4.0)
            $out = Downsample-OrcaBuildValues -Values $in -Columns 2
            $out.Count | Should Be 2
            $out[0] | Should Be 1.5
            $out[1] | Should Be 3.5
        }
    }
}

Describe 'OrcaBuildMetrics - residual series' -Tag 'CI' {
    InModuleScope OrcaBuildMetrics {
        It 'computes total minus named sum' {
            $named = @{
                compiler = @(1.0, 2.0)
                linker   = @(0.5, 0.5)
                build    = @(0.0, 0.0)
                ccache   = @(0.0, 0.0)
            }
            $totals = @(3.0, 4.0)
            $out = Residual-OrcaBuildSeries -Named $named -Totals $totals
            $out[0] | Should Be 1.5
            $out[1] | Should Be 1.5
        }

        It 'clamps negative residual to zero' {
            $named = @{
                compiler = @(5.0)
                linker   = @(0.0)
                build    = @(0.0)
                ccache   = @(0.0)
            }
            $totals = @(3.0)
            $out = Residual-OrcaBuildSeries -Named $named -Totals $totals
            $out[0] | Should Be 0.0
        }
    }
}

Describe 'OrcaBuildMetrics - axis ticks' -Tag 'CI' {
    InModuleScope OrcaBuildMetrics {
        It 'returns exactly rows labels' {
            $labels = Axis-OrcaBuildTicks -Peak 100 -Rows 5 -Unit '%'
            $labels.Count | Should Be 5
        }

        It 'top label is peak' {
            $labels = Axis-OrcaBuildTicks -Peak 100 -Rows 5 -Unit '%'
            $labels[0] | Should Be '100%'
        }

        It 'bottom label is zero' {
            $labels = Axis-OrcaBuildTicks -Peak 100 -Rows 5 -Unit '%'
            $labels[-1] | Should Be '0%'
        }

        It 'labels are unique' {
            $labels = Axis-OrcaBuildTicks -Peak 100 -Rows 5 -Unit '%'
            ($labels | Select-Object -Unique).Count | Should Be 5
        }

        It 'GB unit formats with G suffix' {
            $labels = Axis-OrcaBuildTicks -Peak 8 -Rows 3 -Unit ' GB'
            $labels[0] | Should Be '8G'
            $labels[-1] | Should Be '0G'
        }

        It 'handles zero peak' {
            $labels = Axis-OrcaBuildTicks -Peak 0 -Rows 3 -Unit '%'
            $labels.Count | Should Be 3
        }

        It 'handles single row' {
            $labels = Axis-OrcaBuildTicks -Peak 50 -Rows 1 -Unit '%'
            $labels.Count | Should Be 1
        }
    }
}

Describe 'OrcaBuildMetrics - value to cells' -Tag 'CI' {
    InModuleScope OrcaBuildMetrics {
        It 'zero maps to zero cells' {
            Cells-OrcaBuildValue -Value 0 -Peak 100 | Should Be 0
        }
        It 'negative maps to zero cells' {
            Cells-OrcaBuildValue -Value -5 -Peak 100 | Should Be 0
        }
        It 'peak maps to max rows' {
            Cells-OrcaBuildValue -Value 100 -Peak 100 | Should Be 5
        }
        It 'maps value to rounded cell count' {
            # 60 / 100 * 5 = 3.0 -> 3 cells
            Cells-OrcaBuildValue -Value 60 -Peak 100 | Should Be 3
        }
    }
}

Describe 'OrcaBuildMetrics - report generation' -Tag 'CI' {
    $reportCsv = Join-Path $env:TEMP 'orca_build_metrics_report_test.csv'

    It 'returns a non-empty string for valid CSV' {
        $row = '2026-10-27T01:00:00,50.0,8.0,4.0,4.0,2.0,1.0,0.5,40.0,20.0,10.0,5.0,2.0,1.0,0.5,0.25'
        Set-Content -Path $reportCsv -Value ($csvHeader + "`n" + $row) -Encoding UTF8
        try {
            InModuleScope OrcaBuildMetrics {
                $report = Get-OrcaBuildMetricsReport -CsvPath (Join-Path $env:TEMP 'orca_build_metrics_report_test.csv')
                $report | Should Not BeNullOrEmpty
                $report | Should Match 'CPU %'
                $report | Should Match 'Cores'
                $report | Should Match 'RAM'
                $report | Should Match 'stacked'
            }
        } finally {
            if (Test-Path $reportCsv) { Remove-Item $reportCsv -Force }
        }
    }

    It 'returns no-samples message for empty data' {
        $empty = Join-Path $env:TEMP 'orca_build_metrics_empty.csv'
        Set-Content -Path $empty -Value $csvHeader -Encoding UTF8
        try {
            InModuleScope OrcaBuildMetrics {
                $report = Get-OrcaBuildMetricsReport -CsvPath (Join-Path $env:TEMP 'orca_build_metrics_empty.csv')
                $report | Should Match 'No samples collected'
            }
        } finally {
            if (Test-Path $empty) { Remove-Item $empty -Force }
        }
    }
}

Describe 'OrcaBuildMetrics - public Show-OrcaBuildMetrics' -Tag 'CI' {
    $showCsv = Join-Path $env:TEMP 'orca_build_metrics_show_test.csv'

    It 'returns exit 0 for existing CSV' {
        $row = '2026-10-27T01:00:00,50.0,8.0,4.0,4.0,2.0,1.0,0.5,40.0,20.0,10.0,5.0,2.0,1.0,0.5,0.25'
        Set-Content -Path $showCsv -Value ($csvHeader + "`n" + $row) -Encoding UTF8
        try {
            $code = Show-OrcaBuildMetrics -CsvPath $showCsv
            $code | Should Be 0
        } finally {
            if (Test-Path $showCsv) { Remove-Item $showCsv -Force }
        }
    }

    It 'returns exit 1 for missing CSV' {
        $code = Show-OrcaBuildMetrics -CsvPath (Join-Path $env:TEMP 'no_such_metrics.csv')
        $code | Should Be 1
    }
}
