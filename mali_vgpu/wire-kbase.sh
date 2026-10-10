#!/usr/bin/env bash
# CDH gold-15：把 ARM kbase 接进内核树（in-tree），**幂等**，在构建容器内执行。
#
# 为什么必须 in-tree（而不是 out-of-tree M= 构建）：
#   kbase 的 C 代码用 IS_ENABLED(CONFIG_MALI_NO_MALI) 选择寄存器映射/中断实现，
#   该宏只能来自 include/generated/autoconf.h；out-of-tree 用命令行传 CONFIG_MALI_*
#   不会进 autoconf.h，会与 Kbuild 的 make 级判定（hw_access/Kbuild 据此选
#   model_linux.o 还是 real_hw.o）不一致 → 链接期/运行期行为错乱。
#
# 为什么在容器里做而不是改宿主内核树：
#   build-kernel.sh 用 `git archive HEAD` 导入内核源码，且 check-kernel-worktree.sh
#   会**拒绝未提交的工作树修改** → 接线只在容器内做，第三方 GPL 源码不进项目 git。
#
# 用法（容器内，cwd=/src）：bash kernel/modules/mali_vgpu/wire-kbase.sh
set -euo pipefail

cd /src
mali_src="kernel/modules/mali_vgpu/kbase"

if [[ ! -d "${mali_src}/drivers/gpu/arm/midgard" ]]; then
	echo "[wire-kbase] 缺少 kbase 源码：${mali_src}" >&2
	exit 3
fi

# 1) 源码就位：每次覆盖，保证与宿主一致（便于迭代改 kbase 源码后增量重编）
rm -rf drivers/gpu/arm
cp -a "${mali_src}/drivers/gpu/arm" drivers/gpu/arm
cp -a "${mali_src}/include/linux/." include/linux/
cp -a "${mali_src}/include/uapi/." include/uapi/

# 2) Kconfig / Makefile 接线（幂等）
#    本树是 GKI 布局：drivers/gpu/Kconfig 不存在，drivers/Kconfig 仅 source gpu/trace，
#    故接线点只能是 drivers/Kconfig 与 drivers/gpu/Makefile。
if ! grep -qxF 'source "drivers/gpu/arm/midgard/Kconfig"' drivers/Kconfig; then
	echo 'source "drivers/gpu/arm/midgard/Kconfig"' >> drivers/Kconfig
fi
if ! grep -qxF 'obj-$(CONFIG_MALI_MIDGARD) += arm/midgard/' drivers/gpu/Makefile; then
	echo 'obj-$(CONFIG_MALI_MIDGARD) += arm/midgard/' >> drivers/gpu/Makefile
fi

# 3) 版本适配：内核 6.6 的 include/linux/minmax.h 定义了 MIN/MAX，与 kbase
#    mali_malisw.h 的同名宏冲突，clang 以 -Werror,-Wmacro-redefined 直接失败。
#    两者语义等价（内核注释：“no type checking, and uses the arguments multiple
#    times”，kbase 为 ((x)<(y)?(x):(y))），最终生效的是内核版 → 只需关掉该告警，
#    不改 ARM 源码。必须插在 `subdir-ccflags-y += $(ccflags-y)` **之前**，
#    否则不会传播到 backend/ hw_access/ 等子目录。
if ! grep -q 'Wno-macro-redefined' drivers/gpu/arm/midgard/Kbuild; then
	sed -i '/^subdir-ccflags-y/i ccflags-y += -Wno-macro-redefined' \
		drivers/gpu/arm/midgard/Kbuild
fi

# 4) 源码适配（幂等）：为「无真实硬件 + 无 DT 节点」的虚拟 Mali 修正 r49p0 源码。
#    在构建期打补丁而非改 clone 出来的源码，是为了让 kbase 保持 pristine，
#    将来升级到 r49p1/r54p0 时不会与本地修改冲突。
python3 - <<'PY'
import pathlib
import sys


