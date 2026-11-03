# IDF 6.x 不再通过 driver 隐式提供 UART 驱动，也不内置旧 json 组件。
# cJSON 由下面的 idf_component.yml 明确指定，保持源码可重建。
idf_component_register(
    SRCS "app_main.c" "score_protocol.c" "score_transfer.c"
         "score_record.c" "score_library.c" "score_metadata.c" "score_resident_sync.c" "xy_network.c"
    INCLUDE_DIRS "."
    REQUIRES esp_driver_uart esp_driver_gpio esp_wifi esp_http_server esp_netif
             nvs_flash esp_event esp_timer esp_system esp_hw_support heap
    EMBED_TXTFILES "web_index.html" "web_app.js" "score_catalog.json"
    EMBED_FILES "web_ui.html.gz")
