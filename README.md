# Chromatic 定制固件 4.6-dev6.2-test

[dev6.2 卡带启动识别修正与真机进展](docs/4.6-dev6.2-test测试说明.md)。dev6.1 实机存读档约 1.2～1.5 秒，断电后出现识别码变化，dev6.2 已修正扫描并刷入，原配《俄罗斯方块》的新 3 号槽已通过完整断电恢复。

每款受支持的游戏有 3 个可选即时存档位。插卡开机后自动识别游戏，在「主页 → 即时存档」按 START 切换 1、2、3 号，按 A 保存，按 B 两次读档。已有的快照直接用 1 号位读取。[三槽操作与离线验证](docs/4.6-dev6.1-test测试说明.md)

本项目适用于配备 ESP32 和机内 microSD 卡座的 ModRetro Chromatic。dev6.2 是非官方测试固件，沿用标准 MBC1 适配和高速 SPI。dev5.5 的原配《俄罗斯方块》已通过真机保存、读档与断电恢复，《塞尔达》有可用反馈。dev6.2 的《俄罗斯方块》实测保存约 1 秒、读档约 1.3～1.5 秒。《马里奥大陆》和《星之海洋》的实卡表现仍待测。[dev6 卡带范围和传输说明](docs/4.6-dev6-test测试说明.md)

[dev5.5 修正与测试记录](docs/4.6-dev5.5测试说明.md) · [SD 识别修正](docs/4.6-dev5.2测试说明.md) · [dev5 测试说明](docs/4.6-dev5-test测试说明.md) · [即时存档研究与实现](docs/即时存档研究与实现.md) · [dev4 真机验证记录](docs/4.6-dev4-test测试说明.md)

此前发布的 [4.6-dev2 固件包](https://github.com/lovespaper1990-dot/chromatic-custom-firmware/releases/download/v4.6-dev2/Chromatic-4.6-dev2.zip)仍可下载；它不包含本轮 MBC5 改动。[首次安装说明](docs/安装与使用.md) · [dev2 文件校验值](SHA256SUMS)

| 功能 | 操作 |
| --- | --- |
| 临时待机 | 保持电源开关在 ON，在游戏画面单独长按 MENU 约 1.5 秒，背光熄灭后松手。再短按并松开 MENU，游戏从原处继续。待机不需要 microSD，关机、断电或拔卡会丢失现场。 |
| 简体中文 | 在 System → Language 按 A 切换语言。 |
| 蓝牙耳机 | 耳机进入配对模式后打开主页的“蓝牙”，按 A 扫描，按 B 选择设备，再按 A 连接。 |
| microSD 即时存档 | 使用 FAT32 microSD，每款游戏 3 个槽，每槽轮换两代以保护上一次有效的快照。支持指定的 ROM-only、标准 MBC1 和 MBC5 配置。 |

原配《俄罗斯方块》、《塞尔达传说 大地之章》和 GB/GBC 版《星之海洋 蔚蓝星球》是本轮目标卡带；《俄罗斯方块》已通过基础验收，《塞尔达》有可用反馈，《星之海洋》仍待复测，实际范围需读取卡头确认。读档会一起回退卡带 RAM 中的游戏自带存档。请保留重要进度备份。当前只做单机快照，联机现场恢复不在支持范围。

## 源码和构建

本轮开发日期为 2026-11-18。[changes/fpga](changes/fpga) 和 [changes/mcu](changes/mcu) 包含新增或修改的源码、测试和配置。仓库通过 Git 子模块锁定 ModRetro FPGA v18.14、MCU v4.6 及上游指定的 Gameboy_MiSTer 核心。系统菜单版本为 4.6-dev6.2-test，ESP32 应用版本为 0.13.8-dev6.2-test。

在新的目录中获取此版本的源码，然后把定制文件放入对应的上游目录。

```sh
git clone --recurse-submodules https://github.com/lovespaper1990-dot/chromatic-custom-firmware.git
cd chromatic-custom-firmware
cp -Rp changes/fpga/. fpga/
cp -Rp changes/mcu/. mcu/
```

- FPGA 使用 Gowin FPGA Designer 标准版 1.9.12.04-1，目标器件为 GW5A-EV25UG256CC1/I0，版本 A。为这台开发机配置高云许可证，将 `gw_sh` 加入 PATH，或设置 `GOWIN_SH` 为其完整路径。从仓库根目录运行 `./fpga/esp32t/build_evt1_x2.sh`，输出在 `fpga/esp32t/build`。脚本在布线前运行综合接线检查；未知的层级或命名需要人工核对，不能跳过检查后直接声称验证通过。
- MCU 使用 ESP-IDF 5.3.0 和 LVGL 8.4.0。激活 ESP-IDF 环境后运行 `(cd mcu && idf.py build)`。本次 ESP32 配置、分区选择及依赖锁定文件随源码提供。
- 验证使用 C 编译器、Python 3、Icarus Verilog 13 和 GHDL 6。在仓库根目录运行 `./verification/run.sh`，设置 `SNAPSHOT_FULL_ROM=1` 可额外验证完整 8 MiB ROM 扫描。测试覆盖三个槽的隔离、菜单刷新与快照同时访问内存，以及 CPU 捕获和恢复。历史 dev5 [回归记录](verification/tests-dev5.log)、[完整 ROM 与执行负对照](verification/full-rom-dev5.txt)；历史 dev2 另见 [记录](verification/results.txt)及[时序报告](verification/evt1_x2.tr)。
- 测试卡汇编源码及 RGBDS 重建命令见 [diagnostics/snapshot-test.asm](diagnostics/snapshot-test.asm)。

本项目沿用 ModRetro 固件仓库的 GNU GPLv3，中文菜单字体遵循 SIL Open Font License 1.1。上游源码中的版权和第三方许可声明继续适用。[GPLv3](LICENSE) · [字体许可](changes/mcu/components/fonts/OSD-CJK-LICENSE.txt)