def patch(path, old, new, desc):
    """幂等打补丁：new 已在则跳过；锚点未命中则硬失败（避免静默漏补）。"""
    p = pathlib.Path(path)
    s = p.read_text()
    if new in s:
        print("[wire-kbase] %s：已存在，跳过" % desc)
        return
    if old not in s:
        sys.exit("[wire-kbase] %s：锚点未命中，请人工核对 %s" % (desc, path))
    p.write_text(s.replace(old, new, 1))
    print("[wire-kbase] %s：已打补丁" % desc)


# (1) r49p0 的 backend/gpu/mali_kbase_model_dummy.c 在 !MALI_USE_CSF（我们走 JM
#     路径）下，case GPU_COMMAND_PRFCNT_SAMPLE 少了 break，直接落进 default: →
#     新版 clang 以 -Werror,-Wimplicit-fallthrough 判错（clang 的修复建议原文即
#     “insert 'break;' to avoid fall-through”）。default 分支是空操作，故补
#     break 语义等价，纯修错。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t\tdummy->prfcnt_sample_completed = 1;\n#endif /* !MALI_USE_CSF */\n",
      "\t\t\tdummy->prfcnt_sample_completed = 1;\n\t\t\tbreak;\n"
      "#endif /* !MALI_USE_CSF */\n",
      "补 PRFCNT_SAMPLE 的 break")

# (2) power_control_init() 无条件调 of_clk_get(kbdev->dev->of_node, i)。
#     虚拟 Mali 由 platform_device 注册、没有 DT 节点（of_node == NULL），
#     实测直接 Oops：pc of_clk_get+0x28、x0=0、访问 device_node.full_name
#     （偏移 0x10）→ NULL 解引用。
#     该函数在 #ifndef CONFIG_OF 分支的注释已写明原意：「本初始化至少需要能从
#     设备树取得 regulator 与 clock 的能力，不具备时整体跳过」。我们只是把这条
#     判据从「编译期无 CONFIG_OF」放宽到「运行期无 of_node」，与 ARM 原意一致。
#     nr_clocks/nr_regulators 保持 0，power_control_term 的释放循环不会执行。
patch("drivers/gpu/arm/midgard/mali_kbase_core_linux.c",
      "\tstatic const char *const regulator_names[] = { \"mali\", \"shadercores\" };\n"
      "\tBUILD_BUG_ON(ARRAY_SIZE(regulator_names) < BASE_MAX_NR_CLOCKS_REGULATORS);\n"
      "#endif /* CONFIG_REGULATOR */\n"
      "\n"
      "\tif (!kbdev)\n"
      "\t\treturn -ENODEV;\n",
      "\tstatic const char *const regulator_names[] = { \"mali\", \"shadercores\" };\n"
      "\tBUILD_BUG_ON(ARRAY_SIZE(regulator_names) < BASE_MAX_NR_CLOCKS_REGULATORS);\n"
      "#endif /* CONFIG_REGULATOR */\n"
      "\n"
      "\tif (!kbdev)\n"
      "\t\treturn -ENODEV;\n"
      "\n"
      "\t/* CDH: 无 DT 节点（虚拟 Mali）时按本函数原意整体跳过 clk/regulator 初始化 */\n"
      "\tif (!kbdev->dev->of_node)\n"
      "\t\treturn 0;\n",
      "power_control_init 在无 of_node 时提前返回")

