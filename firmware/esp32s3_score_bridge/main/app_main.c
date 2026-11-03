/**
 * @file app_main.c
 * @brief 应用入口与 HTTP 路由。ESP 只管理符号曲谱；FPGA 负责实时声音、节拍和灯光。所有上传相关处理共享同一互斥锁和固定长度缓冲区。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */

#include "score_transfer.h"
#include "score_library.h"
#include "score_metadata.h"
#include "score_resident_sync.h"
#include "xy_network.h"
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"
#include "driver/uart.h"
#include "driver/gpio.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#if !CONFIG_IDF_TARGET_ESP32S3
#error "This project requires ESP32-S3"
#endif
#if ESP_IDF_VERSION != ESP_IDF_VERSION_VAL(6, 1, 0)
#error "This project requires ESP-IDF 6.1.0 (official tag v6.1)"
#endif

/* HTTP and background sync access shared state only with upload_mutex held. */
static SemaphoreHandle_t upload_mutex;
static xy_link score_link;
static xy_resident_sync resident_sync;
static unsigned uart_timeout_us=500000; /* Changed only while holding upload_mutex. */
static uint8_t upload_buffer[XY_MAX_SCORE_BYTES];
static bool ever_ack;
static int64_t last_ack_ms;
static int selected_slot=-1,pending_slot=-1;
static bool pending_library_unchanged;
extern const char index_start[] asm("_binary_web_index_html_start");
extern const char index_end[] asm("_binary_web_index_html_end");
extern const char js_start[] asm("_binary_web_app_js_start");
extern const char js_end[] asm("_binary_web_app_js_end");
extern const char catalog_start[] asm("_binary_score_catalog_json_start");
extern const char catalog_end[] asm("_binary_score_catalog_json_end");
extern const uint8_t ui_start[] asm("_binary_web_ui_html_gz_start");
extern const uint8_t ui_end[] asm("_binary_web_ui_html_gz_end");

/* 只读曲库直接来自Flash，ESP不解析/复制整份目录到堆中。
 * 浏览器选出一个XS01后，复用原有/score或/library校验及上传接口。 */
static esp_err_t catalog_handler(httpd_req_t *req) {
    httpd_resp_set_type(req,"application/json; charset=utf-8");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,catalog_start,catalog_end-catalog_start-1);
}

/**
 * 发送一帧请求并在 500ms 内搜索有效 ACK。滑动窗口可跨越噪声、截断帧和错位字节；只接受匹配操作码、序号及事务 token 的回执。串口写成功本身不代表 FPGA 已接受。
 */
static bool uart_exchange(void *context,const uint8_t request[XY_FRAME_BYTES],uint8_t response[XY_FRAME_BYTES]) {
    (void)context;
    if(uart_write_bytes(UART_NUM_1,request,XY_FRAME_BYTES)!=(int)XY_FRAME_BYTES ||
       uart_wait_tx_done(UART_NUM_1,pdMS_TO_TICKS(100))!=ESP_OK) return false;
    /* 不直接按每 20 字节分组：任何一个丢字节都可能破坏后续所有分组。 */
    uint8_t window[XY_FRAME_BYTES];size_t used=0;
    int64_t deadline=esp_timer_get_time()+uart_timeout_us;
    xy_frame expected;
    if(!xy_frame_decode(request,&expected)) return false;
    while(esp_timer_get_time()<deadline) {
        uint8_t byte;
        if(uart_read_bytes(UART_NUM_1,&byte,1,pdMS_TO_TICKS(20))!=1) continue;
        if(used<XY_FRAME_BYTES) window[used++]=byte;
        else {memmove(window,window+1,XY_FRAME_BYTES-1);window[XY_FRAME_BYTES-1]=byte;}
        xy_frame candidate;
        if(used==XY_FRAME_BYTES && xy_frame_decode(window,&candidate)) {
            uint32_t token=expected.opcode==XY_STATUS?(uint32_t)candidate.data:score_link.token;
            bool extension=xy_extension_reply_matches(&candidate,expected.opcode,expected.sequence,expected.arg);
            if(extension || xy_reply_matches(&candidate,expected.opcode,expected.sequence,token)) {
                memcpy(response,window,XY_FRAME_BYTES);
                ever_ack=true;last_ack_ms=esp_timer_get_time()/1000;
                return true;
            }
        }
    }
    return false;
}
/**
 * 发送 UTF-8 文本结果，并禁止浏览器缓存操作结果。
 */
