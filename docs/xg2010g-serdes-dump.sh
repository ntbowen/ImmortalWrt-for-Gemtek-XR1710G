#!/bin/sh
# xg2010g-serdes-dump.sh
# Run on the stock vendor firmware to capture SerDes/MAC debug state.
# The hsgmii_lan.ko module exposes these /proc/tc3162 nodes and therefore
# this script bypasses /dev/mem STRICT_DEVMEM restrictions.

OUT=/tmp/serdes-dump-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

echo "model: $(cat /proc/device-tree/model 2>/dev/null || echo unknown)" > "$OUT/info.txt"
echo "compatible: $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)" >> "$OUT/info.txt"
echo "cmdline: $(cat /proc/cmdline 2>/dev/null)" >> "$OUT/info.txt"
date >> "$OUT/info.txt"

# Flash layout / MTD
cat /proc/mtd > "$OUT/proc-mtd.txt" 2>/dev/null

# Network status
ip link > "$OUT/ip-link.txt" 2>/dev/null || ifconfig -a > "$OUT/ifconfig.txt"
cat /proc/net/dev > "$OUT/proc-net-dev.txt"

# Vendor sys serdes tool (if present)
for p in /bin/sys /sbin/sys /usr/bin/sys /usr/sbin/sys; do
	if [ -x "$p" ]; then
		echo "--- $p serdes ---" > "$OUT/sys-serdes.txt"
		$p serdes >> "$OUT/sys-serdes.txt" 2>&1
		break
	fi
done

# hsgmii_lan.ko proc nodes
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

# PHY visibility on MDIO bus
if [ -d /sys/bus/mdio_bus/devices ]; then
	ls -l /sys/bus/mdio_bus/devices > "$OUT/mdio-bus-devices.txt"
fi

# Kernel log
dmesg > "$OUT/dmesg.txt" 2>/dev/null

# Package
tar czf "$OUT.tar.gz" -C /tmp "$(basename "$OUT")"
echo "Dump saved to: $OUT.tar.gz"