# (3) dummy model 的 GPU 身份：改成厂商 DDK 期望的 Mali-G57 编码。
#     实测（实例 gold-15/17，补丁 3 第一版只改 version_minor 后）DDK 仍拒绝：
#       E mali : The DDK (built for 0x9000003 r0p1 status range [0..15]) is not
#                compatible with this Mali GPU device, /dev/mali0 detected as
#                0x9000801 r0p1 status 0, GPU features model-conformant: 'true'.
#     解析链（mali_kbase_gpuprops.c）：
#       kbase_gpuprops_parse_gpu_id() 从 GPU_ID2 位域取
#         arch_major=bits[31:28] arch_minor=bits[27:24] arch_rev=bits[23:20]
#         product_major=bits[19:16] version_major=bits[15:12]
#         version_minor=bits[11:4] version_status=bits[3:0]
#       再 product_id = GPU_ID_PRODUCT_ID_MAKE(arch_major, arch_minor, arch_rev,
#                                             product_major)
#                     = U8_COMP(<<24, <<16, <<8, <<0)
#     tNAx 原值 GPU_ID2_MAKE(9,0,8,1,…) → product_id = 0x09000801
#       （与 DDK 报的 detected 逐位吻合，推理链闭合）
#     DDK 要 0x09000003 → arch_major=9, arch_minor=0, arch_rev=0, product_major=3
#     故把身份改为 GPU_ID2_MAKE(9, 0, 0, 3, 0, 1, 0)：
#       product_id = 0x09000003（匹配）、r0p1（匹配 DDK 的 r0p1）。
#     副作用：product_model = GPU_ID_MODEL_MAKE(9,3) 在 r49p0 产品表里不存在
#     （arch 9 只有 0=tTRx 1=tNAx 2=tBEx 4=tLBEx 5=tBAx），会让
#     kbase_hw_set_issues_mask()/get_features() 落 default → -EINVAL → probe 失败，
#     故必须配套补丁 (4)。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      '\t\t.name = "tNAx",\n'
      "\t\t.gpu_id = GPU_ID2_MAKE(9, 0, 8, 1, 0, 0, 0),\n",
      '\t\t.name = "tNAx",\n'
      "\t\t/* CDH: 身份改为厂商 DDK 期望的 Mali-G57 编码\n"
      "\t\t * (arch 9, arch_minor 0, arch_rev 0, product_major 3, r0p1)\n"
      "\t\t * → product_id 0x09000003；需配套 mali_kbase_hw.c 的 (9,3) case\n"
      "\t\t */\n"
      "\t\t.gpu_id = GPU_ID2_MAKE(9, 0, 0, 3, 0, 1, 0),\n",
      "tNAx 身份改为 DDK 期望的 product_id 0x09000003 / r0p1")

# (4) 产品表补 (arch_major=9, product_major=3)：与 tNAx 是同一颗 GPU（Mali-G57），
#     只是厂商 DDK 用的 product_major 编码不同，故并列 case 复用 tNAx 的
#     features / model issues 表，避免落 default → "Unknown Product ID" → -EINVAL。
#     两处 switch：kbase_hw_get_features()（features）与
#     kbase_hw_set_issues_mask() 的 software-model 分支（issues）。
patch("drivers/gpu/arm/midgard/mali_kbase_hw.c",
      "\tcase GPU_ID_PRODUCT_TNAX:\n"
      "\t\tfeatures = base_hw_features_tNAx;\n"
      "\t\tbreak;\n",
      "\tcase GPU_ID_PRODUCT_TNAX:\n"
      "\t/* CDH: 厂商 DDK 的 Mali-G57 product 编码为 (9,0,0,3)，r49p0 表内无此项，\n"
      "\t * 与 tNAx 同为 Mali-G57，故并列复用其 features 表（见 wire-kbase.sh 补丁 3）\n"
      "\t */\n"
      "\tcase GPU_ID_MODEL_MAKE(9, 3):\n"
      "\t\tfeatures = base_hw_features_tNAx;\n"
      "\t\tbreak;\n",
      "features 表补 product (9,3) → tNAx")

patch("drivers/gpu/arm/midgard/mali_kbase_hw.c",
      "\t\tcase GPU_ID_PRODUCT_TNAX:\n"
      "\t\t\tissues = base_hw_issues_model_tNAx;\n"
      "\t\t\tbreak;\n",
      "\t\tcase GPU_ID_PRODUCT_TNAX:\n"
      "\t\t/* CDH: 同补丁 (4) 上一处，software-model 分支的 issues 表 */\n"
      "\t\tcase GPU_ID_MODEL_MAKE(9, 3):\n"
      "\t\t\tissues = base_hw_issues_model_tNAx;\n"
      "\t\t\tbreak;\n",
      "model issues 表补 product (9,3) → tNAx")

