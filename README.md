# Chromatic 定制固件 4.6-dev2

为配备 ESP32 和机内 microSD 卡座的 ModRetro Chromatic 开发的非官方固件。新增游戏中按键待机、简体中文菜单和蓝牙耳机音频。固件已通过仿真和 FPGA 静态时序检查，三款实体游戏的唤醒、耳机配对和待机续航仍待实机验证。

**[下载 4.6-dev2 固件包](https://github.com/lovespaper1990-dot/chromatic-custom-firmware/releases/download/v4.6-dev2/Chromatic-4.6-dev2.zip)** · [中文安装说明](docs/安装与使用.md) · [文件校验值](SHA256SUMS)

| 功能 | 操作 |
| --- | --- |
| 临时待机 | 保持电源开关在 ON，在游戏画面单独长按 MENU 约 1.5 秒，背光熄灭后松手。再短按并松开 MENU，游戏从原处继续。待机不需要 microSD，关机、断电或拔卡会丢失现场。 |
| 简体中文 | 在 System → Language 按 A 切换语言。 |
| 蓝牙耳机 | 耳机进入配对模式后打开主页的“蓝牙”，按 A 扫描，按 B 选择设备，再按 A 连接。 |
| microSD 即时存档 | 支持 32 KiB ROM-only、无卡带 RAM 的实体卡带。插入 FAT32 microSD，在“即时存档”按 A 保存，读档时按 B 再按 B 确认。 |

原配《俄罗斯方块》、《塞尔达传说 大地之章》和 GB/GBC 版《星之海洋 蔚蓝星球》可用来测试带电待机。这三盘尚不支持 microSD 即时存档。固件包附带一个原创 32 KiB 测试游戏，用于验证关机后的读档。

## 源码和构建

本次修改于 2026-11-12 发布。[changes/fpga](changes/fpga) 和 [changes/mcu](changes/mcu) 包含本版所有新增或修改的源码、测试和配置。仓库通过 Git 子模块锁定 ModRetro FPGA v18.14、MCU v4.6 及上游指定的 Gameboy_MiSTer 核心。系统菜单版本为 4.6-dev2，ESP32 应用版本为 0.13.8-dev2。

在新的目录中获取此版本的源码，然后把定制文件放入对应的上游目录。

```sh
git clone --branch v4.6-dev2 --recurse-submodules https://github.com/lovespaper1990-dot/chromatic-custom-firmware.git
cd chromatic-custom-firmware
cp -Rp changes/fpga/. fpga/
cp -Rp changes/mcu/. mcu/
```

- FPGA 使用 Gowin FPGA Designer 标准版 1.9.12.04-1，目标器件为 GW5A-EV25UG256CC1/I0，版本 A。为这台开发机配置高云许可证，将 `gw_sh` 加入 PATH，或设置 `GOWIN_SH` 为其完整路径。从仓库根目录运行 `./fpga/esp32t/build_evt1_x2.sh`，输出在 `fpga/esp32t/build`。
- MCU 使用 ESP-IDF 5.3.0 和 LVGL 8.4.0。激活 ESP-IDF 环境后运行 `(cd mcu && idf.py build)`。本次 ESP32 配置、分区选择及依赖锁定文件随源码提供。
- 验证使用 C 编译器、Python 3、Icarus Verilog 13 和 GHDL 6。在仓库根目录运行 `./verification/run.sh`。双速和普通速度共完成 440 次卡带待机和唤醒仿真。最终布线分析 55,346 条路径，建立与保持时间均为零违例。[完整验证记录](verification/results.txt) · [布线时序报告](verification/evt1_x2.tr)
- 测试卡汇编源码及 RGBDS 重建命令见 [diagnostics/snapshot-test.asm](diagnostics/snapshot-test.asm)。

本项目沿用 ModRetro 固件仓库的 GNU GPLv3，中文菜单字体遵循 SIL Open Font License 1.1。上游源码中的版权和第三方许可声明继续适用。[GPLv3](LICENSE) · [字体许可](changes/mcu/components/fonts/OSD-CJK-LICENSE.txt)
