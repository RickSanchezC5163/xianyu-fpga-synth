/**
 * @file score_transfer.h
 * @brief 上传状态机接口。同一 xy_link 不可并发使用；所有 API 由应用层互斥调用。返回值 0..6 为 FPGA 状态，256/257 为本地超时/进度异常。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#ifndef XIANYU_SCORE_TRANSFER_H
#define XIANYU_SCORE_TRANSFER_H
#include "score_protocol.h"

/* 回调成功应返回一帧完整候选 ACK；硬件适配层负责字节流重同步。 */
typedef bool (*xy_exchange_fn)(void *context, const uint8_t request[XY_FRAME_BYTES],
                               uint8_t response[XY_FRAME_BYTES]);
enum { XY_LINK_TIMEOUT=256, XY_LINK_PROGRESS=257, XY_LINK_CHANGED=258 };
typedef struct {
    uint8_t title[XY_META_TITLE_BYTES],title_len;
    uint16_t part,total;
    uint8_t resident_slot; /* 0: temporary/legacy; 1..4: resident slot. */
    bool store_only; /* Cache without changing the active score. Requires a slot. */
} xy_score_metadata;
typedef struct {
    bool active;
    uint16_t count,part,total;
    uint8_t bpm,title_len,title[XY_META_TITLE_BYTES];
    uint32_t token;
    uint8_t resident_slot;
} xy_active_score;

typedef struct { uint8_t valid_mask,active_slot; } xy_resident_summary;
typedef struct { bool valid; uint32_t event_crc32,token; } xy_resident_score;
typedef struct {
    xy_exchange_fn exchange;
    void *context;
    uint16_t sequence; /* 下一个请求序号；uint16 自然回卷。 */
    uint32_t token; /* 一首曲谱下载事务的非零随机标识。 */
    uint16_t next_index;
    bool staging;
    bool verified; /* 只有 VERIFY 成功且进度一致才置位。 */
} xy_link;
/** 初始化协议会话及可注入的交换函数；同一 link 只允许一个调用方持锁操作。 */
void xy_link_init(xy_link *link, xy_exchange_fn exchange, void *context, uint16_t sequence);
/** 将整首曲谱下载到 FPGA 非活动银行并校验 CRC。每个 DATA 都核对下一事件下标，防止表面 ACK 正常却漏写或乱序。 */
int xy_stage_score(xy_link *link, const xy_score *score, uint32_t token);
/** Atomically stage a named score, requiring BEGIN bit31 metadata. */
int xy_stage_score_named(xy_link *link,const xy_score *score,uint32_t token,const xy_score_metadata *metadata);
/** Read actual active source/title. Failure leaves no trusted snapshot. */
int xy_read_active_score(xy_link *link,xy_active_score *out);
/** Strict matching for custom extension replies, shared with the UART filter. */
bool xy_extension_reply_matches(const xy_frame *reply,uint8_t opcode,uint16_t sequence,uint32_t arg);
int xy_read_resident_summary(xy_link *link,xy_resident_summary *out);
/** Single attempt for short background liveness polling; timeout is owned by the exchange callback. */
int xy_read_resident_summary_once(xy_link *link,xy_resident_summary *out);
/** Resident detail uses visible storage index 0..3 (wire argument 1..4). */
int xy_read_resident_score(xy_link *link,uint8_t slot,xy_resident_score *out);
int xy_clear_resident_score(xy_link *link,uint8_t slot);
/** 提交已验证银行；只有成功回执且事件计数吻合才清除暂存标志。BUSY 保留暂存并消耗已回复的序号，超时保持原序号用于相同帧重试。 */
int xy_commit_score(xy_link *link);
/** 尝试放弃暂存事务；使用新序号避开前一成功请求缓存。即使 ABORT 失败也清除本地暂存标志；它不能撤销已经成功切换的活动谱。 */
int xy_abort_score(xy_link *link);
#endif