# (5) Phase C·第一补丁：virtio-gpu 的 connector type 由 VIRTUAL(15) 改 DSI(16)。
#     依据（厂商 hwcomposer.mt6833.so 反汇编，DrmModeResource::connectAllDisplay，
#     0x18e418 附近）：MTK HWC 对 drmModeConnector->connector_type 只有三条路——
#       cmp #0x12 (18=WRITEBACK) → 次显示分支
#       cmp #0x10 (16=DSI)      → 主显示（internal）
#       其余 → isConnectorTypeExternal()；VIRTUAL(15) 判非外接
#              → 打日志 "connectAllDisplay(), unknow type 15" 且不建任何 display
#              → HWCDisplay 构造时 IOverlayDevice 为 NULL → SIGSEGV（fault addr 0x1c）
#     把 guest 的 virtio-gpu connector 上报为 DSI 后，HWC 会按主显示路径处理 card0。
#     只改我们自己的内核（virtio-gpu 是本内核 built-in），不碰厂商 so、不改属性。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tdrm_connector_init(dev, connector, &virtio_gpu_connector_funcs,\n"
      "\t\t\t   DRM_MODE_CONNECTOR_VIRTUAL);\n",
      "\tdrm_connector_init(dev, connector, &virtio_gpu_connector_funcs,\n"
      "\t\t\t   /* CDH: 上报 DSI 而非 VIRTUAL——MTK HWC 的 connectAllDisplay 只认\n"
      "\t\t\t    * DSI(16) 为主显示，见 wire-kbase.sh 补丁 (5) 的反汇编依据 */\n"
      "\t\t\t   DRM_MODE_CONNECTOR_DSI);\n",
      "virtio-gpu connector type 改 DSI（Phase C 第一补丁）")

# (6) Phase C·第二补丁：把 MTK HWC 依赖的 49 个私有 CRTC KMS 属性挂到 virtio CRTC。
#     依据（实例 gold-15/21，composer pid 596 启动日志）：getCaps() 按名字逐个查
#     CRTC 属性，全部缺失 → property[OVERLAP_LAYER_NUM] does not do initialize …（49 个）
#     → caps 闸门（connectAllDisplay 反汇编 [x19+284]）为 0 → display 0 not connected
#     → SF BadDisplay → dispatchHotplugError NULL deref → SF 无限 restarting。
#     源文件在 kernel/modules/mali_vgpu/mtk-props/virtgpu_mtk_props.c，每次覆盖拷入，
#     Makefile 幂等追加，virtgpu_display.c 在 drm_crtc_helper_add 之后调用挂属性。
PY

# 6) Phase C·第二补丁接线：mtk-props 源文件就位（每次覆盖，便于宿主侧迭代）
cp -a kernel/modules/mali_vgpu/mtk-props/virtgpu_mtk_props.c \
	drivers/gpu/drm/virtio/virtgpu_mtk_props.c

python3 - <<'PY'
import pathlib
import sys


def patch(path, old, new, desc):
    """幂等打补丁：new 已在则跳过；锚点未命中则硬失败（避免静默漏补）。"""
    p = pathlib.Path(path)
    s = p.read_text()
    if new in s:
        print("[wire-kbase] %s：已存在，跳过" % desc)
        return
    if old not in s:
        sys.exit("[wire-kbase] %s：锚点未命中，请人工核对 %s" % (desc, path))
    p.write_text(s.replace(old, new, 1))
    print("[wire-kbase] %s：已打补丁" % desc)


# (6a) virtio/Makefile：virtio-gpu-y 追加 virtgpu_mtk_props.o（幂等）
if not pathlib.Path("drivers/gpu/drm/virtio/Makefile").read_text().count(
        "virtgpu_mtk_props.o"):
    patch("drivers/gpu/drm/virtio/Makefile",
          "\tvirtgpu_display.o virtgpu_vq.o \\\n",
          "\tvirtgpu_display.o virtgpu_vq.o virtgpu_mtk_props.o \\\n",
          "virtio Makefile 追加 virtgpu_mtk_props.o")
else:
    print("[wire-kbase] virtio Makefile 追加 virtgpu_mtk_props.o：已存在，跳过")

# (6b) virtgpu_display.c：CRTC 初始化处调用挂属性（幂等）
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tdrm_crtc_helper_add(crtc, &virtio_gpu_crtc_helper_funcs);\n",
      "\tdrm_crtc_helper_add(crtc, &virtio_gpu_crtc_helper_funcs);\n"
      "\n"
      "\t/* CDH: MTK HWC getCaps() 需要的私有 CRTC 属性，见 virtgpu_mtk_props.c */\n"
      "\tvirtio_gpu_mtk_attach_crtc_props(dev, crtc);\n",
      "virtgpu_display.c 调用 mtk_attach_crtc_props")

