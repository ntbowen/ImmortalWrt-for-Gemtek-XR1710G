# XG2010G 刷 stock 前的备份（2026-08-10）

刷 stock（image.ub）前的完整备份。

> ⚠️ **实测发现**：stock 刷机写入范围会覆盖/破坏 OpenWrt 的 UBI 区（mtd3），
> 并会连带破坏位于 `0x8600000`（mtd4/system）的 chainloader FIT。刷 stock 后回
> OpenWrt 不是简单改 bootcmd 即可，必须重新走 recovery + sysupgrade 恢复 UBI、
> factory volume 和 chainloader。

## 备份内容

| 文件 | 来源 | 说明 |
|---|---|---|
| `vendor_uenv_mtd1.bin` | `cat /dev/mtd1` | 厂商 U-Boot env 原始分区（含 CRC + bootcmd） |
| `chainloader_ubootenv.txt` | `fw_printenv` | 链式 mainline U-Boot 的 UBI env（刷 stock 会被清） |
| `openwrt_config_etc.tar.gz` | `tar czf ... /etc/config` | OpenWrt 网络/系统配置 |
| `dsd_mtd2.bin` | `cat /dev/mtd2` | 出厂数据（MAC 地址等），本次刷机不动 |
| `art_mtd5.bin` | `cat /dev/mtd5` | 校准数据，本次刷机不动 |

## 关键信息

- 链式 mainline U-Boot 在 **mtd4/system 分区（flash 0x8600000）**，作为 OpenWrt 固件
  镜像的一部分；sysupgrade 会重写它，**stock 刷机也会破坏它**。
- 当前厂商 U-Boot bootcmd（刷 stock 前/后恢复 OpenWrt 时用来启动 chainloader）：
  ```
  flash read 0x8600000 0x50000 0x81800000; bootm 0x81800000
  ```
- 当前厂商 env 里 `serdes_ethernet=411`（光口模式）。教程要求刷 stock 时改成 `421`（网口模式）。
- chainloader TFTP 相关 env：`ipaddr=192.168.0.1`、`serverip=192.168.0.205`（与刷机教程的 PC IP 一致）。
- recovery 阶段网络需要 UBI 里的 `factory` volume 提供 MAC 地址；stock 破坏 UBI
  后必须先重建 `factory`，否则 `airoha_eth`/`switch` 起不来。

## 回到 OpenWrt 的步骤（stock 刷机后）

stock 刷机会破坏 OpenWrt 的 UBI 区（mtd3）和 chainloader（mtd4/0x8600000），
因此回 OpenWrt 必须重新走 recovery + sysupgrade。

### 1. 在厂商 U-Boot 里直接启动 recovery（chainloader 已坏，不依赖它）

```
ECNT> setenv loadaddr 0x88000000
ECNT> tftpboot                       # PC 端 put recovery.itb 为 image.ub
ECNT> iminfo 0x88000000              # 确认 FIT 完整
ECNT> bootm 0x88000000             # 直接启动 recovery initramfs
```

### 2. 在 recovery 里修复 UBI 并重建 factory volume

recovery 起来后可能没有网络（因为 UBI 里没有 factory），在串口里执行：

```sh
# 重建 mtd3 上的 UBI
ubiformat /dev/mtd3 -y
ubiattach -m 3

# 按 85_xg2010g_factory 的逻辑从 dsd（mtdblock2）重建 factory volume
wan=$(strings /dev/mtdblock2 | sed -n 's/^wan_mac=//p')
lan=$(strings /dev/mtdblock2 | sed -n 's/^lan_mac=//p')
hex2bin() { for b in $(echo "$1" | tr ':' ' '); do printf "\\$(printf '%03o' 0x$b)"; done; }
dd if=/dev/zero of=/tmp/factory.bin bs=1024 count=28 2>/dev/null
hex2bin "$wan" | dd of=/tmp/factory.bin bs=1 seek=20480 conv=notrunc 2>/dev/null
hex2bin "$lan" | dd of=/tmp/factory.bin bs=1 seek=24576 conv=notrunc 2>/dev/null
ubimkvol /dev/ubi0 -N factory -s 28672
vol=$(ubinfo -a /dev/ubi0 | awk '/^Volume ID:/{id=$3} /Name:.*factory/{print "/dev/ubi0_"id; exit}')
ubiupdatevol "$vol" /tmp/factory.bin
rm -f /tmp/factory.bin

# 强制重新 probe 网卡，恢复网络
echo airoha_en7581_eth > /sys/bus/platform/drivers/airoha_en7581_eth/bind 2>/dev/null || true
echo 1fb58000.switch > /sys/bus/platform/drivers/mt7530-mmio/bind 2>/dev/null || true
```

### 3. 刷回 OpenWrt（同时恢复 chainloader）

```sh
sysupgrade -F -n /tmp/openwrt-...-sysupgrade.itb
```

`sysupgrade.itb` 包含 chainloader，写入后会恢复 `0x8600000` 的 chainloader。

### 4. 首次启动后重建 chainloader 环境变量

刷完第一次启动会进入 `AN7581>` 新 U-Boot，执行：

```
AN7581> saveenv
```

保存后重启即可正常走 OpenWrt。

### 5. 恢复 OpenWrt 配置

如需恢复之前的网络配置：

```sh
tar xzf openwrt_config_etc.tar.gz -C /
```

## 备选：整块回写厂商 env

不推荐首选（怕坏块重映射），但如果 env 乱了可以用：
```sh
# 在 OpenWrt recovery 里
mtd write vendor_uenv_mtd1.bin uenv
```
