# XG2010G Stock 固件刷写与回退 OpenWrt 完整教程

本教程用于在 Econet/Gemtek XG2010G（Airoha AN7581）上刷写厂商 stock 固件做参考验证，以及失败/完成后回到 OpenWrt。

## 0. 准备

- USB/串口线接到板子串口（115200 8N1）。
- TFTP 服务器（tftpd64、atftpd、dnsmasq 均可）。
- PC 网卡手动设成 `192.168.0.205/24`。
- 需要的文件（提前放到 TFTP 根目录，文件名统一用 `image.ub`）：
  - `stock-image.ub` — 厂商固件。
  - `openwrt-...-initramfs-recovery.itb` — OpenWrt recovery。
  - `openwrt-...-sysupgrade.itb` — OpenWrt sysupgrade。

## 1. 进入厂商 U-Boot

上电后狂按键盘任意键，打断 autoboot，看到：

```text
ECNT>
```

## 2. 确认/设置网络环境

```bash
ECNT> printenv loadaddr
ECNT> printenv ipaddr
ECNT> printenv serverip
```

默认值：

- `loadaddr=0x88000000`
- `ipaddr=192.168.0.1`
- `serverip=192.168.0.205`

不对就改：

```bash
ECNT> setenv loadaddr 0x88000000
ECNT> setenv ipaddr 192.168.0.1
ECNT> setenv serverip 192.168.0.205
ECNT> saveenv
```

## 3. 在 OpenWrt 运行态先备份关键数据

如果你现在还在 OpenWrt，先备份：

```bash
# 厂商 U-Boot env（mtd1，含 CRC，整块回写用）
cat /dev/mtd1 > /tmp/vendor_uenv_mtd1.bin

# chainloader UBI env 文本
fw_printenv > /tmp/chainloader_ubootenv.txt

# OpenWrt 配置
tar czf /tmp/openwrt_config_etc.tar.gz /etc/config

# dsd = MAC/出厂数据；art = 射频校准
cat /dev/mtd2 > /tmp/dsd_mtd2.bin
cat /dev/mtd5 > /tmp/art_mtd5.bin
```

把这些文件传回 PC 保存。

## 4. 刷写 Stock 固件

### 4.1 TFTP 加载 stock

PC 端把 stock 固件重命名为 `image.ub` 放到 TFTP 根目录。

```bash
ECNT> setenv loadaddr 0x88000000
ECNT> tftpboot
```

看到 `Bytes transferred = ...` 且 `$filesize` 被设置即成功。

### 4.2 写入 flash

Stock 固件写在 OpenWrt 固件区（mtd3/ubi，0x600000 起）：

```bash
ECNT> flash erase 0x600000 0x4000000
ECNT> flash write 0x600000 $filesize 0x88000000
```

出现 `spinand_ecc_fail_check` / `Update BMT success` 之类的坏块提示是正常的，那是 SPI-NAND BMT 管理，不是写入失败。

### 4.3 设置正确的 bootcmd（关键！）

**不要**用 `flash read 0x602100 ...` 这种裸读偏移，厂商 stock 镜像头不是普通 FIT，
必须用厂商隐藏命令 `flash imgread 2048` 解析。

```bash
ECNT> setenv bootcmd 'flash imgread 2048; bootm'
ECNT> setenv fw_port 0
ECNT> saveenv
```

`fw_port` 保持 `0`，不要改成 `1`（之前测试发现改它会让 env-watcher 行为异常）。

### 4.4 启动 stock

```bash
ECNT> boot
```

以后上电会自动走这个 bootcmd 启动 stock。

## 5. 验证 Stock 网络

Stock 默认 LAN IP 通常是 `192.168.0.1` 或 `192.168.1.1`，具体看固件。
PC 接 LAN 口，手动设同网段 IP，SSH/Telnet 进系统。

## 6. 在 Stock 上抓取 SerDes 寄存器 Dump

把 `docs/xg2010g-serdes-dump.sh` 传到 stock 系统里：

```bash
# 在 stock 上执行
sh /tmp/xg2010g-serdes-dump.sh
```

脚本会生成 `/tmp/serdes-dump-YYYYMMDD-HHMMSS.tar.gz`，包含：

- `/proc/tc3162/hsgmii_*_mac_dbg` — 厂商暴露的 MAC/SerDes 调试寄存器。
- `/proc/tc3162/hsgmii_*_lan_link_status` — 各 SerDes 链路状态。
- `sys serdes` 输出（如果存在）。
- 当前 `ip link`、内核日志等。

把 tar.gz 传回 PC，用于和 OpenWrt 主线的 bringup 做对比。

## 7. 从 Stock 恢复到 OpenWrt

**警告**：刷 stock 会破坏 OpenWrt 的 UBI 区（mtd3）和位于 `0x8600000` 的
chainloader FIT，不能简单改 bootcmd 回 OpenWrt，必须重新走 recovery + sysupgrade。

### 7.1 重新进入厂商 U-Boot

上电打断 autoboot，回到 `ECNT>`。

