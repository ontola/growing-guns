"""Test party rules without starting the renderer, audio or network services."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--settings-output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='growing-guns-settings-') as directory:
        root = Path(directory)
        (root / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Settings tests"\n')
        for name in ['scripts/gamenight_settings.gd', 'scripts/round_modifiers.gd', 'scripts/weapon.gd', 'tests/gamenight_settings.gd']:
            target = root / name
            target.parent.mkdir(exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        imported = subprocess.run([args.godot, '--headless', '--editor', '--path', str(root), '--import'], capture_output=True, text=True, timeout=30)
        assert imported.returncode == 0 and 'ERROR' not in imported.stdout + imported.stderr, imported.stdout + imported.stderr
        command = [args.godot, '--headless', '--path', str(root), '--script', 'res://tests/gamenight_settings.gd']
        if args.settings_output:
            command += ['--', '--settings-output=' + str(args.settings_output.resolve())]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired as error:
            print(error.stdout, error.stderr)
            raise
        output = result.stdout + result.stderr
        print(output)
        assert result.returncode == 0 and 'GROWING_GUNS_SETTINGS_PASS' in output and 'ERROR' not in output, output

if __name__ == '__main__': main()
