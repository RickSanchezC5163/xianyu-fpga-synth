"""Validate every embedded part with the actual S3 C parser, without ESP SDK/devices."""
import base64
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

PROJECT=Path(__file__).resolve().parents[1]


class Score(C.Structure):
    _fields_=[('count',C.c_uint16),('bpm',C.c_uint8),('base_note',C.c_uint8),
              ('event_crc32',C.c_uint32),('events',C.POINTER(C.c_uint8))]


def main():
    source=PROJECT/'main/score_catalog.json';catalog=json.loads(source.read_text(encoding='utf8'))
    assert len(catalog['songs'])==1 and len(catalog['songs'][0]['parts'])==1
    blobs=[base64.b64decode(b,validate=True)for b in catalog['blobs']]
    assert len({hashlib.sha256(b).hexdigest()for b in blobs})==len(blobs)
    with tempfile.TemporaryDirectory()as temp:
        dll=Path(temp)/'catalog.dll';gcc=os.environ.get('CC')or shutil.which('gcc')
        subprocess.run([gcc,'-std=c11','-Wall','-Wextra','-Werror','-pedantic','-shared','-O2',
                        str(PROJECT/'main/score_protocol.c'),'-o',str(dll)],check=True,capture_output=True)
        lib=C.CDLL(str(dll));lib.xy_score_validate.argtypes=[C.POINTER(C.c_uint8),C.c_size_t,C.POINTER(Score)]
        lib.xy_score_validate.restype=C.c_int
        for song in catalog['songs']:
            assert song['title'] and song['source_midi_bytes']==0 and not song['audition_pending']
            assert len({p['number']for p in song['parts']})==len(song['parts'])
            for part in song['parts']:
                raw=blobs[part['blob']];score=Score();buf=(C.c_uint8*len(raw)).from_buffer_copy(raw)
                assert lib.xy_score_validate(buf,len(raw),C.byref(score))==0
                assert 1<=len(part['storage_title'].encode('utf8'))<=48
                assert len(raw)==part['bytes']and score.count==part['events']and score.bpm==part['bpm']
                words=struct.unpack_from('<'+'Q'*score.count,raw,8)
                assert all((word>>32).bit_count()<=1 for word in words)
                assert part['duration_ms']==round((words[-1]&0xffffffff)*60000/(score.bpm*96))
        if hasattr(C,'windll'):C.windll.kernel32.FreeLibrary(C.c_void_p(lib._handle))
    # All six required routes for browsing remain independent of UART exchange.
    app=(PROJECT/'main/app_main.c').read_text(encoding='utf8')
    assert 'config.max_open_sockets=4;'in app and 'config.lru_purge_enable=true;'in app
    handler=app.split('static esp_err_t catalog_handler',1)[1].split('\n}',1)[0]
    assert 'httpd_resp_send'in handler and 'xy_stage_score'not in handler and 'uart_'not in handler
    assert '"score_catalog.json"'in (PROJECT/'main/CMakeLists.txt').read_text(encoding='utf8')
    result=dict(passed=True,songs=1,parts=1,unique_blobs=len(blobs),
                actual_S3_C_parser_validated=True,catalog_bytes=source.stat().st_size,
                catalog_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                hardware_access=False,S3_target_build_performed=False)
    (PROJECT/'tests/catalog_result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8',newline='\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