# (6c) extern 声明：missing-prototypes 在 W=1 才开，此处仅为可读性
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "static const struct drm_encoder_helper_funcs virtio_gpu_enc_helper_funcs = {\n",
      "/* CDH: MTK HWC 私有 CRTC 属性注册（virtgpu_mtk_props.c） */\n"
      "extern void virtio_gpu_mtk_attach_crtc_props(struct drm_device *dev,\n"
      "\t\t\t\t\t\t struct drm_crtc *crtc);\n"
      "\n"
      "static const struct drm_encoder_helper_funcs virtio_gpu_enc_helper_funcs = {\n",
      "virtgpu_display.c 补 extern 声明")

# (6d) virtio_gpu_crtc_funcs：补 atomic_get/set_property 回调（幂等）
#      根因（实例 24）：枚举 CRTC 属性时 drm_atomic_crtc_get_property 对非标准
#      属性调 crtc->funcs->atomic_get_property，缺失 → -EINVAL → 整个
#      drmModeGetObjectProperties ioctl 失败 → MTK "failed to get properties"
#      → crtc init -19 → getCaps 未被调用。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\t.atomic_destroy_state   = drm_atomic_helper_crtc_destroy_state,\n"
      "};\n",
      "\t.atomic_destroy_state   = drm_atomic_helper_crtc_destroy_state,\n"
      "\n"
      "\t/* CDH: MTK 私有 CRTC 属性读写（virtgpu_mtk_props.c） */\n"
      "\t.atomic_get_property    = virtio_gpu_mtk_crtc_atomic_get_property,\n"
      "\t.atomic_set_property   = virtio_gpu_mtk_crtc_atomic_set_property,\n"
      "};\n",
      "virtio_gpu_crtc_funcs 补 atomic_get/set_property")

# (6e) 两个回调的 extern 声明（幂等）
#      注意：此锚点在文件后部（enc_helper_funcs 之前），而 crtc_funcs 结构在
#      第 56 行——对 (6d) 插入的成员来说使用先于声明会编译失败，故实际生效
#      的是下面 (6f) 的前置声明；此处声明保留（C 重复声明合法，容器树已打）。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "extern void virtio_gpu_mtk_attach_crtc_props(struct drm_device *dev,\n"
      "\t\t\t\t\t\t struct drm_crtc *crtc);\n",
      "extern void virtio_gpu_mtk_attach_crtc_props(struct drm_device *dev,\n"
      "\t\t\t\t\t\t struct drm_crtc *crtc);\n"
      "extern int virtio_gpu_mtk_crtc_atomic_get_property(struct drm_crtc *crtc,\n"
      "\t\t\t\t\t\t const struct drm_crtc_state *state,\n"
      "\t\t\t\t\t\t struct drm_property *property, u64 *val);\n"
      "extern int virtio_gpu_mtk_crtc_atomic_set_property(struct drm_crtc *crtc,\n"
      "\t\t\t\t\t\t struct drm_crtc_state *state,\n"
      "\t\t\t\t\t\t struct drm_property *property, u64 val);\n",
      "virtgpu_display.c 补 get/set 回调 extern")

# (6f) 回调 extern 前置：crtc_funcs 结构在第 56 行、(6e) 的声明在其后，
#      (6d) 的成员引用会 use-before-declare → 编译失败（实例 24 轮 chain18 构建已实证：
#      "error: use of undeclared identifier 'virtio_gpu_mtk_crtc_atomic_*_property'"）。
#      故把声明插到结构体定义之前；幂等键为「声明块+锚点行」，与 (6e) 内容不同块。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "static const struct drm_crtc_funcs virtio_gpu_crtc_funcs = {\n",
      "/* CDH: MTK 私有 CRTC 属性读写回调（virtgpu_mtk_props.c），声明先于使用 */\n"
      "extern int virtio_gpu_mtk_crtc_atomic_get_property(struct drm_crtc *crtc,\n"
      "\t\t\t\t\t const struct drm_crtc_state *state,\n"
      "\t\t\t\t\t struct drm_property *property, u64 *val);\n"
      "extern int virtio_gpu_mtk_crtc_atomic_set_property(struct drm_crtc *crtc,\n"
      "\t\t\t\t\t struct drm_crtc_state *state,\n"
      "\t\t\t\t\t struct drm_property *property, u64 val);\n"
      "static const struct drm_crtc_funcs virtio_gpu_crtc_funcs = {\n",
      "virtgpu_display.c 回调 extern 前置（声明先于使用）")

