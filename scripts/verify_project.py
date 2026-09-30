#!/usr/bin/env python3
"""Portable structural checks; this does not compile Swift or run XCTest."""
from pathlib import Path
import collections
import json
import plistlib
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
errors = []
checks = []


def check(condition, description):
    (checks if condition else errors).append(description)


def object_body(project, identifier):
    match = re.search(r'\b' + identifier + r' /\*[^*]+\*/ = \{', project)
    if not match:
        return ''
    start = match.end()
    depth = 1
    for i in range(start, len(project)):
        depth += (project[i] == '{') - (project[i] == '}')
        if depth == 0:
            return project[start:i]
    return ''


def main():
    project = (ROOT / 'Mio.xcodeproj/project.pbxproj').read_text()
    declarations = re.findall(r'^\t\t([A-F0-9]{24})(?: /\*[^*]+\*/)? = \{', project, re.M)
    check(len(declarations) == len(set(declarations)), 'Unika Xcode-objektidentiteter')
    references = dict(re.findall(r'([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXFileReference;[^\n]*?path = ([^;]+);', project))
    builds = dict(re.findall(r'([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})', project))
    for folder, phase in [('Mio', '910000000000000000000001'), ('MioTests', '910000000000000000000002')]:
        sources = sorted((ROOT / folder).rglob('*.swift'))
        body = object_body(project, phase)
        target_files = [references.get(builds.get(b, ''), '').strip('"') for b in re.findall(r'([A-F0-9]{24}) /\*[^*]+in Sources \*/', body)]
        expected = [p.name for p in sources]
        check(collections.Counter(target_files) == collections.Counter(expected), f'{folder}: exakt alla {len(expected)} Swift-filer ingår en gång i rätt target')
    for path in (ROOT / 'Mio').glob('*.plist'):
        with path.open('rb') as file:
            info = plistlib.load(file)
        check(bool(info.get('NSMicrophoneUsageDescription')), 'Mikrofonens behörighetstext')
        check(bool(info.get('NSAlarmKitUsageDescription')), 'AlarmKits behörighetstext')
        check(info.get('UIBackgroundModes') == ['audio'], 'Bakgrundsläget audio bevarat')
        check(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False), 'Ingen generell HTTP-exception')
    with (ROOT / 'Mio/PrivacyInfo.xcprivacy').open('rb') as file:
        privacy = plistlib.load(file)
    reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons'] for item in privacy['NSPrivacyAccessedAPITypes']}
    check('CA92.1' in reasons.get('NSPrivacyAccessedAPICategoryUserDefaults', []), 'UserDefaults deklarerad för egna inställningar')
    for path in (ROOT / 'Mio.xcodeproj').rglob('*'):
        if path.suffix in ('.xcscheme', '.xcsettings') or path.name == 'contents.xcworkspacedata':
            ET.parse(path)
    check(project.count('PRODUCT_BUNDLE_IDENTIFIER = app.mio.assistant;') == 2, 'Appidentiteten app.mio.assistant i Debug och Release')
    check(project.count('MARKETING_VERSION = 0.9.0;') == 2, 'Helhetsbygge 0.9.0 i Debug och Release')
    check(set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);', project)) == {'26.0'}, 'Minst iOS 26.0')
    check(project.count('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;') == 2, 'AppIcon vald i Debug och Release')
    check('Assets.xcassets in Resources' in object_body(project, '810000000000000000000001'), 'Bildkatalogen ingår i appens resurser')
    icon_folder = ROOT / 'Mio/Assets.xcassets/AppIcon.appiconset'
    icons = json.loads((icon_folder / 'Contents.json').read_text())['images']
    check(len(icons) == 3, 'Appikon för ljust, mörkt och tonat läge')
    for icon in icons:
        data = (icon_folder / icon['filename']).read_bytes()
        check(data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', data[16:24]) == (1024, 1024) and data[25] == 2, f'{icon["filename"]}: 1024 × 1024, RGB utan alfakanal')
    content_repository = (ROOT / 'Mio/Services/MioContentRepository.swift').read_text()
    sessions_repository = (ROOT / 'Mio/Services/SessionRepository.swift').read_text()
    check('"Mio"' in content_repository and '"content-v1.json"' in content_repository, 'Innehållslagring under Mio')
    check('"Mio"' in sessions_repository and '"sessions.json"' in sessions_repository, 'Sessionslagring under Mio')
    for path in [ROOT / 'README.md', ROOT / 'AGENTS.md', ROOT / 'CHANGELOG.md', *(ROOT / 'docs').glob('*.md'), *(ROOT / 'server').glob('*.md')]:
        for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            if '://' in target or target.startswith('#'):
                continue
            target = target.split('#')[0]
            check((path.parent / target).exists(), f'Länk {path.relative_to(ROOT)} → {target}')
    try:
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text())
        check(len(workflow['jobs']) == 1 and workflow['jobs']['build']['runs-on'] == 'xcode-27', 'Ett sammanhållet Xcode 27-jobb')
        for step in workflow['jobs']['build']['steps']:
            if 'run' in step:
                result = subprocess.run(['bash', '-n'], input=step['run'], text=True, capture_output=True)
                check(result.returncode == 0, f'Bash-syntax: {step["name"]}')
    except ImportError:
        print('YAML-kontroll överhoppad: installera PyYAML för full kontroll.')
    result = subprocess.run(['git', 'diff', '--check'], cwd=ROOT, text=True, capture_output=True)
    check(result.returncode == 0, 'git diff --check')
    for folder in ('Mio', 'MioTests', 'server', 'transcription-server', 'scripts', 'docs'):
        for path in (ROOT / folder).rglob('*'):
            if {'node_modules', '.wrangler', 'dist', '.venv', '__pycache__', '.pytest_cache'}.intersection(path.relative_to(ROOT).parts):
                continue
            if not path.is_file() or '.git' in path.parts or path.suffix not in ('.swift', '.md', '.mjs', '.py', '.json'):
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if line != line.rstrip():
                    errors.append(f'Trailing whitespace: {path.relative_to(ROOT)}:{number}')
    if errors:
        print('\n'.join('FEL: ' + error for error in errors))
    print(f'{len(checks)} strukturella kontroller godkända, {len(errors)} fel. Ingen Swift-kompilering eller XCTest utförd.')
    return bool(errors)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyError, OSError, ValueError, ET.ParseError) as error:
        print(f'Kontrollen kunde inte slutföras: {error}', file=sys.stderr)
        sys.exit(1)
