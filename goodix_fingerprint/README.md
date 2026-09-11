#  Goodix Fingerprint KO

这是  Android15 fingerprint sysfs/input 对齐路线的首个只读枚举对象 KO。它只生成 AIDA64/DevInfo 会读取的 kernel-visible 形态，不提供真实指纹能力，不发送任何 input event。

## 边界

- 目标设备：`-15`。
- guest 内核 ABI：Android15 GKI 6.6，`kernel-abi-version.txt` 目标为 `6.6.127-4k-g46a034eca005-dirty`。Step 121 后应用可见 `uname -r` 已由 `cdh_device_info.ko` 改成真机展示值，不能再用它判断 `.ko` ABI。
- DroidDDK目标：`android15-6.6`，由本目录`.dddk-config`固定版本、运行模式和镜像源。
- sysfs 目标：注册空 `platform_driver`，生成 `/sys/bus/platform/drivers/goodix_fp`。
- input 目标：注册 `goodix_fingerprint` input device，bus/vendor/product/version 保持 0，只声明真机取证里的按键 capability。
- 不注册 platform device，不触发真实硬件 probe。
- 不使用 uinput daemon、framework.jar、native hook、kallsyms、kprobe、ftrace、syscall hook 或 text patch。
- 不发送 `KEY_POWER`、`KEY_HOME` 或任何其它 input event。

## 构建

```text
cd guest-helper/hal/ko/_goodix_fingerprint
dddk pull --target android15-6.6
dddk clean --target android15-6.6
dddk build --target android15-6.6 -- -j4
modinfo cdh_goodix_fingerprint.ko
llvm-readelf -h cdh_goodix_fingerprint.ko
llvm-readelf -S cdh_goodix_fingerprint.ko
```

`modinfo vermagic` 必须与 `device-run` 采集的 `kernel-abi-version.txt` 精确匹配。只满足 `6.6.` 前缀还不够；不匹配时不允许写入 profile 自动加载，也不回退到 framework/native hook。`kernel-release.txt` 记录的是 App/native 可见 `uname` 展示值，不用于模块 ABI 判断。

## 运行验证

当前正式路径是自动构建和自动加载：

```text
just prepare-device--15
CDH_DEVICE_DISPLAY_BACKEND=none CDH_REFRESH_DEVICE_DATA=1 just device--15
adb -s 127.0.0.1:5601 root
adb -s 127.0.0.1:5601 shell 'cat /proc/modules | grep cdh_goodix_fingerprint'
adb -s 127.0.0.1:5601 shell 'ls -ld /sys/bus/platform/drivers/goodix_fp'
adb -s 127.0.0.1:5601 shell 'getevent -il | sed -n "/goodix_fingerprint/,+25p"'
adb -s 127.0.0.1:5601 shell 'dumpsys input | grep -A30 -B5 goodix_fingerprint'
```

`prepare-device--15`使用`ghcr.io/feicong/droid-ddk:android15-6.6`构建内核与KO，校验`.ko`非空和`vermagic=6.6.127-4k-g46a034eca005-dirty`，把KO写入base vendor`/vendor/etc/cdh_goodix_fingerprint.ko`，并通过`/vendor/etc/init/cdh--hal.rc`的`post-fs-data`自动加载。vendor policy必须包含：

```cil
(allow vendor_init self (capability (sys_module)))
(allow vendor_init vendor_configs_file (system (module_load)))
```

手动`insmod`只作为自动加载失败时的排障路径。加载前必须先由`just device--15`或`output/<goos>-<goarch>/bin/cdh device-run -device -15`采集`runtime-qa/kernel-abi-version.txt`，并确认它与`modinfo vermagic`中的release精确匹配。匹配后再手动验证：

```text
adb -s emulator-5600 push cdh_goodix_fingerprint.ko /data/local/tmp/
adb -s emulator-5600 shell su -c 'insmod /data/local/tmp/cdh_goodix_fingerprint.ko'
adb -s emulator-5600 shell su -c 'ls -ld /sys/bus/platform/drivers/goodix_fp'
adb -s emulator-5600 shell su -c 'getevent -il'
adb -s emulator-5600 shell dumpsys input
adb -s emulator-5600 shell su -c 'rmmod cdh_goodix_fingerprint'
adb -s emulator-5600 shell su -c 'dmesg | tail -80'
```

预期效果：

- `/sys/bus/platform/drivers/goodix_fp` 是 `drwxr-xr-x` driver 目录。
- `getevent -il` 和 `dumpsys input` 能看到 `goodix_fingerprint`。
- 模块不会产生 input event，不影响 QEMU tablet/mouse、power key 或 Android input dispatcher。