# (7) Phase C·第三补丁：virtgpu_ioctl.c 的 getparam handler 顶部加 MTK 分流。
#     根因（实例 28 反汇编 + 28 轮日志完整因果链）：
#     MTK DrmDevice::createOverlaySession 发 DISP_IOCTL_CREATE_SESSION=0xc0106443，
#     与 DRM_IOCTL_VIRTGPU_GETPARAM 编码完全相同（DRM 单设备单驱动 nr 空间所致，
#     type=0x64/nr=0x43/size=16 全撞）。MTK 入参 4×u32：[0]=type(pipe0→表值 1)
#     [4]=dpy [8]=mode [12]=sid（入参恒 -1）。[0]=1 恰是 VIRTGPU_PARAM_3D_FEATURES
#     → handler 被走到，param->value=0xffffffff00000000（mode/sid 拼成的非法指针）
#     → copy_to_user EFAULT → ioctl 返回 -1 → "Failed to create display session"
#     → OverlayEngine 构造 [this+380] 保持 0 → onPlugIn 拒绝 → [DPY] connected : 0
#     → display(0) is not connected → SF dispatchHotplugError NULL deref 崩溃循环。
#     分流判据 [12]==0xffffffff：正常 getparam 的 value 是合法用户态指针，高 32 位
#     不可能全 1，零误伤。命中后分配 sid 写回 [12] 返回 0，drm_ioctl 按 IOC_OUT
#     把 16 字节整块拷回用户态（MTK 从结构体偏移 12 读 sid）。
patch("drivers/gpu/drm/virtio/virtgpu_ioctl.c",
      "\tstruct virtio_gpu_device *vgdev = dev->dev_private;\n"
      "\tstruct drm_virtgpu_getparam *param = data;\n"
      "\tint value;\n"
      "\n"
      "\tswitch (param->param) {\n",
      "\tstruct virtio_gpu_device *vgdev = dev->dev_private;\n"
      "\tstruct drm_virtgpu_getparam *param = data;\n"
      "\tint value;\n"
      "\n"
      "\t/* CDH(gold-15): MTK HWC 的 DISP_IOCTL_CREATE_SESSION(0xc0106443) 与\n"
      "\t * DRM_IOCTL_VIRTGPU_GETPARAM 编码完全相同（同 type=0x64/nr=0x43/size=16）。\n"
      "\t * MTK 入参 4×u32：[0]=type [4]=dpy [8]=mode [12]=sid（入参恒 -1）；正常\n"
      "\t * getparam 的 value 是用户态指针，高 32 位不可能全 1，据 [12]==-1 分流。 */\n"
      "\tif (unlikely(((u32 *)data)[3] == 0xffffffff)) {\n"
      "\t\tstatic atomic_t cdh_mtk_sid = ATOMIC_INIT(0);\n"
      "\t\tu32 *w = data;\n"
      "\n"
      "\t\tw[3] = (u32)atomic_inc_return(&cdh_mtk_sid);\n"
      "\t\tDRM_INFO(\"cdh_mtk: CREATE_SESSION type=%u dpy=%u mode=%u -> sid=%u\\n\",\n"
      "\t\t\t  w[0], w[1], w[2], w[3]);\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n"
      "\tswitch (param->param) {\n",
      "virtgpu_ioctl.c getparam 顶部 MTK CREATE_SESSION 分流")

