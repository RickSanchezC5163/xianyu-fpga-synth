# 构建与离线验证

## RTL

依赖 Python 3.10+、Icarus Verilog（`iverilog` 与 `vvp` 在 PATH）。

```sh
python scripts/run_review_regressions.py --mode fixed
```

找不到工具时可追加 `--iverilog /absolute/path/to/iverilog`。该回归验证起音、重触发后的松键、STOP 淡出与 USB MIDI 完整性四项合约，不代表全部整机测试。

准备 USB + 音频 + 串口屏 + Wi-Fi 集成构建：

```sh
python scripts/build_instrument_ui.py --display serial-wifi --prepare-only
python scripts/build_instrument_ui.py --display serial-wifi --gowin /path/to/gw_sh
```

Gowin 工具版本基线为 1.9.12.03。也可设置 `GOWIN_BIN`。构建脚本复制输入源并记录结果，不运行 Programmer。务必检查最终报告的资源、Setup/Hold 和约束覆盖，再考虑上板；旧实板数据不能替代新构建报告。

## ESP32-S3

在已安装并激活 ESP-IDF 6.1 的终端执行：

```sh
cd firmware/esp32s3_score_bridge
idf.py set-target esp32s3
idf.py menuconfig
idf.py build
```

确认 N16R8 对应 Flash/PSRAM 配置；在“弦域 ESP32-S3 曲谱桥”菜单修改热点密码。用户决定部署时才执行 `idf.py -p <PORT> flash monitor`。不连接 FPGA 时仍可检查网页能否加载，但不能把本地保存当作琴端提交成功。

## 网页

使用满足 Vite 8 要求的 Node.js（如 Node 22.12+）和 npm：

```sh
cd firmware/esp32s3_score_bridge/web
npm ci
npm run dev
```

开发页面默认访问同源设备 API，没有 S3 服务时不会自动显示真实设备成功状态。回到仓库根目录打包：

```sh
python scripts/build_s3_web.py
```

该步骤生成 `main/web_ui.html.gz`，由 ESP-IDF 嵌入 Flash；浏览器解压和执行 UI，S3 不运行 Node。仓库已附打包资源，未改前端时可直接构建固件。

## 主机协议测试

准备主机 GCC（可通过 `CC` 指定），在仓库根目录执行：

```sh
python scripts/test_s3_resident_slots.py
python firmware/esp32s3_score_bridge/tests/test_esp_score_protocol.py
python firmware/esp32s3_score_bridge/tests/test_score_record.py
python firmware/esp32s3_score_bridge/tests/test_score_metadata.py
python firmware/esp32s3_score_bridge/tests/test_metadata_http_query.py
python firmware/esp32s3_score_bridge/tests/test_catalog.py
```

这些测试覆盖主机上的实际 C 协议/存储编码实现及部分应用适配，不代替 ESP-IDF 目标编译、NVS 实机掉电测试或射频网络压力测试。

自定义曲谱：使用 `tools/make_score.py --input score.json --output score.xys`（路径相对 S3 工程）。JSON 包含 bpm、base_note、events；事件 tick 单位为 1/96 拍，keys 为 0–24 的完整目标键状态，最后必须释放全部键。原始 MIDI 须先自行整理主旋律，不能直接改扩展名。
