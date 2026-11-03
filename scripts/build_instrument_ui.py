"""Snapshot and locally build the complete USB-host/audio/UI design; never program.

Build outputs stay outside the repository under an ASCII path. A source manifest
ties results to the exact copied files, rather than a potentially changing tree.
"""
from pathlib import Path
import argparse
import os
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
GOWIN = Path(os.environ.get("GOWIN_BIN", shutil.which("gw_sh") or "gw_sh"))
BASE = ROOT / "build/integrated"
STEM = "mega60k_instrument"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_reports(build, exit_code, display="spi"):
    log = (build / "build.log").read_text(encoding="utf-8", errors="replace")
    timing_path = build / ("impl/pnr/" + STEM + ".tr")
    report_path = build / ("impl/pnr/" + STEM + ".rpt.txt")
    timing = timing_path.read_text(encoding="utf-8", errors="replace") if timing_path.exists() else ""
    report = report_path.read_text(encoding="utf-8", errors="replace") if report_path.exists() else ""
    bitstream = build / ("impl/pnr/" + STEM + ".fs")
    resources = {}
    for name in ("Logic", "Register", "CLS", "BSRAM", "DSP", "I/O Port"):
        match = re.search(r"(?m)^\s*" + re.escape(name) + r"\s*\|\s*(\d+(?:\.\d+)?)/(\d+)\s*\|", report)
        if match:
            used, total = float(match.group(1)), int(match.group(2))
            if used.is_integer():
                used = int(used)
            resources[name] = {"used": used, "total": total, "percent": round(100 * used / total, 3)}
    violations = {}
    for name in ("Setup", "Hold"):
        match = re.search(r"<Numbers of " + name + r" Violated Endpoints>:\s*(\d+)", timing)
        violations[name] = int(match.group(1)) if match else None
    slacks = {}
    # Parse actual worst-path tables for all four analysis types. Recovery /
    # Removal do not have violated-endpoint counters in this tool version.
    for index, name in enumerate(("Setup", "Hold", "Recovery", "Removal"), 1):
        section = re.search(r"\n3\.1\." + str(index) + " " + name + r" Paths Table\n(.*?)(?=\n3\.)", timing, re.S)
        values = re.findall(r"(?m)^\s*\d+\s+(-?\d+\.\d+)\s+", section.group(1)) if section else []
        slacks[name] = min(map(float, values)) if values else None
    pulse_section = re.search(r"\n3\.2 Minimum Pulse Width Table\n(.*?)(?=\n3\.3)", timing, re.S)
    pulse_values = re.findall(r"(?m)^\s*\d+\s+(-?\d+\.\d+)\s+", pulse_section.group(1)) if pulse_section else []
    pulse_slack = min(map(float, pulse_values)) if pulse_values else None
    clocks = {}
    for match in re.finditer(r"(?m)^\s*\d+\s+(sys_clk|usb_clk)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)", timing):
        clocks[match.group(1)] = {"constraint_mhz": float(match.group(2)), "fmax_mhz": float(match.group(3))}
    warnings = [line for line in log.splitlines() if re.search(r"\bWARN(?:ING)?\b|unconstrained|not constrained|unconnected|not found", line, re.I)]
    errors = [line for line in log.splitlines() if re.match(r"\s*(ERROR|FATAL)\b", line)]
    constraint_failures = [line for line in warnings if
        re.search(r"SDC.*(not found|cannot|empty|invalid)|get_(pins|ports|clocks).*(not found|empty)|unconstrained|no object.*match|constraint.*(ignored|invalid|not exist)|cannot find.*(pin|clock|port)", line, re.I)]
    compact_timing = re.sub(r"\s+", "", timing)
    targets = (("screen_rx", "screen_rx", "audio/screen/receiver/rx_meta_s0/D"),) if display in ("serial","serial-wifi") else (
        ("miso", "lcd_miso", "audio/lcd_miso_meta_s0/D"),
        ("touch_irq", "touch_irq_n", "audio/visual/pixel_display/touch/irq_meta_s0/D"))
    if display=="serial-wifi":
        targets += (("wifi_rx","wifi_rx","audio/visual/wifi_guide/receiver/rx_meta_s0/D"),)
    first_stage_targets = {name: ("TC_FALSE_PATHActivedset_false_path-from[get_ports{" + port + "}]-to[get_pins{" + pin + "}]") in compact_timing
            for name, port, pin in targets}
    shared_sync = None
    if display=="serial-wifi":
        netpath=build/"impl/gwsynthesis"/(STEM+".vg")
        net=netpath.read_text(encoding="utf-8",errors="replace") if netpath.exists() else ""
        def module_body(name):
            found=re.search(r"\bmodule\s+"+re.escape(name)+r"\s*\((.*?)\bendmodule",net,re.S)
            return found.group(1) if found else ""
        panel=module_body("tjc_uart_panel");link=module_body("tjc_high_speed_link")
        low=re.search(r"\b(uart_rx(?:_\d+)?)\s+slow_receiver\s*\((.*?)\);",link,re.S)
        high=re.search(r"\b(uart_rx(?:_\d+)?)\s+receiver\s*\((.*?)\);",panel,re.S)
        shared_sync=bool(low and high and
            ".rx_sync(rx_sync)" in re.sub(r"\s+","",low.group(2)) and
            ".rx_sync(rx_sync)" in re.sub(r"\s+","",high.group(2)) and
            "rx_meta_s0" not in module_body(low.group(1)) and
            "rx_meta_s0" in module_body(high.group(1)))
    full_reports = len(resources) == 6 and set(clocks) == {"sys_clk", "usb_clk"} and all(first_stage_targets.values()) and (shared_sync is not False)
    pass_timing = full_reports and all(violations.get(k) == 0 for k in ("Setup", "Hold")) and all(v is not None and v >= 0 for v in slacks.values()) and pulse_slack is not None and pulse_slack >= 0
    passed = exit_code == 0 and bitstream.is_file() and not errors and not constraint_failures and pass_timing
    return {"status": "pass" if passed else "fail", "exit_code": exit_code,
            "resources": resources, "violated_endpoints": violations,
            "first_stage_constraint_targets_active": first_stage_targets,
            "screen_slow_fast_sync_physically_shared":shared_sync,
            "worst_reported_slack_ns": slacks, "clocks": clocks,
            "minimum_pulse_width_worst_slack_ns": pulse_slack,
            "warnings": warnings, "errors": errors, "constraint_failures": constraint_failures,
            "programmed": False, "hardware_verified": False,
            "display_backend":display,"external_electrical_timing_verified": False,
            "pinout_status": "candidate pin mapping; new image requires board-level verification",
            "bitstream": str(bitstream) if bitstream.exists() else None,
            "bitstream_sha256": digest(bitstream) if bitstream.exists() else None}


