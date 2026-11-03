/**
 * @file native_smoke.c
 * @brief 可在 32/64 位主机运行的纯 C 协议冒烟测试，不访问 ESP 或 FPGA。
 * 仅验证编解码、文件/记录校验以及重试/BUSY 状态处理，不模拟板级电气。
 */
#include "score_protocol.h"
#include "score_record.h"
#include "score_transfer.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned calls;
static bool busy;
static bool lose_first;
static uint32_t token=0x12345678u;
static uint16_t progress;
static uint8_t first_request[XY_FRAME_BYTES];

/* 简化对端只为驱动发送端分支；不作为 FPGA 实现正确性的证据。 */
static bool exchange(void *context,const uint8_t request[XY_FRAME_BYTES],uint8_t reply[XY_FRAME_BYTES]) {
    (void)context;
    xy_frame f;
    assert(xy_frame_decode(request,&f));
    calls++;
    if(lose_first && calls==1) {
        memcpy(first_request,request,XY_FRAME_BYTES);
        return false;
    }
    if(lose_first && calls==2)assert(memcmp(first_request,request,XY_FRAME_BYTES)==0);
    uint8_t status=XY_OK;
    switch(f.opcode) {
        case XY_BEGIN: progress=0;token=(uint32_t)(f.data>>32);break;
        case XY_DATA: progress=(uint16_t)(f.arg+1);break;
        case XY_COMMIT: if(busy)status=XY_BUSY;break;
        default: break;
    }
    xy_frame_encode(reply,(uint8_t)(f.opcode|0x80),f.sequence,
        (uint32_t)status|((uint32_t)progress<<8),token);
    return true;
}

int main(void) {
    /* 标准 CRC 检查值，不依赖本工程编码器生成预期结果。 */
    const uint8_t check[]="123456789";
    assert(xy_crc16(check,9)==0x4b37u);
    assert(xy_crc32(check,9)==0xcbf43926u);
    uint8_t frame[20];xy_frame f;
    xy_frame_encode(frame,XY_BEGIN,0xabcd,0x12345678u,0x0123456789abcdefULL);
    assert(frame[0]==0xc7 && frame[1]==0x3a && frame[4]==0xcd && frame[5]==0xab);
    assert(xy_frame_decode(frame,&f) && f.data==0x0123456789abcdefULL);
    frame[10]^=1;assert(!xy_frame_decode(frame,&f));

    /* 两事件曲谱：tick0 按第一键，tick96 释放；总长 24 字节。 */
    uint8_t raw[24]={'X','S','0','1',2,0,120,48,0,0,0,0,1,0,0,0,96,0,0,0,0,0,0,0};
    xy_score score;
    assert(xy_score_validate(raw,sizeof(raw),&score)==XY_FILE_OK);
    assert(score.count==2 && score.events==raw+8);
    assert(xy_score_validate(raw,23,&score)==XY_FILE_SIZE);
    raw[23]=0x80;assert(xy_score_validate(raw,24,&score)==XY_FILE_RESERVED);raw[23]=0;
    raw[20]=1;assert(xy_score_validate(raw,24,&score)==XY_FILE_FINAL_MASK);raw[20]=0;
    raw[16]=0;assert(xy_score_validate(raw,24,&score)==XY_FILE_ORDER);raw[16]=96;
    assert(xy_score_validate(raw,24,&score)==XY_FILE_OK);

    uint8_t record[XY_MAX_RECORD_BYTES],copy[XY_MAX_SCORE_BYTES];
    char title[XY_SCORE_TITLE_BYTES];size_t length=0,copy_length=0;
    assert(xy_record_encode("demo",raw,24,record,sizeof(record),&length)==XY_RECORD_OK);
    assert(xy_record_decode(record,length,title,sizeof(title),copy,sizeof(copy),&copy_length)==XY_RECORD_OK);
    assert(copy_length==24 && strcmp(title,"demo")==0 && memcmp(raw,copy,24)==0);
    record[length-1]^=1;
    assert(xy_record_decode(record,length,title,sizeof(title),copy,sizeof(copy),&copy_length)==XY_RECORD_CRC);

    xy_link link;
    xy_link_init(&link,exchange,NULL,0xffff);
    lose_first=true;
    assert(xy_stage_score(&link,&score,token)==XY_OK);
    assert(link.verified && link.staging && link.next_index==2 && calls==5);
    busy=true;uint16_t sequence=link.sequence;
    assert(xy_commit_score(&link)==XY_BUSY);
    assert(link.verified && link.staging && link.sequence==(uint16_t)(sequence+1));
    busy=false;
    assert(xy_commit_score(&link)==XY_OK && !link.staging && !link.verified);
    puts("PASS: CRC vectors, frame corruption, XS01 boundaries, XL01 CRC, identical retry, sequence wrap, BUSY and COMMIT");
    return 0;
}
