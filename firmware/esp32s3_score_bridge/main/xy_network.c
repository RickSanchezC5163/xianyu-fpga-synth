/**
 * @file xy_network.c
 * @brief ESP-IDF AP+STA 配网模块：保留设置热点、接入 2.4GHz 路由器、有限重连、单 blob 持久化凭据。网络不参与音频时基。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */

#include "xy_network.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "nvs.h"

#define XY_CREDENTIAL_VERSION 1u
#define XY_NETWORK_BODY_MAX 512u
#define XY_STATION_RETRIES 5u

static const char *TAG="xy_network";
static const char *NVS_NAMESPACE="xy_network";
static const char *NVS_KEY="credentials";

typedef struct {
    uint32_t version;
    uint8_t ssid_length;
    uint8_t password_length;
    uint16_t reserved;
    char ssid[33];
    char password[64];
} credentials_t;

typedef struct {
    bool configured;
    bool connected;
    bool connecting;
    bool reconnect;
    bool ignore_disconnect;
    unsigned retries;
    unsigned last_disconnect_reason;
    char ssid[33];
    char station_ip[16];
} network_state_t;

static portMUX_TYPE state_lock=portMUX_INITIALIZER_UNLOCKED;
static network_state_t state;
static esp_netif_t *ap_netif;
static esp_netif_t *sta_netif;
static bool started;

/**
 * 在短临界区内复制网络状态，HTTP 与 Wi-Fi 事件任务通过副本交换信息；临界区内不调用可能阻塞的 SDK 函数。
 */
static network_state_t snapshot(void) {
    network_state_t copy;
    portENTER_CRITICAL(&state_lock);
    copy=state;
    portEXIT_CRITICAL(&state_lock);
    return copy;
}

/**
 * 校验持久化凭据版本、保留位、SSID/密码字节长度及字符串终止符，拒绝损坏记录。
 */
static bool valid_credentials(const credentials_t *c) {
    if(c->version!=XY_CREDENTIAL_VERSION || c->reserved ||
       c->ssid_length<1 || c->ssid_length>32 ||
       (c->password_length!=0 && (c->password_length<8 || c->password_length>63))) return false;
    return c->ssid[c->ssid_length]=='\0' && c->password[c->password_length]=='\0' &&
        strlen(c->ssid)==c->ssid_length && strlen(c->password)==c->password_length;
}

/**
 * 从本应用单个 NVS blob 读取路由器凭据并复核结构版本；输出缓冲区先清零。
 */
static esp_err_t load_credentials(credentials_t *out) {
    nvs_handle_t handle;
    esp_err_t err=nvs_open(NVS_NAMESPACE,NVS_READONLY,&handle);
    if(err!=ESP_OK) return err;
    size_t size=sizeof(*out);
    memset(out,0,sizeof(*out));
    err=nvs_get_blob(handle,NVS_KEY,out,&size);
    nvs_close(handle);
    if(err!=ESP_OK) return err;
    return size==sizeof(*out) && valid_credentials(out)?ESP_OK:ESP_ERR_INVALID_STATE;
}

/**
 * 将 SSID 和密码作为一个 blob 保存并提交，避免两个键更新到不同版本。
 */
static esp_err_t save_credentials(const credentials_t *c) {
    nvs_handle_t handle;
    esp_err_t err=nvs_open(NVS_NAMESPACE,NVS_READWRITE,&handle);
    if(err!=ESP_OK) return err;
    err=nvs_set_blob(handle,NVS_KEY,c,sizeof(*c));
    if(err==ESP_OK) err=nvs_commit(handle);
    nvs_close(handle);
    return err;
}

/**
 * 仅删除本应用的路由器凭据键；不擦除曲库或整个 NVS 分区。
 */
static esp_err_t forget_credentials(void) {
    nvs_handle_t handle;
    esp_err_t err=nvs_open(NVS_NAMESPACE,NVS_READWRITE,&handle);
    if(err!=ESP_OK) return err;
    err=nvs_erase_key(handle,NVS_KEY);
    if(err==ESP_ERR_NVS_NOT_FOUND) err=ESP_OK;
    if(err==ESP_OK) err=nvs_commit(handle);
    nvs_close(handle);
    return err;
}

