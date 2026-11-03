"""Host-compile and test ESP score protocol/transfer logic; no ESP SDK or devices."""
import ctypes as C
import shutil
import os
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'main'
REPORT = Path(os.environ.get('XY_ESP_TEST_REPORT', str(ROOT / 'tests/protocol_result.json')))
GCC = os.environ.get('CC') or shutil.which('gcc')
if not GCC: raise RuntimeError('需要主机 GCC；该测试不需要 ESP-IDF')
BUILD = (ROOT / 'build-host') / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
BUILD.mkdir(parents=True)


def crc16(data):
    value = 0xffff
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0xa001 if value & 1 else 0)
    return value


def frame(op, seq, arg=0, data=0):
    body = struct.pack('<BBHIQ', 1, op, seq, arg, data)
    return b'\xc7\x3a' + body + struct.pack('<H', crc16(body))


def decoded(raw):
    assert len(raw) == 20 and raw[:2] == b'\xc7\x3a'
    version, op, seq, arg, data = struct.unpack('<BBHIQ', raw[2:18])
    assert version == 1 and crc16(raw[2:18]) == struct.unpack('<H', raw[18:])[0]
    return op, seq, arg, data


def score_file(events=None, bpm=120, base=48):
    events = events if events is not None else [(0, 0b10010001), (96, 0)]
    return b'XS01' + struct.pack('<HBB', len(events), bpm, base) + b''.join(struct.pack('<Q', tick | mask << 32) for tick, mask in events)


U8P = C.POINTER(C.c_uint8)


class Frame(C.Structure):
    _fields_ = [('opcode', C.c_uint8), ('sequence', C.c_uint16), ('arg', C.c_uint32), ('data', C.c_uint64)]


class Score(C.Structure):
    _fields_ = [('count', C.c_uint16), ('bpm', C.c_uint8), ('base_note', C.c_uint8),
                ('event_crc32', C.c_uint32), ('events', U8P)]


EXCHANGE = C.CFUNCTYPE(C.c_bool, C.c_void_p, U8P, U8P)


class Link(C.Structure):
    _fields_ = [('exchange', EXCHANGE), ('context', C.c_void_p), ('sequence', C.c_uint16),
                ('token', C.c_uint32), ('next_index', C.c_uint16), ('staging', C.c_bool), ('verified', C.c_bool)]


def byte_array(raw):
    return (C.c_uint8 * len(raw)).from_buffer_copy(raw)


