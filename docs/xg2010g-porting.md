# Gemtek XG2010G (Airoha AN7581) 移植技术参考

> 本文档整理自 XG2010G 的实际 bring-up 过程，所有结论都在真机上验证过。
> 用于后续在其它项目/板子上移植 AN7581 或该平台时作技术依据。
> 适用源码：`ImmortalWrt-for-Gemtek-XR1710G`（`target/linux/airoha`，kernel 6.18）。

---

## 1. 硬件概览

| 项 | 规格 |
| --- | --- |
| SoC | Airoha AN7581（ARM64，4× Cortex-A53，最高 1.2GHz） |
| 内存 | 1 GiB DDR4 |
| Flash | Winbond W25N04K SPI-NAND，512 MiB（128 KiB block / 2048 B page） |
| PON | EN7573AN（XGSPON 光模块接口） |
| 以太网 PHY | 2× RTL8261N（10G）+ 1× EN8811HN（2.5G）+ SoC 内部 1G |
| WiFi | **无**（XG2010G 不装无线，两条 PCIe SerDes 空闲） |
| 厂商 Bootloader | U-Boot 2014.04-rc1 "AXON 1.7"（有 ARM64 FIT bootm bug，见 §3） |

### 面板口 ↔ PHY ↔ 速率（实测确认）

| 面板口 | 速率 | PHY 型号 | MDIO 地址 | reset GPIO |
| --- | --- | --- | --- | --- |
| LAN1 | 10G | RTL8261N #1 | 5 | 29 (active low) |
| LAN2 | 10G | RTL8261N #2 | 8 | 27 (active low) |
| LAN3 | 2.5G | EN8811HN | 15 (0xf) | 无（自生复位） |
| LAN4 | 1G | SoC 内部 switch 口 | 12 (0xc) | — |
| PON | 10G | EN7573AN 光模块 | — | — |

两颗 RTL8261N 都是 Clause-45 PHY，PHY ID `0x1ccaf3`；EN8811HN 走固件下载（MD32）。

---

## 2. 网络拓扑：GDM / SerDes / 仲裁器（核心）

### 2.1 AN7581 有 4 个 GDM（GMAC）

来自 `airoha_eth` 驱动（`AIROHA_GDM1..4_IDX`）。每个 GDM 接 Frame Engine（FE），
前端可接不同的 SerDes。**dtsi 里默认只有 gdm1/gdm2/gdm4，没有 gdm3**（gdm3 要板级自己加）。

| GDM | 可接的 SerDes 源 | 用途 |
| --- | --- | --- |
| GDM1 | 内部 GSW（switch） | 固定，无 SerDes |
| GDM2 | `pon_pcs`（XFI SerDes） | PON / WAN |
| GDM3 | **PCIe0 / PCIe1**（经 XSI 仲裁器） | 复用 PCIe SerDes 作以太网 |
| GDM4 | **ETH（`eth_pcs`）/ USB**（经 XSI 仲裁器） | 主以太网 SerDes + USB SerDes |

> 注意：`get_sport()` 的 nbq 映射——**GDM3**: nbq4→PCIe0、nbq5→PCIe1；
> **GDM4**: nbq0→ETH、nbq1→USB。一个 GDM 可通过仲裁器挂 2 个 net_device。

### 2.2 XG2010G 的 GDM 分配

```text
PON (EN7573AN)   ── pon_pcs(XFI)                ──► GDM2  → wan
LAN1 phy5(10G)   ── eth_pcs(XSI_ETH) ──┐
                                        ├─ XSI arbiter ► GDM4 → lan1 + lan3
LAN3 en8811(2.5G)── USB1 SerDes(HSGMII)─┘                (两个 netdev)
LAN2 phy8(10G)   ── PCIe1 SerDes(USXGMII)── XSI arbiter ► GDM3 → lan2
LAN4 (内部 1G)   ── 内部 GSW port4 ────────────────────► GDM1  → lan4
```

### 2.3 PCIe SerDes 复用为以太网（无 WiFi 时）

XG2010G 没有 WiFi，PCIe/USB SerDes 空闲，可复用为以太网。SerDes 路由已由厂商
`sys serdes` 工具（见 §7.4）确认：phy8/LAN2 走 PCIe1(USXGMII)、en8811/LAN3 走
USB1(HSGMII)。关键事实：

- **PCIe SerDes 跑以太网最高支持 USXGMII（10G）**——实测 phy8 用 10G 对端能 link 到 10G。
  （曾经误判"只能 2.5G/HSGMII"，那是因为把 lane 接错了，不是模式问题。）