/**
 * 构建 STA 配置；显式空密码允许开放网络，否则认证最低为 WPA2。密码不写入日志或状态接口。
 */
static void station_config(const credentials_t *c,wifi_config_t *config) {
    memset(config,0,sizeof(*config));
    memcpy(config->sta.ssid,c->ssid,c->ssid_length);
    memcpy(config->sta.password,c->password,c->password_length);

    config->sta.threshold.authmode=c->password_length?WIFI_AUTH_WPA2_PSK:WIFI_AUTH_OPEN;
    /* IDF 自动协商 PMF 能力；不写已弃用的 capable 字段。 */
    config->sta.pmf_cfg.required=false;
}

/**
 * 连接请求失败时结束“正在连接”标志，设置热点保留，允许用户修正网络参数。
 */
static void record_connect_failure(void) {
    portENTER_CRITICAL(&state_lock);
    state.connecting=false;
    portEXIT_CRITICAL(&state_lock);
    ESP_LOGW(TAG,"Station connection request failed; setup AP remains available");
}

/**
 * 处理 STA 启动、断开、取得/丢失 IP；失败最多重连五次。主动更换凭据的断开事件不计入失败次数，忘记网络后的迟到 DHCP 事件不能恢复旧状态。
 */
static void network_event(void *arg,esp_event_base_t base,int32_t id,void *data) {
    (void)arg;
    if(base==WIFI_EVENT && id==WIFI_EVENT_STA_START) {
        network_state_t copy=snapshot();
        if(copy.configured && copy.reconnect && esp_wifi_connect()!=ESP_OK) record_connect_failure();
    } else if(base==WIFI_EVENT && id==WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event=data;
        bool retry=false;
        portENTER_CRITICAL(&state_lock);
        state.connected=false;
        state.station_ip[0]='\0';
        state.last_disconnect_reason=event->reason;
        if(state.ignore_disconnect) {
            state.ignore_disconnect=false;

            state.connecting=state.reconnect && state.configured;
            retry=state.connecting;
        } else if(state.reconnect && state.configured && state.retries<XY_STATION_RETRIES) {
            state.retries++;
            state.connecting=true;
            retry=true;
        } else {
            state.connecting=false;
        }
        portEXIT_CRITICAL(&state_lock);
        if(retry && esp_wifi_connect()!=ESP_OK) record_connect_failure();
    } else if(base==IP_EVENT && id==IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event=data;
        char address[16];
        snprintf(address,sizeof(address),IPSTR,IP2STR(&event->ip_info.ip));
        bool accepted;
        portENTER_CRITICAL(&state_lock);
        accepted=state.configured && state.reconnect;
        if(accepted) {
            state.connected=true;
            state.connecting=false;
            state.retries=0;
            state.ignore_disconnect=false;
            memcpy(state.station_ip,address,sizeof(address));
        } else {

            state.connected=false;
            state.connecting=false;
            state.station_ip[0]='\0';
        }
        portEXIT_CRITICAL(&state_lock);
        if(accepted) ESP_LOGI(TAG,"LAN ready; open http://%s/",address);
        else (void)esp_wifi_disconnect();
    } else if(base==IP_EVENT && id==IP_EVENT_STA_LOST_IP) {
        portENTER_CRITICAL(&state_lock);
        state.connected=false;
        state.station_ip[0]='\0';
        state.connecting=state.configured && state.reconnect;
        portEXIT_CRITICAL(&state_lock);
    }
}

/**
 * 禁用旧配置的重连后断开连接，再替换配置并发起新连接；请求成功只是开始连接，需等待 GOT_IP 才能报告联网成功。
 */
static esp_err_t apply_credentials(const credentials_t *c) {

    portENTER_CRITICAL(&state_lock);
    state.reconnect=false;
    state.ignore_disconnect=state.connected || state.connecting;
    state.connected=false;
    state.connecting=false;
    state.station_ip[0]='\0';
    portEXIT_CRITICAL(&state_lock);
    esp_err_t disconnect=esp_wifi_disconnect();
    if(disconnect!=ESP_OK) {
        portENTER_CRITICAL(&state_lock);
        state.ignore_disconnect=false;
        portEXIT_CRITICAL(&state_lock);
    }
    wifi_config_t config;
    station_config(c,&config);
    esp_err_t err=esp_wifi_set_config(WIFI_IF_STA,&config);
    memset(&config,0,sizeof(config));
    if(err!=ESP_OK) return err;
    portENTER_CRITICAL(&state_lock);
    state.configured=true;
    state.reconnect=true;
    state.connecting=true;
    state.retries=0;
    state.last_disconnect_reason=0;
    memcpy(state.ssid,c->ssid,sizeof(state.ssid));
    portEXIT_CRITICAL(&state_lock);
    err=esp_wifi_connect();
    if(err!=ESP_OK) record_connect_failure();
    return err;
}