### 7.2 直接 TFTP 启动 recovery initramfs

PC 端把 OpenWrt recovery initramfs.itb 重命名为 `image.ub`。

```bash
ECNT> setenv loadaddr 0x88000000
ECNT> tftpboot
ECNT> iminfo 0x88000000
ECNT> bootm 0x88000000
```

这里**不依赖** flash 里的 chainloader，直接从 RAM 启动 recovery。

### 7.3 在 recovery 里重建 UBI + factory volume

Recovery 起来后大概率没有网络（factory volume 被 stock 破坏了，网卡拿不到 MAC），
在串口里执行：

```bash
# 重建 UBI
ubiformat /dev/mtd3 -y
ubiattach -m 3

# 从 dsd (mtdblock2) 提取 MAC 并重建 factory volume
wan=$(strings /dev/mtdblock2 | sed -n 's/^wan_mac=//p')
lan=$(strings /dev/mtdblock2 | sed -n 's/^lan_mac=//p')
hex2bin() {
	for b in $(echo "$1" | tr ':' ' '); do
		printf "\\$(printf '%03o' 0x$b)"
	done
}
dd if=/dev/zero of=/tmp/factory.bin bs=1024 count=28 2>/dev/null
hex2bin "$wan" | dd of=/tmp/factory.bin bs=1 seek=20480 conv=notrunc 2>/dev/null
hex2bin "$lan" | dd of=/tmp/factory.bin bs=1 seek=24576 conv=notrunc 2>/dev/null
ubimkvol /dev/ubi0 -N factory -s 28672
vol=$(ubinfo -a /dev/ubi0 | awk '/^Volume ID:/{id=$3} /Name:.*factory/{print "/dev/ubi0_"id; exit}')
ubiupdatevol "$vol" /tmp/factory.bin
rm -f /tmp/factory.bin

# 尝试重新绑定网卡/Switch 驱动
echo airoha_en7581_eth > /sys/bus/platform/drivers/airoha_en7581_eth/bind 2>/dev/null || true
echo 1fb58000.switch > /sys/bus/platform/drivers/mt7530-mmio/bind 2>/dev/null || true
```

如果网络恢复，就可以用 scp 传 sysupgrade；如果没恢复，继续用 TFTP 或 U 盘。

### 7.4 刷回 OpenWrt

把 sysupgrade.itb 放到 `/tmp`，执行：

```bash
sysupgrade -F -n /tmp/openwrt-...-sysupgrade.itb
```

这个操作会同时把 chainloader FIT 重新写回 `0x8600000`。

### 7.5 首次启动后保存 chainloader 环境

刷完第一次启动会进入新的 mainline U-Boot：`AN7581>`。

```bash
AN7581> saveenv
AN7581> reset
```

之后应该能正常进 OpenWrt。

### 7.6 恢复配置

进 OpenWrt 后恢复之前的配置：

```bash
tar xzf openwrt_config_etc.tar.gz -C /
```

## 8. 常见问题

### Q1：刷 stock 后启动报 `Wrong Image Format for bootm command`

A：bootcmd 错了。改成：

```bash
ECNT> setenv bootcmd 'flash imgread 2048; bootm'
ECNT> setenv fw_port 0
ECNT> saveenv
```

### Q2：Recovery 里 `ip a` 没有 eth 接口

A：factory volume 没建或没内容。按 7.3 重建。

### Q3：回 OpenWrt 后重启又回 `ECNT>` 或 `AN7581>`

A：chainloader 没恢复。确保 sysupgrade.itb 是完整固件，或者手动在 `ECNT>` 下把
`chainload-uboot.itb` 写到 `0x8600000` 并设 bootcmd：

```bash
ECNT> setenv loadaddr 0x88000000
ECNT> tftpboot chainload-uboot.itb
ECNT> flash erase 0x8600000 0x50000
ECNT> flash write 0x8600000 $filesize 0x88000000
ECNT> setenv bootcmd 'flash read 0x8600000 0x50000 0x81800000; bootm 0x81800000'
ECNT> saveenv
```

## 9. 分区布局速查

| 分区 | 偏移 | 大小 | 内容 | 刷 stock 影响 |
|---|---|---|---|---|
| mtd0 bootloader | 0x000000 | 0x200000 | 厂商 U-Boot | 不动 |
| mtd1 uenv | 0x200000 | 0x200000 | U-Boot 环境 | 不动 |
| mtd2 dsd | 0x400000 | 0x200000 | MAC/出厂数据 | 不动 |
| mtd3 ubi | 0x600000 | 0x8000000 | OpenWrt / stock 固件 | 被覆盖 |
| mtd4 system | 0x8600000 | — | chainloader FIT | 被 stock 破坏 |

## 10. 相关文件

- `docs/xg2010g-porting.md` — 端口/PHY/SerDes 拓扑和已知问题总览。
- `docs/xg2010g-serdes-dump.sh` — stock 下抓取 SerDes 调试信息的脚本。
- `backups/xg2010g-pre-stock/RESTORE.md` — 备份与恢复参考。