- 模式由 SCU 的 `SSTR` 寄存器选择（见 §2.5）。
- DT 绑定：GDM 节点下挂 `compatible = "airoha,eth-port"` 子节点，每个子节点一个
  `reg = <nbq>`，各自带 `phy-handle` / `phy-mode` / `pcs-handle` / `nvmem-cells` /
  `openwrt,netdev-name`。**这正是 `airoha_eth` 的"单 GDM 多 net_device"特性**
  （补丁 `165-02-net-airoha-Support-multiple-net_devices-for-a-single`）。

参考配置（`an7581-xg2010g-ubi.dts`）：

```dts
&pcie_pcs { status = "okay"; };      // phy8/LAN2 用 PCIe1 SerDes
&usb_pcs  { status = "okay"; };      // en8811/LAN3 用 USB1 SerDes
&pciephy  { status = "disabled"; };  // 见 §6.2 的冲突

&eth {
    status = "okay";

    /* GDM3: PCIe1 SerDes → phy8 (LAN2) */
    gdm3: ethernet@3 {
        compatible = "airoha,eth-mac";
        reg = <3>;
        #address-cells = <1>;
        #size-cells = <0>;

        eth-port@5 {                 /* nbq=5 → PCIe1 */
            compatible = "airoha,eth-port";
            reg = <5>;
            managed = "in-band-status";
            phy-handle = <&phy8>;
            phy-mode = "usxgmii";
            pcs-handle = <&pcie_pcs 1>;
            openwrt,netdev-name = "lan2";
            ...
        };
    };

    /* GDM4: ETH SerDes → phy5 (LAN1)，USB1 SerDes → en8811 (LAN3) */
    gdm4: ethernet@4 {
        compatible = "airoha,eth-mac";
        reg = <4>;
        #address-cells = <1>;
        #size-cells = <0>;

        eth-port@0 {                 /* nbq=0 → ETH */
            compatible = "airoha,eth-port";
            reg = <0>;
            managed = "in-band-status";
            phy-handle = <&phy5>;
            phy-mode = "usxgmii";
            pcs-handle = <&eth_pcs>;
            openwrt,netdev-name = "lan1";
            ...
        };
        eth-port@1 {                 /* nbq=1 → USB1 */
            compatible = "airoha,eth-port";
            reg = <1>;
            phy-handle = <&en8811>;
            phy-mode = "2500base-x";
            pcs-handle = <&usb_pcs>;
            openwrt,netdev-name = "lan3";
            ...
        };
    };
};
```

### 2.4 内部 switch（mt7530-mmio / `airoha,en7581-switch`）

- 用 `mt7988_setup`，**只有 4 个内部 1G PHY 口（MDIO 9-12）+ CPU 口（port 6，10G 到 GDM1）**。
- **没有 SerDes 扩展口**——所以 LAN2/LAN3 这种高速外置 PHY **不能走 switch**，
  只能走 XSI 仲裁器（§2.3）。这是早期的一个错误判断，已纠正。
- XG2010G 只把 switch 的 port4（`gsw_phy4`，MDIO 12）接到了面板 LAN4。

### 2.5 SCU `SSTR` 寄存器（SerDes 模式选择）

- 基址：`scuclk`（clock-controller @ `0x1fb00000`），**SSTR 偏移 0x9c → 地址 `0x1fb0009c`**。
  ⚠️ 注意是 `scuclk`（0x1fb00000），不是 `chip_scu`（syscon @ 0x1fa20000），别读错地址。

| 位域 | 含义 | 取值 |
| --- | --- | --- |
| bits[14:13] `PCIE_XSI0_SEL` | PCIe0 lane 模式 | 1=USXGMII, 2=HSGMII |
| bits[12:11] `PCIE_XSI1_SEL` | PCIe1 lane 模式 | 1=USXGMII, 2=HSGMII |
| bits[10:9]  `PON_XSI_SEL` | PON lane 模式 | 1=USXGMII, 2=HSGMII |
| bit[24] `ETH_MAC_SEL` | ETH MAC | 0=XFI, 1=PON |

`pcs-airoha` 驱动在配置链路时自动写 SSTR（`an7581_pcs_setup_scu_pcie`）。
`phy-mode=2500base-x` → HSGMII；`usxgmii`/`10gbase-r` → USXGMII。

---

## 3. 启动流程：chainloader