/**
 * 返回配网操作的 UTF-8 文本状态，禁止缓存。
 */
static esp_err_t text_reply(httpd_req_t *req,const char *status,const char *message) {
    httpd_resp_set_status(req,status);
    httpd_resp_set_type(req,"text/plain; charset=utf-8");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,message,HTTPD_RESP_USE_STRLEN);
}

/**
 * 正文尚未消费完时关闭 HTTP 连接，避免下一个请求受到半包污染。
 */
static esp_err_t reject_unread(httpd_req_t *req,const char *status,const char *message) {
    httpd_resp_set_hdr(req,"Connection","close");
    (void)text_reply(req,status,message);
    return ESP_FAIL;
}

/**
 * 发送并释放配网 JSON 响应，JSON 对象和输出字符串都由本函数释放。
 */
static esp_err_t json_reply(httpd_req_t *req,const char *status,cJSON *object) {
    char *body=cJSON_PrintUnformatted(object);
    cJSON_Delete(object);
    if(!body) return text_reply(req,"500 Internal Server Error","内存不足。");
    httpd_resp_set_status(req,status);
    httpd_resp_set_type(req,"application/json; charset=utf-8");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t err=httpd_resp_send(req,body,HTTPD_RESP_USE_STRLEN);
    free(body);
    return err;
}

/**
 * 返回 AP 地址、STA 状态和有限重试信息；从不返回路由器密码。
 */
static esp_err_t get_handler(httpd_req_t *req) {
    network_state_t copy=snapshot();
    char ap_address[16]="";
    esp_netif_ip_info_t ap_info;
    if(ap_netif && esp_netif_get_ip_info(ap_netif,&ap_info)==ESP_OK)
        snprintf(ap_address,sizeof(ap_address),IPSTR,IP2STR(&ap_info.ip));
    cJSON *object=cJSON_CreateObject();
    if(!object) return text_reply(req,"500 Internal Server Error","内存不足。");
    cJSON_AddStringToObject(object,"mode","AP+STA");
    cJSON_AddStringToObject(object,"ap_ssid",CONFIG_XY_AP_SSID);
    cJSON_AddStringToObject(object,"ap_ip",ap_address);
    cJSON_AddStringToObject(object,"ssid",copy.ssid);
    cJSON_AddStringToObject(object,"station_ip",copy.connected?copy.station_ip:"");
    cJSON_AddBoolToObject(object,"configured",copy.configured);
    cJSON_AddBoolToObject(object,"connected",copy.connected);
    cJSON_AddBoolToObject(object,"connecting",copy.connecting);
    cJSON_AddNumberToObject(object,"retry_count",copy.retries);
    cJSON_AddNumberToObject(object,"retry_limit",XY_STATION_RETRIES);
    cJSON_AddNumberToObject(object,"last_disconnect_reason",copy.last_disconnect_reason);
    return json_reply(req,"200 OK",object);
}

/**
 * 拒绝 JSON 中的 Unicode NUL 转义，避免 cJSON 解码后 C 字符串被提前截断。
 */
static bool contains_encoded_nul(const char *body,size_t length) {
    for(size_t i=0;i+5<length;i++)
        if(body[i]=='\\' && body[i+1]=='u' && body[i+2]=='0' && body[i+3]=='0' && body[i+4]=='0' && body[i+5]=='0') return true;
    return false;
}

/**
 * 完整接收最多 512 字节 JSON，检查 SSID 和密码类型及长度；先持久化再请求连接，HTTP 202 表示已受理，不代表已连接路由器。
 */
