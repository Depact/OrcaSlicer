#!/usr/bin/env python3
"""Render the build-process CSV written by build_win.ps1.

The chart uses rich when it is installed. Without rich the script still
prints a plain-text summary and a simple bar chart.
"""

from __future__ import annotations

import argparse
import csv
import sys
from datetime import datetime
from pathlib import Path

FIELDS = (
    "build_cpu_percent",
    "build_cores",
    "build_rss_gb",
    "cores_compiler",
    "cores_linker",
    "cores_build",
    "cores_ccache",
)

STACKS = (
    ("cores_compiler", "compiler", "bright_green", "#"),
    ("cores_linker", "linker", "bright_yellow", "="),
    ("cores_build", "build", "bright_cyan", "+"),
    ("cores_ccache", "ccache", "bright_magenta", "."),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path, help="CSV written by build_win.ps1")
    parser.add_argument("--title", default="OrcaSlicer build process")
    parser.add_argument("--height", type=int, default=8, help="chart height in rows")
    parser.add_argument("--ascii", action="store_true", help="use # instead of block glyphs")
    return parser.parse_args()


def read_rows(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        rows = []
        for raw in reader:
            try:
                row = {"time": datetime.fromisoformat(raw["timestamp"])}
            except (KeyError, TypeError, ValueError):
                continue
            for field in FIELDS:
                try:
                    row[field] = float(raw[field])
                except (KeyError, TypeError, ValueError):
                    pass
            rows.append(row)
    return rows


def pick_field(rows: list[dict], name: str) -> str | None:
    return name if all(name in row for row in rows) else None


def bucket_max(values: list[float], width: int) -> list[float]:
    if not values or width <= 0:
        return []
    if len(values) <= width:
        return values
    result = []
    step = len(values) / width
    for index in range(width):
        start = int(index * step)
        end = max(start + 1, int((index + 1) * step))
        result.append(max(values[start:end]))
    return result


def bucket_avg(values: list[float], width: int) -> list[float]:
    if not values or width <= 0:
        return []
    if len(values) <= width:
        return values
    result = []
    step = len(values) / width
    for index in range(width):
        start = int(index * step)
        end = max(start + 1, int((index + 1) * step))
        chunk = values[start:end]
        result.append(sum(chunk) / len(chunk))
    return result


def format_duration(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes:02d}m {secs:02d}s"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


def avg(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def peak(values: list[float]) -> float:
    return max(values) if values else 0.0


def summary(rows: list[dict]) -> dict | None:
    ram_key = pick_field(rows, "build_rss_gb")
    if not ram_key:
        return None
    cpu_key = pick_field(rows, "build_cpu_percent")
    core_key = pick_field(rows, "build_cores")
    stack = {}
    for key, _label, _color, _char in STACKS:
        if pick_field(rows, key):
            stack[key] = [row[key] for row in rows]
    return {
        "start": rows[0]["time"],
        "end": rows[-1]["time"],
        "duration": (rows[-1]["time"] - rows[0]["time"]).total_seconds(),
        "samples": len(rows),
        "cpu": [row[cpu_key] for row in rows] if cpu_key else [],
        "cores": [row[core_key] for row in rows] if core_key else [],
        "ram": [row[ram_key] for row in rows],
        "stack": stack if len(stack) == len(STACKS) else {},
        "has_cpu": bool(cpu_key and core_key),
    }


def render_rich(rows: list[dict], title: str, height: int, ascii_only: bool) -> None:
    from rich import box
    from rich.console import Console
    from rich.columns import Columns

    info = summary(rows)
    if info is None:
        raise ValueError("CSV has no usable build RAM column")

    console = Console()
    width = max(24, console.width - 12)
    if not ascii_only:
        encoding = (sys.stdout.encoding or "").lower().replace("-", "")
        ascii_only = "utf" not in encoding and encoding not in ("cp65001",)
    block = "#" if ascii_only else "█"

    charts = []
    if info["stack"]:
        # Combined chart shows CPU% and RAM broken down by tool
        charts.append(render_combined_stacked_chart(
            info["stack"], height, width, info["start"], info["end"],
            info["duration"], ascii_only, info["cpu"], info["ram"],
        ))
        charts.append(render_chart(
            "RAM GB", info["ram"], 0.0, max(0.1, peak(info["ram"]) * 1.05),
            height, width, "bright_blue", "{:.1f} GB", info["start"], info["end"],
            info["duration"], block,
        ))
    elif info["has_cpu"]:
        # Fall back to separate charts if no process breakdown
        charts.append(render_chart(
            "CPU %", info["cpu"], 0.0, 100.0, height, width,
            "bright_red", "{:.0f}%", info["start"], info["end"],
            info["duration"], block,
        ))
        charts.append(render_chart(
            "Cores", info["cores"], 0.0, max(1.0, peak(info["cores"])),
            height, width, "bright_yellow", "{:.0f}", info["start"], info["end"],
            info["duration"], block,
        ))
        charts.append(render_chart(
            "RAM GB", info["ram"], 0.0, max(0.1, peak(info["ram"]) * 1.05),
            height, width, "bright_blue", "{:.1f} GB", info["start"], info["end"],
            info["duration"], block,
        ))

    console.print(f"[bold]{title}[/bold]")
    if charts:
        console.print(Columns(charts, equal=True, expand=True, padding=0))
    if not info["has_cpu"]:
        console.print("[yellow]CPU and core samples are missing from this CSV; "
                      "it was written by an older sampler.[/yellow]")


def footer_lines(start, end, duration, chart_width, block):
    from rich.text import Text

    # Empty footer without duration
    footer = Text()
    footer.append(" " * (9 + chart_width))
    return [footer]


def axis_line(low, high, height, fmt, width, block):
    from rich.text import Text

    baseline = Text()
    baseline.append(f"{fmt.format(low):>8} ", style="dim")
    baseline.append(("-" if block == "#" else "─") * width, style="dim")
    return baseline


def render_chart(label, values, low, high, height, width, color, fmt,
                 start, end, duration, block):
    from rich import box
    from rich.console import Group
    from rich.panel import Panel
    from rich.text import Text

    bars = max(1, width // 2)
    sampled = bucket_max(values, bars)
    chart_width = max(1, len(sampled) * 2 - 1)
    span = high - low if high > low else 1.0
    lines = []
    for row in range(height - 1, -1, -1):
        threshold = low + (row / height) * span
        line = Text()
        line.append(f"{fmt.format(low + (row + 1) / height * span):>8} ", style="dim")
        for index, value in enumerate(sampled):
            line.append(block if value >= threshold else " ", style=color)
        lines.append(line)
    lines.append(axis_line(low, high, height, fmt, chart_width, block))
    lines.extend(footer_lines(start, end, duration, chart_width, block))
    return Panel(Group(*lines), title=label, border_style="dim", padding=(0, 0),
                 box=box.ASCII if block == "#" else box.ROUNDED)


def render_stacked_chart(stack, height, width, start, end, duration, ascii_only, ram_values=None):
    from rich import box
    from rich.console import Group
    from rich.panel import Panel
    from rich.text import Text

    first_len = len(next(iter(stack.values())))
    bars = max(1, min(width // 2, first_len))
    series = []
    for key, label, color, ascii_char in STACKS:
        series.append((label, color, ascii_char, bucket_avg(stack[key], bars)))
    totals = [sum(values[index] for _label, _color, _char, values in series)
              for index in range(bars)]
    high = max(1.0, peak(totals))
    span = high

    lines = []
    for row in range(height - 1, -1, -1):
        threshold = (row / height) * span
        line = Text()
        line.append(f"{high * (row + 1) / height:>8.0f} ", style="dim")
        for index in range(bars):
            cumulative = 0.0
            chosen = None
            for label, color, ascii_char, values in series:
                cumulative += values[index]
                if threshold < cumulative:
                    chosen = (color, ascii_char)
                    break
            if chosen is None:
                line.append(" ")
            elif ascii_only:
                line.append(chosen[1], style=chosen[0])
            else:
                line.append("█", style=chosen[0])
        lines.append(line)

    baseline = Text()
    baseline.append(f"   0 ", style="dim")
    baseline.append(("-" if ascii_only else "─") * (bars * 2 - 1), style="dim")
    lines.append(baseline)

    legend = Text()
    for _key, label, color, ascii_char in STACKS:
        legend.append("█ " if not ascii_only else f"{ascii_char} ", style=color)
        legend.append(f"{label}  ", style="dim")

    lines.append(legend)
    # Empty footer without duration

    return Panel(Group(*lines), title="Build cores by tool", border_style="dim",
                 padding=(0, 0), box=box.ASCII if ascii_only else box.ROUNDED)


def render_combined_stacked_chart(stack, height, width, start, end, duration, ascii_only, cpu_values=None, ram_values=None):
    from rich import box
    from rich.console import Group
    from rich.panel import Panel
    from rich.text import Text

    # Calculate bars for each chart (split height)
    cpu_height = height // 2
    ram_height = height - cpu_height
    
    # CPU chart
    first_len = len(next(iter(stack.values())))
    cpu_bars = max(1, min(width // 2, first_len))
    cpu_series = []
    for key, label, color, ascii_char in STACKS:
        cpu_series.append((label, color, ascii_char, bucket_avg(stack[key], cpu_bars)))
    cpu_totals = [sum(values[index] for _label, _color, _char, values in cpu_series)
                  for index in range(cpu_bars)]
    cpu_high = max(0.1, peak(cpu_totals) if cpu_totals else 0.1)
    cpu_span = cpu_high

    # RAM chart
    ram_bars = max(1, min(width // 2, first_len))
    ram_series = []
    for key, label, color, ascii_char in STACKS:
        ram_series.append((label, color, ascii_char, bucket_avg(stack[key], ram_bars)))
    ram_totals = [sum(values[index] for _label, _color, _char, values in ram_series)
                  for index in range(ram_bars)]
    ram_high = max(0.1, peak(ram_totals) if ram_totals else 0.1)
    ram_span = ram_high

    lines = []
    
    # CPU section
    for row in range(cpu_height - 1, -1, -1):
        threshold = (row / cpu_height) * cpu_span
        line = Text()
        line.append(f"{cpu_high * (row + 1) / cpu_height:>8.0f} ", style="dim")
        for index in range(cpu_bars):
            cumulative = 0.0
            chosen = None
            for label, color, ascii_char, values in cpu_series:
                cumulative += values[index]
                if threshold < cumulative:
                    chosen = (color, ascii_char)
                    break
            if chosen is None:
                line.append(" ")
            elif ascii_only:
                line.append(chosen[1], style=chosen[0])
            else:
                line.append("█", style=chosen[0])
        lines.append(line)

    # CPU baseline
    cpu_baseline = Text()
    cpu_baseline.append(f"   0 ", style="dim")
    cpu_baseline.append(("-" if ascii_only else "─") * (cpu_bars * 2 - 1), style="dim")
    lines.append(cpu_baseline)

    # CPU legend
    cpu_legend = Text()
    for _key, label, color, ascii_char in STACKS:
        cpu_legend.append("█ " if not ascii_only else f"{ascii_char} ", style=color)
        cpu_legend.append(f"{label}  ", style="dim")
    lines.append(cpu_legend)

    # RAM section
    for row in range(ram_height - 1, -1, -1):
        threshold = (row / ram_height) * ram_span
        line = Text()
        line.append(f"{ram_high * (row + 1) / ram_height:>8.0f} ", style="dim")
        for index in range(ram_bars):
            cumulative = 0.0
            chosen = None
            for label, color, ascii_char, values in ram_series:
                cumulative += values[index]
                if threshold < cumulative:
                    chosen = (color, ascii_char)
                    break
            if chosen is None:
                line.append(" ")
            elif ascii_only:
                line.append(chosen[1], style=chosen[0])
            else:
                line.append("█", style=chosen[0])
        lines.append(line)

    # RAM baseline
    ram_baseline = Text()
    ram_baseline.append(f"   0 ", style="dim")
    ram_baseline.append(("-" if ascii_only else "─") * (ram_bars * 2 - 1), style="dim")
    lines.append(ram_baseline)

    # RAM legend
    ram_legend = Text()
    for _key, label, color, ascii_char in STACKS:
        ram_legend.append("█ " if not ascii_only else f"{ascii_char} ", style=color)
        ram_legend.append(f"{label}  ", style="dim")
    lines.append(ram_legend)

    # Empty footer without duration

    return Panel(Group(*lines), title="CPU% and RAM by tool", border_style="dim",
                 padding=(0, 0), box=box.ASCII if ascii_only else box.ROUNDED)


def render_plain(rows: list[dict], title: str) -> None:
    info = summary(rows)
    if info is None:
        raise ValueError("CSV has no usable build RAM column")
    print(title)
    for value in bucket_max(info["cpu"], 72):
        print("#" * max(0, int(value / 100.0 * 60)))
    for value in bucket_max(info["cores"], 72):
        print("#" * max(0, int(value / max(1.0, peak(info["cores"])) * 60)))
    for value in bucket_max(info["ram"], 72):
        print("#" * max(0, int(value / max(1.0, peak(info["ram"])) * 60)))


def main() -> int:
    args = parse_args()
    if not args.csv.is_file():
        print(f"metrics file not found: {args.csv}", file=sys.stderr)
        return 1
    rows = read_rows(args.csv)
    if not rows:
        print(f"no usable samples in {args.csv}", file=sys.stderr)
        return 1
    try:
        render_rich(rows, args.title, max(1, args.height), args.ascii)
    except ImportError:
        render_plain(rows, args.title)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
