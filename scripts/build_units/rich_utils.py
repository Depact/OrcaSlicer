#!/usr/bin/env python3
"""Rich output utilities for build_win.ps1.

Called from PowerShell to avoid shell string-escaping issues with
embedded Python code.
"""

from rich.console import Console
from rich.rule import Rule
from rich.tree import Tree
import sys


def rule_step(ts, text):
    """Render a major build step as a cyan Rich Rule widget."""
    console = Console()
    console.print(Rule(f"[{ts}] {text}", style="cyan", align="left"))


def rule_separator(style="green"):
    """Render a full-width divider line."""
    console = Console()
    console.print(Rule(characters="\u2501", style=style))


def tree_total(total_str, configure_str, build_str):
    """Render timing breakdown as a Rich Tree widget (Total is parent)."""
    console = Console()
    tree = Tree("Total: " + total_str, style="default")
    tree.add("Configure: " + configure_str)
    tree.add("Build:     " + build_str)
    console.print(tree)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "step":
        rule_step(sys.argv[2], sys.argv[3])
    elif cmd == "rule":
        rule_separator(style=sys.argv[2])
    elif cmd == "tree":
        tree_total(sys.argv[2], sys.argv[3], sys.argv[4])
