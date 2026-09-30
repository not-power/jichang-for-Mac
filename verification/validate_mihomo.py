from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent
exe = root / 'mihomo-v1.19.31'
logs, failed = [], False
for fixture in sorted((root / 'fixtures').glob('*.yaml')):
    home = root / 'mihomo-home' / fixture.stem
    home.mkdir(parents=True, exist_ok=True)
    (home / 'sample.yaml').write_text('payload:\n- +.example.com\n- +.example.org\n')
    run = subprocess.run([str(exe), '-t', '-d', str(home), '-f', str(fixture)], text=True, capture_output=True, timeout=45)
    logs.append(f'{fixture.name}: exit {run.returncode}\n' + run.stdout + run.stderr)
    print(f'{fixture.name}: {"PASS" if run.returncode == 0 else "FAIL"}')
    if run.returncode != 0:
        print(run.stdout, run.stderr)
        failed = True
(root / 'mihomo-validation.log').write_text('\n'.join(logs))
raise SystemExit(1 if failed else 0)
