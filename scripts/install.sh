#!/bin/bash
# No sudo, password prompts, app backups, or retained dist bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
TARGET=/Applications/StylePolish.app
BUNDLE_ID=org.bmdy6.StylePolish
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
scripts/build-app.sh
codesign --verify --strict dist/StylePolish.app
pkill -x StylePolish || true
for attempt in {1..30}; do
    if ! pgrep -x StylePolish >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x StylePolish >/dev/null; then echo 'StylePolish did not exit; installation stopped.' >&2; exit 1; fi
# Explicitly replace the installed version; do not rename it into a backup.
"$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
rm -rf "$TARGET"
mv dist/StylePolish.app "$TARGET"
# Include unindexed archive/build copies as well as Spotlight matches.
python3 - "$ROOT" "$HOME/归档/codex-任务" "$TARGET" "$LSREGISTER" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys
root, archive, target, register = sys.argv[1:]
paths = set(subprocess.check_output(['mdfind', 'kMDItemCFBundleIdentifier == org.bmdy6.StylePolish'], text=True).splitlines())
# The containing repository includes other worktrees/dist outputs.
repo = pathlib.Path(root)
if repo.parent.name == '.worktrees': repo = repo.parent.parent
for scan in (str(repo), archive):
    if not os.path.isdir(scan): continue
    for parent, dirs, _ in os.walk(scan):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '.build')]
        for name in list(dirs):
            if name.endswith('.app'):
                paths.add(os.path.join(parent, name)); dirs.remove(name)
for raw in sorted(paths):
    path = pathlib.Path(raw)
    if path.resolve() == pathlib.Path(target).resolve(): continue
    if path.is_symlink(): raise SystemExit('Refusing symlink app: ' + raw)
    if not path.exists():
        subprocess.run([register, '-u', raw], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); continue
    try:
        with open(path/'Contents/Info.plist', 'rb') as f: bundle = plistlib.load(f)
    except (OSError, ValueError): continue
    if bundle.get('CFBundleIdentifier') != 'org.bmdy6.StylePolish': continue
    # An unregistered/unindexed development bundle can return -10814.
    # Still unregister it, then remove it and verify the final inventory.
    subprocess.run([register, '-u', raw], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(path)
    print('Removed duplicate:', raw)
PY
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" || true
# Spotlight metadata can take a short time to settle after deletion/registration.
for attempt in {1..20}; do
    FOUND="$(mdfind "kMDItemCFBundleIdentifier == org.bmdy6.StylePolish")"
    if [ "$FOUND" = "$TARGET" ]; then break; fi
    sleep 0.5
done
printf '%s\n' "$FOUND"
[ "$FOUND" = "$TARGET" ] || { echo 'Spotlight inventory is not exactly the installed app.' >&2; exit 1; }
codesign --verify --strict "$TARGET"
open "$TARGET"
printf 'Installed single copy: %s\n' "$TARGET"