class FakeReceiver:
    """Only a protocol peer/test double, not evidence of FPGA loader correctness."""
    def __init__(self):
        self.calls = []
        self.errors = []
        self.token = 0
        self.events = []
        self.count = 0
        self.expected_crc = 0
        self.verified = False
        self.active = ['old score']
        self.last = None
        self.playing = False
        self.commits = 0
        self.drop_data_once = False
        self.drop_commit_replies = 0
        self.reply_faults = []
        self.progress_wrong = False
        self.drop_all = False
        self.short_reply_once = False
        self.callback = EXCHANGE(self.exchange)

    def process(self, raw):
        op, seq, arg, data = decoded(raw)
        if self.last and raw == self.last[0]:
            return self.last[1]
        status = 0
        if op == 1:
            self.token = data >> 32
            self.count = arg & 0xffff
            self.expected_crc = data & 0xffffffff
            self.events = []
            self.verified = False
        elif op == 2:
            assert arg == len(self.events)
            self.events.append(data)
        elif op == 3:
            assert arg == 0 and data == self.token
            assert len(self.events) == self.count
            assert zlib.crc32(b''.join(struct.pack('<Q', v) for v in self.events)) == self.expected_crc
            self.verified = True
        elif op == 4:
            assert arg == 0 and data == self.token and self.verified
            if self.playing:
                status = 6
            else:
                self.active = list(self.events)
                self.commits += 1
                self.verified = False
        elif op == 5:
            assert arg == 0 and data == self.token
            self.events = []
            self.verified = False
        reply = frame(op | 0x80, seq, status | len(self.events) << 8, self.token)
        if status == 0:
            self.last = raw, reply
        return reply

    def exchange(self, context, request, response):
        try:
            raw = bytes(request[:20])
            self.calls.append(raw)
            op, seq, arg, data = decoded(raw)
            reply = self.process(raw)
            if self.drop_all:
                return False
            if self.drop_data_once and op == 2 and arg == 0:
                self.drop_data_once = False
                return False  # accepted event but ACK lost
            if op == 4 and self.drop_commit_replies:
                self.drop_commit_replies -= 1
                return False
            if self.short_reply_once:
                self.short_reply_once = False
                C.memmove(response, reply[:9], 9)
                return False
            if self.reply_faults:
                kind = self.reply_faults.pop(0)
                rop, rseq, rarg, rdata = decoded(reply)
                if kind == 'crc':
                    reply = reply[:-1] + bytes([reply[-1] ^ 1])
                elif kind == 'seq':
                    reply = frame(rop, (rseq + 1) & 0xffff, rarg, rdata)
                elif kind == 'op':
                    reply = frame(0x86, rseq, rarg, rdata)
                elif kind == 'token':
                    reply = frame(rop, rseq, rarg, rdata ^ 1)
                elif kind == 'reserved':
                    reply = frame(rop, rseq, rarg | 1 << 24, rdata)
                elif kind == 'status':
                    reply = frame(rop, rseq, (rarg & ~255) | 7, rdata)
            if self.progress_wrong and op == 1:
                reply = frame(op | 0x80, seq, 1 << 8, self.token)
            C.memmove(response, reply, 20)
            return True
        except BaseException as error:
            self.errors.append(repr(error))
            return False


class ProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dll = BUILD / ('score_protocol.dll' if os.name=='nt' else 'score_protocol.so')
        cmd = [GCC, '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-shared', '-O2',
               *(['-Wl,--export-all-symbols'] if os.name=='nt' else ['-fPIC']), SOURCE / 'score_protocol.c', SOURCE / 'score_transfer.c', '-o', dll]
        run = subprocess.run([str(v) for v in cmd], capture_output=True, text=True, timeout=60)
        (BUILD / 'host_compile.log').write_text(run.stdout + run.stderr, encoding='utf-8')
        if run.returncode:
            raise RuntimeError(run.stdout + run.stderr)
        cls.lib = C.CDLL(str(dll))
        cls.lib.xy_crc16.argtypes = [U8P, C.c_size_t]
        cls.lib.xy_crc16.restype = C.c_uint16
        cls.lib.xy_crc32.argtypes = [U8P, C.c_size_t]
        cls.lib.xy_crc32.restype = C.c_uint32
        cls.lib.xy_frame_encode.argtypes = [U8P, C.c_uint8, C.c_uint16, C.c_uint32, C.c_uint64]
        cls.lib.xy_frame_decode.argtypes = [U8P, C.POINTER(Frame)]
        cls.lib.xy_frame_decode.restype = C.c_bool
        cls.lib.xy_reply_matches.argtypes = [C.POINTER(Frame), C.c_uint8, C.c_uint16, C.c_uint32]
        cls.lib.xy_reply_matches.restype = C.c_bool
        cls.lib.xy_score_validate.argtypes = [U8P, C.c_size_t, C.POINTER(Score)]
        cls.lib.xy_score_validate.restype = C.c_int
        cls.lib.xy_link_init.argtypes = [C.POINTER(Link), EXCHANGE, C.c_void_p, C.c_uint16]
        cls.lib.xy_stage_score.argtypes = [C.POINTER(Link), C.POINTER(Score), C.c_uint32]
        cls.lib.xy_stage_score.restype = C.c_int
        cls.lib.xy_commit_score.argtypes = [C.POINTER(Link)]
        cls.lib.xy_commit_score.restype = C.c_int
        cls.lib.xy_abort_score.argtypes = [C.POINTER(Link)]
        cls.lib.xy_abort_score.restype = C.c_int

    def validated(self, raw=None):
        raw = score_file() if raw is None else raw
        buffer = byte_array(raw)
        score = Score()
        self.assertEqual(self.lib.xy_score_validate(buffer, len(raw), C.byref(score)), 0)
        return buffer, score

    def staged(self, peer=None, raw=None):
        peer = FakeReceiver() if peer is None else peer
        buffer, score = self.validated(raw)
        link = Link()
        self.lib.xy_link_init(C.byref(link), peer.callback, None, 0xfffe)
        result = self.lib.xy_stage_score(C.byref(link), C.byref(score), 0x12345678)
        self.assertFalse(peer.errors)
        return peer, buffer, score, link, result

    def test_standard_crc_vectors_and_empty(self):
        raw = byte_array(b'123456789')
        self.assertEqual(self.lib.xy_crc16(raw, 9), 0x4b37)
        self.assertEqual(self.lib.xy_crc32(raw, 9), 0xcbf43926)
        self.assertEqual(self.lib.xy_crc16(raw, 0), 0xffff)
        self.assertEqual(self.lib.xy_crc32(raw, 0), 0)

    def test_random_crc_and_wire_vectors(self):
        rng = random.Random(271027)
        for _ in range(400):
            data = rng.randbytes(rng.randrange(0, 2057))
            buf = byte_array(data or b'\0')
            self.assertEqual(self.lib.xy_crc16(buf, len(data)), crc16(data))
            self.assertEqual(self.lib.xy_crc32(buf, len(data)), zlib.crc32(data))
            op, seq, arg, word = rng.randrange(1, 7), rng.randrange(65536), rng.getrandbits(32), rng.getrandbits(64)
            out = (C.c_uint8 * 20)()
            self.lib.xy_frame_encode(out, op, seq, arg, word)
            self.assertEqual(bytes(out), frame(op, seq, arg, word))
            decoded_frame = Frame()
            self.assertTrue(self.lib.xy_frame_decode(out, C.byref(decoded_frame)))
            self.assertEqual((decoded_frame.opcode, decoded_frame.sequence, decoded_frame.arg, decoded_frame.data), (op, seq, arg, word))

    def test_each_corrupted_frame_byte_rejected(self):
        original = frame(2, 0x3141, 12, 0x123456789abcdef0)
        for n in range(20):
            bad = bytearray(original)
            bad[n] ^= 1
            self.assertFalse(self.lib.xy_frame_decode(byte_array(bad), C.byref(Frame())), n)

    def test_file_boundaries_and_crc(self):
        for count in [2, 3, 255, 256]:
            raw = score_file([(n * 96, (1 << (n % 25)) if n != count - 1 else 0) for n in range(count)])
            keep, parsed = self.validated(raw)
            self.assertEqual(parsed.count, count)
            self.assertEqual(parsed.event_crc32, zlib.crc32(raw[8:]))
        for bpm in [30, 240]:
            for base in [0, 103]:
                self.validated(score_file(bpm=bpm, base=base))

    def test_invalid_files(self):
        good = score_file()
        cases = [(b'', 1), (good[:7], 1), (b'BAD!' + good[4:], 2),
                 (good[:4] + struct.pack('<H', 1) + good[6:], 3),
                 (good[:4] + struct.pack('<H', 257) + good[6:], 3),
                 (good + b'\0', 1), (good[:-1], 1),
                 (good[:6] + bytes([29]) + good[7:], 4), (good[:6] + bytes([241]) + good[7:], 4),
                 (good[:7] + bytes([104]) + good[8:], 5),
                 (score_file([(1, 1), (96, 0)]), 7),
                 (score_file([(0, 1), (0, 0)]), 8), (score_file([(0, 1), (96, 1), (95, 0)]), 8),
                 (score_file([(0, 1), (0xffffffff, 1), (1, 0)]), 8),
                 (score_file([(0, 1), (96, 1)]), 9)]
        reserved = bytearray(good)
        reserved[15] |= 2
        cases.append((reserved, 6))
        for raw, expected in cases:
            with self.subTest(expected=expected, raw=bytes(raw).hex()):
                self.assertEqual(self.lib.xy_score_validate(byte_array(raw or b'\0'), len(raw), C.byref(Score())), expected)

    def test_full_stage_commit_and_sequence_wrap(self):
        peer, keep, score, link, result = self.staged()
        self.assertEqual(result, 0)
        self.assertEqual(link.sequence, 2)  # FFFE BEGIN, FFFF/0000 DATA,0001 VERIFY
        self.assertTrue(link.verified)
        self.assertEqual(peer.active, ['old score'])
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 0)
        self.assertEqual(peer.commits, 1)
        self.assertFalse(link.staging)
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 2)
        self.assertFalse(peer.errors)

    def test_maximum_file_full_transfer(self):
        raw = score_file([(n, (1 << (n % 25)) if n != 255 else 0) for n in range(256)])
        peer, keep, score, link, result = self.staged(raw=raw)
        self.assertEqual(result, 0)
        self.assertEqual(link.next_index, 256)
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 0)
        self.assertEqual(len(peer.active), 256)
        self.assertFalse(peer.errors)

    def test_lost_data_ack_retries_identical_without_duplicate(self):
        peer = FakeReceiver()
        peer.drop_data_once = True
        peer, keep, score, link, result = self.staged(peer)
        self.assertEqual(result, 0)
        requests = [p for p in peer.calls if decoded(p)[0] == 2 and decoded(p)[2] == 0]
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0], requests[1])
        self.assertEqual(len(peer.events), 2)

    def test_bad_and_partial_acks_do_not_advance(self):
        for fault in ['crc', 'seq', 'op', 'token', 'reserved', 'status', 'short']:
            with self.subTest(fault=fault):
                peer = FakeReceiver()
                if fault == 'short':
                    peer.short_reply_once = True
                else:
                    peer.reply_faults = [fault]
                peer, keep, score, link, result = self.staged(peer)
                self.assertEqual(result, 0)
                self.assertEqual(peer.calls[0], peer.calls[1])

    def test_two_invalid_acks_then_third_valid_is_identical(self):
        peer = FakeReceiver()
        peer.reply_faults = ['crc', 'seq']
        peer, keep, score, link, result = self.staged(peer)
        self.assertEqual(result, 0)
        self.assertEqual(peer.calls[0], peer.calls[1])
        self.assertEqual(peer.calls[1], peer.calls[2])

    def test_export_helper_demo_and_rejections(self):
        path = ROOT / 'tools/make_score.py'
        spec = importlib.util.spec_from_file_location('make_score', path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        raw = helper.encode(helper.demo())
        keep, score = self.validated(raw)
        self.assertEqual(score.count, 9)
        self.assertEqual(struct.unpack('<Q', raw[-8:])[0], 768)
        for document in [
            {'events': [{'tick': 0, 'keys': [0, 0]}, {'tick': 96, 'keys': []}]},
            {'events': [{'tick': 0, 'keys': [True]}, {'tick': 96, 'keys': []}]},
            {'events': [{'tick': 0.0, 'keys': [0]}, {'tick': 96, 'keys': []}]},
            {'events': [{'tick': 0, 'keys': [25]}, {'tick': 96, 'keys': []}]},
            {'events': [{'tick': 0, 'keys': [0]}, {'tick': 96, 'keys': [1]}]},
        ]:
            with self.assertRaises(ValueError):
                helper.encode(document)

    def test_busy_commit_retains_staging_and_next_sequence(self):
        peer, keep, score, link, result = self.staged()
        self.assertEqual(result, 0)
        peer.playing = True
        seq = link.sequence
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 6)
        self.assertTrue(link.verified and link.staging)
        self.assertEqual(link.sequence, (seq + 1) & 0xffff)
        self.assertEqual(peer.active, ['old score'])
        peer.playing = False
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 0)
        self.assertEqual(peer.commits, 1)
        self.assertFalse(peer.errors)

    def test_commit_all_acks_lost_and_later_same_sequence_retry(self):
        peer, keep, score, link, result = self.staged()
        self.assertEqual(result, 0)
        peer.drop_commit_replies = 3
        seq = link.sequence
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 256)
        self.assertEqual(link.sequence, seq)
        self.assertEqual(peer.commits, 1)
        self.assertEqual(self.lib.xy_commit_score(C.byref(link)), 0)
        self.assertEqual(peer.commits, 1)
        packets = [p for p in peer.calls if decoded(p)[0] == 4]
        self.assertEqual(len(packets), 4)
        self.assertEqual(len(set(packets)), 1)
        self.assertFalse(peer.errors)

    def test_timeout_then_abort_uses_new_sequence(self):
        peer = FakeReceiver()
        peer.drop_all = True
        peer, keep, score, link, result = self.staged(peer)
        self.assertEqual(result, 256)
        self.assertEqual(len(set(peer.calls)), 1)
        self.assertEqual(peer.active, ['old score'])
        peer.drop_all = False
        self.assertEqual(self.lib.xy_abort_score(C.byref(link)), 0)
        self.assertFalse(link.staging or link.verified)
        self.assertNotEqual(decoded(peer.calls[0])[1], decoded(peer.calls[-1])[1])
        self.assertFalse(peer.errors)

    def test_progress_mismatch_stops_before_data(self):
        peer = FakeReceiver()
        peer.progress_wrong = True
        peer, keep, score, link, result = self.staged(peer)
        self.assertEqual(result, 257)
        self.assertEqual([decoded(p)[0] for p in peer.calls], [1])
        self.assertFalse(link.verified)


