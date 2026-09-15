#!/usr/bin/env python3
"""Export native icon previews and a standalone vector presentation.

The app's .icon package is the canonical source. The standalone SVG deliberately
adds presentation-only masking and a shadow; never import it as an icon layer.
"""

import copy
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import json

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Apps/MiraMac/Resources/MiraAppIcon.icon"
OUTPUT = ROOT / "designs/mira-app-icon/final"
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
NS = "http://www.w3.org/2000/svg"
MODES = ("Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark")


def export(mode: str, size: int, filename: str) -> None:
    result = subprocess.run(
        [str(ICTOOL), str(ICON), "--export-image", "--output-file", str(OUTPUT / filename),
         "--platform", "macOS", "--rendition", mode, "--width", str(size),
         "--height", str(size), "--scale", "1", "--light-angle", "0"],
        check=True, capture_output=True, text=True,
    )
    # CoreSVG can report a parse error even when ictool exits successfully.
    if result.stderr.strip():
        raise RuntimeError(result.stderr)


def vector_presentation() -> None:
    ET.register_namespace("", NS)
    svg = ET.Element(f"{{{NS}}}svg", {
        "width": "1024", "height": "1024", "viewBox": "0 0 1024 1024",
    })
    ET.SubElement(svg, f"{{{NS}}}title").text = "Mira Contour Silver"
    ET.SubElement(svg, f"{{{NS}}}desc").text = (
        "Standalone vector presentation. The app uses unmasked SVG layers in Icon Composer."
    )
    defs = ET.SubElement(svg, f"{{{NS}}}defs")
    ground = ET.SubElement(defs, f"{{{NS}}}radialGradient", {
        "id": "background", "cx": ".3", "cy": "0", "r": "1.15",
    })
    for offset, color in (("0", "#252525"), (".52", "#111111"), ("1", "#070707")):
        ET.SubElement(ground, f"{{{NS}}}stop", {"offset": offset, "stop-color": color})
    shadow = ET.SubElement(defs, f"{{{NS}}}filter", {
        "id": "presentation-shadow", "x": "-.4", "y": "-.4", "width": "1.8", "height": "1.8",
    })
    ET.SubElement(shadow, f"{{{NS}}}feDropShadow", {
        "dx": "0", "dy": "20", "stdDeviation": "16", "flood-opacity": ".65",
    })
    ET.SubElement(svg, f"{{{NS}}}rect", {
        "x": "4", "y": "4", "width": "1016", "height": "1016", "rx": "222",
        "fill": "url(#background)",
    })
    silhouette = ET.SubElement(svg, f"{{{NS}}}g", {"filter": "url(#presentation-shadow)"})
    recipe = json.loads((ICON / "icon.json").read_text())
    # Icon Composer lists front first; SVG paints the last item on top.
    layers = recipe["groups"][0]["layers"]
    for layer in reversed(layers):
        source = ET.parse(ICON / "Assets" / layer["image-name"]).getroot()
        for definition in source.find(f"{{{NS}}}defs"):
            defs.append(copy.deepcopy(definition))
        silhouette.append(copy.deepcopy(source.find(f"{{{NS}}}g")))
    ET.indent(svg, space="  ")
    ET.ElementTree(svg).write(OUTPUT / "Mira-Silver.svg", encoding="unicode")


def website_logos() -> None:
    """Export self-contained graphite/silver marks with static web lighting."""
    ET.register_namespace("", NS)
    recipe = json.loads((ICON / "icon.json").read_text())
    graphite = {
        "front": ["#858585", "#5A5A5A", "#141414", "#3A3A3A", "#787878", "#303030", "#080808"],
        "rear": ["#121212", "#454545", "#939393", "#4F4F4F", "#181818"],
    }
    for name in ("black", "white"):
        prefix = f"mira-{name}-"
        svg = ET.Element(f"{{{NS}}}svg", {
            "width": "920", "height": "650", "viewBox": "50 205 920 650",
            "role": "img", "aria-label": "Mira",
        })
        theme = "Graphite for light backgrounds" if name == "black" else "Silver for dark backgrounds"
        ET.SubElement(svg, f"{{{NS}}}title").text = f"Mira logo - {theme}"
        defs = ET.SubElement(svg, f"{{{NS}}}defs")
        shadow = ET.SubElement(defs, f"{{{NS}}}filter", {
            "id": prefix + "shadow", "x": "-.3", "y": "-.3", "width": "1.6", "height": "1.6",
            "color-interpolation-filters": "sRGB",
        })
        ET.SubElement(shadow, f"{{{NS}}}feDropShadow", {
            "dx": "0", "dy": "10", "stdDeviation": "10", "flood-color": "#000000",
            "flood-opacity": ".18" if name == "black" else ".55",
        })
        edge = ET.SubElement(defs, f"{{{NS}}}linearGradient", {
            "id": prefix + "edge", "x1": "0", "y1": "0", "x2": "1", "y2": "1",
        })
        for offset, color, opacity in (("0", "#FFFFFF", ".85"), (".4", "#AAAAAA", ".2"),
                                       (".7", "#FFFFFF", ".7"), ("1", "#888888", ".15")):
            ET.SubElement(edge, f"{{{NS}}}stop", {
                "offset": offset, "stop-color": color, "stop-opacity": opacity,
            })
        group = ET.SubElement(svg, f"{{{NS}}}g", {"filter": f"url(#{prefix}shadow)"})
        for layer in reversed(recipe["groups"][0]["layers"]):
            source = ET.parse(ICON / "Assets" / layer["image-name"]).getroot()
            for source_gradient in source.find(f"{{{NS}}}defs"):
                gradient = copy.deepcopy(source_gradient)
                gradient_id = gradient.attrib["id"]
                gradient.set("id", prefix + gradient_id)
                if name == "black":
                    for stop, color in zip(gradient, graphite[gradient_id]):
                        stop.set("stop-color", color)
                defs.append(gradient)
            geometry = copy.deepcopy(source.find(f"{{{NS}}}g"))
            for path in list(geometry):
                path.set("fill", path.attrib["fill"].replace("url(#", f"url(#{prefix}"))
                ET.SubElement(geometry, f"{{{NS}}}path", {
                    "d": path.attrib["d"], "fill": "none", "stroke": f"url(#{prefix}edge)",
                    "stroke-width": "1.8", "stroke-linejoin": "round",
                })
            group.append(geometry)
        ET.indent(svg, space="  ")
        ET.ElementTree(svg).write(OUTPUT / f"mira-logo-{name}.svg", encoding="unicode")


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    vector_presentation()
    website_logos()
    for mode in MODES:
        export(mode, 512, f"{mode}.png")
    for size in (16, 24, 32, 64, 128, 1024):
        export("Default", size, f"Default-{size}.png")
    for angle in (-45, 45):
        result = subprocess.run(
            [str(ICTOOL), str(ICON), "--export-image", "--output-file",
             str(OUTPUT / f"Light-{angle}.png"), "--platform", "macOS", "--rendition", "Default",
             "--width", "512", "--height", "512", "--scale", "1", "--light-angle", str(angle)],
            check=True, capture_output=True, text=True,
        )
        if result.stderr.strip():
            raise RuntimeError(result.stderr)
    print(f"Exported vector presentation, black/white logos, and 14 native previews to {OUTPUT}")


if __name__ == "__main__":
    main()