static esp_err_t message(httpd_req_t *req,const char *status,const char *text) {
    httpd_resp_set_status(req,status);httpd_resp_set_type(req,"text/plain; charset=utf-8");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,text,HTTPD_RESP_USE_STRLEN);
}
/**
 * 拒绝含未读取正文的请求并关闭连接，避免残留正文被误当作下一条 HTTP 请求。
 */
static esp_err_t reject_body(httpd_req_t *req,const char *status,const char *text) {
    httpd_resp_set_hdr(req,"Connection","close");(void)message(req,status,text);return ESP_FAIL;
}
/**
 * 序列化并释放 JSON 对象；发送完成后释放字符串，所有权在此结束。
 */
static esp_err_t json_response(httpd_req_t *req,cJSON *json) {
    if(!json)return message(req,"500 Internal Server Error","内存不足。");
    char *body=cJSON_PrintUnformatted(json);cJSON_Delete(json);
    if(!body)return message(req,"500 Internal Server Error","内存不足。");
    httpd_resp_set_type(req,"application/json; charset=utf-8");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t result=httpd_resp_send(req,body,HTTPD_RESP_USE_STRLEN);free(body);return result;
}
/**
 * 从 URL 查询参数中读取单字符槽位 0..3；拒绝负数、多位数和缺失参数。
 */
static bool query_slot(httpd_req_t *req,uint8_t *slot,char *query,size_t capacity) {
    if(httpd_req_get_url_query_str(req,query,capacity)!=ESP_OK)return false;
    char raw[4];
    if(httpd_query_key_value(query,"slot",raw,sizeof(raw))!=ESP_OK ||
       raw[0]<'0' || raw[0]>'3' || raw[1])return false;
    *slot=(uint8_t)(raw[0]-'0');return true;
}
/**
 * 把 URL 百分号编码中的十六进制字符转换成数值；非法字符返回 -1。
 */
static int hex_value(char c) {
    if(c>='0' && c<='9')return c-'0';
    if(c>='a' && c<='f')return c-'a'+10;
    if(c>='A' && c<='F')return c-'A'+10;
    return -1;
}
/**
 * 解码曲名的百分号转义及加号空格；按 UTF-8 字节限制长度并拒绝 NUL。完整 UTF-8 校验交给记录编码器。
 */