def main():
    source_files = sorted(SOURCE.glob('*.c')) + sorted(SOURCE.glob('*.h')) + [Path(__file__).resolve(),
                   ROOT / 'tools/make_score.py']
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
    log_path = BUILD / 'tests.log'
    with log_path.open('w', encoding='utf-8') as log:
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ProtocolTests))
    unchanged = all(hashlib.sha256((ROOT / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
    vector_events = score_file()
    vector_arg = 2 | 120 << 16 | 48 << 24
    golden = {'file_hex': vector_events.hex(), 'event_crc32': zlib.crc32(vector_events[8:]),
              'begin_hex': frame(1, 7, vector_arg, 0x12345678 << 32 | zlib.crc32(vector_events[8:])).hex(),
              'data0_hex': frame(2, 8, 0, struct.unpack('<Q', vector_events[8:16])[0]).hex(),
              'verify_hex': frame(3, 10, 0, 0x12345678).hex(),
              'commit_hex': frame(4, 11, 0, 0x12345678).hex(),
              'ack_data0_hex': frame(0x82, 8, 1 << 8, 0x12345678).hex()}
    out = ROOT / 'tests/golden_vectors.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(golden, indent=2) + '\n', encoding='utf-8')
    report = {'passed': result.wasSuccessful() and unchanged, 'tests': result.testsRun,
              'failures': [(str(t), e) for t, e in result.failures], 'errors': [(str(t), e) for t, e in result.errors],
              'build': str(BUILD), 'source_sha256': hashes, 'sources_unchanged': unchanged,
              'host_compiler': str(GCC), 'host_compiled': result.testsRun > 0 and not result.errors,
              'target_idf_compiled': False, 'hardware_access': False, 'programmed': False,
              'scope': 'portable protocol and transfer C only; Python peer is a test double, not FPGA or ESP hardware proof',
              'golden_vectors': str(out.relative_to(ROOT))}
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(log_path.read_text(encoding='utf-8'))
    print(json.dumps({k: v for k, v in report.items() if k != 'source_sha256'}, ensure_ascii=False, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