static esp_err_t post_handler(httpd_req_t *req) {
    if(req->content_len<2 || req->content_len>XY_NETWORK_BODY_MAX)
        return reject_unread(req,"413 Content Too Large","配网 JSON 正文必须为 2..512 字节。");
    char body[XY_NETWORK_BODY_MAX+1];
    size_t length=0;
    while(length<req->content_len) {
        int got=httpd_req_recv(req,body+length,req->content_len-length);
        if(got<=0) return reject_unread(req,"408 Request Timeout","配网正文未完整收到，没有修改配置。");
        length+=(size_t)got;
    }
    body[length]='\0';
    if(memchr(body,'\0',length) || contains_encoded_nul(body,length))
        return text_reply(req,"400 Bad Request","配网字段不允许包含 NUL 字符。");
    cJSON *json=cJSON_ParseWithLengthOpts(body,length+1,NULL,true);
    if(!json || !cJSON_IsObject(json)) {
        cJSON_Delete(json);
        return text_reply(req,"400 Bad Request","需要包含 ssid 和 password 字符串的 JSON 对象。");
    }
    const cJSON *ssid=cJSON_GetObjectItemCaseSensitive(json,"ssid");
    const cJSON *password=cJSON_GetObjectItemCaseSensitive(json,"password");
    credentials_t credentials={.version=XY_CREDENTIAL_VERSION};
    bool strings=cJSON_IsString(ssid) && cJSON_IsString(password);
    size_t ssid_length=strings?strlen(ssid->valuestring):0;
    size_t password_length=strings?strlen(password->valuestring):0;
    bool valid=strings && ssid_length>=1 && ssid_length<=32 &&
        (password_length==0 || (password_length>=8 && password_length<=63));
    if(valid) {
        credentials.ssid_length=(uint8_t)ssid_length;
        credentials.password_length=(uint8_t)password_length;
        memcpy(credentials.ssid,ssid->valuestring,ssid_length);
        memcpy(credentials.password,password->valuestring,password_length);
    }
    cJSON_Delete(json);
    memset(body,0,sizeof(body));
    if(!valid) return text_reply(req,"400 Bad Request","SSID 必须为 1..32 字节；密码必须显式留空或为 8..63 字节。");
    esp_err_t err=save_credentials(&credentials);
    if(err!=ESP_OK) {
        memset(&credentials,0,sizeof(credentials));
        return text_reply(req,"500 Internal Server Error","配网信息保存失败，未替换 STA 配置。");
    }
    err=apply_credentials(&credentials);
    memset(&credentials,0,sizeof(credentials));
    cJSON *object=cJSON_CreateObject();
    if(!object) return text_reply(req,"500 Internal Server Error","配网信息已保存，但响应内存不足，请查询 /network。");
    cJSON_AddBoolToObject(object,"saved",true);
    cJSON_AddBoolToObject(object,"connection_requested",err==ESP_OK);
    cJSON_AddStringToObject(object,"message",err==ESP_OK?
        "配网信息已保存，已请求连接；请通过 /network 检查局域网地址，当前结果不代表已经联网。":
        "配网信息已保存，但连接请求失败；设置热点保留，请修改参数后重试。");
    return json_reply(req,err==ESP_OK?"202 Accepted":"502 Bad Gateway",object);
}

/**
 * 先删除自有凭据，再停止重连和清理 STA 配置；设置 AP 和八槽位曲库保留。
 */
static esp_err_t forget_handler(httpd_req_t *req) {
    if(req->content_len!=0) return reject_unread(req,"400 Bad Request","忘记路由器操作不接受正文。");
    esp_err_t err=forget_credentials();
    if(err!=ESP_OK) return text_reply(req,"500 Internal Server Error","无法删除本应用的路由器配置。");
    portENTER_CRITICAL(&state_lock);
    state.configured=false;state.reconnect=false;state.connecting=false;state.connected=false;
    state.ignore_disconnect=false;state.retries=0;state.last_disconnect_reason=0;
    state.ssid[0]='\0';state.station_ip[0]='\0';
    portEXIT_CRITICAL(&state_lock);
    (void)esp_wifi_disconnect();

    wifi_config_t empty={0};
    (void)esp_wifi_set_config(WIFI_IF_STA,&empty);
    return text_reply(req,"200 OK","已忘记本应用的路由器配置，设置热点和曲库已保留。");
}

