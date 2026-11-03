/**
 * @file score_protocol.c
 * @brief 纯 C 协议编解码与曲谱语义检查，可在 Linux 主机独立测试，不依赖 ESP-IDF。协议与 b5a3825 的 wifi_score_loader.v 完全一致。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#include "score_protocol.h"
#include <string.h>

/**
 * 按小端读取 16 位字段，避免结构体填充和对齐差异。
 */
static uint16_t read16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
/**
 * 按小端读取 32 位字段；先转为无符号类型再移位。
 */
static uint32_t read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
/**
 * 组合两个小端 32 位数，读取完整 64 位事件，不依赖主机端序。
 */
uint64_t xy_read_u64le(const uint8_t *p) {
    return (uint64_t)read32(p) | ((uint64_t)read32(p + 4) << 32);
}
/**
 * CRC16/MODBUS：初值 FFFF，多项式 A001，反射右移，无最终异或。UART 帧只对字节 2..17 计算。
 */
uint16_t xy_crc16(const uint8_t *bytes, size_t length) {
    uint16_t crc=0xffffu;
    for(size_t n=0;n<length;n++) {
        crc^=bytes[n];
        for(unsigned b=0;b<8;b++) crc=(uint16_t)((crc>>1)^((crc&1u)?0xa001u:0u));
    }
    return crc;
}
/**
 * 标准反射 CRC32：初值 FFFFFFFF，多项式 EDB88320，最终异或 FFFFFFFF，与 Python zlib.crc32 一致。
 */
uint32_t xy_crc32(const uint8_t *bytes, size_t length) {
    uint32_t crc=0xffffffffu;
    for(size_t n=0;n<length;n++) {
        crc^=bytes[n];
        for(unsigned b=0;b<8;b++) crc=(crc>>1)^((crc&1u)?0xedb88320u:0u);
    }
    return crc^0xffffffffu;
}
/**
 * 生成固定 20 字节帧：帧头、版本、操作码、序号、参数、载荷、CRC16；所有多字节字段低字节在先。
 */
void xy_frame_encode(uint8_t out[XY_FRAME_BYTES], uint8_t opcode,
                     uint16_t sequence, uint32_t arg, uint64_t data) {
    /* 字节 0..1 帧头不参与 CRC；2..17 的 16 字节参与 CRC16。 */
    out[0]=0xc7; out[1]=0x3a; out[2]=XY_PROTOCOL_VERSION; out[3]=opcode;
    out[4]=(uint8_t)sequence; out[5]=(uint8_t)(sequence>>8);
    for(unsigned n=0;n<4;n++) out[6+n]=(uint8_t)(arg>>(n*8));
    for(unsigned n=0;n<8;n++) out[10+n]=(uint8_t)(data>>(n*8));
    uint16_t crc=xy_crc16(out+2,16);
    out[18]=(uint8_t)crc; out[19]=(uint8_t)(crc>>8);
}
/**
 * 先核对帧头、版本和 CRC，再写输出字段；解析失败时不输出可供推进事务的字段。
 */
bool xy_frame_decode(const uint8_t raw[XY_FRAME_BYTES], xy_frame *out) {
    if(!raw || !out || raw[0]!=0xc7 || raw[1]!=0x3a || raw[2]!=XY_PROTOCOL_VERSION ||
       xy_crc16(raw+2,16)!=read16(raw+18)) return false;
    out->opcode=raw[3]; out->sequence=read16(raw+4); out->arg=read32(raw+6);
    out->data=xy_read_u64le(raw+10);
    return true;
}
/**
 * 读取 ACK 参数低八位状态码，取值 0..6。
 */
uint8_t xy_reply_status(const xy_frame *reply) { return (uint8_t)reply->arg; }
/**
 * 读取 ACK 参数第 8..23 位，表示 FPGA 下一个期望的事件下标，允许终点 256。
 */
