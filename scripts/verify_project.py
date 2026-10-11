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
    match = re.search(r'\b' + identifier + r'(?: /\*[^*]+\*/)? = \{', project)
    if not match:
        return ''
    start = match.end()
    depth = 1
    for i in range(start, len(project)):
        depth += (project[i] == '{') - (project[i] == '}')
        if depth == 0:
            return project[start:i]
    return ''


def resolved_group_files(project, references, group, parent=Path('.')):
    """Resolve group-relative file paths, not just filenames in Sources phases."""
    body = object_body(project, group)
    path = re.search(r'\bpath = ([^;]+);', body)
    directory = parent / path.group(1).strip('"') if path else parent
    children = re.search(r'children = \((.*?)\);', body, re.S)
    resolved = []
    for child in re.findall(r'[A-F0-9]{24}', children.group(1) if children else ''):
        if child in references:
            name = references[child].strip('"')
            if name.endswith('.swift'):
                resolved.append(directory / name)
        elif 'isa = PBXGroup;' in object_body(project, child):
            resolved.extend(resolved_group_files(project, references, child, directory))
    return resolved


def workflow_contract_issues(name, workflow):
    """Return missing safety-critical fields for Mio's two required workflows."""
    if not isinstance(workflow, dict) or not isinstance(workflow.get('jobs'), dict):
        return ['YAML-roten måste innehålla en jobs-mappning']
    jobs = workflow['jobs']
    if name == 'build-unsigned-ipa.yml':
        job = jobs.get('build', {})
        job = job if isinstance(job, dict) else {}
        steps = job.get('steps', [])
        if not isinstance(steps, list):
            return ['jobbets steps måste vara en lista']
        commands = '\n'.join(step.get('run', '') for step in steps
                              if isinstance(step, dict) and isinstance(step.get('run', ''), str))
        checks = [
            (len(jobs) == 1 and job.get('runs-on') == 'xcode-27', 'ett sammanhållet jobb på xcode-27'),
            ('scripts/verify_concurrency.py' in commands and '--native' in commands,
             'native strict-concurrencydiagnostik'),
            ('-configuration Release' in commands and 'test-without-building' in commands,
             'Release och XCTest'),
            ('Mio-unsigned.ipa' in commands and 'Mio-buildinfo.txt' in commands,
             'IPA-validering och byggproveniens'),
        ]
    elif name == 'verify-linux.yml':
        job = jobs.get('verify', {})
        job = job if isinstance(job, dict) else {}
        steps = job.get('steps', [])
        if not isinstance(steps, list):
            return ['jobbets steps måste vara en lista']
        commands = '\n'.join(step.get('run', '') for step in steps
                              if isinstance(step, dict) and isinstance(step.get('run', ''), str))
        actions = [step.get('uses', '') for step in steps if isinstance(step, dict)]
        checks = [
            (job.get('runs-on') == 'ubuntu-24.04' and job.get('container') == 'swift:6.3.3-noble',
             'Ubuntu 24.04 och Swift 6.3.3 Noble'),
            ('scripts/verify.py' in commands and '--logs-dir' in commands,
             'den gemensamma verifieraren med sparad loggplats'),
            (any(action.startswith('actions/upload-artifact@') for action in actions),
             'uppladdning av verifieringsbevis'),
        ]
    else:
        return []
    return [description for present, description in checks if not present]