static bool title_from_query(const char *query,char out[XY_SCORE_TITLE_BYTES]) {
    char encoded[160];
    if(httpd_query_key_value(query,"title",encoded,sizeof(encoded))!=ESP_OK)return false;
    size_t count=0;
    for(size_t i=0;encoded[i];i++) {
        unsigned char byte=(unsigned char)encoded[i];
        if(byte=='%') {
            if(!encoded[i+1] || !encoded[i+2])return false;
            int a=hex_value(encoded[i+1]),b=hex_value(encoded[i+2]);if(a<0 || b<0)return false;
            byte=(unsigned char)(a*16+b);i+=2;
        } else if(byte=='+')byte=' ';
        if(!byte || count>=XY_SCORE_TITLE_BYTES-1)return false;
        out[count++]=(char)byte;
    }
    out[count]=0;return count>0;
}
/* Optional metadata is checked before receiving/transmitting a score. */
static bool query_number(const char *query,const char *key,uint16_t *out) {
    char raw[5];esp_err_t err=httpd_query_key_value(query,key,raw,sizeof(raw));
    if(err==ESP_ERR_NOT_FOUND)return true;
    if(err!=ESP_OK || !raw[0])return false;
    unsigned value=0;
    for(size_t i=0;raw[i];i++) {if(raw[i]<'0' || raw[i]>'9')return false;value=value*10u+(unsigned)(raw[i]-'0');}
    if(value<1 || value>999)return false;
    *out=(uint16_t)value;return true;
}
static bool score_metadata_query(httpd_req_t *req,const char *fallback,xy_score_metadata *metadata,bool *present) {
    char query[256]={0},title[XY_SCORE_TITLE_BYTES];uint16_t part=1,total=1;
    size_t length=httpd_req_get_url_query_len(req);
    if(length>=sizeof(query) || (length && httpd_req_get_url_query_str(req,query,sizeof(query))!=ESP_OK))return false;
    char probe[2];esp_err_t found=httpd_query_key_value(query,"title",probe,sizeof(probe));
    bool has_title=found!=ESP_ERR_NOT_FOUND;
    if(has_title) {if(!title_from_query(query,title))return false;}
    else if(fallback) {size_t n=strlen(fallback);if(!n || n>=sizeof(title))return false;memcpy(title,fallback,n+1);}
    *present=has_title || fallback;
    if(!has_title && fallback) {
        xy_score_metadata stored;
        if(!xy_metadata_from_storage_title(fallback,&stored))return false;
        /* A saved catalog part keeps its original part/total and display name
         * unless the caller explicitly supplies new metadata query fields. */
        char number[5];
        if(httpd_query_key_value(query,"part",number,sizeof(number))==ESP_ERR_NOT_FOUND &&
           httpd_query_key_value(query,"total",number,sizeof(number))==ESP_ERR_NOT_FOUND) {
            *metadata=stored;return true;
        }
    }
    if(!query_number(query,"part",&part) || !query_number(query,"total",&total) || part>total)return false;
    if(!*present && (part!=1 || total!=1))return false;
    return !*present || xy_metadata_from_utf8(title,part,total,metadata);
}
/**
 * 循环接收完整二进制正文到共享缓冲区；调用前必须检查长度并取得上传互斥锁。半包失败时不能向 FPGA 发送任何数据。
 */
static bool receive_score(httpd_req_t *req) {
    size_t done=0;
    while(done<req->content_len) {
        int count=httpd_req_recv(req,(char *)upload_buffer+done,req->content_len-done);
        if(count<=0)return false;
        done+=(size_t)count;
    }
    return true;
}
/**
 * 返回编译时嵌入固件的中文网页；不依赖 SD 卡、文件系统或外网 CDN。
 */
static esp_err_t home_handler(httpd_req_t *req) {
    httpd_resp_set_type(req,"text/html; charset=utf-8");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    httpd_resp_set_hdr(req,"Content-Encoding","gzip");
    return httpd_resp_send(req,(const char *)ui_start,ui_end-ui_start);
}
/* Retain the tested small legacy frontend as a fallback during UI migration. */
static esp_err_t legacy_handler(httpd_req_t *req) {
    httpd_resp_set_type(req,"text/html; charset=utf-8");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,index_start,index_end-index_start-1);
}
/**
 * 返回编译时嵌入的网页脚本；EMBED_TXTFILES 末尾的 NUL 不发送给浏览器。
 */
static esp_err_t js_handler(httpd_req_t *req) {
    httpd_resp_set_type(req,"application/javascript; charset=utf-8");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,js_start,js_end-js_start-1);
}
/**
 * 读取 ESP 会话状态；最近 ACK 仅表示历史通信成功，不能把 selected_slot 当作 FPGA 实时回读。重启后选择记录为未知。
 */
