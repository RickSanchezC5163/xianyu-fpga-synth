/**
 * @file score_transfer.c
 * @brief 纯 C 曲谱上传事务状态机，采用可注入交换函数隔离硬件。不会自动播放；提交只负责切换 FPGA 曲谱银行。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#include "score_transfer.h"
#include <string.h>

/**
 * 初始化协议会话及可注入的交换函数；同一 link 只允许一个调用方持锁操作。
 */
void xy_link_init(xy_link *link, xy_exchange_fn exchange, void *context, uint16_t sequence) {
    memset(link,0,sizeof(*link));
    link->exchange=exchange; link->context=context; link->sequence=sequence;
}
/**
 * 一问一答事务，最多三次尝试。每次重发使用完全相同的帧和序号，便于 FPGA 对丢失 ACK 的重传去重；只有合法 ACK 才推进序号。
 */
static int transact(xy_link *link, uint8_t opcode, uint32_t arg, uint64_t data) {
    uint8_t request[XY_FRAME_BYTES], raw[XY_FRAME_BYTES];
    xy_frame reply;
    xy_frame_encode(request,opcode,link->sequence,arg,data);

    /* 500ms 等待由交换回调实现；本层最多调用三次。 */
    for(unsigned attempt=0;attempt<3;attempt++) {
        if(link->exchange(link->context,request,raw) && xy_frame_decode(raw,&reply) &&
           xy_reply_matches(&reply,opcode,link->sequence,link->token)) {
            link->sequence++;
            link->next_index=xy_reply_next_index(&reply);
            return xy_reply_status(&reply);
        }
    }
    return XY_LINK_TIMEOUT;
}
/**
 * 将整首曲谱下载到 FPGA 非活动银行并校验 CRC。每个 DATA 都核对下一事件下标，防止表面 ACK 正常却漏写或乱序。
 */
static int stage_score(xy_link *link,const xy_score *score,uint32_t token,const xy_score_metadata *metadata) {
    if(!link || !link->exchange || !score || !score->events || !token ||
       score->count<2 || score->count>XY_MAX_EVENTS || score->bpm<30 || score->bpm>240 ||
       score->base_note>103) return XY_BAD_ARGUMENT;
    if(metadata && (!xy_gb_title_valid(metadata->title,metadata->title_len) ||
       metadata->part<1 || metadata->total<metadata->part || metadata->total>999 ||
       metadata->resident_slot>XY_RESIDENT_SLOTS || (metadata->store_only && !metadata->resident_slot)))return XY_BAD_ARGUMENT;
    /* token 标识整次上传；sequence 区分该次上传内的每个请求。 */
    link->token=token; link->staging=true; link->verified=false; link->next_index=0;
    /* BEGIN：arg=count16|BPM8|base7；data=token32|事件区CRC32。 */
    uint32_t arg=(uint32_t)score->count | ((uint32_t)score->bpm<<16) | ((uint32_t)score->base_note<<24);
    if(metadata)arg|=0x80000000u;
    int result=transact(link,XY_BEGIN,arg,((uint64_t)token<<32)|score->event_crc32);
    if(result!=XY_OK) return result;
    if(link->next_index!=0) return XY_LINK_PROGRESS;
    if(metadata) {
        uint64_t header=token|((uint64_t)metadata->title_len<<32)|
            ((uint64_t)metadata->part<<37)|((uint64_t)metadata->total<<47)|
            ((uint64_t)metadata->resident_slot<<57)|((uint64_t)metadata->store_only<<60);
        result=transact(link,XY_META,0,header);
        if(result!=XY_OK)return result;
        if(link->next_index!=0)return XY_LINK_PROGRESS;
        for(unsigned word=0;word<(metadata->title_len+7u)/8u;word++) {
            uint64_t data=0;
            for(unsigned b=0;b<8;b++) {
                size_t index=word*8u+b;
                if(index<metadata->title_len)data|=(uint64_t)metadata->title[index]<<(b*8u);
            }
            result=transact(link,XY_META,word+1u,data);
            if(result!=XY_OK)return result;
            if(link->next_index!=0)return XY_LINK_PROGRESS;
        }
    }
    for(uint16_t n=0;n<score->count;n++) {
        result=transact(link,XY_DATA,n,xy_read_u64le(score->events+(size_t)n*8u));
        if(result!=XY_OK) return result;
        if(link->next_index!=n+1u) return XY_LINK_PROGRESS;
    }
    /* VERIFY 成功才允许 COMMIT；此时活动银行仍未改变。 */
    result=transact(link,XY_VERIFY,0,token);
    if(result!=XY_OK) return result;
    if(link->next_index!=score->count) return XY_LINK_PROGRESS;
    link->verified=true;
    return XY_OK;
}
/**
 * 提交已验证银行；只有成功回执且事件计数吻合才清除暂存标志。BUSY 保留暂存并消耗已回复的序号，超时保持原序号用于相同帧重试。
 */
