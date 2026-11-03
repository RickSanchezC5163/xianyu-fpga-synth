"""Compile/run real portable C resident protocol and restore service, no devices."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "firmware/esp32s3_score_bridge/main"
TEST = ROOT / "firmware/esp32s3_score_bridge/tests/resident_slots.c"
OUT = ROOT / "output/research/20261031_four_resident_slots/s3"


def app_pending_harness():
    """Exercise actual HTTP state transitions with storage/HTTP adapters mocked."""
    source = (SOURCE / "app_main.c").read_text(encoding="utf-8")

    def function(name):
        start = source.rfind("static ", 0, source.index(name + "("))
        opening = source.index("{", start)
        level, end = 1, opening + 1
        while level:
            level += (source[end] == "{") - (source[end] == "}")
            end += 1
        return source[start:end]

    stub = r'''
#include "score_resident_sync.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
typedef int esp_err_t;
typedef struct {size_t content_len;} httpd_req_t;
enum {ESP_OK=0,ESP_ERR_INVALID_ARG=1,ESP_ERR_NOT_FOUND=2,pdTRUE=1};
static int upload_mutex,selected_slot=-1,pending_slot=-1,storage_result;
static bool pending_library_unchanged;
static xy_link score_link;
static xy_resident_sync resident_sync;
static uint8_t upload_buffer[XY_MAX_SCORE_BYTES],requested_slot;
static int xSemaphoreTake(int lock,int ticks) {(void)lock;(void)ticks;return pdTRUE;}
static void xSemaphoreGive(int lock) {(void)lock;}
static esp_err_t message(httpd_req_t *req,const char *status,const char *text) {(void)req;(void)status;(void)text;return 0;}
static esp_err_t reject_body(httpd_req_t *req,const char *status,const char *text) {return message(req,status,text);}
static bool query_slot(httpd_req_t *req,uint8_t *slot,char *query,size_t capacity) {(void)req;(void)query;(void)capacity;*slot=requested_slot;return true;}
static bool title_from_query(const char *query,char *title) {(void)query;strcpy(title,"Saved");return true;}
static bool receive_score(httpd_req_t *req) {(void)req;return true;}
static esp_err_t xy_library_save(uint8_t slot,const char *title,const uint8_t *score,size_t length) {(void)slot;(void)title;(void)score;(void)length;return storage_result;}
static esp_err_t xy_library_delete(uint8_t slot) {(void)slot;return storage_result;}
static int mock_commit(xy_link *link) {link->staging=false;link->verified=false;return XY_OK;}
static int mock_abort(xy_link *link) {link->staging=false;link->verified=false;return XY_OK;}
#define xy_commit_score mock_commit
#define xy_abort_score mock_abort
'''
    tests = r'''
static void pending(void) {
    xy_resident_sync_init(&resident_sync);
    for(unsigned n=0;n<4;n++)xy_resident_sync_complete(&resident_sync,(uint8_t)n,true);
    pending_slot=2;pending_library_unchanged=true;
    score_link.staging=score_link.verified=true;storage_result=ESP_OK;requested_slot=2;
}
int main(void) {
    httpd_req_t save={24},empty={0};
    pending();library_save_handler(&save);
    assert(!pending_library_unchanged && resident_sync.dirty_mask==4 && score_link.staging);
    finish_commit(&empty);assert(resident_sync.dirty_mask==4 && resident_sync.synchronized_mask==11 && selected_slot==2);
    pending();delete_handler(&empty);finish_commit(&empty);
    assert(resident_sync.dirty_mask==4 && resident_sync.synchronized_mask==11);
    pending();storage_result=ESP_ERR_NOT_FOUND;delete_handler(&empty);finish_commit(&empty);
    assert(resident_sync.dirty_mask==4 && resident_sync.synchronized_mask==11);
    pending();requested_slot=1;library_save_handler(&save);assert(pending_library_unchanged);
    finish_commit(&empty);assert(resident_sync.dirty_mask==2 && resident_sync.synchronized_mask==13);
    pending();storage_result=ESP_ERR_INVALID_ARG;library_save_handler(&save);assert(pending_library_unchanged);
    finish_commit(&empty);assert(!resident_sync.dirty_mask && resident_sync.synchronized_mask==15);
    puts("PASS actual HTTP handlers: save/delete during pending COMMIT preserve latest-NVS dirty state");
    return 0;
}
'''
    return stub + "\n" + "\n".join(function(name) for name in ("finish_commit", "library_save_handler", "delete_handler")) + tests


def main():
    compiler = os.environ.get("CC") or shutil.which("gcc")
    assert compiler, "A C11 host compiler is required"
    sources = [SOURCE / f for f in ("score_protocol.c", "score_transfer.c", "score_metadata.c", "score_resident_sync.c")]
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="s3-resident-") as build:
        binary = Path(build) / ("resident_slots.exe" if os.name == "nt" else "resident_slots")
        compiled = subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pedantic",
                                   "-I" + str(SOURCE), *map(str, sources), str(TEST), "-o", str(binary)],
                                  capture_output=True, text=True, timeout=60)
        (OUT / "host_compile.txt").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        environment = os.environ.copy()
        environment["XY_RESIDENT_CAPTURE"] = str(OUT / "resident_sender_frames.json")
        tested = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, timeout=30)
        app_test = Path(build) / "app_pending.c"
        app_test.write_text(app_pending_harness(), encoding="utf-8")
        app_binary = Path(build) / ("app_pending.exe" if os.name == "nt" else "app_pending")
        app_compiled = subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pedantic",
                                      "-I" + str(SOURCE), *map(str, sources), str(app_test), "-o", str(app_binary)],
                                     capture_output=True, text=True, timeout=60)
        (OUT / "app_compile.txt").write_text(app_compiled.stdout + app_compiled.stderr, encoding="utf-8")
        assert app_compiled.returncode == 0, app_compiled.stdout + app_compiled.stderr
        app_tested = subprocess.run([str(app_binary)], capture_output=True, text=True, timeout=30)
        (OUT / "host_tests.txt").write_text(tested.stdout + tested.stderr + app_tested.stdout + app_tested.stderr, encoding="utf-8")
        watched = sources + [SOURCE / "app_main.c", SOURCE / "score_transfer.h", SOURCE / "score_protocol.h",
                             SOURCE / "score_resident_sync.h", TEST, Path(__file__).resolve()]
        report = {"passed": tested.returncode == 0 and app_tested.returncode == 0, "compiler": compiler,
                  "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},
                  "target_compiled": False, "hardware_access": False,
                  "scope": "real pure-C sender/custom reply validation/background service with a portable C peer double"}
        (OUT / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(tested.stdout + tested.stderr)
        print(app_tested.stdout + app_tested.stderr)
        assert report["passed"], tested.stderr + app_tested.stderr


if __name__ == "__main__":
    main()
