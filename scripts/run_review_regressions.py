"""Reproduce known RTL defects or require repaired contracts with --mode fixed.

Only test-specific contract assertions count as known defects. Setup failures,
timeouts and simulator errors always fail the run. No hardware is accessed.
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# top-level module -> extra RTL files it needs (copied into the build dir)
TESTS = {
    'tb_midi_missing_attack': [
        'uart_rx.v', 'uart_tx.v', 'midi_control.v', 'additive_core.v'],
    'tb_midi_retrigger_note_off': [
        'uart_rx.v', 'uart_tx.v', 'midi_control.v'],
    'tb_stop_fade_discontinuity': [
        'additive_core.v', 'button_conditioner.v', 'echo_effect.v',
        'usb_attach_monitor.v', 'ws2812_status.v', 'pt8211_tx.v', 'i2s_tx.v',
        'uart_rx.v', 'uart_tx.v', 'midi_control.v', 'mega60k_audio_top.v'],
    'tb_usb_midi_integrity_repro': ['usb_hid_host.v', 'usb_midi_event_cdc.v'],
}


IVERILOG_CANDIDATES = ()


def find_iverilog(explicit):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(path)
        return path.resolve()
    for path in IVERILOG_CANDIDATES:
        if path.is_file():
            return path.resolve()
    found = shutil.which('iverilog')
    if not found:
        raise FileNotFoundError('iverilog not found; pass --iverilog')
    return Path(found).resolve()


def tool_environment(iverilog):
    env = os.environ.copy()
    env['PATH'] = str(iverilog.parent) + os.pathsep + env.get('PATH', '')
    return env


def classify(top, variant, code, output):
    expected = 'EXPECTED_BUG:' + top + ':'
    passed = 'PASS:' + top + ':'
    contract = 'CONTRACT_FAILURE:' + top + ':'
    # A contract marker must be on Icarus's fatal assertion line, not arbitrary
    # diagnostic output followed by a simulator crash.
    fatal_contract = any(line.startswith('FATAL:') and contract in line
                         for line in output.splitlines())
    if variant == 'default' and code == 0 and expected in output:
        return 'defect_reproduced'
    if variant == 'fixed' and code == 0 and passed in output:
        return 'contract_passed'
    if variant == 'fixed' and code == 1 and fatal_contract:
        return 'defect_still_present'
    return 'execution_failed'


def run(command, cwd, env):
    try:
        result = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=1800)
        return result.returncode, result.stdout.decode('utf-8', errors='replace')
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b''
        if isinstance(output, bytes):
            output = output.decode('utf8', errors='replace')
        return -1, output + '\nRUNNER_ERROR: process timeout'
    except OSError as exc:
        return -1, 'RUNNER_ERROR: ' + str(exc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-root', type=Path,
                        default=Path(os.environ.get('TEMP', '.')) /
                        'fpga_gaoyun_review_regressions')
    parser.add_argument('--iverilog', type=Path, default=None)
    parser.add_argument('--mode', choices=('reproduce', 'fixed'), default='fixed')
    args = parser.parse_args()

    iverilog = find_iverilog(args.iverilog)
    vvp = iverilog.with_name('vvp' + iverilog.suffix)
    env = tool_environment(iverilog)
    args.build_root.mkdir(parents=True, exist_ok=True)
    build = args.build_root / ('run-' + datetime.datetime.now().strftime(
        '%Y%m%d-%H%M%S-%f'))
    build.mkdir(parents=True, exist_ok=False)
    print('Build directory:', build, flush=True)
    print('iverilog:', iverilog, flush=True)
    if not vvp.is_file():
        raise FileNotFoundError(vvp)

    for directory in ('rtl/audio', 'rtl/boards/mega60k', 'rtl/usb_host'):
        for src in (ROOT / directory).iterdir():
            if src.is_file():
                shutil.copy2(src, build / src.name)
    for src in (ROOT / 'rtl/tb').glob('*.sv'):
        shutil.copy2(src, build / src.name)

    summary = {'date': datetime.datetime.now().isoformat(),
               'iverilog': str(iverilog), 'mode': args.mode, 'tests': {}}
    failures = []
    for top, extra in TESTS.items():
        entry = {}
        variants = [('fixed', ['-DEXPECT_FIXED'])]
        if args.mode == 'reproduce':
            variants.insert(0, ('default', []))
        for mode, defines in variants:
            tag = '%s_%s' % (top, mode)
            command = [iverilog, '-g2012', '-Wall', '-s', top, *defines,
                       '-o', tag + '.vvp', *extra, top + '.sv']
            code, text = run(command, build, env)
            (build / (tag + '_compile.log')).write_text(text, encoding='utf8')
            if code:
                print('%s: COMPILE FAILED' % tag, flush=True)
                print(text[-2000:], flush=True)
                failures.append(tag + ':compile')
                entry[mode] = {'compile': 'failed', 'exit': code, 'verdict': 'execution_failed'}
                continue
            code, text = run([vvp, tag + '.vvp'], build, env)
            (build / (tag + '.log')).write_text(text, encoding='utf8')
            verdict = classify(top, mode, code, text)
            entry[mode] = {'exit': code, 'verdict': verdict}
            required = ('contract_passed' if args.mode == 'fixed' else
                        'defect_reproduced' if mode == 'default' else
                        'defect_still_present')
            if verdict != required:
                failures.append(tag + ':' + verdict)
            print('%-46s rc=%-3s %s' % (tag, code, verdict), flush=True)
        summary['tests'][top] = entry

    summary['default_reproduced'] = sum(
        1 for t in summary['tests'].values()
        if t.get('default', {}).get('verdict') == 'defect_reproduced')
    summary['total'] = len(TESTS)
    summary['success'] = not failures
    summary['failures'] = failures
    summary['contracts_passed'] = sum(t.get('fixed', {}).get('verdict') == 'contract_passed'
                                      for t in summary['tests'].values())
    (build / 'review_regressions_result.json').write_text(
        json.dumps(summary, indent=2), encoding='utf8')
    print('Mode: %s; reproduced: %d/%d; contracts passed: %d/%d; json: %s'
          % (args.mode, summary['default_reproduced'], summary['total'],
             summary['contracts_passed'], summary['total'],
             build / 'review_regressions_result.json'), flush=True)
    if failures:
        print('FAILURES: ' + ', '.join(failures), flush=True)
        return 1
    print('Known defects reproduced with targeted assertions.' if args.mode == 'reproduce'
          else 'All repaired contracts passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
