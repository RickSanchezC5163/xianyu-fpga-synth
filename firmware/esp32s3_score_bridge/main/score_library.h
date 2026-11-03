/**
 * @file score_library.h
 * @brief 八槽位持久曲库接口。调用初始化前必须成功初始化 NVS；读取时区分空槽、损坏与其他存储错误。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#ifndef XIANYU_SCORE_LIBRARY_H
#define XIANYU_SCORE_LIBRARY_H

#include "esp_err.h"
#include "score_record.h"

#define XY_LIBRARY_SLOTS 8u

/** 建立互斥锁并检查八个自有键；仅当全部缺失时写入演示谱，遇到损坏或错误类型的现存键也不覆盖。 */
esp_err_t xy_library_init(void);
/** 先在堆中编码完整 XL01 记录，再用单个 NVS blob 和一次 commit 持久化，避免曲名和正文分开更新。每个错误分支释放资源。 */
esp_err_t xy_library_save(uint8_t slot, const char *title, const uint8_t *score, size_t length);
/** 先查询 blob 大小并限制分配，再读取和解码；缺失返回 NOT_FOUND，类型错误或损坏返回 INVALID_CRC，禁止把损坏记录当有效文件。 */
esp_err_t xy_library_load(uint8_t slot, char title[XY_SCORE_TITLE_BYTES],
    uint8_t score[XY_MAX_SCORE_BYTES], size_t *length);
/** 删除指定槽位的单个键并提交，不擦除整个分区。 */
esp_err_t xy_library_delete(uint8_t slot);

#endif
