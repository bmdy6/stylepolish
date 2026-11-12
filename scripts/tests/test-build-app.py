#!/usr/bin/env python3
"""Exercise release packaging without launching an app or touching real keychains."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class BuildAppTests(unittest.TestCase):
    def build(self, identity=False, icon=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'scripts').mkdir()
            shutil.copy(ROOT / 'scripts/build-app.sh', root / 'scripts')
            setup = root / 'scripts/setup-signing.sh'
            setup.write_text('#!/bin/bash\nexit 0\n')
            setup.chmod(0o755)
            resources = root / 'Sources/StylePolishApp/Resources'
            (resources / 'prompts').mkdir(parents=True)
            (resources / 'prompts/polish.md').write_text('synthetic prompt')
            (resources / 'prompts/habits.md').write_text('synthetic habits')
            rules = root / 'Sources/StylePolishCore/Resources'
            rules.mkdir(parents=True)
            (rules / 'local-typos.json').write_text('{"因该":"应该"}')
            (rules / 'habit-tips.json').write_text('{"在/再":"synthetic tip"}')
            if icon:
                (resources / 'AppIcon.icns').write_bytes(b'synthetic icon')
            home = root / 'home'
            if identity:
                keychain = home / 'Library/Keychains/stylepolish-signing.keychain-db'
                keychain.parent.mkdir(parents=True)
                keychain.touch()
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'StylePolish').write_text('synthetic binary')
            mocks = {
                'swift': '#!/bin/bash\nif [[ "$*" == *--show-bin-path* ]]; then echo "$MOCK_ROOT/bin"; fi\n',
                'git': '#!/bin/bash\ncase "$1" in rev-list) echo 1;; rev-parse) echo fixture;; esac\n',
                'security': '''#!/bin/bash
printf '%s\\n' "$*" >> "$MOCK_ROOT/security.log"
case "$1" in
find-identity) echo '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "StylePolish Local"';;
list-keychains) if [ "$#" = 3 ]; then echo '"/synthetic/original.keychain-db"'; fi;;
esac
''',
                'strip': '#!/bin/bash\nexit 0\n',
                'codesign': '#!/bin/bash\nprintf "%s\\n" "$*" >> "$MOCK_ROOT/codesign.log"\n',
            }
            for name, content in mocks.items():
                f = bin_dir / name
                f.write_text(content)
                f.chmod(0o755)
            env = dict(os.environ, HOME=str(home), MOCK_ROOT=str(root), PATH=str(bin_dir)+':/usr/bin:/bin')
            env.pop('STYLEPOLISH_ADHOC', None)
            result = subprocess.run(['bash', 'scripts/build-app.sh'], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            app = root / 'dist/StylePolish.app/Contents'
            info = plistlib.loads((app / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'], '0.6.0')
            self.assertTrue((app / 'Resources/prompts/polish.md').exists())
            self.assertTrue((app / 'Resources/local-typos.json').exists())
            self.assertEqual((app / 'Resources/habit-tips.json').read_text(), '{"在/再":"synthetic tip"}')
            self.assertEqual((app / 'Resources/prompts/habits.md').read_text(), 'synthetic habits')
            signed = (root / 'codesign.log').read_text()
            self.assertIn('--verify --strict', signed)
            if identity:
                self.assertIn('--keychain', signed)
                self.assertIn('--sign '+ 'A'*40, signed)
                log = (root / 'security.log').read_text().splitlines()
                self.assertEqual(log[-1], 'list-keychains -d user -s /synthetic/original.keychain-db')
            else:
                self.assertIn('--sign - ', signed)
                self.assertIn('ad-hoc', result.stderr)
                self.assertFalse((root / 'security.log').exists())
            if icon:
                self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
                self.assertEqual((app / 'Resources/AppIcon.icns').read_bytes(), b'synthetic icon')
            else:
                self.assertNotIn('CFBundleIconFile', info)
                self.assertIn('AppIcon.icns is missing', result.stderr)

    def test_fresh_machine_uses_adhoc_without_keychain(self):
        self.build()

    def test_dedicated_identity_restores_search_and_copies_icon(self):
        self.build(identity=True, icon=True)

if __name__ == '__main__':
    unittest.main()