int xy_commit_score(xy_link *link) {
    if(!link || !link->exchange || !link->staging || !link->verified) return XY_BAD_STATE;
    uint16_t count=link->next_index;
    int result=transact(link,XY_COMMIT,0,link->token);
    if(result==XY_OK) {
        if(link->next_index!=count) return XY_LINK_PROGRESS;
        link->staging=false; link->verified=false;
    }

    return result;
}
/**
 * 尝试放弃暂存事务；使用新序号避开前一成功请求缓存。即使 ABORT 失败也清除本地暂存标志；它不能撤销已经成功切换的活动谱。
 */
int xy_abort_score(xy_link *link) {
    if(!link || !link->exchange || !link->staging) return XY_BAD_STATE;

    link->sequence++;
    int result=transact(link,XY_ABORT,0,link->token);
    link->staging=false; link->verified=false;
    return result;
}

int xy_stage_score(xy_link *link,const xy_score *score,uint32_t token) {
    return stage_score(link,score,token,NULL);
}
int xy_stage_score_named(xy_link *link,const xy_score *score,uint32_t token,const xy_score_metadata *metadata) {
    if(!metadata)return XY_BAD_ARGUMENT;
    return stage_score(link,score,token,metadata);
}
/* Custom replies contain their own data layout, not transaction-token ACKs. */
bool xy_extension_reply_matches(const xy_frame *reply,uint8_t opcode,uint16_t sequence,uint32_t arg) {
    if(!reply || reply->opcode!=(uint8_t)(opcode|0x80u) || reply->sequence!=sequence ||
       xy_reply_status(reply)>XY_BUSY)return false;
    if(opcode==XY_INFO)return !(reply->arg>>23) && !(reply->data>>63) && ((reply->data>>60)&7u)<=XY_RESIDENT_SLOTS;
    if(opcode==XY_TITLE_READ)return !(reply->arg>>8);
    if(opcode!=XY_RESIDENT_INFO && opcode!=XY_RESIDENT_CLEAR)return false;
    if(xy_reply_status(reply)!=XY_OK)return !(reply->arg>>8) && !reply->data;
    if(opcode==XY_RESIDENT_CLEAR)return arg<XY_RESIDENT_SLOTS && !(reply->arg>>8) && !reply->data;
    if(arg==0) {
        uint8_t active=(uint8_t)reply->data;
        uint8_t mask=(uint8_t)(reply->arg>>8);
        return !(reply->arg>>12) && reply->data<=XY_RESIDENT_SLOTS &&
            (!active || (mask&(1u<<(active-1u))));
    }
    return arg<=XY_RESIDENT_SLOTS && !(reply->arg>>9) && ((reply->arg&256u) || !reply->data);
}
static int read_request(xy_link *link,uint8_t opcode,uint32_t arg,uint64_t data,xy_frame *out,unsigned attempts) {
    uint8_t request[XY_FRAME_BYTES],raw[XY_FRAME_BYTES];
    xy_frame_encode(request,opcode,link->sequence,arg,data);
    for(unsigned n=0;n<attempts;n++) {
        xy_frame reply;
        if(!link->exchange(link->context,request,raw) || !xy_frame_decode(raw,&reply) ||
           !xy_extension_reply_matches(&reply,opcode,link->sequence,arg))continue;
        link->sequence++;
        if(xy_reply_status(&reply)!=XY_OK)return xy_reply_status(&reply);
        *out=reply;return XY_OK;
    }
    return XY_LINK_TIMEOUT;
}
int xy_read_active_score(xy_link *link,xy_active_score *out) {
    if(!link || !link->exchange || !out)return XY_BAD_ARGUMENT;
    memset(out,0,sizeof(*out));
    xy_frame a,b,word;
    int result=read_request(link,XY_INFO,0,0,&a,3);
    if(result!=XY_OK)return result;
    xy_active_score value={0};
    value.active=(a.arg>>8)&1u;value.count=(a.arg>>9)&0x1ffu;
    value.title_len=(a.arg>>18)&31u;value.token=(uint32_t)a.data;
    value.part=(a.data>>32)&1023u;value.total=(a.data>>42)&1023u;
    value.bpm=(a.data>>52)&255u;
    value.resident_slot=(a.data>>60)&7u;
    if(!value.active) {
        if(a.arg || a.data)return XY_LINK_PROGRESS;
    } else {
        if(value.count<2 || value.count>256 || value.bpm<30 || value.bpm>240 || !value.token ||
           value.title_len>XY_META_TITLE_BYTES ||
           (value.title_len && (value.part<1 || value.part>value.total || value.total>999)) ||
           (!value.title_len && (value.part || value.total)))return XY_LINK_PROGRESS;
        for(unsigned n=0;n<3;n++) {
            result=read_request(link,XY_TITLE_READ,n,value.token,&word,3);
            if(result!=XY_OK)return result;
            for(unsigned j=0;j<8;j++)value.title[n*8u+j]=(uint8_t)(word.data>>(8*j));
        }
        if(value.title_len && !xy_gb_title_valid(value.title,value.title_len))return XY_LINK_PROGRESS;
        for(unsigned n=value.title_len;n<XY_META_TITLE_BYTES;n++)if(value.title[n])return XY_LINK_PROGRESS;
    }
    result=read_request(link,XY_INFO,0,0,&b,3);
    if(result!=XY_OK)return result;
    if(a.arg!=b.arg || a.data!=b.data)return XY_LINK_CHANGED;
    *out=value;return XY_OK;
}

