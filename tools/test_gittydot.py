"""Run GittyDot editor regressions in a disposable project inside the agent temp folder."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True, help='Godot 4.7.2 executable')
    parser.add_argument('--visual', action='store_true', help='Use a hidden graphical editor and capture the native highlight preview')
    parser.add_argument('--git', type=Path, help='Git executable for this test process and its disposable editor only')
    args = parser.parse_args()
    if args.git:
        if not args.git.is_file():
            parser.error('--git must point to an existing executable')
        os.environ['PATH'] = str(args.git.resolve().parent) + os.pathsep + os.environ.get('PATH', '')
    root = Path(__file__).resolve().parents[1]
    addon = root / 'addons/gittydot'
    work = root / f'{root.name}-temp-chatgpt' / 'gittydot'
    work.mkdir(parents=True, exist_ok=True)
    (work / '.gdignore').write_text('', encoding='utf-8')
    fixture = work / ('tests-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    fixture.mkdir()
    shutil.copytree(addon, fixture / 'addons/gittydot', ignore=shutil.ignore_patterns('*.uid', '*.import'))
    verify = fixture / 'addons/gittydot_verify'
    verify.mkdir()
    shutil.copyfile(root / 'tests/editor_checks.gd', verify / 'plugin.gd')
    (verify / 'plugin.cfg').write_text(
        '[plugin]\nname="GittyDot verification"\nauthor="Codex"\nversion="1"\nscript="plugin.gd"\n', encoding='utf-8')
    (fixture / 'project.godot').write_text('''config_version=5
[application]
config/name="GittyDot Integration Tests"
[editor_plugins]
enabled=PackedStringArray("res://addons/gittydot/plugin.cfg", "res://addons/gittydot_verify/plugin.cfg")
[rendering]
renderer/rendering_method="gl_compatibility"
''', encoding='utf-8')
    (fixture / '.gitignore').write_text('.godot/\n*-temp-chatgpt/\n', encoding='utf-8')

    def git(*command: str) -> None:
        subprocess.run(['git', '-C', str(fixture), *command], check=True, capture_output=True, text=True)

    git('init', '-b', 'main')
    git('config', 'core.autocrlf', 'false')
    git('config', 'user.name', 'GittyDot Tests')
    git('config', 'user.email', 'gittydot-tests@localhost')
    tracked = fixture / 'tracked.gd'
    tracked.write_text('extends Node\nvar number := 1\n', encoding='utf-8')
    historical = fixture / 'historical.gd'
    historical.write_text('extends Node\nvar historical := 10\n', encoding='utf-8')
    deleted = fixture / 'deleted.txt'
    deleted.write_text('Only available in history\n', encoding='utf-8')
    editable = fixture / 'editable.txt'
    full_text = ''.join(f'line {line}: ' + ('long text ' * 100 if line == 45 else 'original') + '\n' for line in range(100))
    editable.write_text(full_text, encoding='utf-8', newline='\n')
    (fixture / 'editable_crlf.txt').write_bytes(b'\xef\xbb\xbfbefore\r\nlast')
    (fixture / 'editable_scene.tscn').write_text('[gd_scene format=3]\n\n[node name="FixtureRoot" type="Node"]\n', encoding='utf-8', newline='\n')
    (fixture / 'editable_binary.bin').write_bytes(b'\x00\xff\x00\x01')
    folder = fixture / 'folder_actions/deep'
    folder.mkdir(parents=True)
    (folder / 'one.txt').write_text('original one\n', encoding='utf-8', newline='\n')
    (folder / 'two.txt').write_text('original two\n', encoding='utf-8', newline='\n')
    git('add', '--', '.gitignore', 'tracked.gd', 'historical.gd', 'deleted.txt', 'folder_actions', 'editable.txt', 'editable_crlf.txt', 'editable_scene.tscn', 'editable_binary.bin')
    git('commit', '-m', 'Fixture baseline')
    historical.write_text('extends Node\nvar historical := 20\n', encoding='utf-8')
    deleted.unlink()
    git('add', '--', 'historical.gd', 'deleted.txt')
    git('commit', '-m', 'History comparison fixture')
    editable.write_text(full_text.replace('line 2: original', 'line 2: staged'), encoding='utf-8', newline='\n')
    git('add', '--', 'editable.txt')
    editable.write_text(full_text.replace('line 2: original', 'line 2: working').replace('line 40: original\n', 'line 40: original\ninserted one\ninserted two\n'), encoding='utf-8', newline='\n')
    (fixture / 'editable_binary.bin').write_bytes(b'\x00\xff\x00\x02')
    historical.write_text('extends Node\nvar historical := 99\n', encoding='utf-8')
    tracked.write_text('extends Node\nvar number := 2\n', encoding='utf-8')
    git('add', '--', 'tracked.gd')
    tracked.write_text('extends Node\nvar number := 3\n', encoding='utf-8')
    (fixture / 'new_file.gd').write_text('extends Node\nvar fresh := true\n', encoding='utf-8')
    (folder / 'one.txt').write_text('edited one\n', encoding='utf-8', newline='\n')
    (folder / 'two.txt').write_text('edited two\n', encoding='utf-8', newline='\n')
    git('add', '--', 'folder_actions/deep/one.txt')
    for name in ['ignore_actions/deep/new[1].tmp', 'elsewhere/ignore_actions/deep/keep.tmp', 'add_actions/deep/new.tmp']:
        file = fixture / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text('untracked content\n', encoding='utf-8', newline='\n')

    # Separate histories isolate destructive rewrite tests from editor fixtures.
    for case in ['amend', 'amend_conflict', 'amend_continue', 'amend_hook', 'amend_merge']:
        history_repo = fixture / f'{fixture.name}-temp-chatgpt' / case
        history_repo.mkdir(parents=True)
        (history_repo.parent / '.gdignore').write_text('', encoding='utf-8')

        def history_git(*command: str) -> None:
            subprocess.run(['git', '-C', str(history_repo), *command], check=True, capture_output=True, text=True)

        history_git('init', '-b', 'main')
        history_git('config', 'core.autocrlf', 'false')
        history_git('config', 'user.name', 'Original Author')
        history_git('config', 'user.email', 'original@localhost')
        (history_repo / 'root.txt').write_text('root\n', encoding='utf-8', newline='\n')
        history_git('add', '.')
        history_git('commit', '-m', 'Duplicate subject')
        (history_repo / 'target.txt').write_text('original\n', encoding='utf-8', newline='\n')
        history_git('add', '.')
        history_git('commit', '-m', 'Duplicate subject')
        if case in ['amend_conflict', 'amend_continue']:
            (history_repo / 'target.txt').write_text('later\n', encoding='utf-8', newline='\n')
        (history_repo / 'later.txt').write_text('preserve later commit\n', encoding='utf-8', newline='\n')
        history_git('add', '.')
        history_git('commit', '-m', 'Later commit')
        if case == 'amend_merge':
            history_git('checkout', '-b', 'side', 'HEAD~1')
            (history_repo / 'side.txt').write_text('side branch\n', encoding='utf-8', newline='\n')
            history_git('add', '.')
            history_git('commit', '-m', 'Side commit')
            history_git('checkout', 'main')
            history_git('merge', '--no-ff', 'side', '-m', 'Merge side')
        history_git('config', 'user.name', 'GittyDot Tests')
        history_git('config', 'user.email', 'gittydot-tests@localhost')
        (history_repo / 'target.txt').write_text('amended\n', encoding='utf-8', newline='\n')
        history_git('add', '--', 'target.txt')
        if case == 'amend':
            (history_repo / 'target.txt').write_text('amended\nunstaged draft\n', encoding='utf-8', newline='\n')
            (history_repo / 'untracked.txt').write_text('keep me\n', encoding='utf-8', newline='\n')
        if case == 'amend_hook':
            hook = history_repo / '.git/hooks/pre-commit'
            hook.write_text('#!/bin/sh\necho "[b]blocked by test hook[/b]" >&2\nexit 1\n', encoding='utf-8', newline='\n')
            hook.chmod(0o755)

    # A portable copy keeps editor settings inside the project during headless checks.
    engine_dir = work / 'engine'
    engine_dir.mkdir(exist_ok=True)
    engine = engine_dir / 'godot.exe'
    if args.godot.resolve() != engine.resolve():
        if not engine.exists() or engine.stat().st_size != args.godot.stat().st_size:
            shutil.copyfile(args.godot, engine)
    (engine_dir / '._sc_').write_text('', encoding='utf-8')
    log = fixture / 'editor.log'
    command = [str(engine), '--editor', '--path', str(fixture), '--log-file', str(log)]
    startup = None
    if args.visual:
        command += ['--', '--gittydot-visual']
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0  # SW_HIDE: no interactive window is needed.
    else:
        command.insert(1, '--headless')
    run = subprocess.run(command, capture_output=True, text=True, timeout=90, startupinfo=startup)
    report_path = fixture / 'integration-result.json'
    if not report_path.exists():
        print(run.stdout)
        print(run.stderr)
        raise SystemExit(f'Editor did not finish the checks. Inspect {log}')
    report = json.loads(report_path.read_text(encoding='utf-8'))
    output = log.read_text(encoding='utf-8')
    script_errors = re.findall(r'^.*(?:SCRIPT ERROR:|Parse Error:|Failed to load script).*$'
                               , output, flags=re.MULTILINE)
    startup_errors = re.findall(r'^.*(?:Unicode parsing error|Loaded resource as image file|Could not create child process).*$'
                                , output, flags=re.MULTILINE)
    print(f"GittyDot: {report['passed']} passed, {report['failed']} failed; {len(script_errors)} script errors")
    print(f'Startup diagnostics: {len(startup_errors)}')
    print(f'Report: {report_path}')
    if args.visual:
        print(f'Native preview: {fixture / "inline-highlights.png"}')
    for entry in report['checks']:
        if not entry['passed']:
            print('FAIL:', entry['name'])
    for error in script_errors:
        print(error)
    for error in startup_errors:
        print(error)
    if run.returncode or report['failed'] or script_errors or startup_errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