厂商 U-Boot（2014.04 AXON 1.7）**bootm 无法直接加载现代 ARM64 Linux FIT**（会复位）。
解决：用 mainline U-Boot 作 chainloader，包成 FIT 让厂商 bootm 加载跳转。

```text
厂商 U-Boot (0x0)
   │  bootcmd: flash read 0x8600000 0x50000 0x81800000; bootm 0x81800000
   ▼
chainloader mainline U-Boot 2026.07（在 system 分区 0x8600000）
   │  bootcmd: run boot_ubi  →  ubi read fit → bootm
   ▼
OpenWrt（UBI fit volume）
```

- chainloader 的 env 存 UBI（`ubootenv`/`ubootenv2` 冗余 volume，`CONFIG_ENV_IS_IN_UBI`）。
- **chainloader 里 `No ethernet found.`**——它的网口驱动没起来，不能用 TFTP。
  TFTP 恢复要用**厂商 U-Boot**（它有网，recovery 网口是 EN8811H）。

### Flash 布局（SPI-NAND）

| MTD | 名称 | 偏移 | 大小 | 内容 |
| --- | --- | --- | --- | --- |
| mtd0 | bootloader | 0x0 | 2 MiB | 厂商 U-Boot |
| mtd1 | uenv | 0x200000 | 2 MiB | 厂商 U-Boot env（**非标准 CRC**，fw_printenv 读不了） |
| mtd2 | dsd | 0x400000 | 2 MiB | 出厂数据（MAC 地址，据此生成 factory volume） |
| mtd3 | ubi | 0x600000 | 128 MiB | OpenWrt UBI（fit/factory/ubootenv/ubootenv2/rootfs_data） |
| mtd4 | system | 0x8600000 | 311 MiB | chainloader |
| mtd5 | art | 0x1bd00000 | 3 MiB | 校准数据 |

---

## 4. LED 控制（两种控制源）

### 4.1 A 类：GPIO 灯（内核 LED 框架，`/sys/class/leds` 可见，`01_leds` 可控）

厂商 stock 认出的 GPIO 灯：

| 厂商 label | 含义 |
| --- | --- |
| `sts_red` / `sts_green` / `sts_blue` / `sts_white` | 主机状态灯（多色） |
| `pon_act_green` / `pon_lnk_green` / `pon_lnk_red` | PON 状态灯 |
| `lan_led_green` / `lan_led_yellow` | 单个 LAN 指示灯 |
| `phy_tx_power_disable` | PHY 电源控制 |

- 厂商 GPIO 分**两个 bank**（`gpio@1fbf0200`、`gpio@1fbf0270`，`airoha,en7523-gpio`）。
- stock 里 `sts_green` 挂在 `timer` 触发器上（所以 1 秒一闪）；我们想要的话在 `01_leds`
  设成 default 常亮。
- 状态灯的"运行中常亮"由 DTS alias（`led-boot`/`led-running`/...）+ `01_leds` 决定。

### 4.2 B 类：每口独立的 LAN 绿/黄灯 —— **PHY 硬件驱动**

每个 RJ45 口的绿/黄灯（插线亮、随速率/活动变化）由**各口 PHY 的 LED 控制器**直接驱动，
**不在 `/sys/class/leds`**，软件要配的是 PHY 的 LED 模式寄存器（哪个 LED=link/act/速率）：

| 口 | PHY | 驱动 | LED 可控性 |
| --- | --- | --- | --- |
| LAN1/LAN2 | RTL8261N | `realtek`（厂商驱动 realtek_main.c + phy_patch_rtl826x.c） | 有 LED 寄存器，需直接写/补驱动 |
| LAN3 | EN8811HN | `air_en8811h` | 完整 hw_control（`air_led_hw_control_set`），支持 link/act 硬件自动 |
| LAN4 | 内部 GSW PHY | `mtk-ge-soc` | 完整支持（`mt798x_phy_led_*`），可走内核 PHY-LED 框架 |

> 厂商 stock 没配这些 PHY 的 LED，用的是出厂默认值，所以看起来"乱"。
> 修正方向：GSW PHY / EN8811H 用 DTS `leds` 子节点 + 内核 PHY-LED 框架配 link/act；
> RTL8261N 需查厂商 realtek 驱动的 LED 寄存器。

---

## 5. NPU（硬件加速引擎）

- dtsi 里 `npu@1e900000` 默认 `status = "disabled"`。
- 启用：板级 DTS `&npu { status="okay"; firmware-name="airoha/en7581_npu_rv32.bin","airoha/en7581_npu_data.bin"; }`
  并加 package `airoha-en7581-npu-firmware`（generic 固件，无 WiFi 时用，**不要**用 MT7996 版本）。
