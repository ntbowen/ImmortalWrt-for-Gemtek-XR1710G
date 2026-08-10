#!/bin/sh
# xg2010g-serdes-dump-v2.sh
# Extended stock firmware dump for XG2010G SerDes/PCS reverse engineering.
# Collects proc debug, module info, kernel config, and attempts raw MMIO reads.

OUT=/tmp/serdes-dump-v2-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

echo "model: $(cat /proc/device-tree/model 2>/dev/null || echo unknown)" > "$OUT/info.txt"
echo "compatible: $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)" >> "$OUT/info.txt"
echo "cmdline: $(cat /proc/cmdline 2>/dev/null)" >> "$OUT/info.txt"
date >> "$OUT/info.txt"

# ---------------------------------------------------------------
# 1. Proc nodes
# ---------------------------------------------------------------
PROCS="
/proc/tc3162/hsgmii_pcie0_mac_dbg
/proc/tc3162/hsgmii_pcie0_lan_link_status
/proc/tc3162/hsgmii_pcie1_mac_dbg
/proc/tc3162/hsgmii_pcie1_lan_link_status
/proc/tc3162/hsgmii_usb_mac_dbg
/proc/tc3162/hsgmii_usb_lan_link_status
/proc/tc3162/hsgmii_eth_mac_dbg
/proc/tc3162/hsgmii_eth_lan_link_status
/proc/tc3162/hsgmii_force_dstq_mode
/proc/tc3162/hsgmii_lan_ratelimit
/proc/tc3162/hsgmii_lan_use_unify_eth_name
/proc/tc3162/hsgmii_idx
"
for f in $PROCS; do
	b=$(basename "$f")
	if [ -r "$f" ]; then
		echo "=== $f ===" > "$OUT/$b.txt"
		cat "$f" >> "$OUT/$b.txt" 2>&1
	else
		echo "MISSING: $f" >> "$OUT/missing-proc.txt"
	fi
done

ls -la /proc/tc3162/ > "$OUT/proc-tc3162-list.txt" 2>/dev/null

# ---------------------------------------------------------------
# 2. Network / PHY / modules
# ---------------------------------------------------------------
ip link > "$OUT/ip-link.txt" 2>/dev/null || ifconfig -a > "$OUT/ifconfig.txt"
cat /proc/net/dev > "$OUT/proc-net-dev.txt"
if [ -d /sys/bus/mdio_bus/devices ]; then
	ls -l /sys/bus/mdio_bus/devices > "$OUT/mdio-bus-devices.txt"
fi
lsmod > "$OUT/lsmod.txt" 2>/dev/null
cat /proc/modules > "$OUT/proc-modules.txt" 2>/dev/null

# ---------------------------------------------------------------
# 3. Vendor tools
# ---------------------------------------------------------------
for p in /bin/sys /sbin/sys /usr/bin/sys /usr/sbin/sys; do
	if [ -x "$p" ]; then
		echo "--- $p serdes ---" > "$OUT/sys-serdes.txt"
		$p serdes >> "$OUT/sys-serdes.txt" 2>&1
		echo "--- $p serdes -h ---" >> "$OUT/sys-serdes.txt"
		$p serdes -h >> "$OUT/sys-serdes.txt" 2>&1
		break
	fi
done

# ---------------------------------------------------------------
# 4. Kernel config / capability checks
# ---------------------------------------------------------------
if [ -f /proc/config.gz ]; then
	zcat /proc/config.gz | grep -E "CONFIG_STRICT_DEVMEM|CONFIG_MODULES|CONFIG_DEBUG_FS" \
		> "$OUT/kernel-config.txt" 2>/dev/null
fi

cat /proc/version > "$OUT/proc-version.txt"

# ---------------------------------------------------------------
# 5. debugfs / sysfs inventory
# ---------------------------------------------------------------
ls -la /sys/kernel/debug/ > "$OUT/debugfs-list.txt" 2>/dev/null || true
find /sys/kernel/debug -maxdepth 3 -type f -name "*serdes*" -o -name "*pcs*" -o -name "*hsgmii*" -o -name "*xsgmii*" \
	> "$OUT/debugfs-serdes.txt" 2>/dev/null || true

# ---------------------------------------------------------------
# 6. Symbol addresses (for later kernel module or reverse engineering)
# ---------------------------------------------------------------
cat /proc/kallsyms | grep -iE "xsgmii|hsgmii|serdes|pcs" > "$OUT/kallsyms-serdes.txt" 2>/dev/null || true

# ---------------------------------------------------------------
# 7. Attempt raw MMIO reads (may fail due to STRICT_DEVMEM)
# ---------------------------------------------------------------
# Vendor hsgmii_lan.ko HSGMII_BASE_REG values (from .data):
#   [0]=0xbfa04000 [1]=0xbfa05000 [2]=0xbfa07000 [3]=0xbfa08000 [4]=0xbfa09000
# Mainline DTS usb_pcs:
#   pcs_mac=0x1fa07000 pcs_ana=0x1fa9a000
BASES="
0xbfa04000
0xbfa05000
0xbfa07000
0xbfa08000
0xbfa09000
0x1fa07000
0x1fa90000
0x1fa90a00
0x1fa94000
0x1fa96000
0x1fa9a000
"
for a in $BASES; do
	echo "--- devmem $a ---" >> "$OUT/devmem.txt"
	devmem "$a" 32 >> "$OUT/devmem.txt" 2>&1 || true
done

# ---------------------------------------------------------------
# 8. Kernel log
# ---------------------------------------------------------------
dmesg > "$OUT/dmesg.txt" 2>/dev/null

# ---------------------------------------------------------------
# Package
# ---------------------------------------------------------------
tar czf "$OUT.tar.gz" -C /tmp "$(basename "$OUT")"
echo "Dump saved to: $OUT.tar.gz"
