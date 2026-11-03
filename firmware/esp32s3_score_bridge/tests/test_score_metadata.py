"""Real pure-C sender/codec checks with explicit peer doubles; no devices."""
from pathlib import Path
import ctypes as C
import hashlib
import json
import os
import shutil
import struct
import subprocess
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
OUT = REPO / 'output/research/20261029_score_metadata/s3'
BUILD = ROOT / 'build-host' / ('metadata-' + str(time.time_ns()))
BUILD.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
P = C.POINTER(C.c_uint8)
CALL = C.CFUNCTYPE(C.c_bool, C.c_void_p, P, P)

class Link(C.Structure):
    _fields_ = [('exchange', CALL), ('context', C.c_void_p), ('sequence', C.c_uint16),
                ('token', C.c_uint32), ('next_index', C.c_uint16), ('staging', C.c_bool), ('verified', C.c_bool)]
class Score(C.Structure):
    _fields_ = [('count', C.c_uint16), ('bpm', C.c_uint8), ('base_note', C.c_uint8),
                ('event_crc32', C.c_uint32), ('events', P)]
class Metadata(C.Structure):
    _fields_ = [('title', C.c_uint8*24), ('title_len', C.c_uint8), ('part', C.c_uint16), ('total', C.c_uint16),
                ('resident_slot', C.c_uint8), ('store_only', C.c_bool)]
class Active(C.Structure):
    _fields_ = [('active', C.c_bool), ('count', C.c_uint16), ('part', C.c_uint16), ('total', C.c_uint16),
                ('bpm', C.c_uint8), ('title_len', C.c_uint8), ('title', C.c_uint8*24), ('token', C.c_uint32),
                ('resident_slot', C.c_uint8)]

def crc16(b):
    c=65535
    for v in b:
        c ^= v
        for _ in range(8): c=(c>>1)^(0xa001 if c&1 else 0)
    return c
def frame(op,seq,arg=0,data=0):
    b=struct.pack('<BBHIQ',1,op,seq,arg,data)
    return b'\xc7\x3a'+b+struct.pack('<H',crc16(b))
def decode(raw):
    assert raw[:2]==b'\xc7\x3a' and crc16(raw[2:18])==int.from_bytes(raw[18:],'little')
    version,op,seq,arg,data=struct.unpack('<BBHIQ',raw[2:18]);assert version==1
    return op,seq,arg,data

gcc=os.environ.get('CC') or shutil.which('gcc'); assert gcc
dll=BUILD/'metadata.dll'
files=['score_protocol.c','score_transfer.c','score_metadata.c']
q=subprocess.run([gcc,'-std=c11','-O2','-Wall','-Wextra','-Werror','-pedantic','-shared',
                  *(['-Wl,--export-all-symbols'] if os.name=='nt' else ['-fPIC']),
                  *map(str,(ROOT/'main'/f for f in files)),'-o',str(dll)],capture_output=True,text=True,timeout=60)
(OUT/'host_compile.txt').write_text(q.stdout+q.stderr,encoding='utf-8');assert q.returncode==0,q.stderr
lib=C.CDLL(str(dll))
lib.xy_link_init.argtypes=[C.POINTER(Link),CALL,C.c_void_p,C.c_uint16]
lib.xy_stage_score_named.argtypes=[C.POINTER(Link),C.POINTER(Score),C.c_uint32,C.POINTER(Metadata)]
lib.xy_stage_score_named.restype=C.c_int
lib.xy_commit_score.argtypes=[C.POINTER(Link)];lib.xy_commit_score.restype=C.c_int
lib.xy_read_active_score.argtypes=[C.POINTER(Link),C.POINTER(Active)];lib.xy_read_active_score.restype=C.c_int
lib.xy_metadata_from_utf8.argtypes=[C.c_char_p,C.c_uint16,C.c_uint16,C.POINTER(Metadata)]
lib.xy_metadata_from_utf8.restype=C.c_bool
lib.xy_metadata_title_utf8.argtypes=[P,C.c_size_t,C.c_char_p,C.c_size_t];lib.xy_metadata_title_utf8.restype=C.c_bool
lib.xy_metadata_from_storage_title.argtypes=[C.c_char_p,C.POINTER(Metadata)]
lib.xy_metadata_from_storage_title.restype=C.c_bool

