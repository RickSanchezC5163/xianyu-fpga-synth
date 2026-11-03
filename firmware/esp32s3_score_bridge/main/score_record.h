/**
 * @file score_record.h
 * @brief 本地 XL01 记录格式：8 字节头 + UTF-8 曲名 + XS01 正文 + 4 字节 CRC32。曲名最大 48 字节；输入输出不得重叠。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#ifndef XIANYU_SCORE_RECORD_H
#define XIANYU_SCORE_RECORD_H

#include "score_protocol.h"

#define XY_SCORE_TITLE_MAX 48u
#define XY_SCORE_TITLE_BYTES (XY_SCORE_TITLE_MAX + 1u)
#define XY_RECORD_HEADER_BYTES 8u
#define XY_MAX_RECORD_BYTES (XY_RECORD_HEADER_BYTES + XY_SCORE_TITLE_MAX + XY_MAX_SCORE_BYTES + 4u)

enum xy_record_error {
    XY_RECORD_OK=0, XY_RECORD_ARGUMENT, XY_RECORD_SIZE, XY_RECORD_MAGIC,
    XY_RECORD_TITLE, XY_RECORD_SCORE, XY_RECORD_CRC, XY_RECORD_CAPACITY
};

/** 把曲名和已校验 XS01 打包成单个 XL01 记录；检查目标容量后写入，并对头部、曲名、曲谱统一计算 CRC。输入输出缓冲区不得重叠。 */
enum xy_record_error xy_record_encode(const char *title, const uint8_t *score,
    size_t score_length, uint8_t *record, size_t capacity, size_t *record_length);
/** 完整核对长度、魔数、保留位、CRC、UTF-8、XS01 及目标容量，全部通过才更新调用方的输出缓冲区。 */
enum xy_record_error xy_record_decode(const uint8_t *record, size_t length,
    char *title, size_t title_capacity, uint8_t *score, size_t score_capacity,
    size_t *score_length);

#endif