def main():
    global STEM
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--display", choices=("spi","serial","serial-wifi"),default="spi")
    parser.add_argument("--build-root",type=Path,default=BASE)
    parser.add_argument("--gowin", type=Path, default=GOWIN)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--parse-only", type=Path, help="Reparse an existing copied build without invoking tools")
    args = parser.parse_args()
    if args.display=="serial": STEM="mega60k_tjc"
    if args.display=="serial-wifi": STEM="mega60k_tjc_wifi"
    if args.parse_only:
        prior = args.parse_only / "build_result.json"
        exit_code = json.loads(prior.read_text(encoding="utf-8")).get("exit_code", 0) if prior.exists() else 0
        result = parse_reports(args.parse_only, exit_code,args.display)
        manifest_path = args.parse_only / "source_manifest.json"
        if manifest_path.exists():
            result["source_manifest_sha256"] = digest(manifest_path)
        (args.parse_only / "build_result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result, indent=2))
        return 0 if result["status"] == "pass" else 1
    build = args.build_root / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    build.mkdir(parents=True)
    files = []
    for folder in ("rtl/audio", "rtl/usb_host", "rtl/ui"):
        files.extend(p for p in (ROOT / folder).iterdir() if p.suffix in {".v", ".hex", ".mem"})
    board = ROOT / "rtl/boards/mega60k"
    board_files=("mega60k_audio_top.v", "mega60k_tjc_top.v","tjc_ui.cst","tjc_ui.sdc","tjc_ui_build.tcl") if args.display=="serial" else (
        "mega60k_audio_top.v", "mega60k_instrument_top.v","instrument_ui.cst", "instrument_ui.sdc", "instrument_ui_build.tcl")
    if args.display=="serial-wifi":
        board_files=("mega60k_audio_top.v","mega60k_tjc_wifi_top.v","tjc_wifi_ui.cst","tjc_wifi_ui.sdc","tjc_wifi_ui_build.tcl")
    files.extend(board / name for name in board_files)
    missing = [str(p) for p in files if not p.is_file()]
    if missing:
        raise FileNotFoundError("Source snapshot incomplete: " + repr(missing))
    copied, compiled, names = {}, {}, set()
    for source in sorted(files):
        if source.name in names:
            raise ValueError("Flattened source name collision: " + source.name)
        names.add(source.name)
        shutil.copy2(source, build / source.name)
        copied[source.relative_to(ROOT).as_posix()] = digest(source)
        if source.suffix == ".v":
            content = source.read_bytes()
            defines=b"`ifndef INSTRUMENT_UI\n`define INSTRUMENT_UI\n`endif\n"
            if args.display in ("serial","serial-wifi"): defines+=b"`ifndef SERIAL_UI\n`define SERIAL_UI\n`endif\n"
            if args.display=="serial-wifi": defines+=b"`ifndef WIFI_SCORE\n`define WIFI_SCORE\n`endif\n"
            (build / source.name).write_bytes(defines + content)
        compiled[source.name] = digest(build / source.name)
    manifest = {"sources": copied, "compiled_sources": compiled,
                "macro_method": "explicit guarded define prepended to copied .v units; original sources unchanged",
                "tool": str(args.gowin), "top": STEM+"_top",
                "defines": ["INSTRUMENT_UI"]+(["SERIAL_UI"] if args.display in ("serial","serial-wifi") else [])+(["WIFI_SCORE"] if args.display=="serial-wifi" else []),
                "display_backend":args.display,"usb_host_enabled": True,
                "builder_script_sha256":digest(Path(__file__).resolve()),
                "programmed": False, "prepared_only": args.prepare_only}
    (build / "source_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(str(build), flush=True)
    if args.prepare_only:
        return 0
    # Keep the vendor's output on disk while it runs. No inherited terminal
    # input, capture thread, GUI automation, Programmer or device access.
    with (build / "build.log").open("wb") as log:
        try:
            tcl="tjc_wifi_ui_build.tcl" if args.display=="serial-wifi" else "tjc_ui_build.tcl" if args.display=="serial" else "instrument_ui_build.tcl"
            run = subprocess.run([str(args.gowin), tcl], cwd=build,
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
            exit_code = run.returncode
        except subprocess.TimeoutExpired:
            exit_code = 124
    result = parse_reports(build, exit_code,args.display)
    result["source_manifest_sha256"] = digest(build / "source_manifest.json")
    (build / "build_result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
