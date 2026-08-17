# XG2010G U-Boot 是否加密 / 能否直接引导 结论

## 1. U-Boot 没有加密

从路由器 `mtd0`（厂商 bootloader 分区）导出并分析后，结论如下：

|检查项|结果|说明|
|---|---|---|
|文件大小|2,097,152 字节|与 DTS 中 `bootloader` 分区 2 MiB 一致|
|`file` 类型|`data`|不是压缩包，但包含代码/证书|
|字符串|大量可读|能看到 `U-Boot` 构建时间、`LZMA: ...`、`ERROR:/NOTICE:/WARNING:` 等|
|熵值（前 1MB）|**3.858 bits/byte**|远低于加密数据（约 7.9+）|
|熵值（完整 2MB）|**2.184 bits/byte**|代码+数据混合的正常范围|
|hexdump 开头|`00 f0 20 e3 ...`|标准 ARM32 机器码，可直接执行|

### 关键字符串摘录

```text
Built : 17:48:20, Sep  5 2023
v2.3():V7_3_283_1450_verify_20230710_v042-5-g9445764-dirty
Failed to decompress image (err=%d)
LZMA: Image address............... 0x%lx
...
Trusted Boot FW Certificate
Trusted Key Certificate
SoC Firmware Key Certificate
Non-Trusted Firmware Key Certificate
SoC Firmware Content Certificate
Non-Trusted Firmware Content Certificate
```

这些 `Trusted ... Certificate` 字符串说明 `mtd0` 中包含 **ARM Trusted Firmware 的 X.509 证书链**，用于启动时验证 `BL2` / `BL31` / `U-Boot` 等固件的签名。这是 **Secure Boot/可信启动** 的签名机制，**不是加密**。

## 2. 为什么链式引导仍然是最现实方案

当前实现：

```text
厂商 U-Boot (mtd0)
  └─ bootm chainload-uboot.itb
      └─ 主线 U-Boot
          └─ bootm openwrt-...-recovery/sysupgrade.itb
```

### 不能直接引导的原因

#### 2.1 厂商 U-Boot 的 `bootm` 无法直接启动现代 ARM64 FIT

- 厂商 U-Boot 是 **U-Boot 2014.04-rc1 "AXON 1.7"**
- 直接 `bootm` 一个标准 ARM64 Linux FIT 会**复位**
- 主线 U-Boot 被包成 FIT 后，厂商 `bootm` 可以把它当作一个独立的 kernel 类型 FIT 加载并跳转

#### 2.2 `mtd0` 有 ARM Trusted Firmware 签名验证

- boot ROM / BL1 会校验 `BL2` / `BL31` / `U-Boot` 的签名
- 要直接替换 `mtd0` 里的厂商 U-Boot，需要：
  1. 编译完整的 `preloader (BL2) + BL31 + U-Boot FIP`
  2. 用**厂商私钥**对新的 BL2/BL31 签名，或关闭 secure boot（eFuse/debug 模式，风险高且不一定可行）
  3. 写回 `mtd0`，一旦签名不匹配或偏移错误就会变砖

### 各方案对比

|方案|是否可行|风险|建议|
|---|---|---|---|
|**链式引导（当前）**|已验证|低|推荐继续使用|
|厂商 `bootm` 直接启动 OpenWrt|不可行|低|老 U-Boot 不支持 ARM64 FIT|
|用 `go` 跳 `u-boot.bin`|不确定|中|主线 U-Boot 依赖 BL2/BL31 已完成初始化|
|替换 `mtd0` 为完整主线链|需私钥/关验证|**高（可能变砖）**|不推荐|

## 3. 结论

1. **XG2010G 的 U-Boot 没有加密**。`mtd0` 是明文代码，只是嵌入了 ATF 启动签名证书。
2. **不能直接引导**到 OpenWrt 或主线 U-Boot，除非有办法通过/绕过 ATF 的签名验证。
3. 现有 **“修改 `bootcmd` + 链式 U-Boot 引导”** 是安全、可用、推荐的方式。
