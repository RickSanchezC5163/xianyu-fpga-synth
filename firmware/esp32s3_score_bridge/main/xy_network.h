/**
 * @file xy_network.h
 * @brief AP+STA 生命周期和配网 HTTP 注册接口。调用前必须初始化 NVS；状态/响应不得返回密码。
 * 适用工程：ESP32-S3 N16R8 / ESP-IDF 6.1.0。
 */
#ifndef XIANYU_NETWORK_H
#define XIANYU_NETWORK_H

#include "esp_err.h"
#include "esp_http_server.h"

/** 创建 AP 与 STA 网络接口，注册 Wi-Fi/IP 事件，配置 WPA2 设置热点并恢复已保存的路由器连接；Wi-Fi 驱动自身仅用 RAM 存储配置。 */
esp_err_t xy_network_start(void);

/** 注册配网的查询、保存和忘记三个 HTTP 接口，注册失败立即返回 SDK 错误。 */
esp_err_t xy_network_register(httpd_handle_t server);

#endif
