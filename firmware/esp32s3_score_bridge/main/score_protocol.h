/**
 * @file score_protocol.h
 * @brief 公共协议类型和校验接口。帧固定 20 字节；事件低 32 位为 tick，第 32..56 位为 25 键完整状态，第 57..63 位保留为零。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#ifndef XIANYU_SCORE_PROTOCOL_H
#define XIANYU_SCORE_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XY_FRAME_BYTES 20u
#define XY_MAX_EVENTS 256u
#define XY_SCORE_HEADER_BYTES 8u
#define XY_MAX_SCORE_BYTES (XY_SCORE_HEADER_BYTES + XY_MAX_EVENTS * 8u)
#define XY_PROTOCOL_VERSION 1u
#define XY_META_TITLE_BYTES 24u
#define XY_RESIDENT_SLOTS 4u

enum xy_opcode { XY_BEGIN=1, XY_DATA=2, XY_VERIFY=3, XY_COMMIT=4, XY_ABORT=5, XY_STATUS=6, XY_META=7, XY_INFO=8, XY_TITLE_READ=9, XY_RESIDENT_INFO=10, XY_RESIDENT_CLEAR=11 };
enum xy_status { XY_OK=0, XY_BAD_FRAME=1, XY_BAD_STATE=2, XY_BAD_ARGUMENT=3, XY_ORDER=4, XY_CRC=5, XY_BUSY=6 };
enum xy_file_error { XY_FILE_OK=0, XY_FILE_SIZE, XY_FILE_MAGIC, XY_FILE_COUNT,
    XY_FILE_TEMPO, XY_FILE_BASE, XY_FILE_RESERVED, XY_FILE_FIRST_TICK,
    XY_FILE_ORDER, XY_FILE_FINAL_MASK };

typedef struct {
    uint8_t opcode;
    uint16_t sequence;
    uint32_t arg;
    uint64_t data;
} xy_frame;

/* events 指向调用方文件缓冲区，本结构不复制也不拥有这段内存。 */
typedef struct {
    uint16_t count;
    uint8_t bpm;
    uint8_t base_note;
    uint32_t event_crc32;
    const uint8_t *events;
} xy_score;

/** CRC16/MODBUS：初值 FFFF，多项式 A001，反射右移，无最终异或。UART 帧只对字节 2..17 计算。 */
uint16_t xy_crc16(const uint8_t *bytes, size_t length);
/** 标准反射 CRC32：初值 FFFFFFFF，多项式 EDB88320，最终异或 FFFFFFFF，与 Python zlib.crc32 一致。 */
uint32_t xy_crc32(const uint8_t *bytes, size_t length);
/** 组合两个小端 32 位数，读取完整 64 位事件，不依赖主机端序。 */
uint64_t xy_read_u64le(const uint8_t *bytes);
/** 生成固定 20 字节帧：帧头、版本、操作码、序号、参数、载荷、CRC16；所有多字节字段低字节在先。 */
void xy_frame_encode(uint8_t out[XY_FRAME_BYTES], uint8_t opcode,
                     uint16_t sequence, uint32_t arg, uint64_t data);
/** 先核对帧头、版本和 CRC，再写输出字段；解析失败时不输出可供推进事务的字段。 */
bool xy_frame_decode(const uint8_t raw[XY_FRAME_BYTES], xy_frame *out);
/** 过滤旧 ACK、其他事务 ACK、非法状态、越界进度和非零保留位；匹配成功仍不等于状态为 OK。 */
bool xy_reply_matches(const xy_frame *reply, uint8_t request_opcode,
                      uint16_t sequence, uint32_t token);
/** Safe complete GB2312 display text, excluding HMI delimiters. */
bool xy_gb_title_valid(const uint8_t *title,size_t length);
/** 读取 ACK 参数低八位状态码，取值 0..6。 */
uint8_t xy_reply_status(const xy_frame *reply);
/** 读取 ACK 参数第 8..23 位，表示 FPGA 下一个期望的事件下标，允许终点 256。 */
uint16_t xy_reply_next_index(const xy_frame *reply);
/** 校验 XS01 的长度、事件数、BPM、起始音符、保留位、时间顺序及终止空键状态；成功后输出事件数组的只读视图。调用方必须保持文件缓冲区有效。 */
enum xy_file_error xy_score_validate(const uint8_t *file, size_t length, xy_score *out);
/** 把文件校验结果转换为诊断文字，越界枚举也返回可用说明。 */
const char *xy_file_error_name(enum xy_file_error error);

#endif