def main():
    project = (ROOT / 'Mio.xcodeproj/project.pbxproj').read_text()
    declarations = re.findall(r'^\t\t([A-F0-9]{24})(?: /\*[^*]+\*/)? = \{', project, re.M)
    check(len(declarations) == len(set(declarations)), 'Unika Xcode-objektidentiteter')
    references = dict(re.findall(r'([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXFileReference;[^\n]*?path = ([^;]+);', project))
    for path in resolved_group_files(project, references, '710000000000000000000001'):
        check((ROOT / path).is_file(), f'Xcode-gruppens källsökväg finns: {path}')
    builds = dict(re.findall(r'([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})', project))
    # The widget extension also compiles the Foundation/ActivityKit sources it shares with the app.
    widget_shared = ['MioListeningActivityState.swift', 'MioListeningAttributes.swift']
    for folder, phase, shared in [('Mio', '910000000000000000000001', []), ('MioTests', '910000000000000000000002', []),
                                  ('MioUITests', '920000000000000000000001', []),
                                  ('MioWidgets', 'BAC600000000000000000401', widget_shared)]:
        sources = sorted((ROOT / folder).rglob('*.swift'))
        body = object_body(project, phase)
        target_files = [references.get(builds.get(b, ''), '').strip('"') for b in re.findall(r'([A-F0-9]{24}) /\*[^*]+in Sources \*/', body)]
        expected = [p.name for p in sources] + shared
        check(collections.Counter(target_files) == collections.Counter(expected), f'{folder}: exakt alla {len(expected)} Swift-filer ingår en gång i rätt target')
    for name in widget_shared:
        check(len(list((ROOT / 'Mio').rglob(name))) == 1, f'Delad widgetkälla finns i appen: {name}')
    embed = object_body(project, 'BAC600000000000000000404')
    check('dstSubfolderSpec = 13;' in embed and 'MioWidgets.appex in Embed Foundation Extensions' in embed
          and 'BAC600000000000000000404' in object_body(project, 'A10000000000000000000001'),
          'Widgettillägget bäddas in i appens PlugIns')
    check(project.count('PRODUCT_BUNDLE_IDENTIFIER = app.mio.assistant.widgets;') == 2, 'Widgetidentiteten app.mio.assistant.widgets i Debug och Release')
    check(len(set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project))) == 1, 'Appen och widgettillägget har samma byggnummer')
    with (ROOT / 'MioWidgets/Info.plist').open('rb') as file:
        widget_info = plistlib.load(file)
    check(widget_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension', 'Widgettilläggets extension point')
    for path in (ROOT / 'Mio').glob('*.plist'):
        with path.open('rb') as file:
            info = plistlib.load(file)
        check(bool(info.get('NSMicrophoneUsageDescription')), 'Mikrofonens behörighetstext')
        check(bool(info.get('NSAlarmKitUsageDescription')), 'AlarmKits behörighetstext')
        check(info.get('UIBackgroundModes') == ['audio'], 'Bakgrundsläget audio bevarat')
        check(info.get('NSSupportsLiveActivities') is True, 'Live Activity tillåten')
        check(info.get('BGTaskSchedulerPermittedIdentifiers') == ['app.mio.assistant.lesson-notes.*'],
              'Fortsatt bakgrundsbearbetning för lektionsanteckningar tillåten')
        check(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False), 'Ingen generell HTTP-exception')
    with (ROOT / 'Mio/PrivacyInfo.xcprivacy').open('rb') as file:
        privacy = plistlib.load(file)
    reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons'] for item in privacy['NSPrivacyAccessedAPITypes']}
    check('CA92.1' in reasons.get('NSPrivacyAccessedAPICategoryUserDefaults', []), 'UserDefaults deklarerad för egna inställningar')
    for path in (ROOT / 'Mio.xcodeproj').rglob('*'):
        if path.suffix in ('.xcscheme', '.xcsettings') or path.name == 'contents.xcworkspacedata':
            ET.parse(path)
    check(project.count('PRODUCT_BUNDLE_IDENTIFIER = app.mio.assistant;') == 2, 'Appidentiteten app.mio.assistant i Debug och Release')
    check(project.count('MARKETING_VERSION = 0.9.0;') == 4, 'Helhetsbygge 0.9.0 i appens och widgettilläggets Debug och Release')
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
    for path in [ROOT / 'README.md', ROOT / 'CLAUDE.md', ROOT / 'CHANGELOG.md', *(ROOT / 'docs').glob('*.md'), *(ROOT / 'server').glob('*.md')]:
        for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            if '://' in target or target.startswith('#'):
                continue
            target = target.split('#')[0]
            check((path.parent / target).exists(), f'Länk {path.relative_to(ROOT)} → {target}')
    try:
        import yaml
    except ImportError:
        errors.append('PyYAML behövs för att validera båda GitHub-workflowfilerna')
    else:
        for name in ('build-unsigned-ipa.yml', 'verify-linux.yml'):
            try:
                workflow = yaml.safe_load((ROOT / '.github/workflows' / name).read_text())
            except yaml.YAMLError as error:
                errors.append(f'Ogiltig YAML i .github/workflows/{name}: {error}')
                continue
            check(isinstance(workflow, dict), f'.github/workflows/{name}: giltig YAML-mappning')
            issues = workflow_contract_issues(name, workflow)
            if issues:
                errors.extend(f'.github/workflows/{name}: {issue}' for issue in issues)
            else:
                check(True, f'.github/workflows/{name}: säkerhetskritiska jobbinställningar')
            for job in workflow.get('jobs', {}).values() if isinstance(workflow, dict) else []:
                for step in job.get('steps', []) if isinstance(job, dict) else []:
                    if isinstance(step, dict) and 'run' in step:
                        result = subprocess.run(['bash', '-n'], input=step['run'], text=True, capture_output=True)
                        check(result.returncode == 0, f'Bash-syntax: {name}: {step.get("name", "namnlöst steg")}')
    result = subprocess.run(['git', 'diff', '--check'], cwd=ROOT, text=True, capture_output=True)
    check(result.returncode == 0, 'git diff --check')
    for folder in ('Mio', 'MioTests', 'MioUITests', 'MioWidgets', 'server', 'transcription-server', 'scripts', 'docs'):
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
