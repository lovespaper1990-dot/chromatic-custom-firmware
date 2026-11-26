# ModRetro Chromatic 定制固件

**v4.6-d7S1 开发测试版**支持从 microSD 启动 GB/GBC，加入第一阶段 SD 即时存档。已在一台真机验证 SD 启动和单次 GB 保存。机主录像另展示 SD《坦克大战》关机重开后读档。三槽跨断电、GBC 快照与更多卡带仍待测试。选择前请看设备要求、备份和回退说明。

[d7S1 下载与源码](https://github.com/lovespaper1990-dot/chromatic-custom-firmware/releases/tag/v4.6-d7S1) · [d7S1 测试说明](docs/4.6-d7S1-公开测试说明.md)

## 既有 4.6-dev6.2-test 测试版

**本项目是非官方个人分享的开源固件，当前为公开测试版。**

适用于配备 ESP32、机内 microSD 卡座及 GW5A-25 FPGA 的 ModRetro Chromatic，提供简体中文菜单、蓝牙耳机、临时待机和每款游戏三个即时存档槽。

原配《俄罗斯方块》已经通过实机保存、读档和完整断电后恢复。dev6.2 实测保存约 0.99～1.12 秒，读档约 1.45～1.46 秒。测试范围及尚未解决的问题见下文。[dev6.2 实机记录](docs/4.6-dev6.2-test测试说明.md)

**刷机前请阅读测试免责，备份游戏进度及 microSD 上的整个 `SNAP` 文件夹。刷写失败、供电中断或兼容性问题可能造成开机异常、进度丢失、存档损坏，并可能需要额外恢复操作。** 固件按 GNU GPLv3 的现状条款提供，使用者需自行决定是否刷入。[免责声明](docs/免责声明.md) · [完整许可](LICENSE)

## 下载与安装

从 Releases 下载 `Chromatic-4.6-dev6.2-test-install.zip` 并完整解压。在包根目录双击对应入口，按提示准备依赖、核对设备并确认刷写。

| 电脑 | 入口 | 首次使用 |
| --- | --- | --- |
| Mac | `一键刷机-Mac.command` | 需要 Python 3.9 或更新版及 Homebrew。脚本可在确认后准备刷写工具和本地 Python 依赖。 |
| Windows x64 | `一键刷机-Windows.cmd` | 脚本可在确认后通过 winget、MSYS2 准备工具。首次 USB 驱动安装可能需要官方更新器。 |

Mac 与 Windows 入口共用包校验、设备检查和刷写流程。Windows 原生环境尚未实测，已做模拟流程与静态检查。源码 ZIP 不含配套固件镜像，安装时请使用 Releases 中的完整发行包。[下载页面](https://github.com/lovespaper1990-dot/chromatic-custom-firmware/releases/tag/v4.6-dev6.2-test) · [安装与使用](docs/安装与使用.md) · [给 AI 的安装说明](docs/给AI的安装说明.md)

以下功能和实测数据对应 dev6.2。d7S1 的范围和安装方式见上方独立说明。

## 功能与操作

| 功能 | 操作与范围 |
| --- | --- |
| 每游戏三个即时存档槽 | 插卡开机后自动识别游戏。在「主页 → 即时存档」按 START 循环选择 1、2、3 号槽，按 A 保存，按 B 再按 B 确认读档。确认读档时按 A 取消。 |
| 存档备份代际 | 每槽轮换保留两代。读取该槽最新有效的一份，最新一代损坏时可回退到上一代。备份时复制整个 `SNAP` 文件夹。 |
| 简体中文 | 在 `System → Language` 按 A 切换语言。 |
| 蓝牙耳机 | 在主页「蓝牙」按 A 扫描、按 B 选择、按 A 连接。可记住耳机并尝试重连，机身滚轮用于调整蓝牙音量。 |
| 临时待机 | 电源开关保持 ON。在游戏画面单独长按 MENU 约 1.5 秒，背光熄灭后松手。短按并松开 MENU 唤醒，游戏从原处继续。 |

即时存档使用有空余空间的 FAT32 microSD。等待「已存档」或「已读档」再关机、拔卡或离开。临时待机依靠持续供电保留现场，仍会耗电，关机、断电或拔卡会丢失待机现场。

读档会回退 CPU、内部内存和卡带 RAM 中的游戏进度。恢复卡带 RAM 的最后阶段若断电或拔卡，原生游戏存档可能只更新一部分。请先用可重新开始的进度测试。

## 实测结果与已知问题

| 项目 | 当前状态 |
| --- | --- |
| 原配《俄罗斯方块》 | dev6.2 已验证高速保存、读档及完整断电后的 3 号槽恢复。旧识别码下的 1、2 号槽已经复制恢复，机主确认旧 2 号位置正确。 |
| 《塞尔达》新版 GBC 单卡 | dev5.5 有可用反馈，dev6.2 尚待逐卡复测。 |
| 正版《马里奥大陆》 | 先前可运行。dev6.2 的标准 MBC1 无卡带 RAM 快照模型已通过离线验证，实体卡即时存档尚待验证。 |
| 《星之海洋》新版 GBC 单卡 | 先前自定义固件曾出现黑屏，dev6.2 尚待实卡复测。 |
| 蓝牙声音与滚轮 | dev4 已由机主确认同一次连接中可以调大、调小音量。dev6.2 同时播放蓝牙和高速存读档的压力测试仍待完成。 |
| 长期稳定性 | 当前 FPGA 构建通过时序检查，最差建立余量为 +0.002 ns，余量较窄。长时间运行、温度变化及更多设备仍需验证。 |
| 早期存档兼容 | dev6.1 及更早开发版曾受初始 ROM 分页影响而得到不同识别码。dev6.2 修正扫描，旧档可能需要维护者确认同一实体卡后显式导入。 |

当前即时存档开放 32 KiB ROM-only、指定标准 MBC1 和 MBC5 配置。MBC1 支持类型 01/02/03、最高 2 MiB ROM、无 RAM 或 8 KiB RAM，32 KiB RAM 仅开放至 512 KiB ROM。MBC5 最高开放 8 MiB ROM，类型 19 对应无 RAM，类型 1A/1B 对应 8 KiB 或 32 KiB RAM。MBC1M、MBC2、MBC3、RTC、2 KiB RAM及其他特殊卡带尚未开放，联机现场恢复也尚未支持。兼容性由卡头、分页行为和逐盘实测共同决定。[卡带支持范围](docs/4.6-dev6-test测试说明.md)

报告问题时可提供电脑系统、菜单版本、卡带名称、问题发生步骤和界面提示。公开截图与日志前请去除序列号、蓝牙地址、个人目录和其他私人信息。

## 更新官方固件与恢复

游戏偶发卡死时，可先拨到 OFF、拔掉 USB、等待约 10 秒后再开机。需要回到官方固件时，使用官方 ModRetro Updater，并确认 MCU 与 FPGA 两部分都已完成官方固件写入。

本固件的 FPGA 基础版本仍显示 18.14，更新器可能根据版本号跳过相同版本的 FPGA。出现「已经最新」、无法识别设备或只更新了一部分时，单次点击更新无法证明已完整恢复官方固件，需要按官方支持给出的恢复步骤处理。本项目尚未实测通过官方更新器从本版完整刷回官方固件。[官方更新器说明](https://support.modretro.com/en_us/chromatic-firmware-updater-ryhoYnzCx)

## 源码和构建

已上机验证的 dev6.2 固件源码基线为提交 `27c1b7c`。本仓库通过 Git 子模块锁定 ModRetro FPGA v18.14、MCU v4.6 及其对应 Gameboy_MiSTer 核心，定制文件位于 `changes/fpga` 和 `changes/mcu`。系统菜单版本为 `4.6-dev6.2-test`，ESP32 应用版本为 `0.13.8-dev6.2-test`。

```sh
git clone --recurse-submodules https://github.com/lovespaper1990-dot/chromatic-custom-firmware.git
cd chromatic-custom-firmware
cp -Rp changes/fpga/. fpga/
cp -Rp changes/mcu/. mcu/
```

FPGA 使用 Gowin FPGA Designer 标准版 1.9.12.04-1，器件为 GW5A-EV25UG256CC1/I0，版本 A。配置本机许可证后运行 `./fpga/esp32t/build_evt1_x2.sh`。MCU 使用 ESP-IDF 5.3.0 和 LVGL 8.4.0，激活环境后运行 `(cd mcu && idf.py build)`。本仓库提供对应配置及依赖锁定文件。

验证需要 C 编译器、Python 3、Icarus Verilog 13 和 GHDL 6，运行 `./verification/run.sh`。设置 `SNAPSHOT_FULL_ROM=1` 可额外检查完整 8 MiB ROM 扫描。发布前同时检查综合接线、布线时序、镜像校验值和实机结果。[dev6.2 回归记录](verification/tests-dev6.2.log) · [dev6.2 时序报告](verification/evt1_x2-dev6.2-spi.tr)

本项目沿用 ModRetro 固件仓库的 GNU GPLv3，中文点阵字体遵循 SIL Open Font License 1.1。上游版权和第三方许可声明继续适用。[GPLv3](LICENSE) · [字体许可](changes/mcu/components/fonts/OSD-CJK-LICENSE.txt)
