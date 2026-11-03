"""Host tests for library records only. No NVS/ESP/serial/hardware calls."""
import ctypes as C
import shutil
import os
import datetime
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'main'
BUILD=(ROOT / 'build-host')/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
BUILD.mkdir(parents=True)
GCC = os.environ.get('CC') or shutil.which('gcc')
if not GCC: raise RuntimeError('需要主机 GCC；该测试不需要 ESP-IDF')
U8P=C.POINTER(C.c_uint8)


def buffer(raw):
    return (C.c_uint8*len(raw)).from_buffer_copy(raw)


def score(count=2):
    return b'XS01'+struct.pack('<HBB',count,120,48)+b''.join(
        struct.pack('<Q',n*96 | (0 if n==count-1 else 1<<(n%25))<<32) for n in range(count))


def record(title,raw):
    body=b'XL01'+struct.pack('<BBH',len(title),0,len(raw))+title+raw
    return body+struct.pack('<I',zlib.crc32(body))


def recalc(raw):
    return bytes(raw[:-4])+struct.pack('<I',zlib.crc32(raw[:-4]))


class RecordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dll=BUILD/('score_record.dll' if os.name=='nt' else 'score_record.so')
        cmd=[GCC,'-std=c11','-O2','-Wall','-Wextra','-Werror','-pedantic','-shared',
             *(['-Wl,--export-all-symbols'] if os.name=='nt' else ['-fPIC']),SOURCE/'score_record.c',SOURCE/'score_protocol.c','-o',dll]
        run=subprocess.run([str(v) for v in cmd],capture_output=True,text=True,timeout=60)
        (BUILD/'compile.log').write_text(run.stdout+run.stderr,encoding='utf-8')
        if run.returncode:raise RuntimeError(run.stdout+run.stderr)
        cls.lib=C.CDLL(str(dll))
        cls.lib.xy_record_encode.argtypes=[C.c_char_p,U8P,C.c_size_t,U8P,C.c_size_t,C.POINTER(C.c_size_t)]
        cls.lib.xy_record_encode.restype=C.c_int
        cls.lib.xy_record_decode.argtypes=[U8P,C.c_size_t,C.c_void_p,C.c_size_t,U8P,C.c_size_t,C.POINTER(C.c_size_t)]
        cls.lib.xy_record_decode.restype=C.c_int

    def encode(self,title,raw=None,capacity=2116):
        raw=score() if raw is None else raw
        result=(C.c_uint8*2116)(*([0xa5]*2116));length=C.c_size_t(0xdead)
        err=self.lib.xy_record_encode(title,buffer(raw),len(raw),result,capacity,C.byref(length))
        return err,bytes(result),length.value

    def decode(self,raw,title_capacity=49,score_capacity=2056):
        title=(C.c_uint8*49)(*([0xa5]*49));data=(C.c_uint8*2056)(*([0xa5]*2056));length=C.c_size_t(0xdead)
        # Include one byte for zero-length input without dereferencing it.
        buf=buffer(raw or b'\0')
        err=self.lib.xy_record_decode(buf,len(raw),title,title_capacity,data,score_capacity,C.byref(length))
        return err,bytes(title),bytes(data),length.value

    def assert_unchanged(self,result):
        err,title,data,length=result
        self.assertNotEqual(err,0)
        self.assertEqual(title,b'\xa5'*49);self.assertEqual(data,b'\xa5'*2056)
        self.assertEqual(length,0xdead)

    def test_roundtrip_and_python_crc_golden(self):
        for title in [b'A','八和弦练习'.encode(),'🎹 测试'.encode(),b'x'*48,'琴'*16]:
            if isinstance(title,str):title=title.encode()
            raw=score();expected=record(title,raw)
            err,out,length=self.encode(title,raw)
            self.assertEqual(err,0);self.assertEqual(out[:length],expected)
            err,t,s,n=self.decode(expected)
            self.assertEqual((err,t.split(b'\0')[0],s[:n]),(0,title,raw))

    def test_min_and_max_sizes(self):
        for count in [2,3,255,256]:
            raw=score(count);title=b'x'*48
            err,out,n=self.encode(title,raw)
            self.assertEqual(err,0)
            self.assertEqual(n,8+48+len(raw)+4)
            result=self.decode(out[:n]);self.assertEqual(result[0],0)
            self.assertEqual(result[2][:result[3]],raw)
        self.assertEqual(n,2116)

    def test_all_single_byte_corruption_rejected_without_output(self):
        raw=record('曲谱'.encode(),score(3))
        for i in range(len(raw)):
            damaged=bytearray(raw);damaged[i]^=1
            self.assert_unchanged(self.decode(damaged))

    def test_every_truncation_extra_bytes_and_empty_rejected(self):
        raw=record(b'T',score())
        for n in range(len(raw)):
            self.assert_unchanged(self.decode(raw[:n]))
        self.assert_unchanged(self.decode(raw+b'\0'))

    def test_invalid_utf8_and_controls_rejected(self):
        invalid=[b'',b'a\nb',b'\x7f',b'\xc2\x85',b'\x80',b'\xc0\x80',
                 b'\xed\xa0\x80',b'\xf4\x90\x80\x80',b'\xe4\xb8',b'x'*49]
        for title in invalid:
            self.assertNotEqual(self.encode(title)[0],0,title)
            if len(title)<=48:self.assert_unchanged(self.decode(record(title,score())))
        self.assert_unchanged(self.decode(record(b'a\0b',score())))

    def test_invalid_score_rejected_even_with_correct_record_crc(self):
        raw=bytearray(score());raw[6]=29
        err,out,n=self.encode(b'A',raw)
        self.assertNotEqual(err,0);self.assertEqual(n,0xdead);self.assertEqual(out,b'\xa5'*2116)
        self.assert_unchanged(self.decode(record(b'A',raw)))
        raw=bytearray(score());raw[-8:]=struct.pack('<Q',96|(1<<32))
        self.assert_unchanged(self.decode(record(b'A',raw)))

    def test_header_reserved_length_and_capacity_rejected(self):
        valid=record(b'ABC',score())
        for index,value in [(5,1),(4,49),(6,0),(7,255)]:
            bad=bytearray(valid);bad[index]=value
            self.assert_unchanged(self.decode(recalc(bad)))
        self.assert_unchanged(self.decode(valid,title_capacity=3))
        self.assert_unchanged(self.decode(valid,score_capacity=23))
        err,out,n=self.encode(b'ABC',capacity=len(valid)-1)
        self.assertEqual(err,7);self.assertEqual(n,0xdead);self.assertEqual(out,b'\xa5'*2116)

    def test_random_valid_records_match_independent_format(self):
        rng=random.Random(281028)
        for _ in range(200):
            title=bytes(rng.randrange(0x21,0x7f) for _ in range(rng.randrange(1,49)))
            raw=score(rng.randrange(2,257));expected=record(title,raw)
            err,out,n=self.encode(title,raw)
            self.assertEqual(err,0);self.assertEqual(out[:n],expected)
            self.assertEqual(self.decode(expected)[0],0)

    def test_null_arguments_rejected(self):
        out=(C.c_uint8*2116)();n=C.c_size_t()
        self.assertEqual(self.lib.xy_record_encode(None,buffer(score()),24,out,2116,C.byref(n)),1)
        self.assertEqual(self.lib.xy_record_encode(b'A',None,24,out,2116,C.byref(n)),1)
        self.assertEqual(self.lib.xy_record_decode(None,24,out,49,out,2056,C.byref(n)),1)


def main():
    sources=[SOURCE/name for name in ['score_library.c','score_library.h','score_record.c','score_record.h','score_protocol.c','score_protocol.h']]+[Path(__file__).resolve()]
    hashes={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    with (BUILD/'tests.log').open('w',encoding='utf-8') as log:
        result=unittest.TextTestRunner(stream=log,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RecordTests))
    unchanged=all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
    report={'passed':result.wasSuccessful() and unchanged,'tests':result.testsRun,
        'build':str(BUILD),'source_sha256':hashes,'sources_unchanged':unchanged,
        'scope':'portable record codec + existing XS01 validation only; NVS wrapper not host-compiled',
        'target_compiled':False,'physical_nvs_verified':False,'hardware_access':False,'programmed':False,
        'errors':[(str(t),e) for t,e in result.errors],'failures':[(str(t),e) for t,e in result.failures]}
    dest=ROOT/'tests/record_result.json';dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print((BUILD/'tests.log').read_text(encoding='utf-8'))
    print(json.dumps({k:v for k,v in report.items() if k!='source_sha256'},ensure_ascii=False,indent=2))
    if not report['passed']:raise SystemExit(1)


if __name__=='__main__':main()