# (8) Phase C·第四补丁：virtgpu_gem.c dumb create 放宽 bpp 限制。
#     根因（实例 29）：补丁 (7) 打通 CREATE_SESSION 后，OverlayEngine 构造链走到
#     setOverlaySessionModeInternal → setDisplay_0 → prepare FB → allocateBuffer
#     请求 dumb buffer wxh=1080x2400 bpp=8，上游 virtio_gpu_mode_dumb_create 仅
#     接受 bpp==32 → EINVAL → "failed to set display_0: prepare buffer" → MTK
#     显式 abort（composer@3.3-service 每 5s 崩溃重启循环，tombstone 背架
#     setOverlaySessionModeInternal+1344 → createOverlaySession+1392 →
#     OverlayEngine ctor+660）。MTK drm 的 dumb create 在真机上支持任意 bpp
#     （pitch = width*bpp/8）。
#     放宽为 8 的倍数（8..64）：pitch/size 按 bpp 计算（mmap/尺寸语义正确）；
#     宿主 2D 资源仍按 XRGB8888 创建，但宽度按 guest 行字节数折算（pitch/4），
#     使宿主 stride 与 guest pitch 字节一致，避免 TRANSFER_TO_HOST 越界读；
#     bpp==32 时与上游行为完全一致。
patch("drivers/gpu/drm/virtio/virtgpu_gem.c",
      "\tif (args->bpp != 32)\n"
      "\t\treturn -EINVAL;\n"
      "\n"
      "\tpitch = args->width * 4;\n",
      "\t/* CDH(gold-15): MTK HWC allocateBuffer 实测要 8bpp(1080x2400) dumb\n"
      "\t * buffer（上游只接受 32；MTK drm 真机支持任意 bpp）。放宽为 8 的倍数。 */\n"
      "\tif (args->bpp < 8 || args->bpp > 64 || args->bpp % 8)\n"
      "\t\treturn -EINVAL;\n"
      "\n"
      "\tpitch = DIV_ROUND_UP(args->width * args->bpp, 8);\n",
      "virtgpu_gem.c dumb create 放宽 bpp（8 的倍数）")
patch("drivers/gpu/drm/virtio/virtgpu_gem.c",
      "\tparams.format = virtio_gpu_translate_format(DRM_FORMAT_HOST_XRGB8888);\n"
      "\tparams.width = args->width;\n"
      "\tparams.height = args->height;\n",
      "\tparams.format = virtio_gpu_translate_format(DRM_FORMAT_HOST_XRGB8888);\n"
      "\t/* CDH: 宿主按 XRGB8888(4B/px) 建资源；宽度折算为 guest 每行字节数/4，\n"
      "\t * 保证宿主 stride 与 guest pitch 字节一致（bpp==32 时等价上游）。 */\n"
      "\tparams.width = DIV_ROUND_UP(pitch, 4);\n"
      "\tparams.height = args->height;\n",
      "virtgpu_gem.c 宿主资源宽度按 pitch 折算")

