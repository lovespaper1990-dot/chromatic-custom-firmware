# Chromatic 定制固件 4.6-dev5.5 开发测试版

离线开发中的 [4.6-dev6-test 测试记录](docs/4.6-dev6-test测试说明.md) 包含标准 MBC1 适配和 SPI 批量存档。真机已验证的版本仍是 4.6-dev5.5。

为配备 ESP32 和机内 microSD 卡座的 ModRetro Chromatic 开发的非官方固件。当前开发版增加 MBC5 实体卡带即时存档，保存卡带 RAM、分页和卡槽读写相位。真机 SD 已识别；dev5 的捕获失败已修正，dev5.5 已在原配《俄罗斯方块》上通过完整保存、读档与断电恢复，用户另反馈《塞尔达》也可用。《马里奥大陆》即时存档和传输提速仍待实现，《星之海洋》尚待复测。商业卡带兼容性仍待逐盘真机确认。dev4 的蓝牙声音与机身滚轮调音量已由机主验证。

[dev5.5 修正与测试记录](docs/4.6-dev5.5测试说明.md) · [SD 识别修正](docs/4.6-dev5.2测试说明.md) · [dev5 测试说明](docs/4.6-dev5-test测试说明.md) · [即时存档研究与实现](docs/即时存档研究与实现.md) · [dev4 真机验证记录](docs/4.6-dev4-test测试说明.md)

此前发布的 [4.6-dev2 固件包](https://github.com/lovespaper1990-dot/chromatic-custom-firmware/releases/download/v4.6-dev2/Chromatic-4.6-dev2.zip)仍可下载；它不包含本轮 MBC5 改动。[首次安装说明](docs/安装与使用.md) · [dev2 文件校验值](SHA256SUMS)

| 功能 | 操作 |
| --- | --- |
| 临时待机 | 保持电源开关在 ON，在游戏画面单独长按 MENU 约 1.5 秒，背光熄灭后松手。再短按并松开 MENU，游戏从原处继续。待机不需要 microSD，关机、断电或拔卡会丢失现场。 |
| 简体中文 | 在 System → Language 按 A 切换语言。 |
| 蓝牙耳机 | 耳机进入配对模式后打开主页的“蓝牙”，按 A 扫描，按 B 选择设备，再按 A 连接。 |
| microSD 即时存档 | ROM-only 保留支持；dev5 新增 MBC5 19/1A/1B，最大 8 MiB ROM，对应无 RAM、8 KiB 或 32 KiB RAM。FAT32 microSD，“即时存档”按 A 保存，按 B 再按 B 确认读档。原配《俄罗斯方块》已通过保存、读档和断电恢复；其他卡带逐项验证。 |

原配《俄罗斯方块》、《塞尔达传说 大地之章》和 GB/GBC 版《星之海洋 蔚蓝星球》是本轮目标卡带；《俄罗斯方块》已通过基础验收，《塞尔达》有可用反馈，《星之海洋》仍待复测，实际范围需读取卡头确认。读档会一起回退卡带 RAM 中的游戏自带存档。请保留重要进度备份。当前只做单机快照，联机现场恢复不在支持范围。

## 源码和构建

本轮开发日期为 2026-11-17。[changes/fpga](changes/fpga) 和 [changes/mcu](changes/mcu) 包含新增或修改的源码、测试和配置。仓库通过 Git 子模块锁定 ModRetro FPGA v18.14、MCU v4.6 及上游指定的 Gameboy_MiSTer 核心。系统菜单版本为 4.6-dev5.5，ESP32 应用版本为 0.13.8-dev5.5。

在新的目录中获取此版本的源码，然后把定制文件放入对应的上游目录。

```sh
git clone --recurse-submodules https://github.com/lovespaper1990-dot/chromatic-custom-firmware.git
cd chromatic-custom-firmware
cp -Rp changes/fpga/. fpga/
cp -Rp changes/mcu/. mcu/
```

- FPGA 使用 Gowin FPGA Designer 标准版 1.9.12.04-1，目标器件为 GW5A-EV25UG256CC1/I0，版本 A。为这台开发机配置高云许可证，将 `gw_sh` 加入 PATH，或设置 `GOWIN_SH` 为其完整路径。从仓库根目录运行 `./fpga/esp32t/build_evt1_x2.sh`，输出在 `fpga/esp32t/build`。脚本在布线前运行综合接线检查；未知的层级或命名需要人工核对，不能跳过检查后直接声称验证通过。
- MCU 使用 ESP-IDF 5.3.0 和 LVGL 8.4.0。激活 ESP-IDF 环境后运行 `(cd mcu && idf.py build)`。本次 ESP32 配置、分区选择及依赖锁定文件随源码提供。
- 验证使用 C 编译器、Python 3、Icarus Verilog 13 和 GHDL 6。在仓库根目录运行 `./verification/run.sh`，设置 `SNAPSHOT_FULL_ROM=1` 可额外验证完整 8 MiB ROM 扫描。本轮 dev5.5 回归包含真实保存管理器与真实 CPU 自主捕获；历史 dev5 [回归记录](verification/tests-dev5.log)、[完整 ROM 与执行负对照](verification/full-rom-dev5.txt)；历史 dev2 另见 [记录](verification/results.txt)及[时序报告](verification/evt1_x2.tr)。
- 测试卡汇编源码及 RGBDS 重建命令见 [diagnostics/snapshot-test.asm](diagnostics/snapshot-test.asm)。

本项目沿用 ModRetro 固件仓库的 GNU GPLv3，中文菜单字体遵循 SIL Open Font License 1.1。上游源码中的版权和第三方许可声明继续适用。[GPLv3](LICENSE) · [字体许可](changes/mcu/components/fonts/OSD-CJK-LICENSE.txt)