- 驱动 `CONFIG_NET_AIROHA_NPU=y`（内置）。起来后 8 个 RISC-V 核，dmesg 报 `NPU fw version`。
- `luci-app-airoha-npu` 的 GDM/CDM 拓扑标签是按板型硬编码的，移植新板要在
  `status.js` 的 `getPortLabels(board)` 里加映射。

---

## 6. 移植过程踩过的坑（都已修复，有 commit）

### 6.1 phylink fwnode_pcs notifier 泄漏 → kernel panic

OpenWrt 的 `737-05-net-phylink-support-late-PCS-provider-attach.patch` 给
`phylink_create` 注册了 `fwnode_pcs_nb` notifier，但 `phylink_destroy` **没注销**。
驱动在 `-EPROBE_DEFER` 错误路径销毁 phylink 时泄漏 notifier → 重试时遍历悬空链表 panic。
**修复**：`999-net-phylink-unregister-fwnode-pcs-notifier-on-destroy.patch`
（新增 `unregister_fwnode_pcs_notifier` 并在 `phylink_destroy` 调用）。
⚠️ 这是通用 bug，应回填到 generic 的 737-05 / 上游。

### 6.2 pciephy 与 pcie_pcs 寄存器冲突

`pciephy`（`airoha,en7581-pcie-phy`，dtsi 默认启用）用独占 `devm_platform_ioremap_resource`
占住 PMA 区（0x1fa5b000 等），与 `pcie_pcs` 冲突 → pcie_pcs probe `-EBUSY`。
**PCIe SerDes 复用以太网时必须 `&pciephy { status = "disabled"; }`**。
pcie-phy 只做 PCIe 专用模拟校准，pcs 驱动自己做以太网 SerDes PLL 上电，不依赖它。

### 6.3 其它已修复

- PHY LED pinctrl 报错：无 `gbe-led` pinctrl state 时 `-ENODEV` 不该报错（改为只在真失败时告警）。
- `config_generate` CRLF → shebang 解析失败。
- factory volume 从 `dsd` 分区自动生成（preinit `85_xg2010g_factory`）。
- `fw_env.config` → 指向 UBI 的 `ubootenv`/`ubootenv2`。

---

## 7. 调试方法（移植时可复用）

### 7.1 MDIO 探测 PHY 是否在线

在 switch 的 `mdio` 节点里临时加 `ethernet-phy@N` 子节点（不接端口），重编译刷机后：

```sh
ls /sys/bus/mdio_bus/devices/      # 多出 mt7530-0:NN 即在线
dmesg | grep -iE "rtl8261|en8811"  # 看驱动绑定/固件版本
```

> C45 PHY 的 `/sys/.../phy_id` 读出来是 0（它读的是 C22 寄存器），以 dmesg 驱动绑定为准。

### 7.2 读硬件寄存器

- OpenWrt：`devmem 0x<addr> 32`（或用带超时保护的封装，防止 devmem 在 D-state 卡死）。
- 厂商 U-Boot：`md.l 0x<addr> <n>`（无 STRICT_DEVMEM 限制）。
- stock Linux 开了 STRICT_DEVMEM，`/dev/mem` 读不了 MMIO；可交叉编译静态工具传进去
  （但本板 `/dev/mem` mmap 仍被挡，所以用 U-Boot 的 `md` 更可靠）。

### 7.3 刷机 / recovery

- **刷 stock**：厂商 U-Boot TFTP 收 image.ub → `flash erase/write 0x600000 0x4000000` →
  改 bootcmd 直读 stock（`flash read 0x602100 ...; bootm`）。
- **回 OpenWrt**：厂商 U-Boot TFTP 加载 recovery initramfs 到 RAM → 读 chainloader 到 RAM →
  跳 chainloader → 打断 autoboot → 从 RAM 启动 recovery → `sysupgrade -F -n` 刷 sysupgrade.itb。
- 刷机前备份：厂商 env（`cat /dev/mtd1`）、chainloader env（`fw_printenv`）、`/etc/config`、
  `dsd`/`art` 分区。参考 `backups/xg2010g-pre-stock/RESTORE.md`。