# (9) Phase C·第五补丁：virtgpu_plane.c plane 格式表加 MTK 8bpp 格式。
#     根因（实例 30）：补丁 (8) 打通 dumb create 后，allocateBuffer 内部转
#     drmModeAddFB：w:1080 h:2400 f:38424752('RGB8'=DRM_FORMAT_RGB332) p:1080
#     → drm_gem_fb_create_with_funcs 的 drm_any_plane_has_format 检查：无任何
#     plane 支持 RGB332 → ADDFB -EINVAL → prepare FB for CRTC -22 →
#     setDisplay_0 fail → setOverlaySessionModeInternal abort（背架不变）。
#     另一条链（同轮日志）dim 层 ADDFB 'C8  '(DRM_FORMAT_C8) 4096x4096 同因 -22。
#     把两个 8bpp 格式加进 virtio-gpu primary plane 格式表：
#     - drm_any_plane_has_format 放行 → ADDFB 成功；
#     - 宿主资源仍按 XRGB8888 建几何（dumb 路径 bpp 折算，见补丁 (8)），
#       scanout 若用到仅显示失真，不影响 L1（稳定开机）目标。
patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "static const uint32_t virtio_gpu_formats[] = {\n"
      "\tDRM_FORMAT_XRGB8888,\n"
      "\tDRM_FORMAT_ARGB8888,\n"
      "\tDRM_FORMAT_BGRX8888,\n"
      "\tDRM_FORMAT_BGRA8888,\n"
      "\tDRM_FORMAT_RGBX8888,\n"
      "\tDRM_FORMAT_RGBA8888,\n"
      "\tDRM_FORMAT_XBGR8888,\n"
      "\tDRM_FORMAT_ABGR8888,\n"
      "};\n",
      "static const uint32_t virtio_gpu_formats[] = {\n"
      "\tDRM_FORMAT_XRGB8888,\n"
      "\tDRM_FORMAT_ARGB8888,\n"
      "\tDRM_FORMAT_BGRX8888,\n"
      "\tDRM_FORMAT_BGRA8888,\n"
      "\tDRM_FORMAT_RGBX8888,\n"
      "\tDRM_FORMAT_RGBA8888,\n"
      "\tDRM_FORMAT_XBGR8888,\n"
      "\tDRM_FORMAT_ABGR8888,\n"
      "\t/* CDH(gold-15): MTK HWC 的 8bpp 格式——prepareFb 会话哑 buffer 用\n"
      "\t * RGB332('RGB8')，dim 层用 C8('C8  ')；drm_gem_fb_create_with_funcs\n"
      "\t * 的 drm_any_plane_has_format 检查拒列表外格式 → ADDFB -EINVAL →\n"
      "\t * MTK abort（实例 30 实证）。宿主资源仍按 XRGB8888 建（补丁 (8)）。 */\n"
      "\tDRM_FORMAT_RGB332,\n"
      "\tDRM_FORMAT_C8,\n"
      "};\n",
      "virtgpu_plane.c 格式表加 RGB332/C8")

# (10) Phase C·第六补丁：virtgpu_display.c 去掉 fb_modifiers_not_supported 声明。
#      根因（实例 31，反汇编 hwc.so DrmModeResource::addFb @0x190850 实锤）：
#      MTK addFb 调 drmModeAddFB2WithModifiers，modifier 数组恒传非 NULL（bo+0x60；
#      会话哑 buffer 值为 0/LINEAR）→ libdrm 置 DRM_MODE_FB_MODIFIERS → 内核
#      drm_internal_framebuffer_create（drm_framebuffer.c:311）见 flags 带
#      MODIFIERS 且 fb_modifiers_not_supported=true → 直接 -EINVAL，
#      与 fourcc 完全无关——故 run31 两条链同 -22：
#        RGB332 1080x2400 hnd:1（dumb 会话哑 buffer）
#        C8     4096x4096 hnd:0xFF79E6ED（dim 层 PRIME 导入）
#      订正：补丁 (9) 的 drm_any_plane_has_format 假设不成立——virtio 的
#      fb_create=virtio_gpu_user_framebuffer_create（virtgpu_display.c:316）根本
#      不走 drm_gem_fb_create_with_funcs，无任何格式检查；格式表加入仅对
#      GETPLANE/GETRESOURCES 呈报有益，保留无害。
#      virtio 2D scanout 全程忽略 fb->modifier（无压缩概念），删声明放行；
#      run31 之前未暴露此层是因为 run29 前 MTK 卡在更早的 CREATE_SESSION
#      闸门即 abort，add fb 链是 run30 打通 dumb create 后才首次被走到。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tvgdev->ddev->mode_config.fb_modifiers_not_supported = true;\n",
      "\t/* CDH(gold-15): 上游声明不支持 fb modifier，但 MTK HWC addFb 恒走\n"
      "\t * drmModeAddFB2WithModifiers（modifier 数组非 NULL 即置\n"
      "\t * DRM_MODE_FB_MODIFIERS，即便值全 0），会在\n"
      "\t * drm_internal_framebuffer_create 被直接 -EINVAL（与 fourcc 无关，\n"
      "\t * 实例 31：RGB332/C8 两条链同 ret=-22）。virtio 2D scanout 忽略\n"
      "\t * fb->modifier，删声明放行（已删除上行）。 */\n",
      "virtgpu_display.c 去掉 fb_modifiers_not_supported")
PY

echo "[wire-kbase] in-tree 接线完成（drivers/gpu/arm + Kconfig/Makefile + ccflags 适配）"
