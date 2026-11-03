"""Compile actual app metadata-query helpers with a minimal HTTP query adapter.

This validates application input handling, not the ESP-IDF HTTP server runtime.
"""
from pathlib import Path
import ctypes as C
import hashlib
import json
import shutil
import subprocess
import time
from urllib.parse import quote

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT.parents[1]/'output/research/20261029_score_metadata/s3'
BUILD=ROOT/'build-host'/('http-query-'+str(time.time_ns()));BUILD.mkdir(parents=True)
source=(ROOT/'main/app_main.c').read_text(encoding='utf-8')
def function(name):
    start=source.index('static ',source.index(name)-40)
    # Explicit signature anchors avoid a preceding function's static keyword.
    start=source.rfind('static ',0,source.index(name+'('))
    end=source.index('{',start);level=1;i=end+1
    while level:
        if source[i]=='{':level+=1
        elif source[i]=='}':level-=1
        i+=1
    return source[start:i]
stub=r'''
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "score_metadata.h"
#include "score_record.h"
typedef int esp_err_t;
enum {ESP_OK=0,ESP_ERR_NOT_FOUND=1,ESP_ERR_HTTPD_RESULT_TRUNC=2};
typedef struct {const char *query;}httpd_req_t;
static size_t httpd_req_get_url_query_len(httpd_req_t *r){return strlen(r->query);}
static int httpd_req_get_url_query_str(httpd_req_t *r,char *out,size_t size){
    size_t n=strlen(r->query);if(n>=size)return ESP_ERR_HTTPD_RESULT_TRUNC;
    memcpy(out,r->query,n+1);return ESP_OK;
}
/* IDF's query lookup returns raw encoded values, not decoded UTF-8. */
static int httpd_query_key_value(const char *query,const char *key,char *out,size_t size){
    size_t length=strlen(key);
    for(const char *p=query;*p;){
        const char *e=strchr(p,'&');if(!e)e=p+strlen(p);
        const char *v=memchr(p,'=',(size_t)(e-p));
        if(v && (size_t)(v-p)==length && !memcmp(p,key,length)){
            size_t n=(size_t)(e-v-1);if(n>=size)return ESP_ERR_HTTPD_RESULT_TRUNC;
            memcpy(out,v+1,n);out[n]=0;return ESP_OK;
        }
        if(!*e)break;p=e+1;
    }
    return ESP_ERR_NOT_FOUND;
}
'''
harness=stub+'\n'+'\n'.join(function(x) for x in ['hex_value','title_from_query','query_number','score_metadata_query'])+r'''
bool xy_test_query(const char *query,const char *fallback,xy_score_metadata *metadata,bool *present){
    httpd_req_t r={query};return score_metadata_query(&r,fallback,metadata,present);
}
'''
path=BUILD/'query.c';path.write_text(harness,encoding='utf-8');dll=BUILD/'query.dll'
q=subprocess.run([shutil.which('gcc'),'-std=c11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-shared','-O2',
                  '-I'+str(ROOT/'main'),str(path),str(ROOT/'main/score_metadata.c'),str(ROOT/'main/score_protocol.c'),
                  '-o',str(dll)],capture_output=True,text=True,timeout=60)
(OUT/'http_query_compile.txt').write_text(q.stdout+q.stderr,encoding='utf-8');assert q.returncode==0,q.stderr
class Metadata(C.Structure):
    _fields_=[('title',C.c_uint8*24),('length',C.c_uint8),('part',C.c_uint16),('total',C.c_uint16),
              ('resident_slot',C.c_uint8),('store_only',C.c_bool)]
lib=C.CDLL(str(dll));lib.xy_test_query.argtypes=[C.c_char_p,C.c_char_p,C.POINTER(Metadata),C.POINTER(C.c_bool)];lib.xy_test_query.restype=C.c_bool
tests=0
def check(query,expected,fallback=None,title=None,part=None,total=None,named=None):
    global tests
    m=Metadata();p=C.c_bool()
    result=lib.xy_test_query(query.encode(),fallback.encode() if fallback else None,C.byref(m),C.byref(p))
    assert bool(result)==expected,(query,result,expected)
    if result:
        if named is not None:assert p.value==named
        if title is not None:assert bytes(m.title[:m.length]).decode('gb2312')==title
        if part is not None:assert m.part==part
        if total is not None:assert m.total==total
    tests+=1
check('',True,named=False)
check('title='+quote('送别')+'&part=2&total=8',True,title='送别',part=2,total=8,named=True)
check('slot=0',True,fallback='兰亭序·02/03',title='兰亭序',part=2,total=3)
check('title='+quote('彩云追月')+'&part=1&total=1',True,fallback='old',title='彩云追月')
check('title=a%26b+one',True,title='a&b one')
check('title=a%22%5Cb',True,title='a??b')
for query in ['title=','title=%','title=%ZZ','title=%00','title=%0A','title=%C0%AF','title=%ED%A0%80',
              'title=x&part=2&total=1','title=x&part=-1','title=x&part=0','title=x&total=1000',
              'title=x&total=99999','title=x&part=abc','part=2&total=3','title='+quote('汉'*17),'a='+'x'*260]:
    check(query,False)
check('slot=1&part=0',False,fallback='送别·01/03')
result={'passed':True,'tests':tests,'app_main_sha256':hashlib.sha256(source.encode()).hexdigest(),
        'scope':'Compiled actual app metadata query helpers with a minimal raw-query adapter, not the ESP HTTP runtime','hardware_access':False}
(OUT/'http_query_result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result))