> ⚠️ 两个实测过的坑：
> 1. **刷 stock 会覆盖 UBI 区（mtd3）**。stock 的 UBI 会顶掉 chainloader 所在的
>    `0x8600000`（md 读出来是 `UBI#` magic 而不是 FIT）→ 回 OpenWrt 时要先用厂商
>    U-Boot 把 chainloader 重新 `flash write` 回 `0x8600000`，再 boot recovery。
> 2. **recovery 的网络依赖 UBI 里的 factory volume（存 MAC）**。UBI 被 stock 写坏后
>    recovery 挂不上 UBI → 拿不到 MAC → `airoha_eth`/`switch` 一直 `-EPROBE_DEFER`
>    → 整个网络起不来。救法：recovery 串口里 `ubiformat /dev/mtd3 -y && ubiattach -m 3`
>    重建 UBI，再按 `85_xg2010g_factory` 的逻辑从 `dsd` 重建 factory volume，然后
>    `echo <dev> > /sys/bus/platform/drivers_probe` 强制网卡重新 probe。

### 7.4 厂商固件（stock）作为参考

- stock 是 Tclinux（厂商 OpenWrt fork），专有 `frame_engine` 驱动，接口模型
  （`ae_wan`/`eth0.X`/`br-lan`）与 mainline 完全不同，**不能直接照抄**，但
  dmesg 里的 PHY↔SerDes↔速率 对应关系是金标准。
- 厂商 bootargs 的 `serdes_*`（`serdes_pon/serdes_ethernet/serdes_wifi1/serdes_wifi2/serdes_usb1/serdes_usb2`）
  是它的 SerDes 路由表；`serdes_ethernet=421`=网口、`411`=光口。
- 厂商 U-Boot 用 **EN8811H 做 TFTP 网口**，证明 LAN3 的 SerDes 通路硬件正常。
- **`sys serdes` 工具**（stock 上直接可用，不用 devmem）：`sys serdes` 读当前每条
  SerDes 的模式，`sys serdes -h` 打印完整的 sel/I/F 映射表。配合
  rootfs 里的 `usr/share/gPower/hooks/parseSysSerdes.sh`（映射表）和
  `isSerdesSync.sh`（默认模板），加上 bootargs 的 `serdes_*`，就能**确定性地解码出
  每个面板口走哪条 SerDes、什么模式**，不用再盲猜。XG2010G 解码结果：

  | SerDes 口 | bootarg | 模式 | 接到 |
  | --- | --- | --- | --- |
  | SerDes-PON | `serdes_pon=000` | PON | GDM2（wan） |
  | SerDes-Ethernet | `serdes_ethernet=421` | USXGMII | eth_pcs → phy5（LAN1） |
  | SerDes-WiFi1 | `serdes_wifi1=005` | NONE | PCIe0 空闲 |
  | SerDes-WiFi2 | `serdes_wifi2=413` | USXGMII | PCIe1 → phy8（LAN2） |
  | SerDes-USB1 | `serdes_usb1=111` | HSGMII/an8811 | USB1 → en8811（LAN3） |
  | SerDes-USB2 | `serdes_usb2=000` | USB3 | 空闲 |

- stock 提取的 rootfs 里还有厂商驱动模块（`hsgmii_lan.ko` 等，带符号，源码路径
  `linux-airoha_en7581/hsgmii_lan/`），可反汇编看 SerDes bringup 的寄存器写序。

---

## 8. 移植新板子的检查清单

1. [ ] 确认 Flash 布局（bootloader/uenv/dsd/ubi/system/art 的偏移和大小）。
2. [ ] 确认 chainloader 是否需要（厂商 U-Boot 有无 ARM64 FIT bootm bug）。
3. [ ] 数 PHY：`确定每颗 PHY 的 MDIO 地址、型号、reset GPIO`（先加探测节点验证在线）。
4. [ ] 确认每个面板口走哪个 GDM / 哪条 SerDes（参照 §2.2 的 GDM↔SerDes 能力表）。
5. [ ] 无 WiFi 的板子，PCIe SerDes 可复用为以太网（GDM3/GDM4 + eth-port 子节点）。
6. [ ] PCIe SerDes 复用以太网时：**必须禁用 `pciephy`**（寄存器冲突，§6.2）。
7. [ ] 确认每个口的 `phy-mode`（usxgmii / 2500base-x / internal），模式不对链路起不来。
8. [ ] 每口 LAN 灯是 PHY 驱动，要配 PHY LED 寄存器（§4.2）。
9. [ ] NPU：无 WiFi 用 generic 固件，启用 `&npu`。
10. [ ] phylink notifier 补丁必须带上（§6.1），否则 defer 重试会 panic。
