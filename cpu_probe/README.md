#  CPU Probe KO

这是 Android15 CPU`/proc`/sysfs对齐路线的第一个只读KO原型。它只验证DroidDDK构建、模块加载、只读proc/sysfs输出和卸载清理，不减少AIDA64/DevInfo CPU stable差异。

## 边界

- 目标设备：`-15`。
- guest 内核 ABI：必须是 Android 15 GKI 6.6，`kernel-abi-version.txt` 目标为 `6.6.127-4k-g46a034eca005-dirty`。Step 121 后应用可见 `uname -r` 已由 `cdh_device_info.ko` 改成真机展示值，不能再用它判断 `.ko` ABI。
- DroidDDK目标：`android15-6.6`。历史取证中的`6.12.23-4k-gafb0ad713e3c`说明当时`base15`误用了6.12基线，不允许改用`android16-6.12`继续加载-15 KO。
- 只创建 `/proc/cdh_cpu_profile` 和 `/sys/kernel/cdh_cpu/*`。
- 不修改 `/proc/cpuinfo`，不修改 `/sys/devices/system/cpu`，不注册 cpufreq policy。
- 不使用 kallsyms、kprobe、ftrace、syscall hook 或 text patch。

## 构建

macOS上优先使用Lima Docker后端；`.devcontainer/lima-cdh-kvm.yaml`会自动注册amd64 binfmt，并预取验证：

```text
docker run --privileged --rm tonistiigi/binfmt --install amd64
docker run --rm ghcr.io/feicong/droid-ddk:android15-6.6 uname -m
docker run --rm ghcr.io/feicong/droid-ddk:android16-6.12 uname -m
```

Android15常规GKI 6.6 KO使用`ghcr.io/feicong/droid-ddk:android15-6.6`，Android16/6.12使用`ghcr.io/feicong/droid-ddk:android16-6.12`。-15固定走Android15 GKI 6.6，`.dddk-config`同时固定版本、运行模式和镜像源；默认不传平台参数，由`dddk`按宿主选择：

```text
cd guest-helper/hal/ko/_cpu_probe
dddk pull --target android15-6.6
dddk clean --target android15-6.6
dddk build --target android15-6.6
```

构建后必须检查：

```text
modinfo cdh_cpu_probe.ko
llvm-readelf -h cdh_cpu_probe.ko
llvm-readelf -S cdh_cpu_probe.ko
```

Makefile 只接受 DDK 提供的 `KDIR` 或人工显式传入的 `KERNEL_SRC`，不会回退到宿主默认内核目录。当前 `android15-6.6` clean build 已能生成 `cdh_cpu_probe.ko`，`modinfo` 显示 `vermagic=6.6.127-4k-g46a034eca005-dirty`。加载前必须确认 `device-run` 取证的 `kernel-abi-version.txt` 为 `6.6.127-4k-g46a034eca005-dirty`，并且 `.ko` `vermagic` 与该 ABI 精确匹配；不匹配时不能进入 profile 自动加载。`kernel-release.txt` 现在记录 App/native 可见 `uname` 展示值，不用于模块 ABI 判断。旧 `android16-6.12` clean build 得到的 `vermagic=6.12.76-4k-gae4e2f4f997e-dirty` 只是错误 target 证据。若出现 `Unknown symbol`、`Invalid module format` 或 `Exec format error`，直接失败并归档 `dmesg`，不回退到 framework/native hook。

## 验证

加载后应出现：

```text
/proc/cdh_cpu_profile
/sys/kernel/cdh_cpu/profile
/sys/kernel/cdh_cpu/clusters
/sys/kernel/cdh_cpu/midr_el1
/sys/kernel/cdh_cpu/cpufreq
```

这些节点只是  Android15 真机 CPU 目标画像的只读记录。后续如果要减少 AIDA64/DevInfo CPU stable 差异，需要另做现有 `/proc/cpuinfo` 和 `/sys/devices/system/cpu` 读取路径替换方案，并继续保证 QEMU/HVF/KVM 实际 CPU 能力不和可见字段冲突。
