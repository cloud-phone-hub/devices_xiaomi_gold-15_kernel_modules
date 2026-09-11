# Device Info KO

这是 Android15 设备信息展示对齐模块。当前实现 UTS / `uname(2)` 可见字段、`/proc/meminfo` capacity 展示字段、`sysinfo(2).uptime` / `/proc/uptime` 应用可见启动时长、`/proc/cpuinfo` / BogoMIPS / `cpu_capacity` 展示字段、只读 CPU cpufreq sysfs 目录、`cpu_topology[]` 派生的 topology sysfs 字段、arm64 `midr_el1` sysfs 使用的 `cpu_data.reg_midr` 来源，以及 `cpuN/cache` sysfs 父设备隐藏。后续 auxv/HWCAP 和其它内核编程读取路径继续放进同一个 `cdh_device_info.ko` 或同一加载链路中处理，按功能拆源码目录，不再新增多个单用途信息修改 KO。

## 边界

- 目标设备：`note13-5g-15`（Redmi Note 13 5G / MT6833，真机实测）。
- guest内核ABI：Android15 GKI 6.6，模块固定使用`ghcr.io/feicong/droid-ddk:android15-6.6`构建。
- 当前用户态展示目标：`uname -r=6.6.89-android15-8-gbe8d201b0d27-ab13762941-4k`。
- 当前 ABI 校验目标：`gki_abi_release=6.6.127-4k-cdh`。
- 当前实现修改 `init_uts_ns.name`，让 App、toybox `uname` 和 libc `uname(2)` 读取  Android15 真机字段。
- 当前实现注册 `android_vh_si_meminfo_adjust`，把 `si_meminfo()` 的 `totalram` 改为 Android15 目标 `MemTotal=7760724 kB`；该路径同时覆盖 `/proc/meminfo` 原始 `MemTotal` 输出和 `sysinfo(2)` / libc `sysinfo()` 的 `totalram` 编程读取。
- 当前实现注册 `android_vh_meminfo_proc_show`，只在 `/proc/meminfo` 已生成缓冲区中原位替换 `SwapTotal=6291452 kB`、`CommitLimit=10171812 kB`、`CmaTotal=344064 kB` 和 `VmallocTotal=257687552 kB`，不追加重复字段。
- 当前实现用 kretprobe 同时处理 `__arm64_sys_sysinfo` 和 `uptime_proc_show`，为应用可见 `sysinfo(2).uptime` 与 `/proc/uptime` 第一列增加 `uptime_offset_seconds=172800`。这是 Overt `time_info.boot_time` 的 canonical source，不能只改 logcat 或 Overt UI 输出；两条路径必须一起验证，避免多路径读取不一致。
- 当前实现注册 `android_rvh_cpuinfo_c_show` 和 `android_rvh_cpu_capacity_show`，覆盖 `/proc/cpuinfo` 与 `/sys/devices/system/cpu/cpu*/cpu_capacity` 展示路径；真机 (MT6833) `/proc/cpuinfo` 无 `Hardware` 行，因此与真机保持一致不输出该字段。
- 当前实现用 `get_cpu_device()` 在每个 CPU 目录下创建只读 `cpufreq` sysfs 节点，覆盖 `cpuinfo_max_freq`、`cpuinfo_min_freq`、`scaling_*_freq`、`scaling_governor`、`affected_cpus` 和 `related_cpus` 这类应用/服务常读文件，避免只补 `/proc/cpuinfo` 后仍让用户态线程调度器报缺文件。
- 当前实现直接更新 arm64 `cpu_topology[]`，让 `/sys/devices/system/cpu/cpuN/topology/{physical_package_id,cluster_id}` 和 sibling mask 使用  Android15 目标画像；该路径是 topology sysfs 的 canonical source。
- 当前实现通过 kprobe 解析 `kallsyms_lookup_name`，再解析未导出的 per-cpu `cpu_data`，写入 `struct cpuinfo_arm64.reg_midr`，让 `/sys/devices/system/cpu/cpuN/regs/identification/midr_el1` 读回  Android15 目标 MIDR；该路径是 MIDR sysfs 的 canonical source，不创建替代节点。
- 当前实现通过 kprobe 解析 Android15 GKI 6.6 私有 `cpu_cache_sysfs_exit`、`cacheinfo_cpu_online` 和 `cache_dev_map`，隐藏 `/sys/devices/system/cpu/cpuN/cache` 父设备并在卸载时恢复；调用私有 cacheinfo 函数必须走 `__nocfi` 包装，避免 GKI kCFI 对模块间间接调用触发 panic。
- 不修改真实 boot image、`vermagic`、KVM/QEMU CPU 能力或 Android property source。
- 不修改真实 QEMU memory、zram0、`/proc/swaps`、CMA 分配或内核 VA layout；meminfo 是应用可见展示层，行为一致性另按底层路径处理。
- `MemFree`、`MemAvailable`、`SwapFree`、`CmaFree`、`sysinfo_freeram` 和 `sysinfo_freeswap` 是运行时抖动值，不做固定目标值校验，但必须满足 `0 <= value <= 对应 total/limit` 的关系约束。
- Android15 GKI 6.6 当前没有等价的 `si_swapinfo` vendor hook；`sysinfo(2).totalswap` 只有在真实 zram/swap 路径启用后才会对齐，当前运行证据中按 `pending` 记录，不通过追加 `/proc/meminfo` 文本伪装。
- 当前 `ro.kernel.version` 仍是 property 路径差异，不能因为 `uname -r` 已对齐就标记为完成。
- auxv/HWCAP、HWCAP2 和直接指令可执行能力当前仍是 pending；`/proc/cpuinfo` hook、topology 改写、MIDR sysfs 改写和 cache sysfs 隐藏不会自动改变这些编程读取路径。
- `device-run` 和矩阵 QA 分开记录 `kernel-release.txt`（App 可见 uname）与 `kernel-abi-version.txt`（底层 GKI ABI 校验），并通过 `-15-meminfo-capacity.txt` 验证固定容量字段、运行时抖动字段和关系约束；同时保存 `-15-sysinfo.txt` 作为内存编程读取路径证据，保存 `-15-cpu-programmatic.txt` 作为 CPU/UTS 编程读取路径证据。

## 源码组织

```text
core/   模块 init/exit、module_param 和后续统一调度
uts/    UTS namespace / uname 展示层
meminfo/ si_meminfo/sysinfo 与 /proc/meminfo capacity 展示层
time/  sysinfo(2).uptime 与 /proc/uptime 启动时长展示层
cpu/   /proc/cpuinfo、cpu_capacity、topology、MIDR、cache 与只读 cpufreq sysfs 展示层
include/模块内共享头文件
```

后续加入 auxv/HWCAP 或其它 sysfs/proc 展示时，只在新子目录追加源码并更新 `Kbuild` 的 `$(MODULE_NAME)-objs`，最终仍链接成一个 `cdh_device_info.ko`。

## 构建

```text
cd guest-helper/hal/ko/_device_info
dddk clean --target android15-6.6
dddk build --target android15-6.6 -- -j4
modinfo cdh_device_info.ko
```

加载前必须确认 `modinfo` 或 `.modinfo` 字符串中 `vermagic=6.6.127-4k-cdh`。macOS 宿主没有 `modinfo` 时可用：

```text
strings cdh_device_info.ko | rg '^(description=|license=|vermagic=|parm=|name=|depends=)'
```

如果 `insmod` 报 `Unknown symbol`、`Invalid module format`、`Exec format error`、UTS patch 失败或 MIDR `cpu_data` 解析失败，直接失败并归档 `dmesg`，不要回退到 App/framework/native hook。
