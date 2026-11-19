# dev6.2 发行安装器检查

检查日期：2026-11-19。固件镜像保持已上机验证的 dev6.2，源码基线为 `27c1b7c`。发布时新增安装器、入口和说明，未重新构建或刷写设备。

```sh
python3 -m unittest verification/test_bootstrap.py verification/test_flash_installer.py -v
bash -n 一键刷机-Mac.command
```

共 26 项测试通过。覆盖固件包路径和镜像校验、分区表 MD5 与布局、唯一设备选择、风险确认、写入顺序、失败后停止、跨进程锁、依赖安装确认、固定依赖版本、带空格路径以及检查模式不访问 USB。

使用真实配套固件包执行 `--dry-run` 通过；使用已安装的 esptool 4.13.0、pyserial 3.5 和 openFPGALoader 执行 `--check` 通过。两种模式均为离线检查，不探测 USB 或写入设备。

Windows 入口和平台行为已做静态与模拟检查。Windows 原生执行及通过新安装入口的实际硬件刷写尚未验证。包内主镜像的准确摘要见 `firmware-dev6.2.sha256`，完整发行包逐文件摘要见包根目录 `SHA256SUMS`。
