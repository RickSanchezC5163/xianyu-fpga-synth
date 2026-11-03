/**
 * @file score_record.c
 * @brief 纯 C 曲库存储记录编解码。XS01 是上传格式，XL01 是 ESP 本地带曲名和 CRC 的记录，两种格式不可混用。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#include "score_record.h"
#include <string.h>

/**
 * 读取记录中的小端 16 位长度。
 */
static uint16_t read16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1]<<8));
}
/**
 * 读取记录尾部的小端 CRC32。
 */
static uint32_t read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}

/**
 * 严格校验曲名 UTF-8 标量编码：拒绝过长编码、代理项、越界码点、NUL 以及 C0/C1 控制字符；上限 48 字节，不是 48 个汉字。
 */
static bool title_valid(const uint8_t *s, size_t length) {
    if(!s || length==0 || length>XY_SCORE_TITLE_MAX) return false;
    size_t i=0;
    while(i<length) {
        uint32_t cp=s[i++];
        unsigned rest=0;
        uint32_t minimum=0;
        if(cp<0x80u) {  }
        else if(cp>=0xc2u && cp<=0xdfu) { cp&=0x1fu; rest=1; minimum=0x80u; }
        else if(cp>=0xe0u && cp<=0xefu) { cp&=0x0fu; rest=2; minimum=0x800u; }
        else if(cp>=0xf0u && cp<=0xf4u) { cp&=0x07u; rest=3; minimum=0x10000u; }
        else return false;
        if(length-i<rest) return false;
        for(unsigned j=0;j<rest;j++) {
            uint8_t b=s[i++];
            if((b&0xc0u)!=0x80u) return false;
            cp=(cp<<6)|(b&0x3fu);
        }
        if(cp<minimum || cp>0x10ffffu || (cp>=0xd800u && cp<=0xdfffu) ||
           cp<0x20u || (cp>=0x7fu && cp<=0x9fu)) return false;
    }
    return true;
}

/**
 * 把曲名和已校验 XS01 打包成单个 XL01 记录；检查目标容量后写入，并对头部、曲名、曲谱统一计算 CRC。输入输出缓冲区不得重叠。
 */
enum xy_record_error xy_record_encode(const char *title, const uint8_t *score,
    size_t score_length, uint8_t *record, size_t capacity, size_t *record_length) {
    if(!title || !score || !record || !record_length) return XY_RECORD_ARGUMENT;
    size_t title_length=0;
    while(title_length<=XY_SCORE_TITLE_MAX && title[title_length]) title_length++;
    if(!title_valid((const uint8_t *)title,title_length)) return XY_RECORD_TITLE;
    xy_score parsed;
    if(xy_score_validate(score,score_length,&parsed)!=XY_FILE_OK) return XY_RECORD_SCORE;
    size_t length=XY_RECORD_HEADER_BYTES+title_length+score_length+4u;
    if(capacity<length) return XY_RECORD_CAPACITY;
    memcpy(record,"XL01",4);
    record[4]=(uint8_t)title_length; record[5]=0;
    record[6]=(uint8_t)score_length; record[7]=(uint8_t)(score_length>>8);
    memcpy(record+XY_RECORD_HEADER_BYTES,title,title_length);
    memcpy(record+XY_RECORD_HEADER_BYTES+title_length,score,score_length);
    uint32_t crc=xy_crc32(record,length-4u);
    for(unsigned i=0;i<4;i++) record[length-4u+i]=(uint8_t)(crc>>(8u*i));
    *record_length=length;
    return XY_RECORD_OK;
}

/**
 * 完整核对长度、魔数、保留位、CRC、UTF-8、XS01 及目标容量，全部通过才更新调用方的输出缓冲区。
 */
enum xy_record_error xy_record_decode(const uint8_t *record, size_t length,
    char *title, size_t title_capacity, uint8_t *score, size_t score_capacity,
    size_t *score_length) {
    if(!record || !title || !score || !score_length) return XY_RECORD_ARGUMENT;
    if(length<XY_RECORD_HEADER_BYTES+4u || length>XY_MAX_RECORD_BYTES) return XY_RECORD_SIZE;
    if(memcmp(record,"XL01",4)!=0) return XY_RECORD_MAGIC;
    size_t title_length=record[4], raw_length=read16(record+6);
    if(record[5]!=0 || !title_length || title_length>XY_SCORE_TITLE_MAX ||
       raw_length<24 || raw_length>XY_MAX_SCORE_BYTES ||
       length!=XY_RECORD_HEADER_BYTES+title_length+raw_length+4u) return XY_RECORD_SIZE;
    if(xy_crc32(record,length-4u)!=read32(record+length-4u)) return XY_RECORD_CRC;
    if(!title_valid(record+XY_RECORD_HEADER_BYTES,title_length)) return XY_RECORD_TITLE;
    const uint8_t *raw=record+XY_RECORD_HEADER_BYTES+title_length;
    xy_score parsed;
    if(xy_score_validate(raw,raw_length,&parsed)!=XY_FILE_OK) return XY_RECORD_SCORE;
    if(title_capacity<title_length+1u || score_capacity<raw_length) return XY_RECORD_CAPACITY;
    memcpy(title,record+XY_RECORD_HEADER_BYTES,title_length); title[title_length]='\0';
    memcpy(score,raw,raw_length); *score_length=raw_length;
    return XY_RECORD_OK;
}