static esp_err_t status_handler(httpd_req_t *req) {
    if(xSemaphoreTake(upload_mutex,pdMS_TO_TICKS(3000))!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    cJSON *root=cJSON_CreateObject();
    if(root) {
        cJSON_AddStringToObject(root,"target",CONFIG_IDF_TARGET);
        cJSON_AddStringToObject(root,"idf_version",esp_get_idf_version());
        cJSON_AddNumberToObject(root,"internal_free_heap",heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
        cJSON_AddNumberToObject(root,"psram_total",heap_caps_get_total_size(MALLOC_CAP_SPIRAM));
        cJSON_AddBoolToObject(root,"fpga_ack_seen",ever_ack);
        if(ever_ack)cJSON_AddNumberToObject(root,"ack_age_ms",(double)(esp_timer_get_time()/1000-last_ack_ms));
        cJSON_AddNumberToObject(root,"selected_slot",selected_slot);
        cJSON_AddNumberToObject(root,"pending_slot",pending_slot);
        cJSON_AddBoolToObject(root,"pending_verified",score_link.verified);
        cJSON_AddNumberToObject(root,"resident_sync_mask",resident_sync.synchronized_mask);
        cJSON_AddNumberToObject(root,"resident_sync_error",resident_sync.error);
        cJSON_AddNumberToObject(root,"max_events",XY_MAX_EVENTS);
        cJSON_AddNumberToObject(root,"free_heap",esp_get_free_heap_size());
    }
    xSemaphoreGive(upload_mutex);return json_response(req,root);
}
/**
 * 执行只读 STATUS 探测，最多重试三次；不开始引导、不修改音量，也不隐式上传曲谱。
 */
static esp_err_t probe_handler(httpd_req_t *req) {
    if(req->content_len)return reject_body(req,"400 Bad Request","状态查询不接受正文。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    uint8_t request[XY_FRAME_BYTES],reply[XY_FRAME_BYTES];xy_frame decoded;
    xy_frame_encode(request,XY_STATUS,score_link.sequence,0,0);bool received=false;
    for(unsigned n=0;n<3 && !received;n++)received=uart_exchange(NULL,request,reply);
    bool ok=received && xy_frame_decode(reply,&decoded) && xy_reply_status(&decoded)==XY_OK;
    if(received)score_link.sequence++;
    xSemaphoreGive(upload_mutex);
    return message(req,ok?"200 OK":"502 Bad Gateway",ok?"收到FPGA状态回执；未启动曲谱或改变音量。":"没有有效FPGA状态回执；ESP联网不代表FPGA上传接口已启用。");
}
/* Actual active FPGA source, independently read back, never inferred from NVS. */
static esp_err_t fpga_handler(httpd_req_t *req) {
    if(req->content_len)return reject_body(req,"400 Bad Request","状态查询不接受正文。");
    if(xSemaphoreTake(upload_mutex,pdMS_TO_TICKS(3000))!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    xy_active_score active;int result=xy_read_active_score(&score_link,&active);
    cJSON *root=cJSON_CreateObject();
    if(root) {
        cJSON_AddBoolToObject(root,"confirmed",result==XY_OK);
        cJSON_AddNumberToObject(root,"result",result);
        cJSON_AddStringToObject(root,"source",result!=XY_OK?"unknown":active.active?"wifi_ram":"rom");
        if(result==XY_OK) {
            char title[73]={0};
            if(active.active && active.title_len) (void)xy_metadata_title_utf8(active.title,active.title_len,title,sizeof(title));
            cJSON_AddStringToObject(root,"title",!active.active?"内置练习":active.title_len?title:"未命名Wi-Fi曲谱");
            cJSON_AddNumberToObject(root,"part",active.part);cJSON_AddNumberToObject(root,"total",active.total);
            cJSON_AddNumberToObject(root,"events",active.count);cJSON_AddNumberToObject(root,"bpm",active.bpm);
            cJSON_AddNumberToObject(root,"token",active.token);
            cJSON_AddNumberToObject(root,"resident_slot",active.resident_slot);
        }
    }
    xSemaphoreGive(upload_mutex);return json_response(req,root);
}
/**
 * 请求 FPGA 切换已校验的暂存谱。BUSY 时保留待提交状态；无确认时明确报告结果未知，因为丢失 ACK 不能证明切换未发生。
 */
static esp_err_t finish_commit(httpd_req_t *req) {
    int result=xy_commit_score(&score_link);
    /* FPGA 播放/暂停引导时都可能 BUSY，应从屏幕停止后再次提交。 */
    if(result==XY_BUSY)return message(req,"409 Conflict","FPGA引导仍在运行。已验证暂存谱保留；停止引导后重试提交。");
    if(result==XY_OK) {
        if(pending_slot>=0 && pending_library_unchanged)
            xy_resident_sync_complete(&resident_sync,(uint8_t)pending_slot,true);
        selected_slot=pending_slot;pending_slot=-1;
        return message(req,"200 OK","FPGA已确认提交曲谱。未自动开始引导或改变音量。");
    }
    /* COMMIT 的 ACK 丢失时，ABORT 不能撤销已经发生的银行切换。 */
    (void)xy_abort_score(&score_link);pending_slot=-1;selected_slot=-1;
    return message(req,"502 Bad Gateway","提交未获确认，已尝试终止暂存。若确认丢失，活动谱可能已切换；请查询设备。");
}
/**
 * 校验 XS01 文件，生成非零随机事务 token，依次执行 BEGIN / DATA / VERIFY，全部确认后才请求 COMMIT。
 */
static esp_err_t transfer_score(httpd_req_t *req,const uint8_t *bytes,size_t length,int slot,const xy_score_metadata *metadata) {
    xy_score parsed;
    if(xy_score_validate(bytes,length,&parsed)!=XY_FILE_OK)return message(req,"400 Bad Request","曲谱格式无效。");
    if(score_link.staging)(void)xy_abort_score(&score_link);
    uint32_t token;do {token=esp_random();}while(!token);
    pending_slot=slot;pending_library_unchanged=true;
    int result=metadata?xy_stage_score_named(&score_link,&parsed,token,metadata):xy_stage_score(&score_link,&parsed,token);
    if(result==XY_OK)return finish_commit(req);
    (void)xy_abort_score(&score_link);pending_slot=-1;
    return message(req,"502 Bad Gateway","FPGA未确认下载或校验，未请求切换活动谱。ESP曲库文件仍保留；请检查上传器及UART。");
}
/**
 * 允许用户在停止 FPGA 引导后重新提交已校验的暂存谱，不必重复发送全部事件。
 */
static esp_err_t commit_handler(httpd_req_t *req) {
    if(req->content_len)return reject_body(req,"400 Bad Request","提交不接受正文。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    esp_err_t result=score_link.verified?finish_commit(req):message(req,"409 Conflict","没有已验证的待提交曲谱。");
    xSemaphoreGive(upload_mutex);return result;
}
/**
 * 处理只发送不保存的 XS01 文件；长度、完整接收和文件语义均通过后才进入 UART 事务。
 */
static esp_err_t score_handler(httpd_req_t *req) {
    xy_score_metadata metadata;bool named=false;
    if(!score_metadata_query(req,NULL,&metadata,&named))return reject_body(req,"400 Bad Request","曲名或片段参数无效；曲名1..48字节，片段1..999且不超过总数。");
    if(req->content_len<24 || req->content_len>XY_MAX_SCORE_BYTES)return reject_body(req,"413 Content Too Large","仅接受24..2056字节XS01符号谱，不接受MIDI或录音。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return reject_body(req,"409 Conflict","传输正在进行。");
    if(!receive_score(req)) {xSemaphoreGive(upload_mutex);return reject_body(req,"408 Request Timeout","文件未完整收到，没有开始上传。");}
    esp_err_t result=transfer_score(req,upload_buffer,req->content_len,-1,named?&metadata:NULL);
    xSemaphoreGive(upload_mutex);return result;
}
/**
 * Expose four resident slots. Legacy NVS keys 4..7 remain untouched.
 */
static esp_err_t library_handler(httpd_req_t *req) {
    if(xSemaphoreTake(upload_mutex,pdMS_TO_TICKS(3000))!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    cJSON *root=cJSON_CreateObject();
    cJSON *slots=root?cJSON_AddArrayToObject(root,"slots"):NULL;
    if(!slots) {cJSON_Delete(root);xSemaphoreGive(upload_mutex);return message(req,"500 Internal Server Error","内存不足。");}
    for(uint8_t n=0;n<XY_RESIDENT_SLOTS;n++) {
        char title[XY_SCORE_TITLE_BYTES];size_t length=0;xy_score parsed;
        esp_err_t err=xy_library_load(n,title,upload_buffer,&length);
        cJSON *item=cJSON_CreateObject();if(!item)continue;
        cJSON_AddNumberToObject(item,"slot",n);
        bool valid=err==ESP_OK && xy_score_validate(upload_buffer,length,&parsed)==XY_FILE_OK;
        cJSON_AddBoolToObject(item,"valid",valid);cJSON_AddBoolToObject(item,"empty",err==ESP_ERR_NOT_FOUND);
        cJSON_AddBoolToObject(item,"synchronized",(resident_sync.dirty_mask&(1u<<n))==0 &&
            (!valid || (resident_sync.synchronized_mask&(1u<<n))!=0));
        if(valid) {
            cJSON_AddStringToObject(item,"title",title);cJSON_AddNumberToObject(item,"events",parsed.count);
            cJSON_AddNumberToObject(item,"bpm",parsed.bpm);cJSON_AddNumberToObject(item,"base_note",parsed.base_note);
        } else if(err!=ESP_ERR_NOT_FOUND)cJSON_AddStringToObject(item,"error",esp_err_to_name(err));
        cJSON_AddItemToArray(slots,item);
    }
    xSemaphoreGive(upload_mutex);return json_response(req,root);
}
/**
 * Save persistently, then let the background service cache without activation.
 */
static esp_err_t library_save_handler(httpd_req_t *req) {
    uint8_t slot;char query[256],title[XY_SCORE_TITLE_BYTES];
    if(!query_slot(req,&slot,query,sizeof(query)) || !title_from_query(query,title))return reject_body(req,"400 Bad Request","需要slot0..3和1..48字节曲名。");
    if(req->content_len<24 || req->content_len>XY_MAX_SCORE_BYTES)return reject_body(req,"413 Content Too Large","仅接受24..2056字节XS01文件。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return reject_body(req,"409 Conflict","传输正在进行。");
    if(!receive_score(req)) {xSemaphoreGive(upload_mutex);return reject_body(req,"408 Request Timeout","文件未完整收到，未保存。");}
    esp_err_t err=xy_library_save(slot,title,upload_buffer,req->content_len);
    if(err==ESP_OK) {
        xy_resident_sync_dirty(&resident_sync,slot);
        if(score_link.staging && pending_slot==slot)pending_library_unchanged=false;
    }
    xSemaphoreGive(upload_mutex);
    return message(req,err==ESP_OK?"200 OK":err==ESP_ERR_INVALID_ARG?"400 Bad Request":"500 Internal Server Error",
        err==ESP_OK?"已保存到ESP曲库，断电保留。后台将同步到FPGA，不自动播放。":"未保存；检查曲名、XS01格式或ESP存储状态。");
}
/**
 * 读取并复核已保存曲目，然后发送给 FPGA；曲库不存在或损坏时不开始传输。
 */
static esp_err_t select_handler(httpd_req_t *req) {
    uint8_t slot;char query[256];
    if(req->content_len || !query_slot(req,&slot,query,sizeof(query)))return reject_body(req,"400 Bad Request","需要slot0..3，正文为空。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    char title[XY_SCORE_TITLE_BYTES];size_t length=0;
    esp_err_t err=xy_library_load(slot,title,upload_buffer,&length);
    xy_score_metadata metadata;bool named=false;
    esp_err_t result;
    if(err!=ESP_OK)result=message(req,"404 Not Found","曲目不存在或校验失败，未开始传输。");
    else if(!score_metadata_query(req,title,&metadata,&named))result=message(req,"400 Bad Request","曲名或片段参数无效，未开始传输。");
    else {
        metadata.resident_slot=slot+1u;metadata.store_only=false;
        result=transfer_score(req,upload_buffer,length,slot,&metadata);
    }
    xSemaphoreGive(upload_mutex);return result;
}
/**
 * Delete NVS now and queue resident-map removal; active FPGA playback remains.
 */
static esp_err_t delete_handler(httpd_req_t *req) {
    uint8_t slot;char query[64];
    if(req->content_len || !query_slot(req,&slot,query,sizeof(query)))return reject_body(req,"400 Bad Request","需要slot0..3，正文为空。");
    if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)return message(req,"409 Conflict","传输正在进行。");
    esp_err_t err=xy_library_delete(slot);
    if(err==ESP_OK || err==ESP_ERR_NOT_FOUND) {
        xy_resident_sync_dirty(&resident_sync,slot);
        if(score_link.staging && pending_slot==slot)pending_library_unchanged=false;
    }
    xSemaphoreGive(upload_mutex);
    return message(req,err==ESP_OK?"200 OK":err==ESP_ERR_NOT_FOUND?"404 Not Found":"500 Internal Server Error",
        err==ESP_OK?"已删除ESP曲库文件。FPGA活动谱不受影响。":"未删除该曲目。");
}
/* Same mutex order as HTTP: upload_mutex, then the library's NVS lock. */
static int resident_load(void *context,uint8_t slot,char title[XY_SCORE_TITLE_BYTES],
    uint8_t score[XY_MAX_SCORE_BYTES],size_t *length) {
    (void)context;esp_err_t result=xy_library_load(slot,title,score,length);
    return result==ESP_ERR_NOT_FOUND?XY_RESIDENT_MISSING:result;
}
static void resident_timeout(void *context,unsigned timeout_ms) {
    (void)context;uart_timeout_us=timeout_ms*1000u;
}
static void resident_sync_task(void *context) {
    (void)context;
    for(;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        if(xSemaphoreTake(upload_mutex,0)!=pdTRUE)continue;
        uint32_t token;do {token=esp_random();}while(!token);
        (void)xy_resident_sync_round(&resident_sync,&score_link,upload_buffer,
            resident_load,resident_timeout,NULL,token);
        xSemaphoreGive(upload_mutex);
    }
}
/**
 * 检查 N16R8 上应保留的 USB、存储器、绑带与调试串口引脚，避免 menuconfig 误配置占用关键硬件。
 */
static bool uart_gpio_reserved(int gpio) {
    return gpio==0 || gpio==3 || gpio==19 || gpio==20 ||
        (gpio>=26 && gpio<=37) || gpio==43 || gpio==44 || gpio==45 || gpio==46;
}
/**
 * 初始化独立 UART1：115200 / 8N1 / 无硬件流控，GPIO4/5 为默认候选。原生 USB 控制台与 FPGA 串口相互独立。
 */
static void start_uart(void) {
    const int tx=CONFIG_XY_UART_TX_GPIO,rx=CONFIG_XY_UART_RX_GPIO;
    if(tx==rx || !GPIO_IS_VALID_OUTPUT_GPIO(tx) || !GPIO_IS_VALID_GPIO(rx) ||
       uart_gpio_reserved(tx) || uart_gpio_reserved(rx)) {
        ESP_LOGE("score_bridge","UART GPIO configuration conflicts with N16R8 reserved pins");
        abort();
    }
    uart_config_t config={.baud_rate=115200,.data_bits=UART_DATA_8_BITS,.parity=UART_PARITY_DISABLE,
        .stop_bits=UART_STOP_BITS_1,.flow_ctrl=UART_HW_FLOWCTRL_DISABLE,.source_clk=UART_SCLK_DEFAULT};
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_1,2048,0,0,NULL,0));
    ESP_ERROR_CHECK(uart_param_config(UART_NUM_1,&config));
    /* IDF 6.1 显式给出 RTS、CTS、DTR、DSR；本协议四者均不使用。 */
    ESP_ERROR_CHECK(uart_set_pin(UART_NUM_1,CONFIG_XY_UART_TX_GPIO,CONFIG_XY_UART_RX_GPIO,
        UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE));
    xy_link_init(&score_link,uart_exchange,NULL,(uint16_t)esp_random());
}
/**
 * Start NVS, UART/network/HTTP, then restore resident cache without activation.
 */
void app_main(void) {
    /* 失败时保留全部数据，交给用户诊断；绝不调用 nvs_flash_erase() 自动恢复。 */
    ESP_ERROR_CHECK(nvs_flash_init());
    upload_mutex=xSemaphoreCreateMutex();if(!upload_mutex)abort();
    xy_resident_sync_init(&resident_sync);
    ESP_ERROR_CHECK(xy_library_init());start_uart();ESP_ERROR_CHECK(xy_network_start());
    httpd_config_t config=HTTPD_DEFAULT_CONFIG();
    /* lwIP 总额度为 8；HTTP 服务自身预留 3 个 socket。
     * 显式限制为 4 个客户端连接，合计 7，另留 1 个余量。
     * IDF 默认客户端连接上限为 7，直接沿用会因 7+3>8 启动失败。
     * 此处直接配置，已有 sdkconfig 无需重新生成或擦除 NVS。
     */
    config.max_open_sockets=4;
    config.lru_purge_enable=true;
    /* 单个 HTTP 服务任务串行处理路由，上传期间网页请求可能延后。 */
    config.stack_size=12288;config.recv_wait_timeout=5;config.send_wait_timeout=5;config.max_uri_handlers=20;
    httpd_handle_t server=NULL;ESP_ERROR_CHECK(httpd_start(&server,&config));
    const httpd_uri_t routes[]={
        {.uri="/",.method=HTTP_GET,.handler=home_handler},{.uri="/app.js",.method=HTTP_GET,.handler=js_handler},
        {.uri="/legacy",.method=HTTP_GET,.handler=legacy_handler},
        {.uri="/catalog.json",.method=HTTP_GET,.handler=catalog_handler},
        {.uri="/status",.method=HTTP_GET,.handler=status_handler},{.uri="/probe",.method=HTTP_POST,.handler=probe_handler},
        {.uri="/fpga",.method=HTTP_GET,.handler=fpga_handler},
        {.uri="/score",.method=HTTP_POST,.handler=score_handler},{.uri="/commit",.method=HTTP_POST,.handler=commit_handler},
        {.uri="/library",.method=HTTP_GET,.handler=library_handler},{.uri="/library",.method=HTTP_POST,.handler=library_save_handler},
        {.uri="/select",.method=HTTP_POST,.handler=select_handler},{.uri="/delete",.method=HTTP_POST,.handler=delete_handler}
    };
    for(unsigned n=0;n<sizeof(routes)/sizeof(routes[0]);n++)ESP_ERROR_CHECK(httpd_register_uri_handler(server,&routes[n]));
    ESP_ERROR_CHECK(xy_network_register(server));
    if(xTaskCreate(resident_sync_task,"resident_sync",4096,NULL,2,NULL)!=pdPASS)abort();
    ESP_LOGI("score_bridge","ESP32-S3 N16R8, IDF %s, UART1 TX=%d RX=%d, 115200 8N1",
        esp_get_idf_version(),CONFIG_XY_UART_TX_GPIO,CONFIG_XY_UART_RX_GPIO);
    ESP_LOGI("score_bridge","PSRAM total: %u bytes; FPGA ACK required for transfer success",
        (unsigned)heap_caps_get_total_size(MALLOC_CAP_SPIRAM));
}