static int read_resident_summary(xy_link *link,xy_resident_summary *out,unsigned attempts) {
    if(!link || !link->exchange || !out)return XY_BAD_ARGUMENT;
    memset(out,0,sizeof(*out));
    xy_frame reply;int result=read_request(link,XY_RESIDENT_INFO,0,0,&reply,attempts);
    if(result==XY_OK) {out->valid_mask=(reply.arg>>8)&15u;out->active_slot=(uint8_t)reply.data;}
    return result;
}
int xy_read_resident_summary(xy_link *link,xy_resident_summary *out) {
    return read_resident_summary(link,out,3);
}
int xy_read_resident_summary_once(xy_link *link,xy_resident_summary *out) {
    return read_resident_summary(link,out,1);
}
int xy_read_resident_score(xy_link *link,uint8_t slot,xy_resident_score *out) {
    if(!link || !link->exchange || !out || slot>=XY_RESIDENT_SLOTS)return XY_BAD_ARGUMENT;
    memset(out,0,sizeof(*out));
    xy_frame reply;int result=read_request(link,XY_RESIDENT_INFO,slot+1u,0,&reply,3);
    if(result==XY_OK) {out->valid=(reply.arg&256u)!=0;out->event_crc32=(uint32_t)reply.data;out->token=(uint32_t)(reply.data>>32);}
    return result;
}
int xy_clear_resident_score(xy_link *link,uint8_t slot) {
    if(!link || !link->exchange || slot>=XY_RESIDENT_SLOTS)return XY_BAD_ARGUMENT;
    xy_frame reply;return read_request(link,XY_RESIDENT_CLEAR,slot,0,&reply,3);
}
