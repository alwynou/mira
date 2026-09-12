#!/usr/bin/env python3
"""Export the Mira SwiftUI token source as a portable, app-independent JSON file."""

import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Apps/MiraMac/DesignSystem/MiraTheme.swift"
DESTINATION = ROOT / "designs/mira-ui/tokens.json"


def enum_body(source: str, name: str) -> str:
    start = source.index(f"enum {name} {{") + len(f"enum {name} {{")
    depth = 1
    for index in range(start, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index]
    raise ValueError(f"Unclosed enum: {name}")


def dimensions(section: str) -> dict:
    return {name: float(value) for name, value in re.findall(
        r"static let (\w+): (?:CGFloat|Double) = ([\d.]+)", section)}


def typography(section: str) -> dict:
    return {name: {"family": "system", "size": float(size), "weight": weight or "regular"}
            for name, size, weight in re.findall(
                r"static let (\w+): Font = \.system\(size: ([\d.]+)(?:, weight: \.(\w+))?\)", section)}


def export() -> None:
    source = SOURCE.read_text()
    colors = re.findall(
        r"static var (\w+): Color \{ dynamic\(light: 0x([0-9A-F]+), dark: 0x([0-9A-F]+)\)", enum_body(source, "Colors")
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
            },
            "conversationTitlebar": {
                "owner": "SwiftUI ScrollView and safeAreaBar",
                "style": "scrollEdgeEffectStyle soft on macOS 26 and later",
                "height": "native toolbar top safe-area inset",
                "accessibility": "system accessibility preferences",
                "earlierSystemFallback": "colors.canvas with native window title",
                "source": "Apps/MiraMac/DesignSystem/MiraComponents.swift",
            },
        },
        "colors": {
            mode: {name: f"#{values[index]}" for name, *values in colors}
            for index, mode in enumerate(("light", "dark"))
        },
    }
    for group in ("Spacing", "Radius", "Layout", "Opacity", "Markdown"):
        tokens[group.lower()] = dimensions(enum_body(source, group))
    tokens["typography"] = typography(enum_body(source, "Typography"))
    settings = enum_body(source, "Settings")
    tokens["settings"] = {
        "provenance": "Measured from two user-supplied macOS System Settings screenshots with an embedded Color LCD profile; not official Apple tokens.",
        "colors": {
            **{name: {"light": f"#{light}", "dark": f"#{dark}"}
               for name, light, dark in re.findall(
                   r"static var (\w+): Color \{ dynamic\(light: 0x([0-9A-F]+), dark: 0x([0-9A-F]+)\)", settings)},
            **{name: {"system": f"NSColor.{system}"} for name, system in re.findall(
                r"static var (\w+): Color \{ Color\(nsColor: \.(\w+)\)", settings)},
        },
        "layout": dimensions(settings),
        "typography": typography(settings),
        "systemOwned": {
            "form": "SwiftUI Form.formStyle(.grouped): surfaces, radii, outer insets and scrolling; shared settings sections own internal row spacing and separator colors",
            "sidebar": "SwiftUI NavigationSplitView material and List.sidebar selection; fixed settings.layout.sidebarWidth content width, no sidebar toggle",
            "controls": "Native Picker, Toggle, TextField, Button, menus, focus and accessibility",
            "window": "SwiftUI Window scene with associated window-manager role; native traffic lights, window corners and unified toolbar",
            "titlebar": "SwiftUI safeAreaBar with soft scroll edge on macOS 26; height follows the native toolbar safe-area inset",
        },
    }
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_text(json.dumps(tokens, indent=2) + "\n")
    print(DESTINATION.relative_to(ROOT))


if __name__ == "__main__":
    export()
