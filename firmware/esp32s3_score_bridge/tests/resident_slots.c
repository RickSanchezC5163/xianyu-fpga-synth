/* Portable C sender/query/restore tests. Peer is a test double, not RTL proof. */
#include "score_resident_sync.h"
#include "score_metadata.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t valid_mask,active_slot,staged_slot,info_slot,info_reads;
    bool store_only,offline,upload_offline,busy,change_info;
    uint16_t progress;
    uint32_t token,crc,slot_token[4],slot_crc[4];
    unsigned calls,commits,aborts,clears,loads,timeout_ms,timeouts[16],timeout_count;
    int missing_slot,bad_slot,bad_error;
    uint64_t meta_header;
    uint8_t captured[512][XY_FRAME_BYTES];
    unsigned captured_count;
    unsigned invalid_replies;
} peer;
static const uint8_t score_file[24]={'X','S','0','1',2,0,120,48,0,0,0,0,1,0,0,0,96,0,0,0,0,0,0,0};

static bool exchange(void *context,const uint8_t request[XY_FRAME_BYTES],uint8_t reply[XY_FRAME_BYTES]) {
    peer *p=context;xy_frame f;assert(xy_frame_decode(request,&f));p->calls++;
    assert(p->captured_count<512);memcpy(p->captured[p->captured_count++],request,XY_FRAME_BYTES);
    if(p->offline || (p->upload_offline && f.opcode!=XY_RESIDENT_INFO))return false;
    uint32_t arg=0;uint64_t data=0;
    if(f.opcode==XY_RESIDENT_INFO) {
        assert(f.data==0);
        if(f.arg==0) {arg=(uint32_t)p->valid_mask<<8;data=p->active_slot;}
        else {assert(f.arg<=4);unsigned n=f.arg-1u;if(p->valid_mask&(1u<<n)) {arg=256;data=((uint64_t)p->slot_token[n]<<32)|p->slot_crc[n];}}
    } else if(f.opcode==XY_RESIDENT_CLEAR) {
        assert(f.arg<4 && !f.data);p->clears++;p->valid_mask&=(uint8_t)~(1u<<f.arg);
        if(p->active_slot==f.arg+1u)p->active_slot=0;
    } else if(f.opcode==XY_INFO) {
        assert(!f.arg && !f.data);p->info_reads++;
        uint8_t slot=p->change_info && p->info_reads==2?2:p->info_slot;
        arg=256u|(2u<<9)|(1u<<18);data=0x12345678u|((uint64_t)1<<32)|((uint64_t)1<<42)|((uint64_t)120<<52)|((uint64_t)slot<<60);
    } else if(f.opcode==XY_TITLE_READ) {
        assert(f.arg<3 && f.data==0x12345678u);data=f.arg?0:'A';
    } else {
        switch(f.opcode) {
        case XY_BEGIN:p->token=(uint32_t)(f.data>>32);p->crc=(uint32_t)f.data;p->progress=0;p->staged_slot=0;p->store_only=false;break;
        case XY_META:if(!f.arg) {p->meta_header=f.data;p->staged_slot=(f.data>>57)&7u;p->store_only=((f.data>>60)&1u)!=0;assert(!(f.data>>61));}break;
        case XY_DATA:assert(f.arg==p->progress);p->progress++;break;
        case XY_VERIFY:assert(p->progress==2 && f.data==p->token);break;
        case XY_COMMIT:
            assert(f.data==p->token);
            if(p->busy)arg=XY_BUSY;
            else {
                p->commits++;
                if(p->staged_slot) {unsigned n=p->staged_slot-1u;p->valid_mask|=(uint8_t)(1u<<n);p->slot_crc[n]=p->crc;p->slot_token[n]=p->token;}
                if(!p->store_only)p->active_slot=p->staged_slot;
            }
            break;
        case XY_ABORT:p->aborts++;p->progress=0;break;
        default:assert(0);
        }
        arg|=(uint32_t)p->progress<<8;data=p->token;
    }
    if(p->invalid_replies) {p->invalid_replies--;arg|=1u<<31;}
    xy_frame_encode(reply,(uint8_t)(f.opcode|0x80u),f.sequence,arg,data);return true;
}
static int load(void *context,uint8_t slot,char title[XY_SCORE_TITLE_BYTES],uint8_t out[XY_MAX_SCORE_BYTES],size_t *length) {
    peer *p=context;p->loads++;
    if(slot==p->missing_slot)return XY_RESIDENT_MISSING;
    if(slot==p->bad_slot)return p->bad_error;
    memcpy(title,"Saved title",12);memcpy(out,score_file,24);*length=24;return XY_OK;
}
static void timeout(void *context,unsigned ms) {
    peer *p=context;p->timeout_ms=ms;if(p->timeout_count<16)p->timeouts[p->timeout_count++]=ms;
}
static void init(peer *p,xy_link *link) {
    memset(p,0,sizeof(*p));p->missing_slot=p->bad_slot=-1;p->bad_error=1234;
    xy_link_init(link,exchange,p,65534);
}
static int round_sync(peer *p,xy_link *link,xy_resident_sync *sync,uint32_t token) {
    uint8_t buffer[XY_MAX_SCORE_BYTES];return xy_resident_sync_round(sync,link,buffer,load,timeout,p,token);
}
static void test_sender(void) {
    peer p;xy_link link;init(&p,&link);xy_score score;xy_score_metadata m;
    assert(xy_score_validate(score_file,24,&score)==XY_FILE_OK);
    assert(xy_metadata_from_utf8("A",2,9,&m));
    assert(!m.resident_slot && !m.store_only);
    const uint64_t legacy=0x12345678u|((uint64_t)1<<32)|((uint64_t)2<<37)|((uint64_t)9<<47);
    for(unsigned slot=0;slot<=4;slot++) {
        m.resident_slot=(uint8_t)slot;m.store_only=false;
        assert(xy_stage_score_named(&link,&score,0x12345678u,&m)==XY_OK);
        assert(p.meta_header==(legacy|((uint64_t)slot<<57)));
        assert(xy_commit_score(&link)==XY_OK && p.active_slot==slot);
        if(slot) {
            m.store_only=true;p.active_slot=0;
            assert(xy_stage_score_named(&link,&score,0x12345678u,&m)==XY_OK);
            assert(p.meta_header==(legacy|((uint64_t)slot<<57)|((uint64_t)1<<60)));
            assert(xy_commit_score(&link)==XY_OK && !p.active_slot);
        }
    }
    unsigned calls=p.calls;m.resident_slot=0;m.store_only=true;
    assert(xy_stage_score_named(&link,&score,1,&m)==XY_BAD_ARGUMENT);
    m.resident_slot=5;m.store_only=false;
    assert(xy_stage_score_named(&link,&score,1,&m)==XY_BAD_ARGUMENT && p.calls==calls);
    const char *capture=getenv("XY_RESIDENT_CAPTURE");
    if(capture) {
        FILE *file=fopen(capture,"wb");assert(file);
        fprintf(file,"{\n  \"title_gb2312_hex\":\"41\",\"part\":2,\"total\":9,\"bpm\":120,\"token\":305419896,\"event_crc32\":%lu,\n  \"frames_hex\":[\n",(unsigned long)score.event_crc32);
        for(unsigned n=0;n<p.captured_count;n++) {
            fprintf(file,"    \"");for(unsigned j=0;j<XY_FRAME_BYTES;j++)fprintf(file,"%02x",p.captured[n][j]);
            fprintf(file,"\"%s\n",n+1u==p.captured_count?"":",");
        }
        fprintf(file,"  ]\n}\n");assert(fclose(file)==0);
    }
    puts("PASS sender: legacy zero extension, slots1..4, STORE_ONLY, invalid metadata");
}
static void test_reply_validation(void) {
    xy_frame r={.opcode=XY_RESIDENT_INFO|128,.sequence=8,.arg=15u<<8,.data=4};
    assert(xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,0));
    r.arg=1u<<8;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,0));
    r.data=0;r.arg=1u<<12;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,0));
    r.arg=0;r.data=5;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,0));
    r.data=256;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,0));
    r.arg=256;r.data=0;assert(xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,4));
    r.arg=512;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,4));
    r.arg=0;r.data=1;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,4));
    r.arg=XY_BUSY;r.data=0;assert(xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,4));
    r.data=1;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_INFO,8,4));
    r.opcode=XY_RESIDENT_CLEAR|128;r.data=0;r.arg=0;
    assert(xy_extension_reply_matches(&r,XY_RESIDENT_CLEAR,8,3));
    assert(!xy_extension_reply_matches(&r,XY_RESIDENT_CLEAR,9,3));
    r.arg=256;assert(!xy_extension_reply_matches(&r,XY_RESIDENT_CLEAR,8,3));
    r.opcode=XY_INFO|128;r.arg=0;r.data=(uint64_t)4<<60;
    assert(xy_extension_reply_matches(&r,XY_INFO,8,0));
    r.data=(uint64_t)5<<60;assert(!xy_extension_reply_matches(&r,XY_INFO,8,0));
    r.data=(uint64_t)1<<63;assert(!xy_extension_reply_matches(&r,XY_INFO,8,0));
    peer p;xy_link link;init(&p,&link);p.valid_mask=15;p.active_slot=4;
    p.slot_crc[3]=0x76543210u;p.slot_token[3]=0xabcdef98u;
    xy_resident_summary summary;p.invalid_replies=2;
    assert(xy_read_resident_summary(&link,&summary)==XY_OK && summary.valid_mask==15 && summary.active_slot==4);
    assert(p.calls==3 && link.sequence==65535 && !memcmp(p.captured[0],p.captured[1],20) && !memcmp(p.captured[1],p.captured[2],20));
    xy_resident_score score;assert(xy_read_resident_score(&link,3,&score)==XY_OK);
    assert(score.valid && score.event_crc32==0x76543210u && score.token==0xabcdef98u && link.sequence==0);
    assert(xy_clear_resident_score(&link,3)==XY_OK && !p.active_slot && p.valid_mask==7);
    assert(xy_read_resident_score(&link,3,&score)==XY_OK && !score.valid && !score.token && !score.event_crc32);
    unsigned calls=p.calls;assert(xy_read_resident_score(&link,4,&score)==XY_BAD_ARGUMENT && p.calls==calls);
    p.offline=true;memset(&summary,255,sizeof(summary));
    assert(xy_read_resident_summary_once(&link,&summary)==XY_LINK_TIMEOUT && p.calls==calls+1 && !summary.valid_mask);
    xy_active_score active;init(&p,&link);p.info_slot=4;
    assert(xy_read_active_score(&link,&active)==XY_OK && active.resident_slot==4 && active.title[0]=='A');
    p.change_info=true;p.info_reads=0;
    assert(xy_read_active_score(&link,&active)==XY_LINK_CHANGED && !active.active && !active.resident_slot);
    puts("PASS query: reserved bits, masks, error formats, retries, sequence wrap, CRC/token, coherent INFO");
}
static void test_sync(void) {
    peer p;xy_link link;xy_resident_sync sync;init(&p,&link);xy_resident_sync_init(&sync);
    assert(sync.dirty_mask==15 && !sync.synchronized_mask);
    for(unsigned n=0;n<4;n++) {
        unsigned before=p.commits;assert(round_sync(&p,&link,&sync,100+n)==XY_OK);
        assert(p.commits==before+1 && !p.active_slot && p.staged_slot==n+1 && p.store_only && !link.staging);
        assert(p.timeout_ms==500);
    }
    assert(p.valid_mask==15 && sync.synchronized_mask==15 && !sync.dirty_mask && p.loads==4);
    unsigned calls=p.calls;assert(round_sync(&p,&link,&sync,200)==XY_OK && p.calls==calls+1 && p.loads==4);
    /* Simulated FPGA reset clears resident RAM; next four rounds restore all. */
    p.valid_mask=0;
    for(unsigned n=0;n<4;n++)assert(round_sync(&p,&link,&sync,300+n)==XY_OK);
    assert(p.valid_mask==15 && sync.synchronized_mask==15 && p.commits==8);
    /* Manual BUSY staging cannot be overwritten, queried, or aborted. */
    link.staging=true;link.verified=true;link.token=42;calls=p.calls;
    assert(round_sync(&p,&link,&sync,400)==XY_BUSY && p.calls==calls && link.token==42 && link.verified);
    link.staging=link.verified=false;
    /* Active-slot cache BUSY is aborted privately and retried in a later round. */
    xy_resident_sync_dirty(&sync,2);p.busy=true;p.active_slot=3;
    assert(round_sync(&p,&link,&sync,401)==XY_BUSY && sync.dirty_mask==4 && !link.staging && !link.verified && p.aborts==1);
    assert(sync.error==XY_BUSY && p.active_slot==3 && p.timeout_ms==500);
    p.busy=false;assert(round_sync(&p,&link,&sync,402)==XY_OK && !sync.dirty_mask);
    /* Delete clears mapping, and the active score itself belongs to the peer. */
    p.missing_slot=2;xy_resident_sync_dirty(&sync,2);
    assert(round_sync(&p,&link,&sync,403)==XY_OK && !p.active_slot && p.valid_mask==11 && p.clears==1 && sync.synchronized_mask==11);
    unsigned loads=p.loads;calls=p.calls;p.offline=true;
    assert(round_sync(&p,&link,&sync,404)==XY_LINK_TIMEOUT && p.calls==calls+1 && p.loads==loads && !sync.synchronized_mask && sync.dirty_mask==11);
    p.offline=false;p.bad_slot=sync.cursor;
    assert(round_sync(&p,&link,&sync,405)==1234 && (sync.dirty_mask&(1u<<p.bad_slot)) && sync.error==1234 && !link.staging);
    p.bad_slot=-1;
    for(unsigned n=0;n<4;n++)assert(round_sync(&p,&link,&sync,500+n)==XY_OK);
    assert(!sync.dirty_mask && sync.synchronized_mask==11);
    /* Generic ESP_FAIL (-1) must not be mistaken for an empty NVS slot. */
    xy_resident_sync_dirty(&sync,0);p.bad_slot=0;p.bad_error=-1;unsigned clears=p.clears;
    assert(round_sync(&p,&link,&sync,600)==-1 && p.clears==clears && (sync.dirty_mask&1));
    p.bad_slot=-1;p.upload_offline=true;calls=p.calls;
    assert(round_sync(&p,&link,&sync,601)==XY_LINK_TIMEOUT && p.calls==calls+7 &&
        !link.staging && !link.verified && (sync.dirty_mask&1) && p.timeout_ms==500);
    for(unsigned n=p.captured_count-3;n<p.captured_count;n++)assert(p.captured[n][3]==XY_ABORT);
    p.upload_offline=false;assert(round_sync(&p,&link,&sync,602)==XY_OK && !sync.dirty_mask);
    puts("PASS restore: four slots, one/round, no activation, reset, manual staging, BUSY abort, deletion, offline single probe, storage retry");
}
int main(void) {test_sender();test_reply_validation();test_sync();return 0;}
