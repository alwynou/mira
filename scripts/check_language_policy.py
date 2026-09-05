#!/usr/bin/env python3
"""Check English source policy and complete, format-safe UI translations."""
import json
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Apps/MiraMac/Resources/Localizable.xcstrings'
errors = []
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--extracted-dir', type=Path, help='Host target build directory containing compiler-emitted .stringsdata')
options = parser.parse_args()

def non_english_letters(text):
    return any(ord(char) > 127 and char.isalpha() for char in text)

for directory in ('Apps', 'Packages', 'Tests', 'scripts'):
    for path in (ROOT / directory).rglob('*'):
        if '.build' in path.parts or path.suffix not in ('.swift', '.py', '.sh'): continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if non_english_letters(line):
                fixture = ('Tests' in path.parts and '// i18n-fixture:' in line)
                if not fixture:
                    errors.append(f'{path.relative_to(ROOT)}:{number}: unexplained non-English source text')

catalog = json.loads(CATALOG.read_text())
if catalog.get('sourceLanguage') != 'en': errors.append('Catalog sourceLanguage must be en')
# Count typed placeholders; translations may reorder them using positional arguments.
placeholder = re.compile(r'%(?:\d+\$)?(?:[-+ #0]*)(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]')
def signature(value):
    return sorted(re.sub(r'^%\d+\$', '%', item) for item in placeholder.findall(value.replace('%%', '')))

for key, entry in catalog['strings'].items():
    if non_english_letters(key): errors.append(f'Non-English catalog key: {key!r}')
    for locale in ('en', 'zh-Hans'):
        unit = entry.get('localizations', {}).get(locale, {}).get('stringUnit', {})
        if unit.get('state') != 'translated' or not unit.get('value'):
            errors.append(f'{locale}: missing translation for {key!r}')
        elif signature(unit['value']) != signature(key):
            errors.append(f'{locale}: placeholder mismatch for {key!r}')

# Static app-owned errors must have translations. Dynamic audit payloads are content.
quoted = r'"((?:\\.|[^"\\])*)"'
for folder in ('Apps/MiraMac', 'Packages/MiraKit/Sources'):
    for path in (ROOT / folder).rglob('*.swift'):
        for match in re.finditer(r'(?:MiraError|\.init)\(\.[A-Za-z]+,\s*' + quoted, path.read_text()):
            raw = match.group(1)
            if '\\(' in raw: continue
            try: key = json.loads('"' + raw + '"')
            except json.JSONDecodeError: continue
            if key not in catalog['strings']:
                errors.append(f'{path.relative_to(ROOT)}: missing app message key {key!r}')

for path in (ROOT / 'Apps/MiraMac').rglob('*.swift'):
    # Dynamic lookup keys and enum presentation labels do not get compiler extraction.
    source = path.read_text()
    patterns = [r'L10n\.(?:string|format)\(\s*' + quoted, r'case\s+[^:\n]+:\s*' + quoted]
    for pattern in patterns:
        for match in re.finditer(pattern, source):
            raw = match.group(1)
            if '\\(' in raw: continue
            try: key = json.loads('"' + raw + '"')
            except json.JSONDecodeError: continue
            if key and key not in catalog['strings']:
                errors.append(f'{path.relative_to(ROOT)}: missing dynamic UI key {key!r}')

if options.extracted_dir:
    extracted = list(options.extracted_dir.rglob('*.stringsdata'))
    if not extracted: errors.append('No compiler-extracted strings found; build the Host first')
    for path in extracted:
        tables = json.loads(path.read_text()).get('tables', {})
        for item in tables.get('Localizable', []):
            if item['key'] and item['key'] not in catalog['strings']:
                errors.append(f'{path.name}: untranslated UI key {item["key"]!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Language policy passed: {len(catalog["strings"])} bilingual strings; source exceptions are documented fixtures.')