class Peer:
    def __init__(self):
        self.requests=[];self.unique=[];self.cache={};self.token=0;self.events=[];self.title=b''
        self.part=0;self.total=0;self.count=0;self.bpm=0;self.active=False;self.offline=False
        self.old=False;self.busy=False;self.corrupt=None;self.drop=False;self.change=False;self.info=0
        self.callback=CALL(self.exchange);self.errors=[]
    def exchange(self,_,request,response):
        try:
            raw=bytes(request[:20]);op,seq,arg,data=decode(raw);self.requests.append(raw)
            if self.offline:return False
            if raw in self.cache:reply=self.cache[raw]
            else:
                self.unique.append(raw);status=0;outarg=0;outdata=self.token
                if self.old and op>=7:status=3
                elif op==1:
                    assert arg>>31==1;self.token=data>>32;self.crc=data&0xffffffff
                    self.count=arg&65535;self.bpm=(arg>>16)&255;self.events=[];self.title=b''
                    outdata=self.token
                elif op==7:
                    if arg==0:
                        assert data&0xffffffff==self.token
                        self.length=(data>>32)&31;self.part=(data>>37)&1023;self.total=(data>>47)&1023
                    else:
                        assert arg==len(self.title)//8+1
                        self.title+=data.to_bytes(8,'little')
                elif op==2:
                    assert len(self.title)==((self.length+7)//8)*8
                    assert arg==len(self.events);self.events.append(data);outarg=len(self.events)<<8
                elif op==3:
                    assert len(self.events)==self.count
                    assert zlib.crc32(b''.join(x.to_bytes(8,'little') for x in self.events))==self.crc
                    outarg=len(self.events)<<8
                elif op==4:
                    outarg=len(self.events)<<8
                    if self.busy:status=6
                    else:self.active=True
                elif op==8:
                    self.info+=1
                    if self.change and self.info>1:self.token^=1
                    if self.active:
                        outarg=1<<8|self.count<<9|self.length<<18
                        outdata=self.token|self.part<<32|self.total<<42|self.bpm<<52
                    else:outarg=0;outdata=0
                elif op==9:
                    if not self.active or data!=self.token:status=2;outdata=0
                    else:outdata=int.from_bytes(self.title.ljust(24,b'\0')[arg*8:arg*8+8],'little')
                else:raise AssertionError((op,seq,arg,data))
                reply=frame(op|128,seq,outarg|status,outdata)
                if not status:self.cache[raw]=reply
            if self.drop:self.drop=False;return False
            if self.corrupt=='crc':reply=reply[:-1]+bytes([reply[-1]^1])
            elif self.corrupt=='seq':reply=frame(op|128,(seq+1)&65535,0,0)
            elif self.corrupt=='reserved':reply=frame(op|128,seq,1<<31,1<<63)
            C.memmove(response,reply,20);return True
        except BaseException as e:self.errors.append(repr(e));return False

checks=0
def expect(value):
    global checks
    assert value;checks+=1
def metadata(title='歌声与微笑',part=2,total=3):
    m=Metadata();expect(lib.xy_metadata_from_utf8(title.encode(),part,total,C.byref(m)));return m
def setup(peer=None,title='歌声与微笑'):
    peer=peer or Peer();link=Link();lib.xy_link_init(C.byref(link),peer.callback,None,65530)
    raw=struct.pack('<QQ',1<<32,96);buf=(C.c_uint8*len(raw)).from_buffer_copy(raw)
    score=Score(2,120,48,zlib.crc32(raw),C.cast(buf,P));m=metadata(title)
    result=lib.xy_stage_score_named(C.byref(link),C.byref(score),0x12345678,C.byref(m))
    expect(not peer.errors)
    return peer,link,buf,score,m,result

for title in ['送别','歌声与微笑','One Last Kiss','彩云追月-钢琴','汉'*16,'A'*23+'汉','A'*22+'汉','😀主题曲','"x\\y']:
    m=metadata(title);b=bytes(m.title[:m.title_len]);expect(len(b)<=24)
    decoded=b.decode('gb2312');expect('"' not in decoded and '\\' not in decoded)
    out=C.create_string_buffer(73);expect(lib.xy_metadata_title_utf8(m.title,m.title_len,out,len(out)))
    expect(out.value.decode()==decoded)
for bad in [b'',b'\xc0\xaf',b'\xed\xa0\x80',b'\xf4\x90\x80\x80',b'bad\n',b'x'*49]:
    m=Metadata();expect(not lib.xy_metadata_from_utf8(bad,1,1,C.byref(m)))
for part,total in [(0,1),(2,1),(1,1000)]:
    m=Metadata();expect(not lib.xy_metadata_from_utf8(b'ok',part,total,C.byref(m)))
for title,expected,part,total in [('送别·01/06','送别',1,6),('兰亭序·2/3','兰亭序',2,3),('custom','custom',1,1),('a·0/3','a?0/3',1,1)]:
    m=Metadata();expect(lib.xy_metadata_from_storage_title(title.encode(),C.byref(m)))
    expect((bytes(m.title[:m.title_len]).decode('gb2312'),m.part,m.total)==(expected,part,total))
p,l,b,s,m,result=setup();expect(result==0);expect(lib.xy_commit_score(C.byref(l))==0)
capture=list(p.unique)
out=Active();expect(lib.xy_read_active_score(C.byref(l),C.byref(out))==0)
expect(out.active and out.count==2 and out.part==2 and out.total==3 and out.token==0x12345678)
expect(bytes(out.title[:out.title_len]).decode('gb2312')=='歌声与微笑')
p,l,*_=setup();p.busy=True;expect(lib.xy_commit_score(C.byref(l))==6);expect(l.verified and l.staging)
p.busy=False;expect(lib.xy_commit_score(C.byref(l))==0)
p=Peer();p.drop=True;p,l,*tail=setup(p);expect(tail[-1]==0);expect(p.requests[0]==p.requests[1])
for mode in ['offline','old']:
    p=Peer();setattr(p,mode,True);p,l,*tail=setup(p);expect(tail[-1]!=0);expect(not any(decode(x)[0]==4 for x in p.requests))
for corrupt in ['crc','seq','reserved']:
    p=Peer();l=Link();lib.xy_link_init(C.byref(l),p.callback,None,1);p.corrupt=corrupt
    out=Active();out.active=True;expect(lib.xy_read_active_score(C.byref(l),C.byref(out))!=0);expect(not out.active)
p=Peer();l=Link();lib.xy_link_init(C.byref(l),p.callback,None,1);out=Active()
expect(lib.xy_read_active_score(C.byref(l),C.byref(out))==0 and not out.active)
p,l,*_=setup();expect(lib.xy_commit_score(C.byref(l))==0);p.change=True;out=Active();out.active=True
expect(lib.xy_read_active_score(C.byref(l),C.byref(out))==258);expect(not out.active)
vectors={'token':0x12345678,'title_utf8':'歌声与微笑','title_gb2312_hex':'歌声与微笑'.encode('gb2312').hex(),
         'part':2,'total':3,'count':2,'bpm':120,'base':48,'frames_hex':[x.hex() for x in capture],
         'scope':'Actual xy_stage_score_named+xy_commit_score C outputs; peer ACKs mocked; replay on RTL separately required.'}
(OUT/'named_sender_frames.json').write_text(json.dumps(vectors,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(OUT/'named_sender_bytes.hex').write_text(''.join(f'{v:02x}\n' for x in capture for v in x),encoding='ascii')
sources={name:hashlib.sha256((ROOT/'main'/name).read_bytes()).hexdigest() for name in files+['gb2312_table.inc']}
report={'passed':True,'checks':checks,'captured_frames':len(capture),'source_sha256':sources,'hardware_access':False,
        'scope':'Real compiled C codec/transfer with explicit peer doubles; no ESP-IDF, HTTP server, UART hardware or FPGA proof'}
(OUT/'metadata_result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print(json.dumps(report))
