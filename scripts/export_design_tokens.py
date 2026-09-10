#!/usr/bin/env python3
"""Export the Mira SwiftUI token source as a portable, app-independent JSON file."""

import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Apps/MiraMac/DesignSystem/MiraTheme.swift"
DESTINATION = ROOT / "designs/mira-ui/tokens.json"


def export() -> None:
    source = SOURCE.read_text()
    colors = re.findall(
        r"static var (\w+): Color \{ dynamic\(light: 0x([0-9A-F]+), dark: 0x([0-9A-F]+)\)", source
    )
    tokens = {
        "name": "Mira",
        "source": str(SOURCE.relative_to(ROOT)),
        "provenance": "Inferred from a user-supplied Codex screenshot; not official Codex tokens.",
        "units": {"dimensions": "pt", "fontSizes": "pt", "colors": "RGB hex", "opacity": "fraction"},
        "systemSurfaces": {
            "sidebar": {
                "owner": "macOS NSSplitViewItem sidebar",
                "appearance": "automatic",
                "transparency": "system accessibility preference",
                "source": "Apps/MiraMac/App/MiraWindowShell.swift",
                "windowBackground": "colors.canvas",
            }
        },
        "colors": {
            mode: {name: f"#{values[index]}" for name, *values in colors}
            for index, mode in enumerate(("light", "dark"))
        },
    }
    for group in ("Spacing", "Radius", "Layout", "Opacity", "Markdown"):
        section = source.split(f"enum {group} {{", 1)[1].split("}", 1)[0]
        tokens[group.lower()] = {
            name: float(value) for name, value in re.findall(r"static let (\w+): (?:CGFloat|Double) = ([\d.]+)", section)
        }
    tokens["typography"] = {
        name: {"family": "system", "size": float(size), "weight": weight or "regular"}
        for name, size, weight in re.findall(
            r"static let (\w+): Font = \.system\(size: ([\d.]+)(?:, weight: \.(\w+))?\)", source
        )
    }
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_text(json.dumps(tokens, indent=2) + "\n")
    print(DESTINATION.relative_to(ROOT))


if __name__ == "__main__":
    export()