uint16_t xy_reply_next_index(const xy_frame *reply) { return (uint16_t)(reply->arg>>8); }
/**
 * 过滤旧 ACK、其他事务 ACK、非法状态、越界进度和非零保留位；匹配成功仍不等于状态为 OK。
 */
bool xy_reply_matches(const xy_frame *reply, uint8_t opcode, uint16_t sequence, uint32_t token) {
    return reply && opcode>=XY_BEGIN && opcode<=XY_META &&
           reply->opcode==(uint8_t)(opcode|0x80u) && reply->sequence==sequence &&
           (reply->arg>>24)==0 && xy_reply_status(reply)<=XY_BUSY &&
           xy_reply_next_index(reply)<=XY_MAX_EVENTS && (reply->data>>32)==0 &&
           (uint32_t)reply->data==token;
}
/**
 * 校验 XS01 的长度、事件数、BPM、起始音符、保留位、时间顺序及终止空键状态；成功后输出事件数组的只读视图。调用方必须保持文件缓冲区有效。
 */
enum xy_file_error xy_score_validate(const uint8_t *file, size_t length, xy_score *out) {
    if(!file || !out || length<XY_SCORE_HEADER_BYTES || length>XY_MAX_SCORE_BYTES) return XY_FILE_SIZE;
    if(memcmp(file,"XS01",4)!=0) return XY_FILE_MAGIC;
    uint16_t count=read16(file+4);
    if(count<2 || count>XY_MAX_EVENTS) return XY_FILE_COUNT;
    if(length!=XY_SCORE_HEADER_BYTES+(size_t)count*8u) return XY_FILE_SIZE;
    if(file[6]<30 || file[6]>240) return XY_FILE_TEMPO;
    if(file[7]>103) return XY_FILE_BASE;
    /* tick 单位为 1/96 拍。事件表示完整键位状态，不能当 NOTE_ON 增量使用。 */
    uint32_t previous=0;
    uint64_t word=0;
    for(uint16_t n=0;n<count;n++) {
        word=xy_read_u64le(file+XY_SCORE_HEADER_BYTES+(size_t)n*8u);
        uint32_t tick=(uint32_t)word;
        /* 最高七位保留，当前 FPGA 仅支持 25 个键位。 */
        if(word>>57) return XY_FILE_RESERVED;
        if(n==0 && tick!=0) return XY_FILE_FIRST_TICK;
        if(n!=0 && tick<=previous) return XY_FILE_ORDER;
        previous=tick;
    }
    /* 最后一个事件必须释放全部键位，避免引导永久停在按键状态。 */
    if(((word>>32)&0x1ffffffu)!=0) return XY_FILE_FINAL_MASK;
    out->count=count; out->bpm=file[6]; out->base_note=file[7]; out->events=file+XY_SCORE_HEADER_BYTES;
    out->event_crc32=xy_crc32(out->events,(size_t)count*8u);
    return XY_FILE_OK;
}
/**
 * 把文件校验结果转换为诊断文字，越界枚举也返回可用说明。
 */
const char *xy_file_error_name(enum xy_file_error error) {
    static const char *const names[]={"ok","invalid byte length","bad XS01 magic","event count outside2..256",
        "BPM outside30..240","base note outside0..103","reserved event bits nonzero","first tick is not0",
        "ticks must strictly increase","final key mask must be0"};
    return (unsigned)error<sizeof(names)/sizeof(names[0])?names[error]:"unknown validation error";
}

bool xy_gb_title_valid(const uint8_t *title,size_t length) {
    if(!title || !length || length>XY_META_TITLE_BYTES)return false;
    for(size_t i=0;i<length;i++) {
        uint8_t b=title[i];
        if(b>=0x20u && b<=0x7eu) { if(b=='"' || b=='\\')return false; }
        else if(b>=0xa1u && b<=0xf7u) {
            if(++i>=length || title[i]<0xa1u || title[i]>0xfeu)return false;
        } else return false;
    }
    return true;
}
