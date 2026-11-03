/**
 * @file score_library.c
 * @brief ESP-IDF NVS 持久曲库适配层：八槽位、单记录提交、严格回读验证。互斥锁保护并发存储操作，初始化失败不会自动擦除用户数据。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#include "score_library.h"
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

static SemaphoreHandle_t library_mutex;
static bool initialized;
static const char *NAMESPACE="xy_scores";

/**
 * 将槽位 0..7 映射为本应用命名空间中的 s0..s7，不触及其他 NVS 键。
 */
static void key_name(uint8_t slot, char out[3]) {
    out[0]='s';out[1]=(char)('0'+slot);out[2]='\0';
}
/**
 * 检查槽位及初始化状态后获取曲库互斥锁，统一保护 NVS 操作。
 */
static esp_err_t lock_library(uint8_t slot) {
    if(slot>=XY_LIBRARY_SLOTS) return ESP_ERR_INVALID_ARG;
    if(!library_mutex) return ESP_ERR_INVALID_STATE;
    return xSemaphoreTake(library_mutex,portMAX_DELAY)==pdTRUE?ESP_OK:ESP_FAIL;
}
/**
 * 先在堆中编码完整 XL01 记录，再用单个 NVS blob 和一次 commit 持久化，避免曲名和正文分开更新。每个错误分支释放资源。
 */
esp_err_t xy_library_save(uint8_t slot,const char *title,const uint8_t *score,size_t length) {
    if(slot>=XY_LIBRARY_SLOTS) return ESP_ERR_INVALID_ARG;
    uint8_t *record=malloc(XY_MAX_RECORD_BYTES);
    if(!record) return ESP_ERR_NO_MEM;
    size_t record_length=0;
    if(xy_record_encode(title,score,length,record,XY_MAX_RECORD_BYTES,&record_length)!=XY_RECORD_OK) {
        free(record);return ESP_ERR_INVALID_ARG;
    }
    esp_err_t err=lock_library(slot);
    if(err!=ESP_OK) { free(record);return err; }
    nvs_handle_t handle;
    err=nvs_open(NAMESPACE,NVS_READWRITE,&handle);
    if(err==ESP_OK) {
        char key[3];key_name(slot,key);
        /* 单个 blob 包含头部、曲名、正文、CRC，避免分字段写入不一致。 */
        err=nvs_set_blob(handle,key,record,record_length);
        if(err==ESP_OK) err=nvs_commit(handle);
        nvs_close(handle);
    }
    xSemaphoreGive(library_mutex);free(record);
    return err;
}
/**
 * 先查询 blob 大小并限制分配，再读取和解码；缺失返回 NOT_FOUND，类型错误或损坏返回 INVALID_CRC，禁止把损坏记录当有效文件。
 */
esp_err_t xy_library_load(uint8_t slot,char title[XY_SCORE_TITLE_BYTES],
    uint8_t score[XY_MAX_SCORE_BYTES],size_t *length) {
    if(!title || !score || !length) return ESP_ERR_INVALID_ARG;
    esp_err_t err=lock_library(slot);
    if(err!=ESP_OK) return err;
    nvs_handle_t handle;
    err=nvs_open(NAMESPACE,NVS_READONLY,&handle);
    if(err==ESP_OK) {
        char key[3];key_name(slot,key);size_t size=0;
        err=nvs_get_blob(handle,key,NULL,&size);
        if(err==ESP_ERR_NVS_NOT_FOUND) err=ESP_ERR_NOT_FOUND;
        else if(err==ESP_ERR_NVS_TYPE_MISMATCH) err=ESP_ERR_INVALID_CRC;
        else if(err==ESP_OK) {
            if(size<XY_RECORD_HEADER_BYTES+4u || size>XY_MAX_RECORD_BYTES) err=ESP_ERR_INVALID_CRC;
            else {
                uint8_t *record=malloc(size);
                if(!record) err=ESP_ERR_NO_MEM;
                else {
                    err=nvs_get_blob(handle,key,record,&size);
                    if(err==ESP_OK && xy_record_decode(record,size,title,XY_SCORE_TITLE_BYTES,
                            score,XY_MAX_SCORE_BYTES,length)!=XY_RECORD_OK) err=ESP_ERR_INVALID_CRC;
                    free(record);
                }
            }
        }
        nvs_close(handle);
    } else if(err==ESP_ERR_NVS_NOT_FOUND) err=ESP_ERR_NOT_FOUND;
    xSemaphoreGive(library_mutex);
    return err;
}
/**
 * 删除指定槽位的单个键并提交，不擦除整个分区。
 */
esp_err_t xy_library_delete(uint8_t slot) {
    esp_err_t err=lock_library(slot);
    if(err!=ESP_OK) return err;
    nvs_handle_t handle;
    err=nvs_open(NAMESPACE,NVS_READWRITE,&handle);
    if(err==ESP_OK) {
        char key[3];key_name(slot,key);
        err=nvs_erase_key(handle,key);
        if(err==ESP_OK) err=nvs_commit(handle);
        else if(err==ESP_ERR_NVS_NOT_FOUND) err=ESP_ERR_NOT_FOUND;
        nvs_close(handle);
    }
    xSemaphoreGive(library_mutex);
    return err;
}

/**
 * 生成九个键位状态的内置八和弦练习，PPQN=96；末事件释放全部键位。仅作为曲谱引导数据，不生成音频。
 */
static esp_err_t seed_demo(void) {
    static const uint32_t masks[9]={0x91u,0x224u,0x890u,0x1220u,0x4880u,
        0x11200u,0x24880u,0x1091u,0};
    uint8_t raw[8+9*8]={'X','S','0','1',9,0,120,48};
    for(unsigned n=0;n<9;n++) {
        uint64_t word=(uint64_t)(n*96u)|((uint64_t)masks[n]<<32);
        for(unsigned b=0;b<8;b++) raw[8+n*8+b]=(uint8_t)(word>>(8u*b));
    }
    return xy_library_save(0,"八和弦练习",raw,sizeof(raw));
}
/**
 * 建立互斥锁并检查八个自有键；仅当全部缺失时写入演示谱，遇到损坏或错误类型的现存键也不覆盖。
 */
esp_err_t xy_library_init(void) {
    if(initialized) return ESP_OK;
    if(!library_mutex) library_mutex=xSemaphoreCreateMutex();
    if(!library_mutex) return ESP_ERR_NO_MEM;
    nvs_handle_t handle;
    esp_err_t err=nvs_open(NAMESPACE,NVS_READWRITE,&handle);
    if(err!=ESP_OK) return err;
    /* 即使现存键类型错误也视为存在，避免用演示文件覆盖用户记录。 */
    bool all_absent=true;
    for(uint8_t slot=0;slot<XY_LIBRARY_SLOTS;slot++) {
        char key[3];key_name(slot,key);size_t size=0;
        err=nvs_get_blob(handle,key,NULL,&size);
        if(err==ESP_OK || err==ESP_ERR_NVS_TYPE_MISMATCH) all_absent=false;
        else if(err!=ESP_ERR_NVS_NOT_FOUND) { nvs_close(handle);return err; }
    }
    nvs_close(handle);
    err=all_absent?seed_demo():ESP_OK;
    if(err==ESP_OK) initialized=true;
    return err;
}