/**
 * 创建 AP 与 STA 网络接口，注册 Wi-Fi/IP 事件，配置 WPA2 设置热点并恢复已保存的路由器连接；Wi-Fi 驱动自身仅用 RAM 存储配置。
 */
esp_err_t xy_network_start(void) {
    if(started) return ESP_ERR_INVALID_STATE;
    size_t ap_name=strlen(CONFIG_XY_AP_SSID),ap_password=strlen(CONFIG_XY_AP_PASSWORD);
    if(ap_name<1 || ap_name>32 || ap_password<8 || ap_password>63) return ESP_ERR_INVALID_ARG;
    esp_err_t err=esp_netif_init();
    if(err!=ESP_OK) return err;
    err=esp_event_loop_create_default();
    if(err!=ESP_OK && err!=ESP_ERR_INVALID_STATE) return err;
    ap_netif=esp_netif_create_default_wifi_ap();
    sta_netif=esp_netif_create_default_wifi_sta();
    if(!ap_netif || !sta_netif) return ESP_ERR_NO_MEM;
    err=esp_netif_set_hostname(sta_netif,"xianyu-score");
    if(err!=ESP_OK) return err;
    wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT();
    err=esp_wifi_init(&init);
    if(err!=ESP_OK) return err;

    err=esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if(err!=ESP_OK) return err;
    err=esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,network_event,NULL);
    if(err!=ESP_OK) return err;
    err=esp_event_handler_register(IP_EVENT,IP_EVENT_STA_GOT_IP,network_event,NULL);
    if(err!=ESP_OK) return err;
    err=esp_event_handler_register(IP_EVENT,IP_EVENT_STA_LOST_IP,network_event,NULL);
    if(err!=ESP_OK) return err;
    wifi_config_t ap={0};
    memcpy(ap.ap.ssid,CONFIG_XY_AP_SSID,ap_name);
    ap.ap.ssid_len=(uint8_t)ap_name;
    memcpy(ap.ap.password,CONFIG_XY_AP_PASSWORD,ap_password);
    ap.ap.channel=6;ap.ap.max_connection=2;ap.ap.authmode=WIFI_AUTH_WPA2_PSK;
    err=esp_wifi_set_mode(WIFI_MODE_APSTA);
    if(err!=ESP_OK) return err;
    err=esp_wifi_set_config(WIFI_IF_AP,&ap);
    memset(&ap,0,sizeof(ap));
    if(err!=ESP_OK) return err;
    credentials_t credentials;
    esp_err_t loaded=load_credentials(&credentials);
    if(loaded==ESP_OK) {
        wifi_config_t station;
        station_config(&credentials,&station);
        err=esp_wifi_set_config(WIFI_IF_STA,&station);
        memset(&station,0,sizeof(station));
        if(err!=ESP_OK) {memset(&credentials,0,sizeof(credentials));return err;}
        portENTER_CRITICAL(&state_lock);
        state.configured=true;state.reconnect=true;state.connecting=true;
        memcpy(state.ssid,credentials.ssid,sizeof(state.ssid));
        portEXIT_CRITICAL(&state_lock);
    } else if(loaded!=ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG,"Saved router settings unavailable; configure through setup AP");
    }
    memset(&credentials,0,sizeof(credentials));
    err=esp_wifi_start();
    if(err==ESP_OK) {
        started=true;
        ESP_LOGI(TAG,"Setup AP ready at http://192.168.4.1/ ; router credentials are not logged");
    }
    return err;
}

/**
 * 注册配网的查询、保存和忘记三个 HTTP 接口，注册失败立即返回 SDK 错误。
 */
esp_err_t xy_network_register(httpd_handle_t server) {
    const httpd_uri_t get={.uri="/network",.method=HTTP_GET,.handler=get_handler};
    const httpd_uri_t post={.uri="/network",.method=HTTP_POST,.handler=post_handler};
    const httpd_uri_t forget={.uri="/network/forget",.method=HTTP_POST,.handler=forget_handler};
    esp_err_t err=httpd_register_uri_handler(server,&get);
    if(err!=ESP_OK) return err;
    err=httpd_register_uri_handler(server,&post);
    if(err!=ESP_OK) return err;
    return httpd_register_uri_handler(server,&forget);
}
