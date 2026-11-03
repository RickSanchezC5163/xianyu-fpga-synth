"""Build the supplied React UI into one offline gzip asset for ESP-IDF. No flash."""
from pathlib import Path
import argparse, gzip, hashlib, json, re, subprocess
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / 'firmware/esp32s3_score_bridge/web'
DEST = WEB.parent / 'main/web_ui.html.gz'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--skip-npm-build', action='store_true')
    p.add_argument('--output',type=Path,default=ROOT/'output/research/20261030_s3_ui')
    a = p.parse_args()
    if not a.skip_npm_build:
        subprocess.run(['npm.cmd' if __import__('os').name == 'nt' else 'npm', 'run', 'build'], cwd=WEB, check=True)
    dist = WEB / 'dist'; html = (dist / 'index.html').read_text(encoding='utf-8')
    def asset(name):
        path = (dist / name.removeprefix('./')).resolve()
        if not path.is_relative_to(dist.resolve()): raise ValueError('Asset outside dist')
        return path.read_text(encoding='utf-8')
    html = re.sub(r'<script[^>]+src="([^"]+)"[^>]*></script>',
                  lambda m: '<script type="module">' + asset(m[1]).replace('</script', '<\\/script') + '</script>', html)
    html = re.sub(r'<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"[^>]*>', lambda m: '<style>' + asset(m[1]) + '</style>', html)
    svg = (dist / 'favicon.svg').read_text(encoding='utf-8')
    html = html.replace('href="/favicon.svg"', 'href="data:image/svg+xml,' + quote(svg, safe='') + '"')
    if re.search(r'(?:src|href)="(?:\./)?assets/', html): raise ValueError('Unembedded browser asset')
    payload = html.encode('utf-8'); packed = gzip.compress(payload, mtime=0)
    if len(packed) > 160000: raise ValueError('Unexpected embedded UI growth')
    DEST.write_bytes(packed)
    out = a.output; out.mkdir(parents=True, exist_ok=True)
    (out / 'preview').mkdir(exist_ok=True); (out / 'preview/index.html').write_bytes(payload)
    files = [x for x in (WEB / 'src').rglob('*') if x.is_file()] + [WEB / n for n in ['package.json', 'package-lock.json', 'vite.config.ts', 'index.html']]
    report = {'passed': True, 'programmed': False, 'UI_bytes': len(payload), 'gzip_bytes': len(packed),
              'gzip_sha256': hashlib.sha256(packed).hexdigest(), 'standalone_browser_asset': True,
              'source_sha256': {x.relative_to(ROOT).as_posix(): hashlib.sha256(x.read_bytes()).hexdigest() for x in files}}
    (out / 'web_build.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'source_sha256'}))

if __name__ == '__main__': main()
