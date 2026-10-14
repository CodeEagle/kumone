#!/usr/bin/env python3
"""Check bilingual catalogs and the Swift compiler's extracted UI keys.

Run after `swift build` to validate the current macOS localization call sites.
Pass a different build directory to check another platform's .stringsdata files.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', re.MULTILINE)
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?)?(?:ll|l|z)?[@diufoxXsc]')


def catalog(path):
    entries = [(json.loads(k), json.loads(v)) for k, v in ENTRY.findall(path.read_text())]
    keys = [key for key, _ in entries]
    if len(keys) != len(set(keys)):
        raise ValueError(f'Duplicate keys in {path}')
    return dict(entries)


def main():
    tables = {lang: catalog(ROOT / f'Sources/Kumone/Resources/{lang}.lproj/Localizable.strings')
              for lang in ('en', 'zh-Hans')}
    errors = []
    for lang, entries in tables.items():
        for key in tables['en'].keys() | tables['zh-Hans'].keys():
            if key not in entries:
                errors.append(f'{lang}: missing {key}')
        for key, value in entries.items():
            if sorted(PLACEHOLDER.findall(key)) != sorted(PLACEHOLDER.findall(value)):
                errors.append(f'{lang}: format placeholders differ for {key}')
    build = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.build/out'
    extracted = 0
    for path in build.rglob('*.stringsdata'):
        data = json.loads(path.read_text())
        source = data.get('source', '')
        if '/Tests/' in source or not source.startswith(str(ROOT) + '/'):
            continue
        for entry in data.get('tables', {}).get('Localizable', []):
            key = entry['key']
            # Technical labels (VIP, HQ, PCM) and punctuation need no translation.
            if not re.search('[\u4e00-\u9fff]', key):
                continue
            extracted += 1
            for lang, entries in tables.items():
                if key not in entries:
                    errors.append(f'{source}:{entry["location"]["startingLine"]}: {lang} missing {key}')
    if not extracted:
        errors.append('No compiler localization keys found. Run swift build first.')
    if errors:
        print('\n'.join(sorted(set(errors))))
        return 1
    print(f'Localization check passed: {len(tables["en"])} bilingual keys; {extracted} compiler call sites.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
