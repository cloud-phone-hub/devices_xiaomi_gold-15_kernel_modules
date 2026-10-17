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


def patch(path, old, new, desc, done=None):
    """幂等打补丁：new 已在则跳过；锚点未命中则硬失败（避免静默漏补）。
    done：可选幂等标记——当后续补丁（如 14b/14c）改写了本补丁的插入内容时，
    new 将不再是文件子串，需以不受改写的稳定标记（done）判定已打状态，
    否则会重复插入（virtgpu_display.c redefinition 实锤，v55 构建失败教训）。"""
    p = pathlib.Path(path)
    s = p.read_text()
    if (done and done in s) or new in s:
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


def patch(path, old, new, desc, done=None):
    """幂等打补丁：new 已在则跳过；锚点未命中则硬失败（避免静默漏补）。
    done：可选幂等标记——当后续补丁（如 14b/14c）改写了本补丁的插入内容时，
    new 将不再是文件子串，需以不受改写的稳定标记（done）判定已打状态，
    否则会重复插入（virtgpu_display.c redefinition 实锤，v55 构建失败教训）。"""
    p = pathlib.Path(path)
    s = p.read_text()
    if (done and done in s) or new in s:
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

# (6g) virtgpu_display.c: connector 回调 extern 与属性注册（幂等）
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "static const struct drm_connector_funcs virtio_gpu_connector_funcs = {\n",
      "/* CDH: MTK Connector 属性读写回调（virtgpu_mtk_props.c） */\n"
      "extern void virtio_gpu_mtk_attach_connector_props(struct drm_device *dev,\n"
      "\t\t\t\t\t\t struct drm_connector *conn);\n"
      "extern int virtio_gpu_mtk_connector_atomic_get_property(struct drm_connector *conn,\n"
      "\t\t\t\t\t\t\t const struct drm_connector_state *state,\n"
      "\t\t\t\t\t\t\t struct drm_property *property, u64 *val);\n"
      "extern int virtio_gpu_mtk_connector_atomic_set_property(struct drm_connector *conn,\n"
      "\t\t\t\t\t\t\t struct drm_connector_state *state,\n"
      "\t\t\t\t\t\t\t struct drm_property *property, u64 val);\n"
      "static const struct drm_connector_funcs virtio_gpu_connector_funcs = {\n",
      "virtgpu_display.c connector 回调 extern 前置")

patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\t.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,\n"
      "};\n",
      "\t.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,\n"
      "\t/* CDH: MTK Connector 属性读写（virtgpu_mtk_props.c） */\n"
      "\t.atomic_get_property  = virtio_gpu_mtk_connector_atomic_get_property,\n"
      "\t.atomic_set_property  = virtio_gpu_mtk_connector_atomic_set_property,\n"
      "};\n",
      "virtgpu_display.c connector_funcs 补 atomic_get/set_property")

patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tdrm_connector_helper_add(connector, &virtio_gpu_conn_helper_funcs);\n",
      "\tdrm_connector_helper_add(connector, &virtio_gpu_conn_helper_funcs);\n"
      "\t/* CDH: MTK Connector 属性注册（virtgpu_mtk_props.c） */\n"
      "\tvirtio_gpu_mtk_attach_connector_props(dev, connector);\n",
      "virtgpu_display.c 调用 mtk_attach_connector_props")

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

# (9b) virtgpu_plane.c: plane 属性、回调与 can_position 放行（幂等）
patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "static const struct drm_plane_funcs virtio_gpu_plane_funcs = {\n",
      "/* CDH: MTK Plane 属性与读写回调（virtgpu_mtk_props.c） */\n"
      "extern void virtio_gpu_mtk_attach_plane_props(struct drm_device *dev,\n"
      "\t\t\t\t\t      struct drm_plane *plane);\n"
      "extern int virtio_gpu_mtk_plane_atomic_get_property(struct drm_plane *plane,\n"
      "\t\t\t\t\t\t   const struct drm_plane_state *state,\n"
      "\t\t\t\t\t\t   struct drm_property *property, u64 *val);\n"
      "extern int virtio_gpu_mtk_plane_atomic_set_property(struct drm_plane *plane,\n"
      "\t\t\t\t\t\t   struct drm_plane_state *state,\n"
      "\t\t\t\t\t\t   struct drm_property *property, u64 val);\n"
      "static const struct drm_plane_funcs virtio_gpu_plane_funcs = {\n",
      "virtgpu_plane.c plane 回调 extern 前置")

patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "\t.atomic_destroy_state\t= drm_atomic_helper_plane_destroy_state,\n"
      "};\n",
      "\t.atomic_destroy_state\t= drm_atomic_helper_plane_destroy_state,\n"
      "\t/* CDH: MTK Plane 属性读写（virtgpu_mtk_props.c） */\n"
      "\t.atomic_get_property\t= virtio_gpu_mtk_plane_atomic_get_property,\n"
      "\t.atomic_set_property\t= virtio_gpu_mtk_plane_atomic_set_property,\n"
      "};\n",
      "virtgpu_plane.c plane_funcs 补 atomic_get/set_property")

patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "\tbool is_cursor = plane->type == DRM_PLANE_TYPE_CURSOR;\n",
      "\t/* bool is_cursor = plane->type == DRM_PLANE_TYPE_CURSOR; (can_position 恒为 true) */\n",
      "virtgpu_plane.c 注释 unused is_cursor")

patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "\tret = drm_atomic_helper_check_plane_state(new_plane_state, crtc_state,\n"
      "\t\t\t\t\t\t  DRM_PLANE_NO_SCALING,\n"
      "\t\t\t\t\t\t  DRM_PLANE_NO_SCALING,\n"
      "\t\t\t\t\t\t  is_cursor, true);\n",
      "\t/* CDH: can_position 恒设为 true，放行状态栏/导航栏等非全屏图层，防止 -EINVAL(-22) */\n"
      "\tret = drm_atomic_helper_check_plane_state(new_plane_state, crtc_state,\n"
      "\t\t\t\t\t\t  DRM_PLANE_NO_SCALING,\n"
      "\t\t\t\t\t\t  DRM_PLANE_NO_SCALING,\n"
      "\t\t\t\t\t\t  true, true);\n",
      "virtgpu_plane.c atomic_check 放行 can_position")

patch("drivers/gpu/drm/virtio/virtgpu_plane.c",
      "\tif (type == DRM_PLANE_TYPE_PRIMARY)\n"
      "\t\tdrm_plane_enable_fb_damage_clips(plane);\n",
      "\tif (type == DRM_PLANE_TYPE_PRIMARY)\n"
      "\t\tdrm_plane_enable_fb_damage_clips(plane);\n"
      "\n"
      "\t/* CDH: 挂载 MTK Plane 必需属性（alpha, blend mode, zpos, MTK 私有属性） */\n"
      "\tvirtio_gpu_mtk_attach_plane_props(dev, plane);\n",
      "virtgpu_plane.c 调用 mtk_attach_plane_props")

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

# (11) Phase C·第七补丁：system_heap.c 注册 MTK dma_heap 别名。
#      根因（实例 32 实锤，三链闭环：SF tombstone + libsurfaceflinger 反汇编 +
#      guest 日志）：RenderEngine Cache::primeShaderCache 构造 GraphicBuffer
#      (128,128,RGBA_8888,1,usage 0x300=HW_RENDER|HW_TEXTURE)——反汇编 0x5d37ec/
#      0x5d38b8 处 mov w5,#0x300 实证 usage 请求值正常；mali_gralloc→libdmabufheap
#      按 heap 名打开 /dev/dma_heap/mtk_mm(-uncached)，云机只有 system/system-uncached
#      → 分配失败 -12（guest 日志 'libdmabufheap allocation failed for mtk_mm heap'、
#      'Failed to allocate (128 x 128) layerCount 1 format 1 usage 300: -12'）。
#      libui GraphicBuffer 仅在 allocate 成功后才写 ANativeWindowBuffer::usage 字段，
#      失败则保持 0 → drawLayersInternal→validateOutputBufferUsage 断言
#      getUsage()&0x200==0 → LOG_FATAL('output buffer not gpu writeable') →
#      SF SIGABRT ~5s 循环；FramebufferSurface 1080x2400 usage 0x1b00 同因失败。
#      修复：MTK gralloc 只认 heap 名，把 MTK heap 名注册为 system heap 别名
#      （cached 组走 system_heap_ops，uncached/region 组走 system_uncached_heap_ops）。
#      云机无真 DMA 设备（Mali 为 NO_MALI CPU 模拟），cache 属性不影响正确性。
#      heap 名单为 android.hardware.graphics.allocator-V2-mediatek.so strings 实测：
#      mtk_mm / mtk_mm-uncached / mtk_2d_fr_region / mtk_prot_region /
#      mtk_svp_region-aligned / mtk_wfd_region-aligned。
#      v2 订正（实例 33 Oops 实锤）：uncached 分配的 map/unmap 链
#      （dma_direct_unmap_sg→arch_sync_dma_for_cpu→dcache_inval_poc）依赖
#      heap device 的 dma_mask（上游 system_heap.c:521 仅给 sys_uncached_heap
#      做 dma_coerce_mask_and_coherent(DMA_BIT_MASK(64))）。v1 漏做导致
#      dcache_inval_poc 收到非法地址 0xffffffffc0000000 → level 1 translation
#      fault → Kernel panic 循环（31 次 Linux banner）。v2 给每个注册的 MTK
#      heap device 都补 coerce（cached 组对齐处理，无害）。
#      链式补丁订正（run46/chain30）：原实现锚点=v1 输出文本（增量卷专用），
#      全量卷（recipe 升版重建）上 v1 未打 → 锚点不命中硬失败。改为三态幂等：
#        a) v2 文本已在 → 跳过；
#        b) v1 文本在（增量卷半途）→ 就地升级 v2；
#        c) 原始锚点在（全量卷）→ 一步插入 v2 块（v1+v2 合并语义，插在
#           system_heap_init 的 return 0 前，与 v1/v2 链等价）。
_heap_path = "drivers/dma-buf/heaps/system_heap.c"
_heap_v1 = (
      "\t{\n"
      "\t\tstatic const char * const mtk_cached_heaps[] = {\n"
      "\t\t\t\"mtk_mm\", \"mtk_2d_fr_region\", \"mtk_prot_region\",\n"
      "\t\t};\n"
      "\t\tstatic const char * const mtk_uncached_heaps[] = {\n"
      "\t\t\t\"mtk_mm-uncached\", \"mtk_svp_region-aligned\",\n"
      "\t\t\t\"mtk_wfd_region-aligned\",\n"
      "\t\t};\n"
      "\t\tstruct dma_heap *heap;\n"
      "\t\tint i;\n"
      "\n"
      "\t\tfor (i = 0; i < ARRAY_SIZE(mtk_cached_heaps); i++) {\n"
      "\t\t\texp_info.name = mtk_cached_heaps[i];\n"
      "\t\t\texp_info.ops = &system_heap_ops;\n"
      "\t\t\texp_info.priv = NULL;\n"
      "\t\t\theap = dma_heap_add(&exp_info);\n"
      "\t\t\tif (IS_ERR(heap))\n"
      "\t\t\t\treturn PTR_ERR(heap);\n"
      "\t\t}\n"
      "\t\tfor (i = 0; i < ARRAY_SIZE(mtk_uncached_heaps); i++) {\n"
      "\t\t\texp_info.name = mtk_uncached_heaps[i];\n"
      "\t\t\texp_info.ops = &system_uncached_heap_ops;\n"
      "\t\t\texp_info.priv = NULL;\n"
      "\t\t\theap = dma_heap_add(&exp_info);\n"
      "\t\t\tif (IS_ERR(heap))\n"
      "\t\t\t\treturn PTR_ERR(heap);\n"
      "\t\t}\n"
      "\t}\n"
)
_heap_v2 = (
      "\t{\n"
      "\t\tstatic const char * const mtk_cached_heaps[] = {\n"
      "\t\t\t\"mtk_mm\", \"mtk_2d_fr_region\", \"mtk_prot_region\",\n"
      "\t\t};\n"
      "\t\tstatic const char * const mtk_uncached_heaps[] = {\n"
      "\t\t\t\"mtk_mm-uncached\", \"mtk_svp_region-aligned\",\n"
      "\t\t\t\"mtk_wfd_region-aligned\",\n"
      "\t\t};\n"
      "\t\tstruct dma_heap *heap;\n"
      "\t\tint i;\n"
      "\n"
      "\t\tfor (i = 0; i < ARRAY_SIZE(mtk_cached_heaps); i++) {\n"
      "\t\t\texp_info.name = mtk_cached_heaps[i];\n"
      "\t\t\texp_info.ops = &system_heap_ops;\n"
      "\t\t\texp_info.priv = NULL;\n"
      "\t\t\theap = dma_heap_add(&exp_info);\n"
      "\t\t\tif (IS_ERR(heap))\n"
      "\t\t\t\treturn PTR_ERR(heap);\n"
      "\t\t\tdma_coerce_mask_and_coherent(dma_heap_get_dev(heap), DMA_BIT_MASK(64));\n"
      "\t\t}\n"
      "\t\tfor (i = 0; i < ARRAY_SIZE(mtk_uncached_heaps); i++) {\n"
      "\t\t\texp_info.name = mtk_uncached_heaps[i];\n"
      "\t\t\texp_info.ops = &system_uncached_heap_ops;\n"
      "\t\t\texp_info.priv = NULL;\n"
      "\t\t\theap = dma_heap_add(&exp_info);\n"
      "\t\t\tif (IS_ERR(heap))\n"
      "\t\t\t\treturn PTR_ERR(heap);\n"
      "\t\t\t/* 与上游 system-uncached 相同：uncached 分配的 cache 维护\n"
      "\t\t\t * （dcache_inval_poc）依赖 dev->dma_mask，必须 coerce 64bit */\n"
      "\t\t\tdma_coerce_mask_and_coherent(dma_heap_get_dev(heap), DMA_BIT_MASK(64));\n"
      "\t\t}\n"
      "\t}\n"
)
_heap_anchor = (
      "\tsystem_uncached_heap_ops.allocate = system_uncached_heap_allocate;\n"
      "\n"
      "\treturn 0;\n"
      "}\n"
)
_hp = pathlib.Path(_heap_path)
_hs = _hp.read_text()
if _heap_v2 in _hs:
    print("[wire-kbase] system_heap.c MTK dma_heap 别名 v2：已存在，跳过")
elif _heap_v1 in _hs:
    _hp.write_text(_hs.replace(_heap_v1, _heap_v2, 1))
    print("[wire-kbase] system_heap.c MTK dma_heap 别名：v1 已在，升级 v2")
elif _heap_anchor in _hs:
    _hp.write_text(_hs.replace(
            _heap_anchor,
            "\tsystem_uncached_heap_ops.allocate = system_uncached_heap_allocate;\n"
            "\n" + _heap_v2 + "\treturn 0;\n}\n", 1))
    print("[wire-kbase] system_heap.c MTK dma_heap 别名 v2：全量卷一步打 v1+v2")
else:
    sys.exit("[wire-kbase] system_heap.c MTK dma_heap 别名：三种锚点全未命中，请人工核对")

# (12) Phase C·第九补丁：放行 UK 11.46 user DDK 的 72 字节 job atom（stride=72）。
#     依据（run35，gpu.md §7.22，libGLES_mali.so 反汇编取证）：
#       - 1de5050 = KBASE_IOCTL_JOB_SUBMIT（_IOWR(0x80,2,16B)=0x40108002）包装，
#         参数即 struct kbase_ioctl_job_submit {u64 addr; u32 nr_atoms; u32 stride}；
#       - 调用者 1de2160 硬编码 stride=72（mov w9,#0x48），其上层 1cf1150 的
#         atom 数组步进 0x48 —— user 11.46 的 atom 结构 = 72 字节；
#       - 内核 stride 白名单 {40,48,56} 拒收 → ioctl -EINVAL → 1de2160 对
#         非 0 返回直接走纯 abort thunk（1f530b0，无消息）→ SF RenderEngine
#         循环 SIGABRT；dmesg 每 5s 一条 "Stride 72 passed to job_submit ..."。
#     处理（v70 订正）：72B atom = kernel v1 base_jd_atom（64B，seq_nr 开头）
#     + 8B 尾部，不是 v2 布局！run39 hexdump 逐字节吻合 v1 偏移：
#       +0x00 seq_nr=0、+0x08 jc=b4000070…、+0x30 atom_number=0x01、
#       +0x34 core_req=0x209（(16d) 用 +0x08/+0x34 成功定位 RT 填色亦实证）。
#     v69 及以前误按 v2 解析（从 +0x00 拷 56B 到 &user_atom.jc）→ 字段整体
#     错位：jc←seq_nr(0)、atom_number←+0x28 nr_extres（普通 job 恒 0、带
#     1 extres 的 job=1）→ 全部 atom 只挤 atoms 槽 0/1 → 每次 submit 必撞
#     滞留事件（run82 碰撞日志只出现 …/0、…/1 实锤）→ path C 慢性碰撞、
#     事件 atom_number 回传错乱。v70 起 stride==72 走 v1 copy 路径。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\tbool jd_atom_is_v2 = (stride == sizeof(struct base_jd_atom_v2) ||\n"
      "\t\t\t      stride == offsetof(struct base_jd_atom_v2, renderpass_id));\n",
      "\t/* CDH: UK 11.46 user DDK 的 atom 为 72 字节 = v1 base_jd_atom(64B)\n"
      "\t * + 8B 尾部（v70 订正：勿按 v2 解析，见 wire-kbase.sh (12) 注释）\n"
      "\t */\n"
      "\tstatic atomic_t cdh_stride72_probe = ATOMIC_INIT(0);\n"
      "\tbool jd_atom_is_v2 = (stride == sizeof(struct base_jd_atom_v2) ||\n"
      "\t\t\t      stride == offsetof(struct base_jd_atom_v2, renderpass_id));\n",
      "jd_atom_is_v2 撤销 stride=72（v70：72B 走 v1 布局）")

patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\tif (stride != offsetof(struct base_jd_atom_v2, renderpass_id) &&\n"
      "\t    stride != sizeof(struct base_jd_atom_v2) &&\n"
      "\t    stride != offsetof(struct base_jd_atom, renderpass_id) &&\n"
      "\t    stride != sizeof(struct base_jd_atom)) {\n"
      "\t\tdev_err(kbdev->dev,\n"
      "\t\t\t\"Stride %u passed to job_submit isn't supported by the kernel\\n\", stride);\n"
      "\t\treturn -EINVAL;\n"
      "\t}\n",
      "\tif (stride != offsetof(struct base_jd_atom_v2, renderpass_id) &&\n"
      "\t    stride != sizeof(struct base_jd_atom_v2) &&\n"
      "\t    stride != offsetof(struct base_jd_atom, renderpass_id) &&\n"
      "\t    stride != sizeof(struct base_jd_atom) &&\n"
      "\t    stride != 72) {\n"
      "\t\tdev_err(kbdev->dev,\n"
      "\t\t\t\"Stride %u passed to job_submit isn't supported by the kernel\\n\", stride);\n"
      "\t\treturn -EINVAL;\n"
      "\t}\n"
      "\n"
      "\t/* CDH: stride=72 首 atom 布局取证探针（前 4 次提交，run36 dmesg 比对\n"
      "\t * 前 48 字节与 kernel v2 的兼容性，见 wire-kbase.sh (12)；确认后可删）\n"
      "\t */\n"
      "\tif (stride == 72 && atomic_inc_return(&cdh_stride72_probe) <= 4) {\n"
      "\t\tu8 cdh_atom[72];\n"
      "\n"
      "\t\tif (!copy_from_user(cdh_atom, user_addr, sizeof(cdh_atom))) {\n"
      "\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t \"cdh-mali: stride=72 submit nr_atoms=%u, first atom:\\n\",\n"
      "\t\t\t\t nr_atoms);\n"
      "\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \", DUMP_PREFIX_OFFSET,\n"
      "\t\t\t\t       32, 8, cdh_atom, sizeof(cdh_atom), false);\n"
      "\t\t}\n"
      "\t}\n",
      "job_submit stride 白名单放行 72 + 首 atom hexdump 探针")

# (12b) run39 实测订正：72B atom 在 v2 padding 区（user+0x31）有新字段
#      （hexdump 首 atom 0x30-0x37 = 01 03 00 00 09 02 00 00：renderpass_id=1、
#      +0x31=3 为 11.46 新字段；core_req@0x2C=0x209 soft job），内核报
#      "Bad padding byte 0: 3" → -EINVAL → 同一 abort 链。豁免 padding 校验：
#      该字节落入 kernel user_atom.padding（提交后不被消费），忽略即可。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\tif (stride == offsetof(struct base_jd_atom_v2, renderpass_id)) {\n"
      "\t\t\tdev_dbg(kbdev->dev, \"No renderpass ID: use 0\\n\");\n"
      "\t\t\tuser_atom.renderpass_id = 0;\n"
      "\t\t} else {\n",
      "\t\tif (stride == offsetof(struct base_jd_atom_v2, renderpass_id)) {\n"
      "\t\t\tdev_dbg(kbdev->dev, \"No renderpass ID: use 0\\n\");\n"
      "\t\t\tuser_atom.renderpass_id = 0;\n"
      "\t\t} else if (stride == 72) {\n"
      "\t\t\t/* CDH: UK 11.46 的 72B atom 在 v2 padding 区（+0x31）带新字段\n"
      "\t\t\t * （run39 hexdump：padding[0]=3），豁免 padding 校验；该字节\n"
      "\t\t\t * 落入 kernel 不消费的 padding 区。见 wire-kbase.sh (12b) */\n"
      "\t\t\tdev_dbg(kbdev->dev, \"CDH: 72B atom, skip padding check\\n\");\n"
      "\t\t} else {\n",
      "72B atom 豁免 padding 校验（run39 订正）")

# (12c) v70：v1 copy 路径限长。72B user atom = v1 base_jd_atom(64B)+8B 尾部，
#      else 分支 copy stride(72) 字节进 64B 栈结构体会溢出 8B —— 只拷
#      min(stride, sizeof(user_atom))，尾部 8B 不读（user_addr 步进仍按 72）。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\t} else {\n"
      "\t\t\tif (copy_from_user(&user_atom, user_addr, stride) != 0) {\n",
      "\t\t} else {\n"
      "\t\t\t/* CDH: stride=72 时 user atom = v1 base_jd_atom(64B)+8B 尾部，\n"
      "\t\t\t * 只拷 min(stride, sizeof) 防栈溢出（wire-kbase.sh (12c)） */\n"
      "\t\t\tif (copy_from_user(&user_atom, user_addr,\n"
      "\t\t\t\t\t   stride > sizeof(user_atom) ? sizeof(user_atom) : stride) != 0) {\n",
      "v1 copy 限长 min(stride, sizeof)（72B 只拷 64B）")

# (14) Phase C·第十四补丁：virtio-gpu vblank 支持（hrtimer 模拟 60Hz）。
#      根因（run50 取证，watchdog 死锁链闭环）：
#        ANR trace（watchdog kill 时自动生成）实锤 system_server android.ui
#        线程持 WindowManagerGlobalLock 阻塞在 BpSurfaceComposer::captureLayersSync
#        （TaskSnapshotController 截屏快照链）← SF 不回 binder。
#        SF/HWC 侧：MTK HWC 的 DrmModeResource::waitNextVsync 走**标准
#        drmWaitVBlank**（hwcomposer.mt6833.so @0x191b54 实锤，非 MTK 私有
#        ioctl），而上游 virtio-gpu 无 enable_vblank 回调且未 drm_vblank_init
#        → drm_waitvblank 恒 -EOPNOTSUPP → HWC vsync 线程忙等（qemu.log 每
#        4ms 一条 "failed to waitNextVsync: -1"）→ HWC present/screenshot
#        链永不完成 → SF binder 挂 → system_server ui 持锁 67-143s →
#        Watchdog KILLING 循环（run47/50 各 2-9 次/boot）。
#      实现：hrtimer 60Hz 调 drm_crtc_handle_vblank()——vblank counter 与
#      timestamp 由 drm vblank core 维护，drmWaitVBlank(RELATIVE) 语义天然
#      成立（等待者被 timer 唤醒）。云机单块 virtio-gpu，全局 timer 足够。
#      竞态：disable_vblank 先 hrtimer_cancel（同步等回调退出）再清指针。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "#include <drm/drm_atomic_helper.h>\n",
      "#include <linux/hrtimer.h>\n"
      "\n"
      "#include <drm/drm_atomic_helper.h>\n"
      "#include <drm/drm_vblank.h>\n",
      "virtgpu_display.c include hrtimer+vblank")

patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "static const struct drm_crtc_funcs virtio_gpu_crtc_funcs = {\n"
      "\t.set_config             = drm_atomic_helper_set_config,\n",
      "/* CDH(gold-15): hrtimer 模拟 60Hz vblank —— MTK HWC 的 drmWaitVBlank\n"
      " * 依赖（上游 virtio-gpu 无 vblank，drm_waitvblank 恒 -EOPNOTSUPP，\n"
      " * HWC vsync 忙等 → SF present/screenshot 挂 → system_server watchdog\n"
      " * 死锁，run50 取证）。云机单设备，全局 timer；counter/timestamp 由\n"
      " * drm vblank core 维护，timer 回调只负责 handle_vblank 唤醒等待者。\n"
      " */\n"
      "static struct hrtimer cdh_vblank_timer;\n"
      "static struct drm_crtc *cdh_vblank_crtc;\n"
      "static ktime_t cdh_vblank_period;\n"
      "\n"
      "static enum hrtimer_restart cdh_vblank_timer_fn(struct hrtimer *timer)\n"
      "{\n"
      "\tstruct drm_crtc *crtc = cdh_vblank_crtc;\n"
      "\n"
      "\tif (crtc)\n"
      "\t\tdrm_crtc_handle_vblank(crtc);\n"
      "\thrtimer_forward_now(timer, cdh_vblank_period);\n"
      "\treturn HRTIMER_RESTART;\n"
      "}\n"
      "\n"
      "static int virtio_gpu_crtc_enable_vblank(struct drm_crtc *crtc)\n"
      "{\n"
      "\tcdh_vblank_crtc = crtc;\n"
      "\tcdh_vblank_period = ktime_set(0, NSEC_PER_SEC / 60);\n"
      "\thrtimer_start(&cdh_vblank_timer, cdh_vblank_period,\n"
      "\t\t      HRTIMER_MODE_REL);\n"
      "\treturn 0;\n"
      "}\n"
      "\n"
      "static void virtio_gpu_crtc_disable_vblank(struct drm_crtc *crtc)\n"
      "{\n"
      "\thrtimer_cancel(&cdh_vblank_timer);\n"
      "\tcdh_vblank_crtc = NULL;\n"
      "}\n"
      "\n"
      "static const struct drm_crtc_funcs virtio_gpu_crtc_funcs = {\n"
      "\t.set_config             = drm_atomic_helper_set_config,\n",
      "virtgpu_display.c vblank 实现（hrtimer 60Hz）",
      done="static enum hrtimer_restart cdh_vblank_timer_fn")

patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\t.page_flip              = drm_atomic_helper_page_flip,\n",
      "\t.page_flip              = drm_atomic_helper_page_flip,\n"
      "\t.enable_vblank          = virtio_gpu_crtc_enable_vblank,\n"
      "\t.disable_vblank         = virtio_gpu_crtc_disable_vblank,\n",
      "virtgpu_display.c crtc_funcs 补 vblank 回调")

patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tdrm_mode_config_reset(vgdev->ddev);\n",
      "\t/* CDH(gold-15): 启用 vblank core + 初始化 60Hz timer（见上方） */\n"
      "\tret = drm_vblank_init(vgdev->ddev, vgdev->num_scanouts);\n"
      "\tif (ret)\n"
      "\t\treturn ret;\n"
      "\thrtimer_init(&cdh_vblank_timer, CLOCK_MONOTONIC,\n"
      "\t\t      HRTIMER_MODE_REL);\n"
      "\tcdh_vblank_timer.function = cdh_vblank_timer_fn;\n"
      "\n"
      "\tdrm_mode_config_reset(vgdev->ddev);\n",
      "virtgpu_display.c modeset_init 启用 vblank core",
      done="hrtimer_init(&cdh_vblank_timer")

# (14b) vblank 诊断打印（run51 取证：补丁是否真的进入运行内核待证）：
#     enable_vblank 被调时打一行。幂等两态：旧版实现（无打印）在卷上时，
#     以 enable 函数体首行 cdh_vblank_crtc = crtc; 为锚插入打印。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "static int virtio_gpu_crtc_enable_vblank(struct drm_crtc *crtc)\n"
      "{\n"
      "\tcdh_vblank_crtc = crtc;\n",
      "static int virtio_gpu_crtc_enable_vblank(struct drm_crtc *crtc)\n"
      "{\n"
      "\tDRM_INFO(\"cdh_vblank: enable on crtc %s\\n\", crtc->name);\n"
      "\tcdh_vblank_crtc = crtc;\n",
      "virtgpu_display.c vblank enable 诊断打印")

# (14c) vblank init 诊断打印（run52 取证：enable 打印 0 次且 vsync 仍失败，
#     需分辨「modeset_init 补丁没执行」vs「执行了但 ioctl 路径短路」）：
#     drm_vblank_init 成功后必打一行（启动期）。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tret = drm_vblank_init(vgdev->ddev, vgdev->num_scanouts);\n"
      "\tif (ret)\n"
      "\t\treturn ret;\n",
      "\tret = drm_vblank_init(vgdev->ddev, vgdev->num_scanouts);\n"
      "\tif (ret)\n"
      "\t\treturn ret;\n"
      "\tDRM_INFO(\"cdh_vblank: init ok, num_crtcs=%u\\n\",\n"
      "\t\t vgdev->num_scanouts);\n",
      "virtgpu_display.c vblank init 诊断打印")

# (14d) drm_vblank.c ioctl 入口诊断（run53 取证：init ok 打印已出但 enable
#     打印 0 次 + waitNextVsync 持续 -1——需分辨「ioctl 没到达 vblank core」
#     vs「到达但中途返回」）。打 type/flags/num_crtcs，限速打印（仅诊断轮）。
patch("drivers/gpu/drm/drm_vblank.c",
      "\tif (!drm_wait_vblank_supported(dev))\n"
      "\t\treturn -EOPNOTSUPP;\n",
      "\tpr_info_ratelimited(\"cdh_vblank: wait ioctl type=0x%x num_crtcs=%u\\n\",\n"
      "\t\t\t     vblwait->request.type, dev->num_crtcs);\n"
      "\tif (!drm_wait_vblank_supported(dev))\n"
      "\t\treturn -EOPNOTSUPP;\n",
      "drm_vblank.c wait ioctl 入口诊断打印")

# (14e) run54/55 定案后续：pipe=0 pipe_index=0 本来就正常（lease 假设亦错），
#      ioctl 全链走到 drm_vblank_get 前一行的下一行，但 enable 打印仍 0——
#      在 get/enable/__enable_vblank 三层入口加打印，一锤定音断点层级。
patch("drivers/gpu/drm/drm_vblank.c",
      "int drm_vblank_get(struct drm_device *dev, unsigned int pipe)\n"
      "{\n"
      "\tstruct drm_vblank_crtc *vblank = &dev->vblank[pipe];\n",
      "int drm_vblank_get(struct drm_device *dev, unsigned int pipe)\n"
      "{\n"
      "\tstruct drm_vblank_crtc *vblank = &dev->vblank[pipe];\n"
      "\tpr_info_ratelimited(\"cdh_vblank: get entry pipe=%u refcnt=%d has_vblank=%d ncrtcs=%u\\n\",\n"
      "\t\t\t     pipe, atomic_read(&vblank->refcount),\n"
      "\t\t\t     drm_dev_has_vblank(dev), dev->num_crtcs);\n",
      "drm_vblank.c get 入口打印")

patch("drivers/gpu/drm/drm_vblank.c",
      "\tassert_spin_locked(&dev->vbl_lock);\n"
      "\n"
      "\tspin_lock(&dev->vblank_time_lock);\n",
      "\tassert_spin_locked(&dev->vbl_lock);\n"
      "\tpr_info_ratelimited(\"cdh_vblank: enable entry pipe=%u enabled=%d\\n\",\n"
      "\t\t\t     pipe, vblank->enabled);\n"
      "\n"
      "\tspin_lock(&dev->vblank_time_lock);\n",
      "drm_vblank.c enable 入口打印")

# (14f) run57 定案：get entry 打印显示 refcnt 恒=1、enabled 恒=false（else
#      分支 -EINVAL 死循环），且无任何 enable 打印——26s 前有一次无日志的
#      +1 泄漏（console 被刷屏冲掉或 vendor 状态机黑盒）。不再深挖来源，
#      直接死状态自愈：else 分支 !enabled 时强制重走 drm_vblank_enable
#      （hrtimer 启动幂等，重复 start 只会重置定时器）。
patch("drivers/gpu/drm/drm_vblank.c",
      "\t} else {\n"
      "\t\tif (!vblank->enabled) {\n"
      "\t\t\tatomic_dec(&vblank->refcount);\n"
      "\t\t\tret = -EINVAL;\n"
      "\t\t}\n"
      "\t}\n"
      "\tspin_unlock_irqrestore(&dev->vbl_lock, irqflags);\n",
      "\t} else {\n"
      "\t\tif (!vblank->enabled) {\n"
      "\t\t\t/* CDH(gold-15): 死状态自愈——refcount 悬空(+1 泄漏)且\n"
      "\t\t\t * enabled=false 时，原版直接 -EINVAL 使 vsync 永挂\n"
      "\t\t\t * （run57：refcnt 恒 1 → SF/HWC 死锁链根因）。强制\n"
      "\t\t\t * 重走 enable（hrtimer start 幂等），成功则不清计数。 */\n"
      "\t\t\tret = drm_vblank_enable(dev, pipe);\n"
      "\t\t\tif (ret)\n"
      "\t\t\t\tatomic_dec(&vblank->refcount);\n"
      "\t\t}\n"
      "\t}\n"
      "\tspin_unlock_irqrestore(&dev->vbl_lock, irqflags);\n",
      "drm_vblank.c get 死状态自愈（强制 enable）")

# (16) B2 blit 桥取证探针：dump 非 soft atom 的 job chain 首 256B +
#      extres_list + END_RENDERPASS 的 base_jd_fragment 四链地址。
#      依据（run66 dmesg + mali_base_jm_kernel.h 布局）：
#        - 72B atom 前 56B 与 base_jd_atom 兼容（§7.22）；run66 实测 T1439
#          提交 FS atom（core_req=0x1=BASE_JD_REQ_FS）、jc=0x5effb5d780
#          （SAME_VA：GPU VA == 用户 VA），render target 藏在 jc 指向的
#          job chain 里；T822 的 0x209/0x203/0x202 为 SOFT_JIT_ALLOC/
#          FENCE_* 软作业（jc 是 CPU 参数指针），跳过不 dump。
#        - kbase 内核不解析 job chain（jc 只写 JS_CONFIG 寄存器），job
#          descriptor 为 Mali HW 格式 → RT 字段偏移需 dump 实测字节对照
#          Mesa panfrost genxml 布局定案（B2 搬运/填充的落地点）。
#      位置：kbase_jd_submit atom 循环、END_RENDERPASS 处理之后（该类 atom
#      的 jc 已置 0 自动跳过）；ioctl 用户进程上下文，copy_from_user 合法。
#      探针限次（jc/extres 8 次、IR 4 次），RT 布局定案后可删。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n"
      "\n"
      "\t\tmutex_lock(&jctx->lock);\n",
      "\t\t/* CDH: B2 取证探针（wire-kbase.sh (16)）——dump 非 soft atom\n"
      "\t\t * 的 job chain 首 256B（jc=GPU VA=SAME_VA 用户地址）、\n"
      "\t\t * extres_list（RT dma-buf 导入表）、END_RENDERPASS 四链地址，\n"
      "\t\t * 用于定位 fragment job 的 render target 字段。限次，定案后删。\n"
      "\t\t * (16b) 补 kernel 视角摘要行：72B atom 的 v2 copy 只读前 56B，\n"
      "\t\t * 11.46 字段迁移（core_req 疑在 +0x34=padding 区）使 kernel 字段\n"
      "\t\t * 与 hexdump 直读存在歧义（run68：jc 恒 0 致 chain dump 零命中），\n"
      "\t\t * 摘要行打印 kernel 实际解析值以一次定案布局。 */\n"
      "\t\tstatic atomic_t cdh_all_probe = ATOMIC_INIT(0);\n"
      "\t\tif (atomic_inc_return(&cdh_all_probe) <= 12) {\n"
      "\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t \"cdh-mali: B2-atom i=%u jc=0x%llx core_req=0x%x nr_extres=%u extres=0x%llx rp=%u atom_nr=%u\\n\",\n"
      "\t\t\t\t i, user_atom.jc, user_atom.core_req,\n"
      "\t\t\t\t user_atom.nr_extres, user_atom.extres_list,\n"
      "\t\t\t\t user_atom.renderpass_id, user_atom.atom_number);\n"
      "\t\t}\n"
      "\t\t/* (16c) atom 原始 72B——run70 布局定案（solution.md §12.4）：\n"
      "\t\t * 真 jc 在 +0x08、真 core_req 在 +0x34（FS=0x1/TILER=0x2/\n"
      "\t\t * SOFT_JIT_ALLOC=0x209），kernel v2 copy 只读前 56B 且字段全错位\n"
      "\t\t * → 每次都按 raw 解析真值供 B2 链 dump 使用；hexdump 限 4 次。 */\n"
      "\t\tu64 cdh_real_jc = 0;\n"
      "\t\tu32 cdh_real_req = 0;\n"
      "\t\t{\n"
      "\t\t\tstatic atomic_t cdh_raw_probe = ATOMIC_INIT(0);\n"
      "\t\t\tu8 cdh_raw[72];\n"
      "\t\t\tint cdh_raw_ok = !copy_from_user(cdh_raw, user_addr,\n"
      "\t\t\t\t\t\t  sizeof(cdh_raw));\n"
      "\n"
      "\t\t\tif (cdh_raw_ok) {\n"
      "\t\t\t\tmemcpy(&cdh_real_jc, cdh_raw + 0x08, 8);\n"
      "\t\t\t\tmemcpy(&cdh_real_req, cdh_raw + 0x34, 4);\n"
      "\t\t\t}\n"
      "\t\t\tif (cdh_raw_ok &&\n"
      "\t\t\t    atomic_inc_return(&cdh_raw_probe) <= 4) {\n"
      "\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t \"cdh-mali: B2-atom-raw i=%u 72B user atom (real jc=0x%llx real req=0x%x):\\n\",\n"
      "\t\t\t\t\t i, cdh_real_jc, cdh_real_req);\n"
      "\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t       cdh_raw, sizeof(cdh_raw), false);\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tif (cdh_real_jc && !(cdh_real_req & BASE_JD_REQ_SOFT_JOB)) {\n"
      "\t\t\tstatic atomic_t cdh_jc_probe = ATOMIC_INIT(0);\n"
      "\t\t\tu8 cdh_chain[256];\n"
      "\n"
      "\t\t\tif (atomic_inc_return(&cdh_jc_probe) <= 8 &&\n"
      "\t\t\t    !copy_from_user(cdh_chain, u64_to_user_ptr(cdh_real_jc),\n"
      "\t\t\t\t\t    sizeof(cdh_chain))) {\n"
      "\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t \"cdh-mali: B2 chain jc=0x%llx real req=0x%x, chain head:\\n\",\n"
      "\t\t\t\t\t cdh_real_jc, cdh_real_req);\n"
      "\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t       cdh_chain, sizeof(cdh_chain), false);\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\t/* (16d) B2 v1 渲染桥：FS atom 提交时解析 v9 Fragment Job →\n"
      "\t\t * FBD → RT 数组，对 RT0 填纯色（SAME_VA 直写；NO_MALI 下 job\n"
      "\t\t * 立即完成，SF 合成上屏 → 画面可见）。布局依据 Mesa panfrost\n"
      "\t\t * genxml v9.xml + run71 chain dump 字节对照（§13）：\n"
      "\t\t *   Fragment Job 64B：Type u7@(0x10:1)=9=Fragment、\n"
      "\t\t *     Next u64@0x18、Payload@0x20、FBD 指针 u64@0x28（低 6 位\n"
      "\t\t *     打包：bit0=type、bit1=ZS CRC 扩展、bit2-5=RT 数-1）；\n"
      "\t\t *   FBD：Parameters 64B（宽 u16@0x20、高 u16@0x22，-1 编码）\n"
      "\t\t *     + Padding 64B → [ZS CRC 扩展 64B] → RT 数组，每项 64B，\n"
      "\t\t *     RGB RT：Base u64@0x20、Row Stride u32@0x28、\n"
      "\t\t *     Surface Stride u32@0x2c（genxml start 为 word:bit，word=4B）。\n"
      "\t\t */\n"
      "\t\tif ((cdh_real_req & BASE_JD_REQ_FS) && cdh_real_jc) {\n"
      "\t\t\tstatic atomic_t cdh_fill_probe = ATOMIC_INIT(0);\n"
      "\t\t\tu64 cdh_j = cdh_real_jc;\n"
      "\t\t\tu32 cdh_job_n;\n"
      "\t\t\tfor (cdh_job_n = 0; cdh_job_n < 8 && cdh_j; cdh_job_n++) {\n"
      "\t\t\t\tu8 cdh_job[64];\n"
      "\t\t\t\tu32 cdh_hdr, cdh_type;\n"
      "\t\t\t\tu64 cdh_next, cdh_fb;\n"
      "\n"
      "\t\t\t\tif (copy_from_user(cdh_job, u64_to_user_ptr(cdh_j),\n"
      "\t\t\t\t\t\t   sizeof(cdh_job)))\n"
      "\t\t\t\t\tbreak;\n"
      "\t\t\t\tmemcpy(&cdh_hdr, cdh_job + 0x10, 4);\n"
      "\t\t\t\tmemcpy(&cdh_next, cdh_job + 0x18, 8);\n"
      "\t\t\t\tmemcpy(&cdh_fb, cdh_job + 0x28, 8);\n"
      "\t\t\t\tcdh_type = (cdh_hdr >> 1) & 0x7f;\n"
      "\t\t\t\tif (cdh_type == 9) { /* Fragment */\n"
      "\t\t\t\t\tu64 cdh_fbd = cdh_fb & ~0x3fULL;\n"
      "\t\t\t\t\tu32 cdh_rts = ((cdh_fb >> 2) & 0xf) + 1;\n"
      "\t\t\t\t\tu32 cdh_zs = (cdh_fb >> 1) & 1;\n"
      "\t\t\t\t\tu8 cdh_p[64], cdh_rt[64];\n"
      "\t\t\t\t\tu32 cdh_w = 0, cdh_h = 0;\n"
      "\t\t\t\t\tu64 cdh_base = 0;\n"
      "\t\t\t\t\tu32 cdh_rows = 0, cdh_surf = 0;\n"
      "\t\t\t\t\tu32 cdh_w0 = 0, cdh_w1 = 0, cdh_w2 = 0;\n"
      "\t\t\t\t\tu32 cdh_blk = 0, cdh_fmt = 0, cdh_we = 0, cdh_filled = 0;\n"
      "\n"
      "\t\t\t\t\tif (copy_from_user(cdh_p,\n"
      "\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_fbd),\n"
      "\t\t\t\t\t\t\t   sizeof(cdh_p)))\n"
      "\t\t\t\t\t\tgoto cdh_next_job;\n"
      "\t\t\t\t\tmemcpy(&cdh_w, cdh_p + 0x20, 2);\n"
      "\t\t\t\t\tmemcpy(&cdh_h, cdh_p + 0x22, 2);\n"
      "\t\t\t\t\tcdh_w += 1;\n"
      "\t\t\t\t\tcdh_h += 1;\n"
      "\t\t\t\t\tif (copy_from_user(cdh_rt,\n"
      "\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_fbd + 128 +\n"
      "\t\t\t\t\t\t\t\t\t   (cdh_zs ? 64 : 0)),\n"
      "\t\t\t\t\t\t\t   sizeof(cdh_rt)))\n"
      "\t\t\t\t\t\tgoto cdh_next_job;\n"
      "\t\t\t\t\tmemcpy(&cdh_base, cdh_rt + 0x20, 8);\n"
      "\t\t\t\t\tmemcpy(&cdh_rows, cdh_rt + 0x28, 4);\n"
      "\t\t\t\t\tmemcpy(&cdh_surf, cdh_rt + 0x2c, 4);\n"
      "\t\t\t\t\tmemcpy(&cdh_w0, cdh_rt + 0x00, 4);\n"
      "\t\t\t\t\tmemcpy(&cdh_w1, cdh_rt + 0x04, 4);\n"
      "\t\t\t\t\tmemcpy(&cdh_w2, cdh_rt + 0x08, 4);\n"
      "\t\t\t\t\tcdh_we = cdh_w1 & 1;\n"
      "\t\t\t\t\tcdh_fmt = (cdh_w1 >> 3) & 0x1f;\n"
      "\t\t\t\t\t/* Writeback Block Format（word1:8-11，v9.xml enum Block\n"
      "\t\t\t\t\t * Format：0=No Write 1=Tiled 2=Linear 12=AFBC 13=AFBC Tiled）*/\n"
      "\t\t\t\t\tcdh_blk = (cdh_w1 >> 8) & 0xf;\n"
      "\t\t\t\t\t{\n"
      "\t\t\t\t\t\tstatic atomic_t cdh_rt_probe = ATOMIC_INIT(0);\n"
      "\n"
      "\t\t\t\t\t\tif (atomic_inc_return(&cdh_rt_probe) <= 4) {\n"
      "\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t \"cdh-mali: B2 rt-struct:\\n\");\n"
      "\t\t\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t\t\t       cdh_rt, sizeof(cdh_rt), false);\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t\tif (!cdh_base || !cdh_rows || cdh_rows > 0x10000 ||\n"
      "\t\t\t\t\t    !cdh_h || cdh_h > 0x4000)\n"
      "\t\t\t\t\t\tgoto cdh_next_job;\n"
      "\t\t\t\t\t/* 填色 v3：线性面（blk=2）直填 行距×高；AFBC 面\n"
      "\t\t\t\t\t * （blk=12/13）改写 solid superblock 头（合法纯色压缩面）。\n"
      "\t\t\t\t\t * 布局依据 Mesa pan_afbc.h/pan_mod.c + run73 全 13 样本\n"
      "\t\t\t\t\t * 数值实测双证吻合：\n"
      "\t\t\t\t\t *   solid 头 16B = u64[0] 全 0（subblock0=0 即 solid）\n"
      "\t\t\t\t\t *     + u8[8..11] = RGBA8888；\n"
      "\t\t\t\t\t *   非平铺 blk=12：头行主序，行步长=Row Stride，\n"
      "\t\t\t\t\t *     sb=16x16（Wide block 时 32x8），Body offset=头总大小\n"
      "\t\t\t\t\t *     对齐 128（实测 w=75h=163: 80*11=880→896 ✓）；\n"
      "\t\t\t\t\t *   平铺 blk=13：8x8 SB 为一 tile（tile 头 1024B），tile\n"
      "\t\t\t\t\t *     行主序、行步长=Row Stride=ALIGN(sb_cols*128,1024)，\n"
      "\t\t\t\t\t *     Body offset=tiles_x*tiles_y*1024 对齐 4096（实测\n"
      "\t\t\t\t\t *     1080x2400: 9*19*1024=175104→176128 ✓）。\n"
      "\t\t\t\t\t * solid 块无 body 载荷，body 不动。 */\n"
      "\t\t\t\t\t/* CDH: 彻底关闭 (16d) 纯绿色硬编码兜底填色，保留 RT 元数据供宿主渲染 */\n"
      "\t\t\t\t\tcdh_filled = 0;\n"
      "\t\t\t\t\tif (atomic_inc_return(&cdh_fill_probe) <= 16)\n"
      "\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t \"cdh-mali: B2 fill rt=0x%llx rows=%u surf=%u w=%u h=%u rts=%u zs=%u blk=%u fmt=%u we=%u w0=0x%x w2=0x%x filled=%u\\n\",\n"
      "\t\t\t\t\t\t\t cdh_base, cdh_rows, cdh_surf,\n"
      "\t\t\t\t\t\t\t cdh_w, cdh_h, cdh_rts, cdh_zs,\n"
      "\t\t\t\t\t\t\t cdh_blk, cdh_fmt, cdh_we,\n"
      "\t\t\t\t\t\t\t cdh_w0, cdh_w2, cdh_filled);\n"
      "\t\t\t\t}\n"
      "cdh_next_job:\n"
      "\t\t\t\tcdh_j = cdh_next;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tif (user_atom.nr_extres && user_atom.extres_list) {\n"
      "\t\t\tstatic atomic_t cdh_ext_probe = ATOMIC_INIT(0);\n"
      "\t\t\tu64 cdh_ext[BASE_EXT_RES_COUNT_MAX];\n"
      "\t\t\tu32 cdh_n = user_atom.nr_extres;\n"
      "\n"
      "\t\t\tif (cdh_n > BASE_EXT_RES_COUNT_MAX)\n"
      "\t\t\t\tcdh_n = BASE_EXT_RES_COUNT_MAX;\n"
      "\t\t\tif (atomic_inc_return(&cdh_ext_probe) <= 8 &&\n"
      "\t\t\t    !copy_from_user(cdh_ext,\n"
      "\t\t\t\t\t    u64_to_user_ptr(user_atom.extres_list),\n"
      "\t\t\t\t\t    cdh_n * sizeof(u64))) {\n"
      "\t\t\t\tu32 e;\n"
      "\n"
      "\t\t\t\tfor (e = 0; e < cdh_n; e++)\n"
      "\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t \"cdh-mali: B2 extres[%u]=0x%llx\\n\",\n"
      "\t\t\t\t\t\t e, cdh_ext[e]);\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tif (user_atom.core_req & BASE_JD_REQ_END_RENDERPASS) {\n"
      "\t\t\tstatic atomic_t cdh_ir_probe = ATOMIC_INIT(0);\n"
      "\n"
      "\t\t\tif (atomic_inc_return(&cdh_ir_probe) <= 4)\n"
      "\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t \"cdh-mali: B2 IR chains %llx %llx %llx %llx\\n\",\n"
      "\t\t\t\t\t user_jc_incr.norm_read_norm_write,\n"
      "\t\t\t\t\t user_jc_incr.norm_read_forced_write,\n"
      "\t\t\t\t\t user_jc_incr.forced_read_forced_write,\n"
      "\t\t\t\t\t user_jc_incr.forced_read_norm_write);\n"
      "\t\t}\n"
      "\n"
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n"
      "\n"
      "\t\tmutex_lock(&jctx->lock);\n",
      "B2 取证：job chain head + extres + IR 四链 dump 探针",
      done="cdh-mali: B2 chain jc=")

# (19) P3 真机 shader 捕获探针：定位并 dump 真机 Valhall 机器码，为 P3
#      的指令子集扩充（varying 插值/纹理采样）取证。位置与 (16) 同锚点
#      （atom 循环尾、user_addr 步进前），故 cdh_real_jc/cdh_real_req 在作用域内；
#      仅打印不改行为，限次，定案后删。
#      布局依据 Mesa panfrost genxml v9.xml（size/start 单位为 word=4B，
#      start=word:bit），静态模型下 JM 的 Fragment Job/FBD 不含 shader 指针
#      （见 issue-gold15-gpu-jm-format/raw/jm-descriptor-facts.md §5#2），
#      shader 绑定落在 Shader Environment 结构上：
#        Shader Environment 64B：.Resources u64@+0x20、.Shader u64@+0x28、
#          .Thread storage u64@+0x30、.FAU u64@+0x38；
#        Shader Program 32B(align 32)：word0 bits0-3=8(Descriptor Type Shader)、
#          bits4-7=Stage(1=Compute 2=Fragment 3=Vertex)、
#          .Binary 机器码指针 u64@+0x08；
#        Compute Job：Compute Payload@32，内 Compute(ShaderEnv)@word8→env@+0x40，
#          env.Shader@+0x40+0x28=+0x68（v75 实测 SF RenderEngine 提交 type4 链）；
#        Tiler Job 256B：Header@0 … Draw(DCD，struct Draw align64)@128，
#          DCD 内 .Shader Shader Environment@+0x40 → env.Shader@128+0x40+0x28=+0xE8；
#        Malloc Vertex Job 384B：Position env@256、Varying env@320（各自 +0x28）；
#        Job Type：4=Compute 7=Tiler 9=Fragment 11=Malloc vertex 12=Fullscreen。
#      链路预期：Shader Environment.Shader → Shader Program(32B) → .Binary → 机器码。
#      v75→v76 实测纠偏：① chase 签名判据应为 8（Descriptor Type Shader，非 3）；
#      ② .Binary 落在 GPU-exec 区（0x7f00_xxxx_xxxx，CPU 侧 PROT_NONE），
#      copy_from_user 必失败 → 改用 kbase_vmap/kbase_vunmap 取内核可读指针
#      （copy_from_user 仍作兜底）。
#      v77（recapture，消除截断面）：Shader Program（v9.xml 32B）无长度字段
#      （仅 Type/Stage/Preload/Binary）→ dump 上限 128B 放宽到 4KB（防呆），
#      kbase_vmap 整段越出 region 时折半重试（下限 128B），并打印实际遍历长度
#      len=<dump 字节数> end=<首个 flow=end（Flow 枚举 15，bits59-62）处字节数>。
#      128B 旧上限把长 shader 截断（E2E 里 BRANCHZ 目标越界 index=25/19>15
#      的根因），本次按完整指令流重捕。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n"
      "\n"
      "\t\tmutex_lock(&jctx->lock);\n",
      "\t\t/* CDH: P3 真机 shader 捕获探针（wire-kbase.sh (19)）——dump\n"
      "\t\t * Compute/Tiler/MallocVertex job 描述符并按 Shader Environment\n"
      "\t\t * 静态布局提取 Shader Program → .Binary 机器码（.Binary 在\n"
      "\t\t * GPU-exec 区，走 kbase_vmap 取内核映射）；另做有界指针追踪\n"
      "\t\t * （命中 Descriptor Type Shader=8 才打印，抑制误报）。仅打印\n"
      "\t\t * 不改行为；限 16 次提交、24 次追踪；dump 上限 4KB 并打印\n"
      "\t\t * 实际遍历长度 len/end（128B 截断面已消除）。定案后删。 */\n"
      "\t\tif (cdh_real_jc && !(cdh_real_req & BASE_JD_REQ_SOFT_JOB) &&\n"
      "\t\t    !(cdh_real_req & BASE_JD_REQ_END_RENDERPASS)) {\n"
      "\t\t\tstatic atomic_t cdh_p3_probe = ATOMIC_INIT(0);\n"
      "\t\t\tstatic atomic_t cdh_p3_chase = ATOMIC_INIT(0);\n"
      "\t\t\tstatic u8 cdh_p3_job[384];\n"
      "\n"
      "\t\t\tif (atomic_inc_return(&cdh_p3_probe) <= 16) {\n"
      "\t\t\t\tu64 cdh_p3_j = cdh_real_jc;\n"
      "\t\t\t\tu32 cdh_p3_n;\n"
      "\n"
      "\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t \"cdh-mali: P3 chain tgid=%d comm=%s jc=0x%llx req=0x%x\\n\",\n"
      "\t\t\t\t\t kctx->tgid, current->comm, cdh_real_jc,\n"
      "\t\t\t\t\t cdh_real_req);\n"
      "\t\t\t\tfor (cdh_p3_n = 0; cdh_p3_n < 8 && cdh_p3_j;\n"
      "\t\t\t\t     cdh_p3_n++) {\n"
      "\t\t\t\t\tu32 cdh_p3_hdr, cdh_p3_type, cdh_p3_len;\n"
      "\t\t\t\t\tu64 cdh_p3_next;\n"
      "\t\t\t\t\tu32 cdh_p3_off;\n"
      "\n"
      "\t\t\t\t\tif (copy_from_user(cdh_p3_job,\n"
      "\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_p3_j),\n"
      "\t\t\t\t\t\t\t   sizeof(cdh_p3_job)))\n"
      "\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\tmemcpy(&cdh_p3_hdr, cdh_p3_job + 0x10, 4);\n"
      "\t\t\t\t\tmemcpy(&cdh_p3_next, cdh_p3_job + 0x18, 8);\n"
      "\t\t\t\t\tcdh_p3_type = (cdh_p3_hdr >> 1) & 0x7f;\n"
      "\t\t\t\t\tif (cdh_p3_type == 4)\n"
      "\t\t\t\t\t\tcdh_p3_len = 128;/* Compute Job */\n"
      "\t\t\t\t\telse if (cdh_p3_type == 7)\n"
      "\t\t\t\t\t\tcdh_p3_len = 256;/* Tiler Job */\n"
      "\t\t\t\t\telse if (cdh_p3_type == 11)\n"
      "\t\t\t\t\t\tcdh_p3_len = 384;/* Malloc Vertex Job */\n"
      "\t\t\t\t\telse\n"
      "\t\t\t\t\t\tcdh_p3_len = 64;\n"
      "\n"
      "\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t \"cdh-mali: P3 job[%u] jc=0x%llx type=%u next=0x%llx\\n\",\n"
      "\t\t\t\t\t\t cdh_p3_n, cdh_p3_j, cdh_p3_type, cdh_p3_next);\n"
      "\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t       cdh_p3_job, cdh_p3_len, false);\n"
      "\t\t\t\t\t/* Fragment Job：payload 无 ShaderEnv，其 fragment\n"
      "\t\t\t\t\t * shader 落在 Tiler Job 的 DCD 里；此处仅打印\n"
      "\t\t\t\t\t * Framebuffer(FBD) 指针（低 6 位打包）供核对。 */\n"
      "\t\t\t\t\tif (cdh_p3_type == 9) {\n"
      "\t\t\t\t\t\tu64 cdh_p3_fb = 0;\n"
      "\n"
      "\t\t\t\t\t\tmemcpy(&cdh_p3_fb, cdh_p3_job + 0x28, 8);\n"
      "\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t \"cdh-mali: P3 frag fb=0x%llx rts=%u zs=%u fbd=0x%llx\\n\",\n"
      "\t\t\t\t\t\t\t cdh_p3_fb,\n"
      "\t\t\t\t\t\t\t (u32)((cdh_p3_fb >> 2) & 0xf) + 1,\n"
      "\t\t\t\t\t\t\t (u32)((cdh_p3_fb >> 1) & 1),\n"
      "\t\t\t\t\t\t\t cdh_p3_fb >> 6);\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t\tif (cdh_p3_type == 4 || cdh_p3_type == 7 ||\n"
      "\t\t\t\t\t    cdh_p3_type == 11) {\n"
      "\t\t\t\t\t\tu32 cdh_p3_offs[2];\n"
      "\t\t\t\t\t\tu32 cdh_p3_nc, cdh_p3_c;\n"
      "\n"
      "\t\t\t\t\t\tif (cdh_p3_type == 4) {\n"
      "\t\t\t\t\t\t\tcdh_p3_offs[0] = 0x40;/* Compute env */\n"
      "\t\t\t\t\t\t\tcdh_p3_nc = 1;\n"
      "\t\t\t\t\t\t} else if (cdh_p3_type == 7) {\n"
      "\t\t\t\t\t\t\tcdh_p3_offs[0] = 128 + 0x40;/* Draw(DCD) */\n"
      "\t\t\t\t\t\t\tcdh_p3_nc = 1;\n"
      "\t\t\t\t\t\t} else {\n"
      "\t\t\t\t\t\t\tcdh_p3_offs[0] = 256;/* Position */\n"
      "\t\t\t\t\t\t\tcdh_p3_offs[1] = 320;/* Varying */\n"
      "\t\t\t\t\t\t\tcdh_p3_nc = 2;\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\tfor (cdh_p3_c = 0; cdh_p3_c < cdh_p3_nc;\n"
      "\t\t\t\t\t\t     cdh_p3_c++) {\n"
      "\t\t\t\t\t\t\tu64 cdh_p3_sh = 0, cdh_p3_bin = 0;\n"
      "\t\t\t\t\t\t\tu8 cdh_p3_sp[32];\n"
      "\n"
      "\t\t\t\t\t\t\tmemcpy(&cdh_p3_sh,\n"
      "\t\t\t\t\t\t\t       cdh_p3_job + cdh_p3_offs[cdh_p3_c] + 0x28, 8);\n"
      "\t\t\t\t\t\t\tif (!cdh_p3_sh ||\n"
      "\t\t\t\t\t\t\t    copy_from_user(cdh_p3_sp,\n"
      "\t\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_p3_sh),\n"
      "\t\t\t\t\t\t\t\t\t   sizeof(cdh_p3_sp)))\n"
      "\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\tmemcpy(&cdh_p3_bin, cdh_p3_sp + 0x08, 8);\n"
      "\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t \"cdh-mali: P3 shader-desc off=+0x%x p=0x%llx type=%u stage=%u bin=0x%llx\\n\",\n"
      "\t\t\t\t\t\t\t\t cdh_p3_offs[cdh_p3_c], cdh_p3_sh,\n"
      "\t\t\t\t\t\t\t\t cdh_p3_sp[0] & 0xf,\n"
      "\t\t\t\t\t\t\t\t (cdh_p3_sp[0] >> 4) & 0xf, cdh_p3_bin);\n"
      "\t\t\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t\t\t       cdh_p3_sp, sizeof(cdh_p3_sp), false);\n"
      "\t\t\t\t\t\t\tif (cdh_p3_bin) {\n"
      "\t\t\t\t\t\t\t\tstruct kbase_vmap_struct cdh_p3_bmap;\n"
      "\t\t\t\t\t\t\t\tstatic u8 cdh_p3_buf[4096];\n"
      "\t\t\t\t\t\t\t\tconst u8 *cdh_p3_code = NULL, *cdh_p3_src = NULL;\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_p3_dump = 0, cdh_p3_end = 0;\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_p3_try, cdh_p3_i;\n"
      "\n"
      "\t\t\t\t\t\t\t\t/* Shader Program 无长度字段（v9.xml 仅\n"
      "\t\t\t\t\t\t\t\t * Type/Stage/Preload/Binary）→ dump 上限\n"
      "\t\t\t\t\t\t\t\t * 4KB 防呆；kbase_vmap 须整段落在 region\n"
      "\t\t\t\t\t\t\t\t * 内，越界自动折半重试（下限 128B）。 */\n"
      "\t\t\t\t\t\t\t\tfor (cdh_p3_try = 4096; cdh_p3_try >= 128;\n"
      "\t\t\t\t\t\t\t\t     cdh_p3_try >>= 1) {\n"
      "\t\t\t\t\t\t\t\t\tcdh_p3_code = kbase_vmap(kctx, cdh_p3_bin,\n"
      "\t\t\t\t\t\t\t\t\t\t\t   cdh_p3_try,\n"
      "\t\t\t\t\t\t\t\t\t\t\t   &cdh_p3_bmap);\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_p3_code) {\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_p3_src = cdh_p3_code;\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_p3_dump = cdh_p3_try;\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (!cdh_p3_src &&\n"
      "\t\t\t\t\t\t\t\t    !copy_from_user(cdh_p3_buf,\n"
      "\t\t\t\t\t\t\t\t\t\t    u64_to_user_ptr(cdh_p3_bin),\n"
      "\t\t\t\t\t\t\t\t\t\t    sizeof(cdh_p3_buf))) {\n"
      "\t\t\t\t\t\t\t\t\tcdh_p3_src = cdh_p3_buf;\n"
      "\t\t\t\t\t\t\t\t\tcdh_p3_dump = sizeof(cdh_p3_buf);\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (cdh_p3_src) {\n"
      "\t\t\t\t\t\t\t\t\t/* 实际遍历长度：扫到首个 flow=end\n"
      "\t\t\t\t\t\t\t\t\t * （Flow 枚举 15=Return from shader，\n"
      "\t\t\t\t\t\t\t\t\t * bits59-62）为止（含该字）。 */\n"
      "\t\t\t\t\t\t\t\t\tfor (cdh_p3_i = 0;\n"
      "\t\t\t\t\t\t\t\t\t     cdh_p3_i + 8 <= cdh_p3_dump;\n"
      "\t\t\t\t\t\t\t\t\t     cdh_p3_i += 8) {\n"
      "\t\t\t\t\t\t\t\t\t\tu64 cdh_p3_w;\n"
      "\n"
      "\t\t\t\t\t\t\t\t\t\tmemcpy(&cdh_p3_w,\n"
      "\t\t\t\t\t\t\t\t\t\t       cdh_p3_src + cdh_p3_i, 8);\n"
      "\t\t\t\t\t\t\t\t\t\tif (((cdh_p3_w >> 59) & 0xf) == 15) {\n"
      "\t\t\t\t\t\t\t\t\t\t\tcdh_p3_end = cdh_p3_i + 8;\n"
      "\t\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t\t \"cdh-mali: P3 code %s 0x%llx len=%zu end=%zu\\n\",\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_p3_code ? \"vmap\" : \"user\",\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_p3_bin, cdh_p3_dump, cdh_p3_end);\n"
      "\t\t\t\t\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t\t\t\t\t       cdh_p3_src, cdh_p3_dump,\n"
      "\t\t\t\t\t\t\t\t\t\t       false);\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_p3_code)\n"
      "\t\t\t\t\t\t\t\t\t\tkbase_vunmap(kctx, &cdh_p3_bmap);\n"
      "\t\t\t\t\t\t\t\t} else {\n"
      "\t\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t\t \"cdh-mali: P3 code unreadable 0x%llx\\n\",\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_p3_bin);\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t\t/* 有界指针追踪：扫 job 描述符里 8B 对齐字，指向\n"
      "\t\t\t\t\t * Shader Program（Descriptor Type Shader=8）才打印。 */\n"
      "\t\t\t\t\tfor (cdh_p3_off = 0; cdh_p3_off + 8 <= cdh_p3_len;\n"
      "\t\t\t\t\t     cdh_p3_off += 8) {\n"
      "\t\t\t\t\t\tu64 cdh_p3_v = 0, cdh_p3_vb = 0;\n"
      "\t\t\t\t\t\tu8 cdh_p3_peek[32];\n"
      "\n"
      "\t\t\t\t\t\tmemcpy(&cdh_p3_v, cdh_p3_job + cdh_p3_off, 8);\n"
      "\t\t\t\t\t\tif (cdh_p3_v < 0x1000000ULL ||\n"
      "\t\t\t\t\t\t    cdh_p3_v >= 0x10000000000ULL)\n"
      "\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\tif (atomic_read(&cdh_p3_chase) >= 24)\n"
      "\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\tif (copy_from_user(cdh_p3_peek,\n"
      "\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_p3_v),\n"
      "\t\t\t\t\t\t\t\t   sizeof(cdh_p3_peek)))\n"
      "\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\tif ((cdh_p3_peek[0] & 0xf) != 8)\n"
      "\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\tatomic_inc(&cdh_p3_chase);\n"
      "\t\t\t\t\t\tmemcpy(&cdh_p3_vb, cdh_p3_peek + 0x08, 8);\n"
      "\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t \"cdh-mali: P3 chase +0x%x -> 0x%llx stage=%u bin=0x%llx\\n\",\n"
      "\t\t\t\t\t\t\t cdh_p3_off, cdh_p3_v,\n"
      "\t\t\t\t\t\t\t (cdh_p3_peek[0] >> 4) & 0xf, cdh_p3_vb);\n"
      "\t\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t\t       cdh_p3_peek, sizeof(cdh_p3_peek), false);\n"
      "\t\t\t\t\t\tdo {\n"
      "\t\t\t\t\t\t\tstruct kbase_vmap_struct cdh_p3_cb;\n"
      "\t\t\t\t\t\t\tconst u8 *cdh_p3_cc = NULL;\n"
      "\t\t\t\t\t\t\tsize_t cdh_p3_cdump = 0, cdh_p3_cend = 0;\n"
      "\t\t\t\t\t\t\tsize_t cdh_p3_try, cdh_p3_i;\n"
      "\n"
      "\t\t\t\t\t\t\t/* 与主路径同：4KB 防呆上限 + 折半重试。 */\n"
      "\t\t\t\t\t\t\tfor (cdh_p3_try = 4096; cdh_p3_try >= 128;\n"
      "\t\t\t\t\t\t\t     cdh_p3_try >>= 1) {\n"
      "\t\t\t\t\t\t\t\tcdh_p3_cc = kbase_vmap(kctx, cdh_p3_vb,\n"
      "\t\t\t\t\t\t\t\t\t\t   cdh_p3_try, &cdh_p3_cb);\n"
      "\t\t\t\t\t\t\t\tif (cdh_p3_cc) {\n"
      "\t\t\t\t\t\t\t\t\tcdh_p3_cdump = cdh_p3_try;\n"
      "\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\tif (cdh_p3_cc) {\n"
      "\t\t\t\t\t\t\t\tfor (cdh_p3_i = 0;\n"
      "\t\t\t\t\t\t\t\t     cdh_p3_i + 8 <= cdh_p3_cdump;\n"
      "\t\t\t\t\t\t\t\t     cdh_p3_i += 8) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_p3_w;\n"
      "\n"
      "\t\t\t\t\t\t\t\t\tmemcpy(&cdh_p3_w,\n"
      "\t\t\t\t\t\t\t\t\t       cdh_p3_cc + cdh_p3_i, 8);\n"
      "\t\t\t\t\t\t\t\t\tif (((cdh_p3_w >> 59) & 0xf) == 15) {\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_p3_cend = cdh_p3_i + 8;\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t \"cdh-mali: P3 chase-code 0x%llx len=%zu end=%zu\\n\",\n"
      "\t\t\t\t\t\t\t\t\t cdh_p3_vb, cdh_p3_cdump, cdh_p3_cend);\n"
      "\t\t\t\t\t\t\t\tprint_hex_dump(KERN_INFO, \"cdh-mali: \",\n"
      "\t\t\t\t\t\t\t\t\t       DUMP_PREFIX_OFFSET, 32, 8,\n"
      "\t\t\t\t\t\t\t\t\t       cdh_p3_cc, cdh_p3_cdump,\n"
      "\t\t\t\t\t\t\t\t\t       false);\n"
      "\t\t\t\t\t\t\t\tkbase_vunmap(kctx, &cdh_p3_cb);\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t} while (0);\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t\tcdh_p3_j = cdh_p3_next;\n"
      "\t\t\t\t}\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\n"
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n"
      "\n"
      "\t\tmutex_lock(&jctx->lock);\n",
      "P3 真机 shader 捕获探针（Job→ShaderEnv→ShaderProgram→Binary + 有界追踪）",
      done="cdh-mali: P3 chain tgid=")

# (17) watchdog 断链：拒绝 crash_dump/debuggerd ptrace 冻结 SF/composer/
#      system_server。run68/69 实锤死锁链：MIUIScout FW_SCOUT_HANG →
#      debuggerd 派生 crash_dump64 attach SF → 读 guest state EFAULT 挂死
#      不 detach → SF 全进程 tracing stop（State=t）→ binder 停摆 →
#      system_server watchdog 67s → WATCHDOG KILLING → nativehang →
#      整机自我重启。sfdump v5.1 自愈（5s kill）仍击穿 67s 阈值（run69：
#      阻塞起点与 SF 首次冻结同刻）。调试取证由 cdh_sfdump 内核探针覆盖，
#      debuggerd dump 无增量价值 → attach 直接 -EPERM，从源头断冻结。
patch("kernel/ptrace.c",
      "static int ptrace_attach(struct task_struct *task, long request,\n"
      "\t\t\t unsigned long addr,\n"
      "\t\t\t unsigned long flags)\n"
      "{\n"
      "\tbool seize = (request == PTRACE_SEIZE);\n"
      "\tint retval;\n",
      "static int ptrace_attach(struct task_struct *task, long request,\n"
      "\t\t\t unsigned long addr,\n"
      "\t\t\t unsigned long flags)\n"
      "{\n"
      "\tbool seize = (request == PTRACE_SEIZE);\n"
      "\tint retval;\n"
      "\n"
      "\t/* CDH(gold-15): 拒绝 crash_dump/debuggerd 冻结 SF/composer/\n"
      "\t * system_server/gpumbox_bridge（云机 watchdog 死锁链，wire-kbase.sh\n"
      "\t * (17)，run68/69 实锤；gpumbox_bridge = B2 渲染桥 helper，被冻结\n"
      "\t * 则回执段永不闭环（b2-bridge-min 卡点①）。 */\n"
      "\tif (task->group_leader &&\n"
      "\t    (!strcmp(task->group_leader->comm, \"surfaceflinger\") ||\n"
      "\t     !strcmp(task->group_leader->comm, \"android.hardwar\") ||\n"
      "\t     !strcmp(task->group_leader->comm, \"gpumbox_bridge\") ||\n"
      "\t     !strcmp(task->group_leader->comm, \"system_server\")) &&\n"
      "\t    (!strcmp(current->comm, \"crash_dump64\") ||\n"
      "\t     !strcmp(current->comm, \"crash_dump32\") ||\n"
      "\t     !strcmp(current->comm, \"debuggerd\"))) {\n"
      "\t\tpr_info(\"cdh_sfdump: deny %s attach to %s\\n\",\n"
      "\t\t\tcurrent->comm, task->group_leader->comm);\n"
      "\t\tretval = -EPERM;\n"
      "\t\tgoto out;\n"
      "\t}\n",
      "ptrace 拒绝 crash_dump 冻结 SF/composer/system_server（watchdog 断链）")

# (18)-(20) 原内核填色桥已彻底移除，纯真呈现 Android 原生 SurfaceFlinger 真实画面

# (20b) virtgpu_drv.c: 注入 cdh_virtio_gpu_fops 与 cdh_mtk_unlocked_ioctl，并实现 fd 0 保护
patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "#include <linux/module.h>\n",
      "#include <linux/module.h>\n#include <linux/uaccess.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n",
      "virtgpu_drv.c include uaccess/file/fdtable",
      done="#include <linux/fdtable.h>")

patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "DEFINE_DRM_GEM_FOPS(virtio_gpu_driver_fops);\n",
      "DEFINE_DRM_GEM_FOPS(virtio_gpu_driver_fops);\n"
      "\n"
      "/* CDH(gold-15): 占用未使用的 fd 0 防止 MTK HWC ionImport assert */\n"
      "static int cdh_virtio_gpu_open(struct inode *inode, struct file *filp)\n"
      "{\n"
      "\tint fd0 = get_unused_fd_flags(0);\n"
      "\tif (fd0 == 0) {\n"
      "\t\tstruct file *null_filp = filp_open(\"/dev/null\", O_RDONLY, 0);\n"
      "\t\tif (!IS_ERR(null_filp)) {\n"
      "\t\t\tfd_install(0, null_filp);\n"
      "\t\t\tpr_info(\"cdh_fd0: occupied fd 0 with /dev/null for %s (pid %d)\\n\",\n"
      "\t\t\t\tcurrent->comm, current->pid);\n"
      "\t\t} else {\n"
      "\t\t\tput_unused_fd(0);\n"
      "\t\t}\n"
      "\t} else if (fd0 > 0) {\n"
      "\t\tput_unused_fd(fd0);\n"
      "\t}\n"
      "\treturn drm_open(inode, filp);\n"
      "}\n"
      "\n"
      "/* CDH(gold-15): MTK 私有 DRM ioctl stub */\n"
      "static long cdh_mtk_unlocked_ioctl(struct file *filp, unsigned int cmd,\n"
      "\t\t\t\t       unsigned long arg)\n"
      "{\n"
      "\tswitch (cmd) {\n"
      "\tcase 0xc0186450: /* DRM_IOCTL_MTK_KICK_IDLE */\n"
      "\tcase 0xc0046449: /* DRM_IOCTL_MTK_SET_MODE */\n"
      "\tcase 0xc004644c: /* DRM_IOCTL_MTK master_info */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n"
      "\tdefault:\n"
      "\t\treturn drm_ioctl(filp, cmd, arg);\n"
      "\t}\n"
      "}\n"
      "\n"
      "static const struct file_operations cdh_virtio_gpu_fops = {\n"
      "\t.owner		= THIS_MODULE,\n"
      "\t.open		= cdh_virtio_gpu_open,\n"
      "\t.release	= drm_release,\n"
      "\t.unlocked_ioctl	= cdh_mtk_unlocked_ioctl,\n"
      "\t.compat_ioctl	= drm_compat_ioctl,\n"
      "\t.poll		= drm_poll,\n"
      "\t.read		= drm_read,\n"
      "\t.llseek		= noop_llseek,\n"
      "\t.mmap		= drm_gem_mmap,\n"
      "};\n",
      "virtgpu_drv.c 定义 cdh_virtio_gpu_fops 和 cdh_mtk_unlocked_ioctl",
      done="cdh_virtio_gpu_fops")

patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\t.fops = &virtio_gpu_driver_fops,\n",
      "\t.fops = &cdh_virtio_gpu_fops,\n",
      "virtgpu_drv.c 切换 driver.fops 到 cdh_virtio_gpu_fops",
      done=".fops = &cdh_virtio_gpu_fops")


patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "static long cdh_mtk_unlocked_ioctl(struct file *filp, unsigned int cmd,\n",
      "/* CDH(gold-15): MTK master_info = 无 CAP_SYS_ADMIN 授权 DRM master 的私有\n"
      " * 通道（见 wire-kbase.sh (21) 注释）。 */\n"
      "extern int drm_setmaster_ioctl(struct drm_device *dev, void *data,\n"
      "\t\t\t       struct drm_file *file_priv);\n"
      "\n"
      "static long cdh_mtk_grant_master(struct file *filp, unsigned long arg)\n"
      "{\n"
      "\tstruct drm_file *file_priv = filp->private_data;\n"
      "\tstruct drm_device *dev = file_priv->minor->dev;\n"
      "\tu32 in_val = 0;\n"
      "\tint ret;\n"
      "\n"
      "\tget_user(in_val, (u32 __user *)arg);\n"
      "\tfile_priv->was_master = true;\n"
      "\tret = drm_setmaster_ioctl(dev, NULL, file_priv);\n"
      "\tif (!ret)\n"
      "\t\tput_user(1, (u32 __user *)arg);\n"
      "\tpr_info_ratelimited(\"cdh_mtk: master_info in=%u ret=%d\\n\",\n"
      "\t\t\t     in_val, ret);\n"
      "\treturn ret;\n"
      "}\n"
      "\n"
      "static long cdh_mtk_unlocked_ioctl(struct file *filp, unsigned int cmd,\n",
      "virtgpu_drv.c master_info 真授权 helper",
      done="static long cdh_mtk_grant_master")

patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\tcase 0xc004644c: /* DRM_IOCTL_MTK master_info */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n",
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n"
      "\tcase 0xc004644c: /* DRM_IOCTL_MTK master_info：真授权 master */\n"
      "\t\treturn cdh_mtk_grant_master(filp, arg);\n",
      "virtgpu_drv.c master_info 分流到真授权",
      done="cdh_mtk_grant_master(filp, arg)")

# v63 (22)：atomic_flush 消费 vblank 事件。virtio 原生不 arm 事件；加了
# vblank 支持后 no_vblank=false → fake_vblank 不再代发 → flip_done 永不
# 完成 → HWC commit 卡 10s 超时（run76 实锤：flip_done timed out +
# WARN_ON(event) at drm_atomic_helper_commit_hw_done）。cdh_vblank hrtimer
# 60Hz 调 drm_crtc_handle_vblank → drm_handle_vblank_events 送出事件。
# v72 订正（run84 丢唤醒根因）：drm_crtc_arm_vblank_event 上游契约要求
# 调用者**先 drm_crtc_vblank_get()**（drm_vblank.c L1095-1096：ref 由
# handle_vblank_events 发送时 put）。v63 只 arm 不 get → 每个 flip 事件
# 净减一次 refcount → 减穿归零（dmesg 实锤：drm_vblank_put WARN
# refcount==0）→ vblank 被 disable → drm_handle_vblank L1995
# （!vblank->enabled 直接 return）→ 后续 flip_done 事件永不发送 →
# display out_fence 永不 signal → SF 持 27 个 sync_file 等死、
# mali-cmar 忙 poll fence 不 read mali 事件（run84 kprobe 实锤：
# kbase_poll 3万次返回 EPOLLIN、kbase_read 0 次）→ 全链冻结 →
# nativehang 重启循环。修法：arm 前 get；get 失败则直接 send 立即
# 完成（fake GPU 无真实扫描延迟，立即 flip 语义成立）。
patch("drivers/gpu/drm/virtio/virtgpu_display.c",
      "\tif (drm_atomic_crtc_needs_modeset(crtc_state)) {\n"
      "\t\toutput->needs_modeset = true;\n"
      "\t}\n",
      "\tif (drm_atomic_crtc_needs_modeset(crtc_state)) {\n"
      "\t\toutput->needs_modeset = true;\n"
      "\t}\n"
      "\n"
      "\t/* CDH(gold-15): 消费 atomic vblank 事件（修 flip_done 10s 超时）。\n"
      "\t * v72: arm 前必须 drm_crtc_vblank_get()（契约见 drm_vblank.c\n"
      "\t * drm_crtc_arm_vblank_event 注释），否则 handle_vblank_events 的\n"
      "\t * put 未配对减穿 refcount → vblank 禁用 → 事件链全断。 */\n"
      "\tif (crtc_state->event) {\n"
      "\t\tunsigned long flags;\n"
      "\n"
      "\t\tspin_lock_irqsave(&crtc->dev->event_lock, flags);\n"
      "\t\tif (drm_crtc_vblank_get(crtc) == 0) {\n"
      "\t\t\tdrm_crtc_arm_vblank_event(crtc, crtc_state->event);\n"
      "\t\t} else {\n"
      "\t\t\tdrm_crtc_send_vblank_event(crtc, crtc_state->event);\n"
      "\t\t}\n"
      "\t\tcrtc_state->event = NULL;\n"
      "\t\tspin_unlock_irqrestore(&crtc->dev->event_lock, flags);\n"
      "\t}\n",
      "virtgpu_display.c atomic_flush 消费 vblank 事件（修 flip_done 超时）",
      done="CDH(gold-15): 消费 atomic vblank 事件（修 flip_done 10s 超时）。")

# (23) 填色日志已彻底移除

# v63 (24)：default 臂未知 cmd 探针。run76 实锤 KICK_IDLE 从未命中
# (19) 的 case 0xc0186450（0 次）→ 该 cmd 常量有误；记录实际 cmd 供
# 下轮精确 stub。过滤 DRM modeset 段（nr>=0x90）防刷屏。
patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\tdefault:\n"
      "\t\treturn drm_ioctl(filp, cmd, arg);\n",
      "\tdefault:\n"
      "\t\tif (_IOC_NR(cmd) < 0x90) {\n"
      "\t\t\tstatic int cdh_mtk_plog;\n"
      "\n"
      "\t\t\tif (cdh_mtk_plog < 8) {\n"
      "\t\t\t\tcdh_mtk_plog++;\n"
      "\t\t\t\tpr_info(\"cdh_mtk: passthru cmd=0x%x type=0x%x nr=0x%x size=%u\\n\",\n"
      "\t\t\t\t\tcmd, _IOC_TYPE(cmd), _IOC_NR(cmd), _IOC_SIZE(cmd));\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\treturn drm_ioctl(filp, cmd, arg);\n",
      "drv.c default 臂未知 cmd 探针（定位 KICK_IDLE 真 cmd）",
      done="cdh_mtk: passthru cmd=")

# v65 (25)：KICK_IDLE 真 cmd = 0xc004649b。run77 实锤 (19) 的 case
# 0xc0186450 从未命中（ratelimit 调用点仅 1 条 SET_MODE），HWC
# "DRM_IOCTL_MTK_KICK_IDLE failed ... error: -1" 2424 次 → enableHWVSync
# 10/10 失败 → onVsync 0 → SF 无 vsync 不出帧。反查 hwcomposer.so
# DrmDevice::kickIdle（0x189af4: mov w1,#0x649b; movk w1,#0xc004,lsl#16）
# 定出真 cmd。修正型补丁 + done 标记（(18e) 模式）。
patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\tswitch (cmd) {\n"
      "\tcase 0xc0186450: /* DRM_IOCTL_MTK_KICK_IDLE */\n"
      "\tcase 0xc0046449: /* DRM_IOCTL_MTK_SET_MODE */\n",
      "\tswitch (cmd) {\n"
      "\tcase 0xc004649b: /* DRM_IOCTL_MTK_KICK_IDLE 真 cmd（run77 反查\n"
      "\t\t\t  * DrmDevice::kickIdle：mov w1,#0x649b; movk #0xc004） */\n"
      "\tcase 0xc0186450: /* 旧常量保留（从未命中） */\n"
      "\tcase 0xc0046449: /* DRM_IOCTL_MTK_SET_MODE */\n",
      "drv.c KICK_IDLE 真 cmd 0xc004649b 修正",
      done="case 0xc004649b:")

# v66 (26)：enableHWVSync 真 cmd = 0xc0046456。run78 实锤 KICK_IDLE 通
# （failed=0、stub 150 次）但 enableHWVSync 仍 11/11 失败 error:-1 →
# onVsync 0 → SF 无 vsync 不出帧（VNC 仍 RGB8 灰）。反查 hwcomposer.so
# enableHWVSync（0x187c04/0x187c4c：mov w1,#0x6456; movk w1,#0xc004），
# 与 KICK_IDLE(0x649b) 是两个不同 ioctl。nr=0x56 < 0x90 但 (24) 探针
# cap=8 早已耗尽故未抓到。HWC 只检查返回值符号（tbnz w20,#31），stub
# return 0 即可。修正型补丁 + done 标记（(18e)/(25) 模式）。
patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\tcase 0xc0046449: /* DRM_IOCTL_MTK_SET_MODE */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n",
      "\tcase 0xc0046449: /* DRM_IOCTL_MTK_SET_MODE */\n"
      "\tcase 0xc0046456: /* DRM_IOCTL_MTK enableHWVSync 真 cmd（run78 反查\n"
      "\t\t\t  * enableHWVSync：mov w1,#0x6456; movk #0xc004） */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n",
      "drv.c enableHWVSync 真 cmd 0xc0046456 修正",
      done="case 0xc0046456:")

# v89 (26b)：拦截 MTK 私有 ioctl（尤其 DRM_IOCTL_MTK_GEM_SUBMIT 0xc0286442）。
# run140 实锤（gpu.md §8 与 solution.md §36）：
# 1. MTK HWC 提交帧时下发 DRM_IOCTL_MTK_GEM_SUBMIT(0xc0286442，nr=0x42)。
# 2. 未被 cdh_mtk_unlocked_ioctl 拦截，落入 drm_ioctl，按 nr=0x42 命中
#    DRM_IOCTL_VIRTGPU_EXECBUFFER(virtio_gpu_execbuffer_ioctl)！
# 3. 驱动误将 MTK 40B 结构体当作 drm_virtgpu_execbuffer 提交给 virtio-gpu，
#    导致后台 kworker virtio_gpu_dequeue_ctrl_func 释放时踩坏 SLUB 链表，
#    触发 mm/slub.c:433 BUG! -> 整个系统在 t≈36.9s 必 panic 重启！
# 4. 同步返回 -1，导致 HWC "[COMP] Failed to get releaseFence" ->
#    SurfaceFlinger [SW-WD] <<[composite]>> timeout (4147ms) 挂死循环！
# 5. 同时拦截 MTK 其他私有 ioctl (0xc00c6446, 0xc0046447 等)，严防误入
#    VIRTGPU_TRANSFER_FROM_HOST / VIRTGPU_TRANSFER_TO_HOST。
patch("drivers/gpu/drm/virtio/virtgpu_drv.c",
      "\tcase 0xc0046456: /* DRM_IOCTL_MTK enableHWVSync 真 cmd（run78 反查\n"
      "\t\t\t  * enableHWVSync：mov w1,#0x6456; movk #0xc004） */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n",
      "\tcase 0xc0046456: /* DRM_IOCTL_MTK enableHWVSync 真 cmd（run78 反查\n"
      "\t\t\t  * enableHWVSync：mov w1,#0x6456; movk #0xc004） */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n"
      "\tcase 0xc0286442: /* DRM_IOCTL_MTK_GEM_SUBMIT (run140: 撞车 VIRTGPU_EXECBUFFER) */\n"
      "\t\t{\n"
      "\t\t\ts32 no_fence = -1;\n"
      "\t\t\t(void)put_user(no_fence, (s32 __user *)(arg + 20));\n"
      "\t\t\t(void)put_user(no_fence, (s32 __user *)(arg + 24));\n"
      "\t\t}\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub GEM_SUBMIT cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n"
      "\tcase 0xc00c6446: /* DRM_IOCTL_MTK_CRTC_GETFENCE (gold-15: 撞车 VIRTGPU_TRANSFER_FROM_HOST，显式写 -1 规避 fd 0) */\n"
      "\t\t{\n"
      "\t\t\ts32 no_fence = -1;\n"
      "\t\t\t(void)put_user(no_fence, (s32 __user *)(arg + 4));\n"
      "\t\t}\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub CRTC_GETFENCE cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n"
      "\tcase 0xc0046447: /* MTK 私有 ioctl (撞车 VIRTGPU_TRANSFER_TO_HOST) */\n"
      "\tcase 0xc004647e: /* MTK 私有 ioctl */\n"
      "\tcase 0xc0286455: /* MTK 私有 ioctl */\n"
      "\tcase 0xc00c6494: /* MTK 私有 ioctl */\n"
      "\tcase 0xc040646d: /* MTK 私有 ioctl */\n"
      "\tcase 0xc1286488: /* MTK 私有 ioctl */\n"
      "\tcase 0xdc6c6486: /* MTK 私有 ioctl */\n"
      "\t\tpr_info_ratelimited(\"cdh_mtk: stub ioctl cmd=0x%x\\n\", cmd);\n"
      "\t\treturn 0;\n",
      "drv.c 拦截 MTK GEM_SUBMIT 等私有 ioctl 防止误入 virtgpu 命令表",
      done="stub CRTC_GETFENCE")

# (26c) drm_atomic_uapi.c: 诊断日志——记录 atomic 提交与属性设置失败细节
patch("drivers/gpu/drm/drm_atomic_uapi.c",
      "\t\t\tret = drm_atomic_set_property(state, file_priv,\n"
      "\t\t\t\t\t\t      obj, prop, prop_value);\n"
      "\t\t\tif (ret) {\n",
      "\t\t\tret = drm_atomic_set_property(state, file_priv,\n"
      "\t\t\t\t\t\t      obj, prop, prop_value);\n"
      "\t\t\tif (ret) {\n"
      "\t\t\t\tpr_info_ratelimited(\"cdh_atomic_set_prop_err: obj=%u type=0x%x prop=%s(%u) val=%llu ret=%d by %s(%d)\\n\",\n"
      "\t\t\t\t\t\t    obj->id, obj->type, prop->name, prop->base.id, prop_value, ret, current->comm, current->pid);\n",
      "drm_atomic_uapi.c 属性设置失败诊断日志")

patch("drivers/gpu/drm/drm_atomic_uapi.c",
      "\tdrm_modeset_acquire_fini(&ctx);\n"
      "\n"
      "\treturn ret;\n"
      "}\n",
      "\tdrm_modeset_acquire_fini(&ctx);\n"
      "\n"
      "\tif (ret && ret != -EDEADLK)\n"
      "\t\tpr_info_ratelimited(\"cdh_atomic_commit_err: ret=%d count_objs=%u flags=0x%x by %s (pid %d)\\n\",\n"
      "\t\t\t\t    ret, arg->count_objs, arg->flags,\n"
      "\t\t\t\t    current->comm, current->pid);\n"
      "\treturn ret;\n"
      "}\n",
      "drm_atomic_uapi.c atomic commit 失败诊断日志")



# v67 (27a)：path C 自死锁兜底——强制释放"已完成但事件未被取走"的 atom。
# run79 终局定案（solution.md §17）：用户态事件线程（cmar"提交+消费"同线程）
# 卡在 kbase_jd_submit 等 atom 槽位（wait_event_killable，jd.c:1165），而
# 占槽 atom 已 COMPLETED 挂在 event_list（事件没人 read → 不置 UNUSED →
# 槽位永不释放 → submit 永久自锁）。
# v69 修订：**事件不再丢弃**，改为暂存后回放（run81 取证：丢事件使用户态
# 等完成信号的条件变量永不唤醒 → SF binder 线程卡 75s+ 判空闲 futex、
# watchdog nativehang 重启循环）。摘链释放槽位的同时把 event_code/atom_nr/
# udata 快照入全局暂存表，kbase_event_dequeue 优先回放，用户态语义不变。
# 超时强制路径只在事件滞留 ≥ 数百 ms 时触发（健康路径毫秒级被消费），
# 回放延迟无副作用。
patch("drivers/gpu/arm/midgard/mali_kbase_event.c",
      "KBASE_EXPORT_TEST_API(kbase_event_dequeue);\n",
      "KBASE_EXPORT_TEST_API(kbase_event_dequeue);\n"
      "\n"
      "/* CDH(gold-15): 超时强制释放的完成事件暂存表（jd_submit 自锁兜底，\n"
      " * wire-kbase.sh (27a) v69）。事件不丢弃：快照后由 kbase_event_dequeue\n"
      " * 优先回放，避免用户态等完成信号永不唤醒（run81 nativehang 根因之一）。\n"
      " */\n"
      "struct cdh_saved_event {\n"
      "\tstruct list_head link;\n"
      "\tstruct kbase_context *kctx;\n"
      "\tu32 event_code;\n"
      "\tu32 atom_number;\n"
      "\tstruct base_jd_udata udata;\n"
      "};\n"
      "static LIST_HEAD(cdh_saved_events);\n"
      "static DEFINE_SPINLOCK(cdh_saved_events_lock);\n"
      "\n"
      "static void cdh_save_event(struct kbase_context *kctx, u32 atom_number,\n"
      "\t\t\t   u32 event_code, struct base_jd_udata udata)\n"
      "{\n"
      "\tstruct cdh_saved_event *e;\n"
      "\n"
      "\te = kmalloc(sizeof(*e), GFP_KERNEL);\n"
      "\tif (!e)\n"
      "\t\treturn;\n"
      "\te->kctx = kctx;\n"
      "\te->atom_number = atom_number;\n"
      "\te->event_code = event_code;\n"
      "\te->udata = udata;\n"
      "\tspin_lock(&cdh_saved_events_lock);\n"
      "\tlist_add_tail(&e->link, &cdh_saved_events);\n"
      "\tspin_unlock(&cdh_saved_events_lock);\n"
      "}\n"
      "\n"
      "static bool cdh_take_event(struct kbase_context *kctx,\n"
      "\t\t\t   struct base_jd_event_v2 *uevent)\n"
      "{\n"
      "\tstruct cdh_saved_event *e;\n"
      "\tbool got = false;\n"
      "\n"
      "\tspin_lock(&cdh_saved_events_lock);\n"
      "\tlist_for_each_entry(e, &cdh_saved_events, link) {\n"
      "\t\tif (e->kctx == kctx) {\n"
      "\t\t\tuevent->event_code = e->event_code;\n"
      "\t\t\tuevent->atom_number = e->atom_number;\n"
      "\t\t\tuevent->udata = e->udata;\n"
      "\t\t\tlist_del(&e->link);\n"
      "\t\t\tkfree(e);\n"
      "\t\t\tgot = true;\n"
      "\t\t\tbreak;\n"
      "\t\t}\n"
      "\t}\n"
      "\tspin_unlock(&cdh_saved_events_lock);\n"
      "\treturn got;\n"
      "}\n"
      "\n"
      "static void cdh_purge_events(struct kbase_context *kctx)\n"
      "{\n"
      "\tstruct cdh_saved_event *e, *n;\n"
      "\n"
      "\tspin_lock(&cdh_saved_events_lock);\n"
      "\tlist_for_each_entry_safe(e, n, &cdh_saved_events, link) {\n"
      "\t\tif (e->kctx == kctx) {\n"
      "\t\t\tlist_del(&e->link);\n"
      "\t\t\tkfree(e);\n"
      "\t\t}\n"
      "\t}\n"
      "\tspin_unlock(&cdh_saved_events_lock);\n"
      "}\n"
      "\n"
      "/* CDH(gold-15): 强制释放已完成但事件滞留的 atom（jd_submit 自锁兜底）。\n"
      " * 仅当 katom 为 COMPLETED 且确实挂在 event_list 时生效，否则返回 0。\n"
      " * 锁序与 kbase_event_dequeue 一致：event_mutex 摘链 → jctx.lock 过程化。\n"
      " */\n"
      "int kbase_event_force_dequeue_atom(struct kbase_context *kctx, struct kbase_jd_atom *katom)\n"
      "{\n"
      "\tstruct list_head *entry;\n"
      "\tbool found = false;\n"
      "\tu32 atom_number, event_code;\n"
      "\n"
      "\tmutex_lock(&kctx->event_mutex);\n"
      "\tif (katom->status == KBASE_JD_ATOM_STATE_COMPLETED) {\n"
      "\t\tlist_for_each(entry, &kctx->event_list) {\n"
      "\t\t\tif (entry == &katom->dep_item[0]) {\n"
      "\t\t\t\tlist_del_init(entry);\n"
      "\t\t\t\tatomic_dec(&kctx->event_count);\n"
      "\t\t\t\tfound = true;\n"
      "\t\t\t\tbreak;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t}\n"
      "\tmutex_unlock(&kctx->event_mutex);\n"
      "\tif (!found)\n"
      "\t\treturn 0;\n"
      "\n"
      "\tatom_number = (u32)(katom - kctx->jctx.atoms);\n"
      "\tevent_code = katom->event_code;\n"
      "\tif (katom->core_req & BASE_JD_REQ_EXTERNAL_RESOURCES)\n"
      "\t\tkbase_jd_free_external_resources(katom);\n"
      "\n"
      "\tmutex_lock(&kctx->jctx.lock);\n"
      "\tcdh_save_event(kctx, atom_number, event_code,\n"
      "\t\t       kbase_event_process(kctx, katom));\n"
      "\tmutex_unlock(&kctx->jctx.lock);\n"
      "\treturn 1;\n"
      "}\n",
      "event.c 强制释放滞留 atom（path C 自锁兜底，v69 事件暂存回放）",
      done="static void cdh_purge_events(struct kbase_context *kctx)")

# v67 (27b)：(27a) 的声明。
patch("drivers/gpu/arm/midgard/mali_kbase.h",
      "int kbase_event_dequeue(struct kbase_context *kctx, struct base_jd_event_v2 *uevent);\n",
      "int kbase_event_dequeue(struct kbase_context *kctx, struct base_jd_event_v2 *uevent);\n"
      "int kbase_event_force_dequeue_atom(struct kbase_context *kctx, struct kbase_jd_atom *katom);\n",
      "kbase.h kbase_event_force_dequeue_atom 声明",
      done="int kbase_event_force_dequeue_atom(struct kbase_context *kctx, struct kbase_jd_atom *katom);")

# v67 (27c)：jd.c submit 等槽位限时化 + 超时自愈。原 wait_event_killable
# 无限等占槽 atom 置 UNUSED；path C 自锁时该 atom 永远停在 COMPLETED
# （事件滞留），等待永无止境。改 500ms 超时：到点调 (27a) 强制摘除滞留事件
# 并暂存回放（v69 起事件不丢弃，见 27a 注释；健康路径事件毫秒级被消费，
# 不会误触发）。超时长压到 500ms：run80/81 实锤 path C 是 boot 期慢性复发
# （约每 5-20s 一次碰撞），单次等待代价必须远低于 watchdog 窗口。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\t\tif (wait_event_killable(katom->completed,\n"
      "\t\t\t\t\t\tkatom->status == KBASE_JD_ATOM_STATE_UNUSED) != 0) {\n"
      "\t\t\t\t/* We're being killed so the result code\n"
      "\t\t\t\t * doesn't really matter\n"
      "\t\t\t\t */\n"
      "\t\t\t\treturn 0;\n"
      "\t\t\t}\n"
      "\t\t\tmutex_lock(&jctx->lock);\n",
      "\t\t\t{\n"
      "\t\t\t\t/* CDH(gold-15): 限时等待 + 超时自愈（run79 path C 自锁兜底）。\n"
      "\t\t\t\t * 占槽 atom 已 COMPLETED 而事件滞留（用户态事件线程正卡在\n"
      "\t\t\t\t * 本 submit 里等槽位、永不 read）时无限等待即自锁：超时后\n"
	      "\t\t\t\t * 强制摘除该 atom 的滞留事件（暂存回放，v69），槽位让出。\n"
      "\t\t\t\t */\n"
      "\t\t\t\tlong remain = wait_event_killable_timeout(katom->completed,\n"
      "\t\t\t\t\t\tkatom->status == KBASE_JD_ATOM_STATE_UNUSED,\n"
      "\t\t\t\t\t\tmsecs_to_jiffies(500));\n"
      "\n"
      "\t\t\t\tif (remain < 0) {\n"
      "\t\t\t\t\t/* We're being killed so the result code\n"
      "\t\t\t\t\t * doesn't really matter\n"
      "\t\t\t\t\t */\n"
      "\t\t\t\t\treturn 0;\n"
      "\t\t\t\t}\n"
      "\t\t\t\tif (remain == 0 && kbase_event_force_dequeue_atom(kctx, katom))\n"
      "\t\t\t\t\tdev_warn(kctx->kbdev->dev,\n"
      "\t\t\t\t\t\t \"cdh: jd_submit 超时强制释放滞留 atom %d_%d/%ld\\n\",\n"
      "\t\t\t\t\t\t kctx->tgid, kctx->id, (long)(katom - kctx->jctx.atoms));\n"
      "\t\t\t}\n"
      "\t\t\tmutex_lock(&jctx->lock);\n",
      "jd.c submit 等槽限时化 + 超时强制释放（path C 兜底）",
      done="kbase_event_force_dequeue_atom(kctx, katom)")

# v69 (27d)：kbase_event_dequeue 优先回放 (27a) 暂存的事件，用户态无感。
# （cdh_take_event 定义在本文件后部，此处补前向声明。）
patch("drivers/gpu/arm/midgard/mali_kbase_event.c",
      "int kbase_event_dequeue(struct kbase_context *kctx, struct base_jd_event_v2 *uevent)\n"
      "{\n"
      "\tstruct kbase_jd_atom *atom;\n"
      "\n"
      "\tKBASE_DEBUG_ASSERT(kctx);\n"
      "\n"
      "\tmutex_lock(&kctx->event_mutex);\n",
      "static bool cdh_take_event(struct kbase_context *kctx,\n"
      "\t\t\t   struct base_jd_event_v2 *uevent);\n"
      "\n"
      "int kbase_event_dequeue(struct kbase_context *kctx, struct base_jd_event_v2 *uevent)\n"
      "{\n"
      "\tstruct kbase_jd_atom *atom;\n"
      "\n"
      "\tKBASE_DEBUG_ASSERT(kctx);\n"
      "\n"
      "\t/* CDH(gold-15): 优先回放 (27a) 暂存的滞留事件（v69，零丢失） */\n"
      "\tif (cdh_take_event(kctx, uevent))\n"
      "\t\treturn 0;\n"
      "\n"
      "\tmutex_lock(&kctx->event_mutex);\n",
      "event.c dequeue 优先回放暂存事件",
      done="if (cdh_take_event(kctx, uevent))")

# v69 (27e)：context 清理时兜底清空暂存事件，防悬挂指针/泄漏。
patch("drivers/gpu/arm/midgard/mali_kbase_event.c",
      "\tKBASE_DEBUG_ASSERT(kctx->event_workq);\n"
      "\n"
      "\tflush_workqueue(kctx->event_workq);\n",
      "\tKBASE_DEBUG_ASSERT(kctx->event_workq);\n"
      "\n"
      "\tcdh_purge_events(kctx);\n"
      "\tflush_workqueue(kctx->event_workq);\n",
      "event.c cleanup 清空暂存事件",
      done="cdh_purge_events(kctx);")

# v71 (27f)：completed_jobs 无条件 flush——run83 丢唤醒残留根治。
#      run83 取证：SF ctx 143 个 atom 全 St=4（COMPLETED"未交回用户态"）滞留，
#      含 DEP（core_req=0，submit 时 post_immediately=true 秒完成）等全类型，
#      用户态全线程 futex（FORCEDEQ=0、job_fault 未触发）→ 事件卡在
#      kctx->completed_jobs 链表，无人 flush。
#      上游机制：done_nolock(post_immediately=true) 仅链表空时直接 post，
#      否则挂链；flush 只在 done_worker 尾部 work_count 归零时执行（jd.c
#      L1342）。work_count 由 kbase_jd_done inc、worker dec 配平，但存在
#      早退不 dec 的路径（STOPPED promoted 早退 L1243-1259 return 前无 dec）
#      ——一次泄漏即 work_count 永久 >0 → flush 条件永假 → 所有后续事件
#      永久滞留 → 用户态等完成信号 futex 永不唤醒 → SF binder 挂 →
#      nativehang 重启循环。v70 后 job 首次走真 JS 调度（v70 前 core_req
#      误读为 0=DEP 秒完成从不进 JS），soft stop/promote 路径激活，此泄漏
#      才可能触发。
#      修法（不依赖泄漏路径猜测）：worker 尾部 dec 后**无条件** flush 整链。
#      job_done_wq 为 max_active=1 串行（jd.c L1560），flush 在 jctx.lock 内
#      FIFO 投递，事件顺序语义不变；work_count 仅剩统计意义。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\tif (!atomic_dec_return(&kctx->work_count)) {\n"
      "\t\t/* If worker now idle then post all events that kbase_jd_done_nolock()\n"
      "\t\t * has queued\n"
      "\t\t */\n"
      "\t\tmutex_lock(&jctx->lock);\n"
      "\t\twhile (!list_empty(&kctx->completed_jobs)) {\n"
      "\t\t\tstruct kbase_jd_atom *atom = list_entry(kctx->completed_jobs.next,\n"
      "\t\t\t\t\t\t\t\tstruct kbase_jd_atom, jd_item);\n"
      "\t\t\tlist_del(kctx->completed_jobs.next);\n"
      "\n"
      "\t\t\tkbase_event_post(kctx, atom);\n"
      "\t\t}\n"
      "\t\tmutex_unlock(&jctx->lock);\n"
      "\t}\n",
      "\t/* CDH(gold-15): dec 后无条件 flush completed_jobs（v71，run83 残留\n"
      "\t * 根治）。上游仅 work_count 归零时 flush，任何早退泄漏（如 STOPPED\n"
      "\t * promoted 早退不 dec）都会让链表永久滞留、用户态丢唤醒；串行 wq\n"
      "\t * 下无条件 flush 不改事件顺序（jctx.lock 内 FIFO）。 */\n"
      "\tatomic_dec(&kctx->work_count);\n"
      "\t{\n"
      "\t\tmutex_lock(&jctx->lock);\n"
      "\t\twhile (!list_empty(&kctx->completed_jobs)) {\n"
      "\t\t\tstruct kbase_jd_atom *atom = list_entry(kctx->completed_jobs.next,\n"
      "\t\t\t\t\t\t\t\tstruct kbase_jd_atom, jd_item);\n"
      "\t\t\tlist_del(kctx->completed_jobs.next);\n"
      "\n"
      "\t\t\tkbase_event_post(kctx, atom);\n"
      "\t\t}\n"
      "\t\tmutex_unlock(&jctx->lock);\n"
      "\t}\n",
      "jd.c done_worker 尾部无条件 flush completed_jobs（v71）",
      done="/* CDH(gold-15): dec 后无条件 flush completed_jobs（v71，run83 残留")

# v71 (27g)：worker STOPPED 早退路径补 dec（保持 work_count 计数平衡，
#      防御性修复；(27f) 已根治滞留，此补丁止住计数泄漏本身）。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\tmutex_unlock(&js_kctx_info->ctx.jsctx_mutex);\n"
      "\t\tmutex_unlock(&js_devdata->queue_mutex);\n"
      "\n"
      "\t\tspin_lock_irqsave(&kbdev->hwaccess_lock, flags);\n"
      "\n"
      "\t\tkatom->status = KBASE_JD_ATOM_STATE_IN_JS;\n"
      "\t\tdev_dbg(kctx->kbdev->dev, \"Atom %pK status to in JS\\n\", (void *)katom);\n"
      "\t\tkbase_js_unpull(kctx, katom);\n"
      "\n"
      "\t\tspin_unlock_irqrestore(&kbdev->hwaccess_lock, flags);\n"
      "\t\tmutex_unlock(&jctx->lock);\n"
      "\n"
      "\t\treturn;\n"
      "\t}\n",
      "\t\tmutex_unlock(&js_kctx_info->ctx.jsctx_mutex);\n"
      "\t\tmutex_unlock(&js_devdata->queue_mutex);\n"
      "\n"
      "\t\tspin_lock_irqsave(&kbdev->hwaccess_lock, flags);\n"
      "\n"
      "\t\tkatom->status = KBASE_JD_ATOM_STATE_IN_JS;\n"
      "\t\tdev_dbg(kctx->kbdev->dev, \"Atom %pK status to in JS\\n\", (void *)katom);\n"
      "\t\tkbase_js_unpull(kctx, katom);\n"
      "\n"
      "\t\tspin_unlock_irqrestore(&kbdev->hwaccess_lock, flags);\n"
      "\t\tmutex_unlock(&jctx->lock);\n"
      "\n"
      "\t\t/* CDH(gold-15): 早退必须 dec work_count（v71 防御，配平\n"
      "\t\t * kbase_jd_done 的 inc，止住计数泄漏） */\n"
      "\t\tatomic_dec(&kctx->work_count);\n"
      "\t\treturn;\n"
      "\t}\n",
      "jd.c done_worker STOPPED 早退补 dec（v71 防御）",
      done="CDH(gold-15): 早退必须 dec work_count")

# v71 (27h)：atoms debugfs 表头加判别计数（ec=event_count / wc=work_count /
#      cj=completed_jobs 非空 / sv=暂存事件数）。挂起时一眼判别事件卡层。
patch("drivers/gpu/arm/midgard/mali_kbase_jd_debugfs.c",
      "\t/* Print table heading */\n"
      "\tseq_puts(sfile, \" ID, Core req, St,   Predeps,           Start time, Additional info...\\n\");\n",
      "\t/* CDH(gold-15): 判别计数（v71 诊断） */\n"
      "\tseq_printf(sfile, \"cdh: ec=%d wc=%d cj=%d\\n\",\n"
      "\t\t   atomic_read(&kctx->event_count),\n"
      "\t\t   atomic_read(&kctx->work_count),\n"
      "\t\t   list_empty(&kctx->completed_jobs) ? 0 : 1);\n"
      "\t/* Print table heading */\n"
      "\tseq_puts(sfile, \" ID, Core req, St,   Predeps,           Start time, Additional info...\\n\");\n",
      "jd_debugfs atoms 表头判别计数（v71 诊断）",
      done="cdh: ec=%d wc=%d cj=%d")

# v73 (27i)-(27l)：fence 链判别探针（run86 丢唤醒残留靶子，solution.md §21.6）。
# run84 判别结论：内核事件链健康（ec=143 wc=0 cj=0），卡点收敛为"用户态
# dma fence 不 signal"，候选 (a) mali FENCE_TRIGGER out fence /
# (b) 显示 release fence。v72 已修通 flip 链（flip_done 超时归零）但 nativehang
# 仍在（run86：提交 31s 停、全链 futex 冻结）→ 需定 fence 链哪一环断：
#   (27i) FENCE_TRIGGER 建 fence 是否成功（fd）
#   (27j) out-trigger 是否 is_ours、signal 结果
#   (27k) FENCE_WAIT 等的是哪条 fence（driver-timeline 名 + 状态）★关键判别
#   (27l) in-fence 回调是否曾触发
# 全部限条数（48）防刷屏，挂起窗口读 dmesg 即可定案。
patch("drivers/gpu/arm/midgard/mali_kbase_softjobs.c",
      "int kbase_prepare_soft_job(struct kbase_jd_atom *katom)\n"
      "{\n",
      "/* CDH(gold-15): fence 链判别探针计数（v73 (27i)/(27k)） */\n"
      "static int cdh_fence_plog;\n"
      "static int cdh_fence_wlog;\n"
      "\n"
      "int kbase_prepare_soft_job(struct kbase_jd_atom *katom)\n"
      "{\n",
      "softjobs.c fence 探针计数声明（v73）",
      done="static int cdh_fence_plog")
patch("drivers/gpu/arm/midgard/mali_kbase_softjobs.c",
      "\t\tfd = kbase_sync_fence_out_create(katom, fence.basep.stream_fd);\n"
      "\t\tif (fd < 0)\n"
      "\t\t\treturn -EINVAL;\n"
      "\n"
      "\t\tfence.basep.fd = fd;\n",
      "\t\tfd = kbase_sync_fence_out_create(katom, fence.basep.stream_fd);\n"
      "\t\tif (fd < 0)\n"
      "\t\t\treturn -EINVAL;\n"
      "\n"
      "\t\tif (cdh_fence_plog < 48) {\n"
      "\t\t\tcdh_fence_plog++;\n"
      "\t\t\tpr_info(\"cdh_fence: trigger-prep fd=%d\\n\", fd);\n"
      "\t\t}\n"
      "\t\tfence.basep.fd = fd;\n",
      "softjobs.c FENCE_TRIGGER 建 fence 探针（v73 (27i)）",
      done="cdh_fence: trigger-prep fd=%d")
patch("drivers/gpu/arm/midgard/mali_kbase_softjobs.c",
      "\t\t/* Get a reference to the fence object */\n"
      "\t\tret = kbase_sync_fence_in_from_fd(katom, fence.basep.fd);\n"
      "\t\tif (ret < 0)\n"
      "\t\t\treturn ret;\n"
      "\t} break;\n",
      "\t\t/* Get a reference to the fence object */\n"
      "\t\tret = kbase_sync_fence_in_from_fd(katom, fence.basep.fd);\n"
      "\t\tif (ret < 0)\n"
      "\t\t\treturn ret;\n"
      "\t\tif (katom->dma_fence.fence_in && cdh_fence_wlog < 48) {\n"
      "\t\t\tstruct dma_fence *f = katom->dma_fence.fence_in;\n"
      "\n"
      "\t\t\tcdh_fence_wlog++;\n"
      "\t\t\tpr_info(\"cdh_fence: wait-in fd=%d fence=%p %s-%s status=%d\\n\",\n"
      "\t\t\t\tfence.basep.fd, (void *)f, f->ops->get_driver_name(f),\n"
      "\t\t\t\tf->ops->get_timeline_name(f), dma_fence_get_status(f));\n"
      "\t\t}\n"
      "\t} break;\n",
      "softjobs.c FENCE_WAIT 等待对象探针（v73 (27k)）",
      done="cdh_fence: wait-in fd=%d")
patch("drivers/gpu/arm/midgard/mali_kbase_sync_file.c",
      "static const struct file_operations stream_fops = { .owner = THIS_MODULE };\n",
      "static const struct file_operations stream_fops = { .owner = THIS_MODULE };\n"
      "\n"
      "/* CDH(gold-15): fence 链判别探针计数（v73 (27j)/(27l)） */\n"
      "static int cdh_fence_tlog;\n"
      "static int cdh_fence_clog;\n",
      "sync_file.c fence 探针计数声明（v73）",
      done="static int cdh_fence_tlog")
patch("drivers/gpu/arm/midgard/mali_kbase_sync_file.c",
      "\tif (!kbase_fence_out_is_ours(katom)) {\n"
      "\t\t/* Not our fence */\n"
      "\t\treturn BASE_JD_EVENT_JOB_CANCELLED;\n"
      "\t}\n"
      "\n"
      "\tres = kbase_fence_out_signal(katom, result);\n",
      "\tif (!kbase_fence_out_is_ours(katom)) {\n"
      "\t\t/* Not our fence */\n"
      "\t\tif (cdh_fence_tlog < 48) {\n"
      "\t\t\tcdh_fence_tlog++;\n"
      "\t\t\tpr_info(\"cdh_fence: out-trigger NOT-OURS fence=%p\\n\",\n"
      "\t\t\t\t(void *)katom->dma_fence.fence);\n"
      "\t\t}\n"
      "\t\treturn BASE_JD_EVENT_JOB_CANCELLED;\n"
      "\t}\n"
      "\n"
      "\tif (cdh_fence_tlog < 48) {\n"
      "\t\tcdh_fence_tlog++;\n"
      "\t\tpr_info(\"cdh_fence: out-trigger result=%d fence=%p\\n\",\n"
      "\t\t\tresult, (void *)katom->dma_fence.fence);\n"
      "\t}\n"
      "\tres = kbase_fence_out_signal(katom, result);\n",
      "sync_file.c out-trigger 判别探针（v73 (27j)）",
      done="cdh_fence: out-trigger result=%d")
patch("drivers/gpu/arm/midgard/mali_kbase_sync_file.c",
      "\tCSTD_UNUSED(fence);\n"
      "\n"
      "\t/* Cancel atom if fence is erroneous */\n",
      "\tCSTD_UNUSED(fence);\n"
      "\n"
      "\tif (cdh_fence_clog < 48) {\n"
      "\t\tcdh_fence_clog++;\n"
      "\t\tpr_info(\"cdh_fence: in-fence fired fence=%p\\n\", (void *)fence);\n"
      "\t}\n"
      "\n"
      "\t/* Cancel atom if fence is erroneous */\n",
      "sync_file.c in-fence 回调探针（v73 (27l)）",
      done="cdh_fence: in-fence fired fence=%p")

# v74 (27m)：dummy model job 执行延迟模拟——run86-88 丢唤醒残留时序根因。
# 判据链（solution.md §22）：v73 探针定案 mali fence 链 18/18 全部 signal、
# FENCE_WAIT 0 次（候选 (a) 排除），卡点收敛为「DDK 用户态事件消费死锁」。
# 静态解码（cmar_func.asm）：cmar 线程 poll 4 fd，mali 读被 w24 门控，w24 仅当
# doorbell 记录 [ctx+0x660]==0 时置 1；记录卡死非零 → 永不读 mali → 紧凑自旋。
# 时序根因：NO_MALI dummy model 原语义 = 写 JS_COMMAND_NEXT=START 的同一次
# update() tick 即完成 job 并断言 JOB_IRQ → 完成事件可在 KBASE_IOCTL_JOB_SUBMIT
# 批量循环（jd.c kbase_jd_submit 逐 atom 放锁）尚未返回时投递给用户态。
# 真机 job 执行需 µs-ms，绝无此序；厂商 DDK 内部 producer/consumer（render list
# 24B 条目流）按真机时序编排，完成过早会打乱其状态机（run45 伪指针写只读模板、
# cmar 门控死锁同族）。
# 改动：job 激活（START 写 / 链式 job_queued 晋升）记 cdh_done_ns = now+1ms，
# update() 未到点不判定完成；schedule_delayed_work 到点补一次 model tick
# （无寄存器访问也推进，防丢唤醒；已在队列则不动到期，防 reg 高频访问把 tick
# 无限推后）。软 job（FENCE_TRIGGER 同步完成）不动——真机同序，v73 已证健康。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "struct job_slot {\n"
      "\tint job_active;\n"
      "\tint job_queued;\n"
      "\tu32 job_complete_irq_asserted;\n"
      "\tu32 job_irq_mask;\n"
      "\tint job_disabled;\n"
      "};",
      "struct job_slot {\n"
      "\tint job_active;\n"
      "\tint job_queued;\n"
      "\tu32 job_complete_irq_asserted;\n"
      "\tu32 job_irq_mask;\n"
      "\tint job_disabled;\n"
      "\tu64 cdh_done_ns; /* CDH(gold-15): 最早完成时刻，模拟 job 执行耗时（v74 (27m)） */\n"
      "};",
      "model_dummy.c job_slot 加 cdh_done_ns（v74 (27m)）",
      done="u64 cdh_done_ns;")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "#include <asm/arch_timer.h>\n",
      "#include <asm/arch_timer.h>\n"
      "\n"
      "/* CDH(gold-15): v74 (27m) job 执行延迟模拟需要 ktime/workqueue */\n"
      "#include <linux/ktime.h>\n"
      "#include <linux/workqueue.h>\n",
      "model_dummy.c include ktime/workqueue（v74）",
      done="CDH(gold-15): v74 (27m) job 执行延迟模拟需要 ktime/workqueue")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "struct error_status_t hw_error_status;\n",
      "struct error_status_t hw_error_status;\n"
      "\n"
      "/* CDH(gold-15): v74 (27m) GPU job 执行延迟模拟——见 cdh_job_arm() 注释 */\n"
      "#define CDH_JOB_LATENCY_NS 1000000ULL /* 名义 1ms；实际完成粒度 ~1 tick */\n"
      "static struct dummy_model_t *cdh_dummy_model;\n"
      "static void cdh_job_tick(struct work_struct *work);\n"
      "static DECLARE_DELAYED_WORK(cdh_job_dwork, cdh_job_tick);\n",
      "model_dummy.c v74 全局（定时工作声明）",
      done="static DECLARE_DELAYED_WORK(cdh_job_dwork, cdh_job_tick);")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "static void midgard_model_update(void *h)\n"
      "{\n",
      "/* CDH(gold-15): v74 —— job 激活后满 CDH_JOB_LATENCY_NS 才允许完成；\n"
      " * schedule_delayed_work 到点补一次 model tick（不依赖寄存器访问密度，\n"
      " * 防丢唤醒）。已在队列则不动到期，防 reg 高频访问把 tick 无限推后。 */\n"
      "static void cdh_job_arm(void)\n"
      "{\n"
      "\tschedule_delayed_work(&cdh_job_dwork, 1);\n"
      "}\n"
      "\n"
      "static void midgard_model_update(void *h)\n"
      "{\n",
      "model_dummy.c cdh_job_arm 助手（v74）",
      done="static void cdh_job_arm(void)")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t/*this job is done assert IRQ lines */\n"
      "\t\tsignal_int(dummy, i);\n",
      "\t\t/* CDH(gold-15): v74 执行延迟——未到 cdh_done_ns 不判定完成，\n"
      "\t\t * 到点由 cdh_job_tick 推进（无寄存器访问也防丢唤醒） */\n"
      "\t\tif (ktime_get_ns() < dummy->slots[i].cdh_done_ns) {\n"
      "\t\t\tcdh_job_arm();\n"
      "\t\t\tcontinue;\n"
      "\t\t}\n"
      "\n"
      "\t\t/*this job is done assert IRQ lines */\n"
      "\t\tsignal_int(dummy, i);\n",
      "model_dummy.c update() 完成门控（v74）",
      done="未到 cdh_done_ns 不判定完成")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t/*process next job */\n"
      "\t\tdummy->slots[i].job_active = dummy->slots[i].job_queued;\n"
      "\t\tdummy->slots[i].job_queued = 0;\n"
      "\t\tif (dummy->slots[i].job_active) {\n",
      "\t\t/*process next job */\n"
      "\t\tdummy->slots[i].job_active = dummy->slots[i].job_queued;\n"
      "\t\tdummy->slots[i].job_queued = 0;\n"
      "\t\tif (dummy->slots[i].job_active) {\n"
      "\t\t\t/* CDH(gold-15): v74 链式 job 同样按执行耗时延迟完成 */\n"
      "\t\t\tdummy->slots[i].cdh_done_ns = ktime_get_ns() + CDH_JOB_LATENCY_NS;\n"
      "\t\t\tcdh_job_arm();\n",
      "model_dummy.c 链式 job 晋升记时刻（v74）",
      done="v74 链式 job 同样按执行耗时延迟完成")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t\t} else {\n"
      "\t\t\t\tdummy->slots[slot_idx].job_active = 1;\n"
      "\t\t\t}\n",
      "\t\t\t} else {\n"
      "\t\t\t\tdummy->slots[slot_idx].job_active = 1;\n"
      "\t\t\t\t/* CDH(gold-15): v74 记录最早完成时刻（模拟 job 执行耗时） */\n"
      "\t\t\t\tdummy->slots[slot_idx].cdh_done_ns = ktime_get_ns() + CDH_JOB_LATENCY_NS;\n"
      "\t\t\t\tcdh_job_arm();\n"
      "\t\t\t}\n",
      "model_dummy.c START 写记时刻（v74）",
      done="v74 记录最早完成时刻（模拟 job 执行耗时）")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\tgpu_device_set_data(dummy, kbdev);\n"
      "\n"
      "\t\tdev_info(kbdev->dev, \"Using Dummy Model\");\n",
      "\t\tgpu_device_set_data(dummy, kbdev);\n"
      "\n"
      "\t\t/* CDH(gold-15): v74 定时工作全局指针（tick 回调用） */\n"
      "\t\tcdh_dummy_model = dummy;\n"
      "\n"
      "\t\tdev_info(kbdev->dev, \"Using Dummy Model\");\n",
      "model_dummy.c create 记全局指针（v74）",
      done="v74 定时工作全局指针")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "void midgard_model_destroy(void *h)\n"
      "{\n"
      "\tkfree((void *)h);\n"
      "}\n",
      "void midgard_model_destroy(void *h)\n"
      "{\n"
      "\t/* CDH(gold-15): v74 撤 tick 工作防悬空 */\n"
      "\tcdh_dummy_model = NULL;\n"
      "\tcancel_delayed_work_sync(&cdh_job_dwork);\n"
      "\tkfree((void *)h);\n"
      "}\n",
      "model_dummy.c destroy 撤工作（v74）",
      done="v74 撤 tick 工作防悬空")
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "void midgard_model_write_reg(void *h, u32 addr, u32 value)\n"
      "{\n",
      "/* CDH(gold-15): v74 到点补 tick——无寄存器访问时也推进 job 完成\n"
      " * （update() 的门控分支也会 cdh_job_arm()，此处只做无锁快跑） */\n"
      "static void cdh_job_tick(struct work_struct *work)\n"
      "{\n"
      "\tstruct dummy_model_t *dummy = cdh_dummy_model;\n"
      "\tunsigned long flags;\n"
      "\n"
      "\tif (!dummy)\n"
      "\t\treturn;\n"
      "\n"
      "\tspin_lock_irqsave(&hw_error_status.access_lock, flags);\n"
      "\tmidgard_model_update(dummy);\n"
      "\tmidgard_model_get_outputs(dummy);\n"
      "\tspin_unlock_irqrestore(&hw_error_status.access_lock, flags);\n"
      "}\n"
      "\n"
      "void midgard_model_write_reg(void *h, u32 addr, u32 value)\n"
      "{\n",
      "model_dummy.c cdh_job_tick 回调（v74）",
      done="v74 到点补 tick——无寄存器访问时也推进 job 完成")

# (28) B2 渲染桥 v2（guest 侧两件：内核 mailbox/像素写回 + 用户态桥 helper）。
#      架构：kbase 提交 FS atom 时（(16d) 已解析 RT）把 Fragment shader 机器码
#      经 /dev/cdh_gpumbox（bridge/cdh_gpumbox.c，wire 末尾拷入 drivers/dma-buf/）
#      交给 guest helper（out/tmp/p2/gpumbox_bridge.c）→ /dev/hvc11 → host 渲染
#      （out/tmp/p2/gpurender_host.py，va2spirv+MoltenVK）→ RP01 像素写回 RT
#      并放行 job 完成；500ms 超时/失败走 (16d) 填色兜底（图层不动）。
#      本组补丁只做 kbase 侧胶水（提取 shader、入队、hold/release job 完成），
#      (16d) 填色语义原样保留作兜底；桥是增强路径，任何失败不 fail-loud。
#      ABI/字节序见 bridge/cdh_gpumbox.h 头注释（与 gpurender_host.py 的
#      ">4sIQIIIIIII"/">4sIIIII" 大端逐字段一致）。
#
# (28a) mali_kbase_jd.c：include + cdh_bridge_hold() extern 声明。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "#include <mali_kbase_caps.h>\n",
      "#include <mali_kbase_caps.h>\n"
      "\n"
      "/* CDH(gold-15): B2 渲染桥（wire-kbase.sh (28a)）——mailbox ABI 见\n"
      " * include/linux/cdh_gpumbox.h；cdh_bridge_hold() 定义在\n"
      " * backend/gpu/mali_kbase_model_dummy.c（seq→slot hold 表，容量 8），\n"
      " * job 激活时认领并把完成时刻推到 hold deadline。 */\n"
      "#include <linux/cdh_gpumbox.h>\n"
      "#include <linux/ktime.h>\n"
      "\n"
      "extern void cdh_bridge_hold(u32 seq, u64 jc, u64 deadline_ns);\n",
      "B2 桥：jd.c include + cdh_bridge_hold extern 声明",
      done="extern void cdh_bridge_hold(u32 seq, u64 jc, u64 deadline_ns);")

# (28k) mali_kbase_jd.c：cdh_b2_extract_at() 公共提取辅助——判定 ptr
#      直指 Shader Program（Descriptor Type=8, Stage=2 Fragment），取
#      .Binary（kbase_vmap 折半 4096→128 + flow=end 定长）。(28h-b/c)/(28j) 共用。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "extern void cdh_bridge_hold(u32 seq, u64 jc, u64 deadline_ns);\n",
      "extern void cdh_bridge_hold(u32 seq, u64 jc, u64 deadline_ns);\n"
      "\n"
      "/* CDH(gold-15): B2 桥 shader 提取辅助（wire-kbase.sh (28k)）。\n"
      " * 判定 ptr 直指 Shader Program（Descriptor Type=8,\n"
      " * Stage=2 Fragment），取 .Binary（GPU-exec 区 kbase_vmap 折半\n"
      " * 4096→128，flow=end 定长）拷入 out（上限 4096B）。\n"
      " * 返回 1=找到并拷出。 */\n"
      "static int cdh_b2_extract_at(struct kbase_context *kctx, u64 ptr,\n"
      "\t\t\t     u8 *out, u32 *out_len)\n"
      "{\n"
      "\tu8 sp[32];\n"
      "\tu64 bin = 0;\n"
      "\tconst u8 *code = NULL;\n"
      "\tstruct kbase_vmap_struct bmap;\n"
      "\tsize_t tlen, i, end = 0;\n"
      "\n"
      "\tif (ptr < 0x1000000ULL || ptr >= 0x10000000000ULL)\n"
      "\t\treturn 0;\n"
      "\tif (copy_from_user(sp, u64_to_user_ptr(ptr), sizeof(sp)))\n"
      "\t\treturn 0;\n"
      "\tif ((sp[0] & 0xf) != 8 || ((sp[0] >> 4) & 0xf) != 2)\n"
      "\t\treturn 0;\n"
      "\tmemcpy(&bin, sp + 0x08, 8);\n"
      "\tif (!bin)\n"
      "\t\treturn 0;\n"
      "\tfor (tlen = 4096; tlen >= 128; tlen >>= 1) {\n"
      "\t\tcode = kbase_vmap(kctx, bin, tlen, &bmap);\n"
      "\t\tif (code)\n"
      "\t\t\tbreak;\n"
      "\t}\n"
      "\tif (!code)\n"
      "\t\treturn 0;\n"
      "\tfor (i = 0; i + 8 <= tlen; i += 8) {\n"
      "\t\tu64 w;\n"
      "\n"
      "\t\tmemcpy(&w, code + i, 8);\n"
      "\t\tif (((w >> 59) & 0xf) == 15) {\n"
      "\t\t\tend = i + 8;\n"
      "\t\t\tbreak;\n"
      "\t\t}\n"
      "\t}\n"
      "\t*out_len = (u32)(end ? end : tlen);\n"
      "\tif (*out_len > 4096)\n"
      "\t\t*out_len = 4096;\n"
      "\tmemcpy(out, code, *out_len);\n"
      "\tkbase_vunmap(kctx, &bmap);\n"
      "\treturn 1;\n"
      "}\n"
      "\n"
      "/* CDH(gold-15): 从 .Resources 提取源纹理（Valhall v9 描述符解析）。\n"
      " * Shader Environment 偏移 +0x20 为 Resources 根指针。\n"
      " * 根表为 struct Resource 数组（每项 16B：[0..7]=Address:56 + contains_desc:1, [8..15]=Size）。\n"
      " * Address 指向描述符数组（每项 32B，Type 2=Texture）。\n"
      " * 纹理描述符：+0x04 为 Width(16b)/Height(16b) -1 编码；+0x10 为 Surfaces 指针。\n"
      " * 面描述符：+0x08 为 Pointer（源像素 GPU VA），+0x10 为 Row stride。\n"
      " * 成功提取返回 1，否则返回 0。 */\n"
      "static int cdh_b2_extract_res(struct kbase_context *kctx, u64 res_ptr,\n"
      "\t\t\t     u64 *src_base, u32 *src_w, u32 *src_h, u32 *src_stride)\n"
      "{\n"
      "\tu64 tex_desc_addr = 0;\n"
      "\tu8 tex_desc[64];\n"
      "\tu64 surfaces_ptr = 0;\n"
      "\tu8 plane_desc[32];\n"
      "\tu32 w1 = 0;\n"
      "\tu64 res_table_addr;\n"
      "\tu32 ntab, i, j;\n"
      "\tu64 dbg_ent[4] = { 0 };\n"
      "\tu8 dbg_tag[4] = { 0 };\n"
      "\n"
      "\tif (!src_base || !src_w || !src_h || !src_stride)\n"
      "\t\treturn 0;\n"
      "\t*src_base = 0;\n"
      "\t*src_w = 0;\n"
      "\t*src_h = 0;\n"
      "\t*src_stride = 0;\n"
      "\n"
      "\tif (res_ptr < 0x1000000ULL || res_ptr >= 0x10000000000ULL) {\n"
      "\t\tpr_info_ratelimited(\"cdh-mali: B2 src bad-res res=0x%llx\\n\", res_ptr);\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n"
      "\t/* panfrost 约定：Resources 指针低 6 位=资源表项数（表 64B 对齐）。\n"
      "\t * 计数为 0 时按上限 16 探测；每项 16B {Address:56|flags, Size}，\n"
      "\t * Size/32 = 该表描述符个数（上限 32）。 */\n"
      "\tres_table_addr = res_ptr & ~0x3fULL;\n"
      "\tntab = (u32)(res_ptr & 0x3f);\n"
      "\tif (!ntab || ntab > 16)\n"
      "\t\tntab = 16;\n"
      "\tfor (i = 0; i < ntab && !tex_desc_addr; i++) {\n"
      "\t\tu64 ent[2];\n"
      "\t\tu64 daddr;\n"
      "\t\tu32 ndesc;\n"
      "\n"
      "\t\tif (copy_from_user(ent, u64_to_user_ptr(res_table_addr + i * 16), sizeof(ent)))\n"
      "\t\t\tbreak;\n"
      "\t\tif (i < 4)\n"
      "\t\t\tdbg_ent[i] = ent[0];\n"
      "\t\tdaddr = ent[0] & 0x00ffffffffffffe0ULL;\n"
      "\t\tif (daddr < 0x1000000ULL || daddr >= 0x10000000000ULL)\n"
      "\t\t\tcontinue;\n"
      "\t\tndesc = (u32)(ent[1] / 32);\n"
      "\t\tif (!ndesc || ndesc > 32)\n"
      "\t\t\tndesc = 32;\n"
      "\t\tfor (j = 0; j < ndesc; j++) {\n"
      "\t\t\tu64 cand = daddr + j * 32;\n"
      "\t\t\tu8 tag = 0;\n"
      "\n"
      "\t\t\tif (copy_from_user(&tag, u64_to_user_ptr(cand), 1))\n"
      "\t\t\t\tbreak;\n"
      "\t\t\tif (i < 4 && j == 0)\n"
      "\t\t\t\tdbg_tag[i] = tag;\n"
      "\t\t\tif ((tag & 0xf) == 2) {\n"
      "\t\t\t\ttex_desc_addr = cand;\n"
      "\t\t\t\tbreak;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t}\n"
      "\n"
      "\tif (!tex_desc_addr) {\n"
      "\t\tpr_info_ratelimited(\"cdh-mali: B2 src no-tex res=0x%llx ntab=%u e0=0x%llx/%02x e1=0x%llx/%02x e2=0x%llx/%02x e3=0x%llx/%02x\\n\",\n"
      "\t\t\t\t    res_ptr, ntab, dbg_ent[0], dbg_tag[0], dbg_ent[1], dbg_tag[1],\n"
      "\t\t\t\t    dbg_ent[2], dbg_tag[2], dbg_ent[3], dbg_tag[3]);\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n"
      "\tif (copy_from_user(tex_desc, u64_to_user_ptr(tex_desc_addr), 32))\n"
      "\t\treturn 0;\n"
      "\n"
      "\tif ((tex_desc[0] & 0xf) != 2)\n"
      "\t\treturn 0;\n"
      "\n"
      "\tmemcpy(&w1, tex_desc + 0x04, 4);\n"
      "\t*src_w = (w1 & 0xffff) + 1;\n"
      "\t*src_h = ((w1 >> 16) & 0xffff) + 1;\n"
      "\n"
      "\t/* Plane 描述符 32B 对齐（v9.xml Generic Plane align=32） */\n"
      "\tmemcpy(&surfaces_ptr, tex_desc + 0x10, 8);\n"
      "\tsurfaces_ptr &= ~0x1fULL;\n"
      "\tif (surfaces_ptr < 0x1000000ULL || surfaces_ptr >= 0x10000000000ULL)\n"
      "\t\treturn 0;\n"
      "\n"
      "\tif (copy_from_user(plane_desc, u64_to_user_ptr(surfaces_ptr), sizeof(plane_desc)))\n"
      "\t\treturn 0;\n"
      "\n"
      "\t/* 只接受 Descriptor Type=10(Plane) + Plane type=1(Generic) +\n"
      "\t * Clump ordering=2(Linear)：AFBC(6)/U-Interleaved(1) 按行线性拷贝\n"
      "\t * 会得到错乱像素，宁可不直通（回落原路径）也不出错图。 */\n"
      "\tif ((plane_desc[0] & 0xf) != 10 || ((plane_desc[0] >> 4) & 0xf) != 1 ||\n"
      "\t    (plane_desc[1] & 0xf) != 2) {\n"
      "\t\tpr_info_ratelimited(\"cdh-mali: B2 src reject plane hdr=0x%02x%02x %ux%u (need Generic+Linear)\\n\",\n"
      "\t\t\t\t    plane_desc[1], plane_desc[0], *src_w, *src_h);\n"
      "\t\t*src_w = 0;\n"
      "\t\t*src_h = 0;\n"
      "\t\treturn 0;\n"
      "\t}\n"
      "\n"
      "\tmemcpy(src_base, plane_desc + 0x08, 8);\n"
      "\tmemcpy(src_stride, plane_desc + 0x10, 4);\n"
      "\n"
      "\tif (*src_base >= 0x1000000ULL && *src_base < 0x10000000000ULL &&\n"
      "\t    *src_w > 0 && *src_w <= 0x4000 &&\n"
      "\t    *src_h > 0 && *src_h <= 0x4000 &&\n"
      "\t    *src_stride >= *src_w * 4 && *src_stride <= 0x10000)\n"
      "\t\treturn 1;\n"
      "\n"
      "\t*src_base = 0;\n"
      "\treturn 0;\n"
      "}\n",
      "B2 桥 shader/源纹理提取辅助（v110 (28k)）",
      done="cdh_b2_extract_res(struct kbase_context *kctx")

# (29) run136：事件出入队双点打点（限 64）——回答「32 个吞点是否来自被读的内核事件」
#      （EV-GET 计数=交付数）+ 「udata 回显值对账」（blob0/blob1 值 vs DDK 提交值）。
#      纯日志、无语义改动。
patch("drivers/gpu/arm/midgard/mali_kbase_event.c",
      "\t\tdev_dbg(kbdev->dev, \"Reporting %d events\\n\", event_count);\n",
      "\t\tdev_dbg(kbdev->dev, \"Reporting %d events\\n\", event_count);\n"
      "\t\t/* CDH(gold-15): (29) run136 事件入队打点（限 64，取证用） */\n"
      "\t\t{\n"
      "\t\t\tstatic atomic_t cdh_ev_add = ATOMIC_INIT(0);\n"
      "\n"
      "\t\t\tif (atomic_inc_return(&cdh_ev_add) <= 64)\n"
      "\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t \"cdh-mali: EV-ADD atom=%u code=0x%x blob0=0x%llx blob1=0x%llx\\n\",\n"
      "\t\t\t\t\t kbase_jd_atom_id(kctx, atom), atom->event_code,\n"
      "\t\t\t\t\t (unsigned long long)atom->udata.blob[0],\n"
      "\t\t\t\t\t (unsigned long long)atom->udata.blob[1]);\n"
      "\t\t}\n",
      "run136 事件入队打点 EV-ADD（v81 (29a)）",
      done="cdh-mali: EV-ADD atom=")

patch("drivers/gpu/arm/midgard/mali_kbase_event.c",
      "\tuevent->udata = kbase_event_process(kctx, atom);\n",
      "\tuevent->udata = kbase_event_process(kctx, atom);\n"
      "\t/* CDH(gold-15): (29) run136 事件出队打点（限 64）——交付数=EV-GET 计数 */\n"
      "\t{\n"
      "\t\tstatic atomic_t cdh_ev_get = ATOMIC_INIT(0);\n"
      "\n"
      "\t\tif (atomic_inc_return(&cdh_ev_get) <= 64)\n"
      "\t\t\tdev_info(kctx->kbdev->dev,\n"
      "\t\t\t\t \"cdh-mali: EV-GET atom=%u code=0x%x blob0=0x%llx blob1=0x%llx\\n\",\n"
      "\t\t\t\t uevent->atom_number, uevent->event_code,\n"
      "\t\t\t\t (unsigned long long)uevent->udata.blob[0],\n"
      "\t\t\t\t (unsigned long long)uevent->udata.blob[1]);\n"
      "\t}\n",
      "run136 事件出队打点 EV-GET（v81 (29b)）",
      done="cdh-mali: EV-GET atom=")

# (28b) mali_kbase_model_dummy.c：include 桥 ABI 头。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "/* CDH(gold-15): v74 (27m) job 执行延迟模拟需要 ktime/workqueue */\n"
      "#include <linux/ktime.h>\n"
      "#include <linux/workqueue.h>\n",
      "/* CDH(gold-15): v74 (27m) job 执行延迟模拟需要 ktime/workqueue */\n"
      "#include <linux/ktime.h>\n"
      "#include <linux/workqueue.h>\n"
      "/* (28) B2 渲染桥 job hold/release 需要桥 ABI */\n"
      "#include <linux/cdh_gpumbox.h>\n",
      "model_dummy.c include cdh_gpumbox.h（v77 (28b)）",
      done="(28) B2 渲染桥 job hold/release 需要桥 ABI")

# (28c) model_dummy.c：B2 桥 hold 表 + 认领/门控/放行 + ops 注册胶水。
#      插在 midgard_model_update() 之前（cdh_job_arm/cdh_dummy_model/
#      CDH_JOB_LATENCY_NS 均已在 (27m) 就位且在其上文）。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "static void midgard_model_update(void *h)\n"
      "{\n",
      "/* CDH(gold-15): B2 渲染桥 job hold/release（wire-kbase.sh (28c)）——\n"
      " * jd.c 提交 FS atom 入队成功后 cdh_bridge_hold(seq, jc, deadline) 登记\n"
      " * pending（此刻 job 尚未进 slot）；job 激活（JS_COMMAND_NEXT=START 写）\n"
      " * 时 cdh_bridge_claim(slot, current_jc) 认领（jc 匹配优先，否则最老\n"
      " * 未认领项），完成时刻经 cdh_bridge_gate 推到 deadline（now+500ms\n"
      " * 兜底）；桥响应/超时时 cdh_bridge_release_seq(seq) 把对应 slot 完成\n"
      " * 时刻拉回 now+CDH_JOB_LATENCY_NS 并 cdh_job_arm() 补 tick（对齐\n"
      " * (27m) 机制）。表容量 8，与 cdh_gpumbox.c 的 mailbox ring 对应。\n"
      " * 锁序：hw_error_status.access_lock → cdh_bridge_map_lock。 */\n"
      "#define CDH_BRIDGE_MAP_N 8\n"
      "struct cdh_bridge_hold_ent {\n"
      "\tu32 seq; /* 0=空闲 */\n"
      "\tu64 jc;          /* FS atom 链首 jc，激活时认领匹配 */\n"
      "\tu64 deadline_ns; /* 兜底完成时刻 */\n"
      "\tint slot;        /* -1=未认领 */\n"
      "};\n"
      "static struct cdh_bridge_hold_ent cdh_bridge_map[CDH_BRIDGE_MAP_N];\n"
      "static DEFINE_SPINLOCK(cdh_bridge_map_lock);\n"
      "static u64 cdh_slot_hold_ns[NUM_SLOTS];\n"
      "\n"
      "void cdh_bridge_hold(u32 seq, u64 jc, u64 deadline_ns)\n"
      "{\n"
      "\tunsigned long flags;\n"
      "\tint i, free_i = -1;\n"
      "\n"
      "\tspin_lock_irqsave(&cdh_bridge_map_lock, flags);\n"
      "\tfor (i = 0; i < CDH_BRIDGE_MAP_N; i++) {\n"
      "\t\tif (!cdh_bridge_map[i].seq) {\n"
      "\t\t\tif (free_i < 0)\n"
      "\t\t\t\tfree_i = i;\n"
      "\t\t\tcontinue;\n"
      "\t\t}\n"
      "\t\tif (cdh_bridge_map[i].seq == seq) {\n"
      "\t\t\tfree_i = i; /* 同 seq 覆盖旧项（防御性） */\n"
      "\t\t\tbreak;\n"
      "\t\t}\n"
      "\t}\n"
      "\tif (free_i >= 0) {\n"
      "\t\tcdh_bridge_map[free_i].seq = seq;\n"
      "\t\tcdh_bridge_map[free_i].jc = jc;\n"
      "\t\tcdh_bridge_map[free_i].deadline_ns = deadline_ns;\n"
      "\t\tcdh_bridge_map[free_i].slot = -1;\n"
      "\t}\n"
      "\tspin_unlock_irqrestore(&cdh_bridge_map_lock, flags);\n"
      "}\n"
      "\n"
      "/* job 激活（START 写）时认领：jc 匹配优先，否则最老未认领项兜底 */\n"
      "static void cdh_bridge_claim(int slot_idx, u64 jc)\n"
      "{\n"
      "\tint i, hit = -1, oldest = -1;\n"
      "\n"
      "\tspin_lock(&cdh_bridge_map_lock);\n"
      "\tfor (i = 0; i < CDH_BRIDGE_MAP_N; i++) {\n"
      "\t\tif (!cdh_bridge_map[i].seq || cdh_bridge_map[i].slot >= 0)\n"
      "\t\t\tcontinue;\n"
      "\t\tif (jc && cdh_bridge_map[i].jc == jc) {\n"
      "\t\t\thit = i;\n"
      "\t\t\tbreak;\n"
      "\t\t}\n"
      "\t\tif (oldest < 0)\n"
      "\t\t\toldest = i;\n"
      "\t}\n"
      "\ti = (hit >= 0) ? hit : oldest;\n"
      "\tif (i >= 0) {\n"
      "\t\tcdh_bridge_map[i].slot = slot_idx;\n"
      "\t\tcdh_slot_hold_ns[slot_idx] = cdh_bridge_map[i].deadline_ns;\n"
      "\t}\n"
      "\tspin_unlock(&cdh_bridge_map_lock);\n"
      "}\n"
      "\n"
      "/* 完成时刻：正常 now+1ms；已认领 hold 则推到 deadline（(28)） */\n"
      "static u64 cdh_bridge_gate(int slot_idx, u64 base_ns)\n"
      "{\n"
      "\tu64 hold = cdh_slot_hold_ns[slot_idx];\n"
      "\n"
      "\treturn hold > base_ns ? hold : base_ns;\n"
      "}\n"
      "\n"
      "/* B2 桥放行：RP01 写回完成/超时时经 ops->release 调用 */\n"
      "static void cdh_bridge_release_seq(u32 seq)\n"
      "{\n"
      "\tunsigned long flags, mflags;\n"
      "\tint i, slot = -1;\n"
      "\n"
      "\tspin_lock_irqsave(&hw_error_status.access_lock, flags);\n"
      "\tspin_lock_irqsave(&cdh_bridge_map_lock, mflags);\n"
      "\tfor (i = 0; i < CDH_BRIDGE_MAP_N; i++) {\n"
      "\t\tif (cdh_bridge_map[i].seq != seq)\n"
      "\t\t\tcontinue;\n"
      "\t\tslot = cdh_bridge_map[i].slot;\n"
      "\t\tcdh_bridge_map[i].seq = 0;\n"
      "\t\tcdh_bridge_map[i].jc = 0;\n"
      "\t\tcdh_bridge_map[i].slot = -1;\n"
      "\t\tbreak;\n"
      "\t}\n"
      "\tif (slot >= 0) {\n"
      "\t\tcdh_slot_hold_ns[slot] = 0;\n"
      "\t\tif (cdh_dummy_model)\n"
      "\t\t\tcdh_dummy_model->slots[slot].cdh_done_ns =\n"
      "\t\t\t\tktime_get_ns() + CDH_JOB_LATENCY_NS;\n"
      "\t}\n"
      "\tspin_unlock_irqrestore(&cdh_bridge_map_lock, mflags);\n"
      "\tspin_unlock_irqrestore(&hw_error_status.access_lock, flags);\n"
      "\tif (slot >= 0)\n"
      "\t\tcdh_job_arm();\n"
      "}\n"
      "\n"
      "static const struct cdh_bridge_ops cdh_bridge_ops_inst = {\n"
      "\t.release = cdh_bridge_release_seq,\n"
      "};\n"
      "\n"
      "void cdh_bridge_glue_init(void)\n"
      "{\n"
      "\tcdh_bridge_register_ops(&cdh_bridge_ops_inst);\n"
      "\tpr_info(\"cdh-mali: B2 bridge glue ready\\n\");\n"
      "}\n"
      "\n"
      "void cdh_bridge_glue_exit(void)\n"
      "{\n"
      "\tcdh_bridge_register_ops(NULL);\n"
      "}\n"
      "\n"
      "static void midgard_model_update(void *h)\n"
      "{\n",
      "model_dummy.c B2 桥 hold 表 + 放行胶水（v77 (28c)）",
      done="void cdh_bridge_glue_init(void)")

# (28d) model_dummy.c：START 写（job 激活）认领 hold 并门控完成时刻。
#      覆写 (27m)「START 写记时刻」插入文本（保留其 done 标记注释原文，
#      保证 (27m) 幂等判定不受影响）。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t\t} else {\n"
      "\t\t\t\tdummy->slots[slot_idx].job_active = 1;\n"
      "\t\t\t\t/* CDH(gold-15): v74 记录最早完成时刻（模拟 job 执行耗时） */\n"
      "\t\t\t\tdummy->slots[slot_idx].cdh_done_ns = ktime_get_ns() + CDH_JOB_LATENCY_NS;\n"
      "\t\t\t\tcdh_job_arm();\n"
      "\t\t\t}\n",
      "\t\t\t} else {\n"
      "\t\t\t\tdummy->slots[slot_idx].job_active = 1;\n"
      "\t\t\t\t/* CDH(gold-15): v74 记录最早完成时刻（模拟 job 执行耗时）\n"
      "\t\t\t\t * (28d) 认领 B2 桥 hold：job 激活才知 slot，hold 在此\n"
      "\t\t\t\t * 落到对应 slot，完成时刻推到 deadline（now+500ms 兜底） */\n"
      "\t\t\t\tcdh_bridge_claim(slot_idx, hw_error_status.current_jc);\n"
      "\t\t\t\tdummy->slots[slot_idx].cdh_done_ns = cdh_bridge_gate(slot_idx, ktime_get_ns() + CDH_JOB_LATENCY_NS);\n"
      "\t\t\t\tcdh_job_arm();\n"
      "\t\t\t}\n",
      "model_dummy.c START 写认领 hold + 门控（v77 (28d)）",
      done="(28d) 认领 B2 桥 hold")

# (28e) model_dummy.c：链式 job 晋升同样经门控取 hold deadline。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\tif (dummy->slots[i].job_active) {\n"
      "\t\t\t/* CDH(gold-15): v74 链式 job 同样按执行耗时延迟完成 */\n"
      "\t\t\tdummy->slots[i].cdh_done_ns = ktime_get_ns() + CDH_JOB_LATENCY_NS;\n"
      "\t\t\tcdh_job_arm();\n",
      "\t\tif (dummy->slots[i].job_active) {\n"
      "\t\t\t/* CDH(gold-15): v74 链式 job 同样按执行耗时延迟完成\n"
      "\t\t\t * (28e) 已认领的 B2 桥 hold 优先（认领发生在入队写时） */\n"
      "\t\t\tdummy->slots[i].cdh_done_ns = cdh_bridge_gate(i, ktime_get_ns() + CDH_JOB_LATENCY_NS);\n"
      "\t\t\tcdh_job_arm();\n",
      "model_dummy.c 晋升门控 hold（v77 (28e)）",
      done="(28e) 已认领的 B2 桥 hold 优先")

# (28f) model_dummy.c：job 入队（job_queued=1）即认领——该写时 jc 有效
#      （JS_HEAD_NEXT 刚写完），晋升激活时经 cdh_bridge_gate 取到 deadline。
patch("drivers/gpu/arm/midgard/backend/gpu/mali_kbase_model_dummy.c",
      "\t\t\t\tdummy->slots[slot_idx].job_queued = 1;\n",
      "\t\t\t\tdummy->slots[slot_idx].job_queued = 1;\n"
      "\t\t\t\t/* CDH(gold-15): (28f) 入队即认领（jc 在 START 写时有效，\n"
      "\t\t\t\t * current_jc 即本 job 链首），晋升时经 cdh_bridge_gate\n"
      "\t\t\t\t * 取到 hold deadline */\n"
      "\t\t\t\tcdh_bridge_claim(slot_idx, hw_error_status.current_jc);\n",
      "model_dummy.c 入队认领 hold（v77 (28f)）",
      done="(28f) 入队即认领")

# (28g) mali_kbase_core_linux.c：模块 init/exit 注册/注销桥放行回调。
patch("drivers/gpu/arm/midgard/mali_kbase_core_linux.c",
      "static int __init kbase_driver_init(void)\n"
      "{\n"
      "\tint ret;\n",
      "/* CDH(gold-15): B2 渲染桥 kbase 侧胶水（wire-kbase.sh (28g)）——\n"
      " * cdh_bridge_glue_* 定义在 backend/gpu/mali_kbase_model_dummy.c */\n"
      "extern void cdh_bridge_glue_init(void);\n"
      "extern void cdh_bridge_glue_exit(void);\n"
      "\n"
      "static int __init kbase_driver_init(void)\n"
      "{\n"
      "\tint ret;\n"
      "\n"
      "\t/* B2 桥：注册放行回调（release(seq) 把 job 完成时刻拉回 now+1ms） */\n"
      "\tcdh_bridge_glue_init();\n",
      "core_linux.c B2 桥 glue init（v77 (28g)）",
      done="extern void cdh_bridge_glue_init(void);")
patch("drivers/gpu/arm/midgard/mali_kbase_core_linux.c",
      "static void __exit kbase_driver_exit(void)\n"
      "{\n"
      "\tplatform_driver_unregister(&kbase_platform_driver);\n",
      "static void __exit kbase_driver_exit(void)\n"
      "{\n"
      "\tcdh_bridge_glue_exit();\n"
      "\tplatform_driver_unregister(&kbase_platform_driver);\n",
      "core_linux.c B2 桥 glue exit（v77 (28g)）",
      done="\tcdh_bridge_glue_exit();")

# (28h) mali_kbase_jd.c：FS atom 提交桥接（(16d) type==9 块内、填色日志后
#      追加，填色语义不动仍作兜底）。shader 提取仿 (19) chase：沿 job 链取
#      Shader Environment → Shader Program(type=8,stage=2) → .Binary，
#      kbase_vmap 折半取（4096→128），长度用 (19) 的 flow=end 遍历法；
#      提取失败/队满只记日志（限 16 次），兜底图层直接生效。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\t\t\t\t\t\t cdh_w0, cdh_w2, cdh_filled);\n"
      "\t\t\t\t}\n"
      "cdh_next_job:\n",
      "\t\t\t\t\t\t\t cdh_w0, cdh_w2, cdh_filled);\n"
      "\t\t\t\t\t/* CDH: B2 v2 渲染桥（wire-kbase.sh (28h)）——(16d) 填色\n"
      "\t\t\t\t\t * 保留作兜底图层（先填，桥渲结果随后覆盖）；shader\n"
      "\t\t\t\t\t * 提取失败/队满时兜底图层直接生效：桥是增强路径，\n"
      "\t\t\t\t\t * 不 fail-loud 整个 submit。入队成功登记 pending hold，\n"
      "\t\t\t\t\t * job 激活认领时完成时刻推到 now+500ms 兜底（(28c-d)）。 */\n"
      "\t\t\t\t\tdo {\n"
      "\t\t\t\t\t\tstatic u8 cdh_b2_shbuf[4096];\n"
      "\t\t\t\t\t\tstatic u8 cdh_b2_job[384];\n"
      "\t\t\t\t\t\tstatic atomic_t cdh_b2_seq = ATOMIC_INIT(0);\n"
      "\t\t\t\t\t\tstatic atomic_t cdh_b2_probe = ATOMIC_INIT(0);\n"
      "\t\t\t\t\t\tu64 cdh_b2_j = cdh_real_jc;\n"
      "\t\t\t\t\t\tu32 cdh_b2_n, cdh_b2_slen = 0;\n"
      "\t\t\t\t\t\tu64 cdh_b2_pay = 0, cdh_b2_fbd = 0;\n"
      "\t\t\t\t\t\tu64 cdh_b2_src_base = 0;\n"
      "\t\t\t\t\t\tu32 cdh_b2_src_w = 0, cdh_b2_src_h = 0, cdh_b2_src_stride = 0;\n"
      "\n"
      "\t\t\t\t\t\tfor (cdh_b2_n = 0;\n"
      "\t\t\t\t\t\t     cdh_b2_n < 8 && cdh_b2_j && !cdh_b2_slen;\n"
      "\t\t\t\t\t\t     cdh_b2_n++) {\n"
      "\t\t\t\t\t\t\tu64 cdh_b2_envs[3];\n"
      "\t\t\t\t\t\t\tu64 cdh_b2_next;\n"
      "\t\t\t\t\t\t\tu32 cdh_b2_hdr, cdh_b2_type;\n"
      "\t\t\t\t\t\t\tu32 cdh_b2_ne = 0, cdh_b2_e;\n"
      "\n"
      "\t\t\t\t\t\t\tif (copy_from_user(cdh_b2_job,\n"
      "\t\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_b2_j),\n"
      "\t\t\t\t\t\t\t\t\t   sizeof(cdh_b2_job)))\n"
      "\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\tmemcpy(&cdh_b2_hdr, cdh_b2_job + 0x10, 4);\n"
      "\t\t\t\t\t\t\tmemcpy(&cdh_b2_next, cdh_b2_job + 0x18, 8);\n"
      "\t\t\t\t\t\t\tcdh_b2_type = (cdh_b2_hdr >> 1) & 0x7f;\n"
      "\t\t\t\t\t\t\t/* Shader Environment 候选（(19) 布局）：Compute\n"
      "\t\t\t\t\t\t\t * env@+0x40、Tiler DCD@128→env@128+0x40、\n"
      "\t\t\t\t\t\t\t * MallocVertex env@256/320；Fragment Job 无内嵌\n"
      "\t\t\t\t\t\t\t * env，payload@+0x20 可能指外置 env（任务书\n"
      "\t\t\t\t\t\t\t * 「Fragment Job → shader env」）。 */\n"
      "\t\t\t\t\t\t\tif (cdh_b2_type == 4) {\n"
      "\t\t\t\t\t\t\t\tcdh_b2_envs[cdh_b2_ne++] = cdh_b2_j + 0x40;\n"
      "\t\t\t\t\t\t\t} else if (cdh_b2_type == 7) {\n"
      "\t\t\t\t\t\t\t\tcdh_b2_envs[cdh_b2_ne++] =\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_j + 128 + 0x40;\n"
      "\t\t\t\t\t\t\t} else if (cdh_b2_type == 11) {\n"
      "\t\t\t\t\t\t\t\tcdh_b2_envs[cdh_b2_ne++] = cdh_b2_j + 256;\n"
      "\t\t\t\t\t\t\t\tcdh_b2_envs[cdh_b2_ne++] = cdh_b2_j + 320;\n"
      "\t\t\t\t\t\t\t} else if (cdh_b2_type == 9) {\n"
      "\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_pay, cdh_b2_job + 0x20, 8);\n"
      "\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_fbd, cdh_b2_job + 0x28, 8);\n"
      "\t\t\t\t\t\t\t\tcdh_b2_fbd &= ~0x3fULL;\n"
      "\t\t\t\t\t\t\t\tif (cdh_b2_pay >= 0x1000000ULL &&\n"
      "\t\t\t\t\t\t\t\t    cdh_b2_pay < 0x10000000000ULL)\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_envs[cdh_b2_ne++] =\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_pay;\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\tfor (cdh_b2_e = 0;\n"
      "\t\t\t\t\t\t\t     cdh_b2_e < cdh_b2_ne && !cdh_b2_slen;\n"
      "\t\t\t\t\t\t\t     cdh_b2_e++) {\n"
      "\t\t\t\t\t\t\t\tstruct kbase_vmap_struct cdh_b2_bmap;\n"
      "\t\t\t\t\t\t\t\tconst u8 *cdh_b2_code = NULL;\n"
      "\t\t\t\t\t\t\t\tu64 cdh_b2_sh = 0, cdh_b2_bin = 0;\n"
      "\t\t\t\t\t\t\t\tu8 cdh_b2_sp[32];\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_b2_try, cdh_b2_i;\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_b2_end = 0;\n"
      "\t\t\t\t\t\t\t\tu32 cdh_b2_len;\n"
      "\n"
      "\t\t\t\t\t\t\t\tif (copy_from_user(\n"
      "\t\t\t\t\t\t\t\t\t\t&cdh_b2_sh,\n"
      "\t\t\t\t\t\t\t\t\t\tu64_to_user_ptr(cdh_b2_envs[cdh_b2_e] +\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t0x28),\n"
      "\t\t\t\t\t\t\t\t\t\tsizeof(cdh_b2_sh)) || !cdh_b2_sh)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tif (copy_from_user(cdh_b2_sp,\n"
      "\t\t\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_b2_sh),\n"
      "\t\t\t\t\t\t\t\t\t\t   sizeof(cdh_b2_sp)))\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\t/* Descriptor Type=8(Shader)、Stage=2(Fragment) */\n"
      "\t\t\t\t\t\t\t\tif ((cdh_b2_sp[0] & 0xf) != 8 ||\n"
      "\t\t\t\t\t\t\t\t    ((cdh_b2_sp[0] >> 4) & 0xf) != 2)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_bin, cdh_b2_sp + 0x08, 8);\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_bin)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\t/* .Binary 在 GPU-exec 区：kbase_vmap 折半取\n"
      "\t\t\t\t\t\t\t\t * （4096→128，越界自动降长，同 (19)） */\n"
      "\t\t\t\t\t\t\t\tfor (cdh_b2_try = 4096; cdh_b2_try >= 128;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_try >>= 1) {\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_code = kbase_vmap(\n"
      "\t\t\t\t\t\t\t\t\t\tkctx, cdh_b2_bin,\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_try, &cdh_b2_bmap);\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_b2_code)\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_code)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\t/* (19) flow=end 遍历法定长 */\n"
      "\t\t\t\t\t\t\t\tfor (cdh_b2_i = 0;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_i + 8 <= cdh_b2_try;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_i += 8) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_b2_w;\n"
      "\n"
      "\t\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_w,\n"
      "\t\t\t\t\t\t\t\t\t       cdh_b2_code + cdh_b2_i, 8);\n"
      "\t\t\t\t\t\t\t\t\tif (((cdh_b2_w >> 59) & 0xf) == 15) {\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_end = cdh_b2_i + 8;\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tcdh_b2_len = (u32)(cdh_b2_end ?\n"
      "\t\t\t\t\t\t\t\t\t\t  cdh_b2_end : cdh_b2_try);\n"
      "\t\t\t\t\t\t\t\tif (cdh_b2_len > sizeof(cdh_b2_shbuf))\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_len = sizeof(cdh_b2_shbuf);\n"
      "\t\t\t\t\t\t\t\tmemcpy(cdh_b2_shbuf, cdh_b2_code, cdh_b2_len);\n"
      "\t\t\t\t\t\t\t\tkbase_vunmap(kctx, &cdh_b2_bmap);\n"
      "\t\t\t\t\t\t\t\tcdh_b2_slen = cdh_b2_len;\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_src_base) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_b2_res = 0;\n"
      "\t\t\t\t\t\t\t\t\tif (!copy_from_user(&cdh_b2_res, u64_to_user_ptr(cdh_b2_envs[cdh_b2_e] + 0x20), sizeof(cdh_b2_res)) && cdh_b2_res)\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_extract_res(kctx, cdh_b2_res, &cdh_b2_src_base, &cdh_b2_src_w, &cdh_b2_src_h, &cdh_b2_src_stride);\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (atomic_inc_return(&cdh_b2_probe) <= 16)\n"
      "\t\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge shader jc=0x%llx type=%u bin=0x%llx len=%u end=%zu src=0x%llx %ux%u\\n\",\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_j, cdh_b2_type,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_bin, cdh_b2_slen,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_end, cdh_b2_src_base,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_src_w, cdh_b2_src_h);\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t/* (28h-b) 通用有界指针追踪（(19) chase 同款）：\n"
      "\t\t\t\t\t\t\t * 扫 job 缓冲 8B 对齐字，直指 Shader Program\n"
      "\t\t\t\t\t\t\t * （Descriptor Type=8, Stage=2 Fragment）即取\n"
      "\t\t\t\t\t\t\t * .Binary。实证：真机 FS 链 fragment shader 指针\n"
      "\t\t\t\t\t\t\t * 落 +0xe8 等非固定 env 位（run100 对照 P3 chase\n"
      "\t\t\t\t\t\t\t * 日志逐条吻合），固定 env 候选全不中。 */\n"
      "\t\t\t\t\t\t\tfor (cdh_b2_e = 0;\n"
      "\t\t\t\t\t\t\t     cdh_b2_e + 8 <= sizeof(cdh_b2_job) &&\n"
      "\t\t\t\t\t\t\t     !cdh_b2_slen;\n"
      "\t\t\t\t\t\t\t     cdh_b2_e += 8) {\n"
      "\t\t\t\t\t\t\t\tstruct kbase_vmap_struct cdh_b2_bmap;\n"
      "\t\t\t\t\t\t\t\tconst u8 *cdh_b2_code = NULL;\n"
      "\t\t\t\t\t\t\t\tu64 cdh_b2_v = 0, cdh_b2_bin = 0;\n"
      "\t\t\t\t\t\t\t\tu8 cdh_b2_sp[32];\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_b2_try, cdh_b2_i;\n"
      "\t\t\t\t\t\t\t\tsize_t cdh_b2_end = 0;\n"
      "\t\t\t\t\t\t\t\tu32 cdh_b2_len;\n"
      "\n"
      "\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_v, cdh_b2_job + cdh_b2_e, 8);\n"
      "\t\t\t\t\t\t\t\tif (cdh_b2_v < 0x1000000ULL ||\n"
      "\t\t\t\t\t\t\t\t    cdh_b2_v >= 0x10000000000ULL)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tif (copy_from_user(cdh_b2_sp,\n"
      "\t\t\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_b2_v),\n"
      "\t\t\t\t\t\t\t\t\t\t   sizeof(cdh_b2_sp)))\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tif ((cdh_b2_sp[0] & 0xf) != 8 ||\n"
      "\t\t\t\t\t\t\t\t    ((cdh_b2_sp[0] >> 4) & 0xf) != 2)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_bin, cdh_b2_sp + 0x08, 8);\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_bin)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tfor (cdh_b2_try = 4096; cdh_b2_try >= 128;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_try >>= 1) {\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_code = kbase_vmap(\n"
      "\t\t\t\t\t\t\t\t\t\tkctx, cdh_b2_bin,\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_try, &cdh_b2_bmap);\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_b2_code)\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_code)\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tfor (cdh_b2_i = 0;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_i + 8 <= cdh_b2_try;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_i += 8) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_b2_w;\n"
      "\n"
      "\t\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_w,\n"
      "\t\t\t\t\t\t\t\t\t       cdh_b2_code + cdh_b2_i, 8);\n"
      "\t\t\t\t\t\t\t\t\tif (((cdh_b2_w >> 59) & 0xf) == 15) {\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_end = cdh_b2_i + 8;\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tcdh_b2_len = (u32)(cdh_b2_end ?\n"
      "\t\t\t\t\t\t\t\t\t\t  cdh_b2_end : cdh_b2_try);\n"
      "\t\t\t\t\t\t\t\tif (cdh_b2_len > sizeof(cdh_b2_shbuf))\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_len = sizeof(cdh_b2_shbuf);\n"
      "\t\t\t\t\t\t\t\tmemcpy(cdh_b2_shbuf, cdh_b2_code, cdh_b2_len);\n"
      "\t\t\t\t\t\t\t\tkbase_vunmap(kctx, &cdh_b2_bmap);\n"
      "\t\t\t\t\t\t\t\tcdh_b2_slen = cdh_b2_len;\n"
      "\t\t\t\t\t\t\t\tif (!cdh_b2_src_base && cdh_b2_e >= 8) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_b2_res = 0;\n"
      "\t\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_res, cdh_b2_job + cdh_b2_e - 8, 8);\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_extract_res(kctx, cdh_b2_res, &cdh_b2_src_base, &cdh_b2_src_w, &cdh_b2_src_h, &cdh_b2_src_stride);\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\tif (atomic_inc_return(&cdh_b2_probe) <= 16)\n"
      "\t\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge shader chase +0x%x jc=0x%llx bin=0x%llx len=%u end=%zu src=0x%llx %ux%u\\n\",\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_e, cdh_b2_j,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_bin, cdh_b2_slen,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_end, cdh_b2_src_base,\n"
      "\t\t\t\t\t\t\t\t\t\t cdh_b2_src_w, cdh_b2_src_h);\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\tcdh_b2_j = cdh_b2_next;\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t/* (28h-c) payload/FBD 广度追逐（种子+二级，容量\n"
      "\t\t\t\t\t\t * 12）+ 捕获缓存兜底：FS 链为单 type=9 job、链上\n"
      "\t\t\t\t\t\t * 追不到 fragment shader（(19) 注释定案=落 Tiler\n"
      "\t\t\t\t\t\t * Job DCD，run102 实证 FS 时点全 skip）→ ① payload\n"
      "\t\t\t\t\t\t * @+0x20 / FBD 两种子 BFS 找 stage-2 直指；② 仍无\n"
      "\t\t\t\t\t\t * →取 (28j) Tiler atom 捕获缓存（同 tgid，2s）。 */\n"
      "\t\t\t\t\t\tif (!cdh_b2_slen && (cdh_b2_pay || cdh_b2_fbd)) {\n"
      "\t\t\t\t\t\t\tu64 cdh_b2_seeds[12];\n"
      "\t\t\t\t\t\t\tu32 cdh_b2_ns = 0, cdh_b2_si;\n"
      "\n"
      "\t\t\t\t\t\t\tif (cdh_b2_pay)\n"
      "\t\t\t\t\t\t\t\tcdh_b2_seeds[cdh_b2_ns++] = cdh_b2_pay;\n"
      "\t\t\t\t\t\t\tif (cdh_b2_fbd)\n"
      "\t\t\t\t\t\t\t\tcdh_b2_seeds[cdh_b2_ns++] = cdh_b2_fbd;\n"
      "\t\t\t\t\t\t\tfor (cdh_b2_si = 0;\n"
      "\t\t\t\t\t\t\t     cdh_b2_si < cdh_b2_ns && !cdh_b2_slen &&\n"
      "\t\t\t\t\t\t\t     cdh_b2_ns < 12;) {\n"
      "\t\t\t\t\t\t\t\tu8 cdh_b2_reg[256];\n"
      "\t\t\t\t\t\t\t\tu64 cdh_b2_seed =\n"
      "\t\t\t\t\t\t\t\t\tcdh_b2_seeds[cdh_b2_si++];\n"
      "\t\t\t\t\t\t\t\tu32 cdh_b2_ri;\n"
      "\n"
      "\t\t\t\t\t\t\t\tif (copy_from_user(cdh_b2_reg,\n"
      "\t\t\t\t\t\t\t\t\t\t   u64_to_user_ptr(cdh_b2_seed),\n"
      "\t\t\t\t\t\t\t\t\t\t   sizeof(cdh_b2_reg)))\n"
      "\t\t\t\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\t\t\t\tfor (cdh_b2_ri = 0;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_ri + 8 <= sizeof(cdh_b2_reg) &&\n"
      "\t\t\t\t\t\t\t\t     !cdh_b2_slen;\n"
      "\t\t\t\t\t\t\t\t     cdh_b2_ri += 8) {\n"
      "\t\t\t\t\t\t\t\t\tu64 cdh_b2_rv = 0;\n"
      "\n"
      "\t\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_rv,\n"
      "\t\t\t\t\t\t\t\t\t       cdh_b2_reg + cdh_b2_ri, 8);\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_b2_extract_at(kctx, cdh_b2_rv,\n"
      "\t\t\t\t\t\t\t\t\t\t\t  cdh_b2_shbuf,\n"
      "\t\t\t\t\t\t\t\t\t\t\t  &cdh_b2_slen)) {\n"
      "\t\t\t\t\t\t\t\t\t\tif (cdh_b2_ri >= 8) {\n"
      "\t\t\t\t\t\t\t\t\t\t\tu64 cdh_b2_res = 0;\n"
      "\t\t\t\t\t\t\t\t\t\t\tmemcpy(&cdh_b2_res, cdh_b2_reg + cdh_b2_ri - 8, 8);\n"
      "\t\t\t\t\t\t\t\t\t\t\tcdh_b2_extract_res(kctx, cdh_b2_res,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t   &cdh_b2_src_base, &cdh_b2_src_w,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t   &cdh_b2_src_h, &cdh_b2_src_stride);\n"
      "\t\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t\t\tif (atomic_inc_return(&cdh_b2_probe) <=\n"
      "\t\t\t\t\t\t\t\t\t\t    16)\n"
      "\t\t\t\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge shader seed=0x%llx off=+0x%x jc=0x%llx len=%u src=0x%llx %ux%u\\n\",\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t cdh_b2_seed,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t cdh_b2_ri, cdh_real_jc,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t cdh_b2_slen, cdh_b2_src_base,\n"
      "\t\t\t\t\t\t\t\t\t\t\t\t cdh_b2_src_w, cdh_b2_src_h);\n"
      "\t\t\t\t\t\t\t\t\t\tbreak;\n"
      "\t\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t\t\tif (cdh_b2_rv >= 0x1000000ULL &&\n"
      "\t\t\t\t\t\t\t\t\t    cdh_b2_rv < 0x10000000000ULL &&\n"
      "\t\t\t\t\t\t\t\t\t    cdh_b2_ns < 12)\n"
      "\t\t\t\t\t\t\t\t\t\tcdh_b2_seeds[cdh_b2_ns++] =\n"
      "\t\t\t\t\t\t\t\t\t\t\tcdh_b2_rv;\n"
      "\t\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\tif (!cdh_b2_slen &&\n"
      "\t\t\t\t\t\t    cdh_bridge_cache_get(cdh_b2_shbuf, &cdh_b2_slen,\n"
      "\t\t\t\t\t\t\t\t\t (u32)current->tgid,\n"
      "\t\t\t\t\t\t\t\t\t &cdh_b2_src_base, &cdh_b2_src_w,\n"
      "\t\t\t\t\t\t\t\t\t &cdh_b2_src_h, &cdh_b2_src_stride) &&\n"
      "\t\t\t\t\t\t    atomic_inc_return(&cdh_b2_probe) <= 16)\n"
      "\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge shader cache-hit jc=0x%llx len=%u src=0x%llx %ux%u\\n\",\n"
      "\t\t\t\t\t\t\t\t cdh_real_jc, cdh_b2_slen,\n"
      "\t\t\t\t\t\t\t\t cdh_b2_src_base, cdh_b2_src_w, cdh_b2_src_h);\n"
      "\t\t\t\t\t\tif (cdh_b2_slen) {\n"
      "\t\t\t\t\t\t\tstruct cdh_bridge_req cdh_b2_req = { 0 };\n"
      "\t\t\t\t\t\t\tu32 cdh_b2_seqv;\n"
      "\t\t\t\t\t\tint cdh_sub_ret;\n"
      "\n"
      "\t\t\t\t\t\t\tcdh_b2_seqv = (u32)atomic_inc_return(&cdh_b2_seq);\n"
      "\t\t\t\t\t\t\tif (!cdh_b2_seqv)\n"
      "\t\t\t\t\t\t\t\tcdh_b2_seqv = (u32)atomic_inc_return(&cdh_b2_seq);\n"
      "\t\t\t\t\t\t\tcdh_b2_req.seq = cdh_b2_seqv;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.rt_base = cdh_base;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.w = cdh_w;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.h = cdh_h;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.row_stride = cdh_rows;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.surf_stride = cdh_surf;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.blk = cdh_blk;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.src_base = cdh_b2_src_base;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.src_w = cdh_b2_src_w;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.src_h = cdh_b2_src_h;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.src_stride = cdh_b2_src_stride;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.flags = (cdh_w2 & 0x4) ?\n"
      "\t\t\t\t\t\t\t\tCDH_BRIDGE_FLAG_WIDE_SB : 0;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.shader = cdh_b2_shbuf;\n"
      "\t\t\t\t\t\t\tcdh_b2_req.shader_len = cdh_b2_slen;\n"
      "\t\t\t\t\t\t\tcdh_sub_ret = cdh_bridge_submit(&cdh_b2_req);\n"
      "\t\t\t\t\t\t\tif (!cdh_sub_ret) {\n"
      "\t\t\t\t\t\t\t\t/* 入队成功（host 执行 shader + 真实源纹理）：登记 pending hold */\n"
      "\t\t\t\t\t\t\t\tcdh_bridge_hold(cdh_b2_seqv, cdh_real_jc,\n"
      "\t\t\t\t\t\t\t\t\t\tktime_get_ns() + 3000000000ULL);\n"
      "\t\t\t\t\t\t\t} else if (atomic_inc_return(&cdh_b2_probe) <= 16) {\n"
      "\t\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge skip seq=%u jc=0x%llx submit err=%d\\n\",\n"
      "\t\t\t\t\t\t\t\t\t cdh_b2_seqv, cdh_real_jc, cdh_sub_ret);\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t} else if (atomic_inc_return(&cdh_b2_probe) <= 16) {\n"
      "\t\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t\t \"cdh-mali: B2 bridge skip jc=0x%llx rt=0x%llx no fragment shader\\n\",\n"
      "\t\t\t\t\t\t\t\t cdh_real_jc, cdh_base);\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t} while (0);\n"
      "\t\t\t\t}\n"
      "cdh_next_job:\n",
      "B2 桥 FS atom 提交桥接（v110 (28h)）",
      done="cdh_sub_ret = cdh_bridge_submit(&cdh_b2_req);")

# (28j) mali_kbase_jd.c：Tiler atom stage-2 shader 捕获进缓存。
#      (19) 注释定案：fragment shader 落 Tiler Job 的 DCD（job 缓冲
#      +0xe8 处直指 Shader Program），FS atom 为单 type=9 job 链、链上
#      追不到 → Tiler atom 提交时捕获（同 tgid、2s 有效），FS 周转取用。
patch("drivers/gpu/arm/midgard/mali_kbase_jd.c",
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n",
      "\t\t/* CDH(gold-15): B2 桥 Tiler atom stage-2 shader 捕获\n"
      "\t\t * （wire-kbase.sh (28j)）——见上方 (28h-c) 注释：fragment\n"
      "\t\t * shader 落 Tiler Job 的 DCD，此处捕获进缓存供 FS 周转取用。 */\n"
      "\t\tif ((cdh_real_req & 0x2) && cdh_real_jc) {\n"
      "\t\t\tstatic u8 cdh_b2_tjob[384];\n"
      "\t\t\tstatic u8 cdh_b2_tbuf[4096];\n"
      "\t\t\tstatic atomic_t cdh_b2_tprobe = ATOMIC_INIT(0);\n"
      "\t\t\tu64 cdh_b2_tj = cdh_real_jc;\n"
      "\t\t\tu32 cdh_b2_tn;\n"
      "\n"
      "\t\t\tfor (cdh_b2_tn = 0; cdh_b2_tn < 8 && cdh_b2_tj;\n"
      "\t\t\t     cdh_b2_tn++) {\n"
      "\t\t\t\tu64 cdh_b2_tnext = 0;\n"
      "\t\t\t\tu32 cdh_b2_tw;\n"
      "\n"
      "\t\t\t\tif (copy_from_user(cdh_b2_tjob,\n"
      "\t\t\t\t\t\t   u64_to_user_ptr(cdh_b2_tj),\n"
      "\t\t\t\t\t\t   sizeof(cdh_b2_tjob)))\n"
      "\t\t\t\t\tbreak;\n"
      "\t\t\t\tmemcpy(&cdh_b2_tnext, cdh_b2_tjob + 0x18, 8);\n"
      "\t\t\t\tfor (cdh_b2_tw = 0;\n"
      "\t\t\t\t     cdh_b2_tw + 8 <= sizeof(cdh_b2_tjob);\n"
      "\t\t\t\t     cdh_b2_tw += 8) {\n"
      "\t\t\t\t\tu64 cdh_b2_tv = 0;\n"
      "\t\t\t\t\tu32 cdh_b2_tlen = 0;\n"
      "\t\t\t\t\tu64 cdh_b2_tsrc = 0;\n"
      "\t\t\t\t\tu32 cdh_b2_tsw = 0, cdh_b2_tsh = 0, cdh_b2_tsstride = 0;\n"
      "\n"
      "\t\t\t\t\tmemcpy(&cdh_b2_tv, cdh_b2_tjob + cdh_b2_tw, 8);\n"
      "\t\t\t\t\tif (!cdh_b2_extract_at(kctx, cdh_b2_tv,\n"
      "\t\t\t\t\t\t\t  cdh_b2_tbuf, &cdh_b2_tlen))\n"
      "\t\t\t\t\t\tcontinue;\n"
      "\t\t\t\t\tif (cdh_b2_tw >= 8) {\n"
      "\t\t\t\t\t\tu64 cdh_b2_tres = 0;\n"
      "\t\t\t\t\t\tmemcpy(&cdh_b2_tres, cdh_b2_tjob + cdh_b2_tw - 8, 8);\n"
      "\t\t\t\t\t\tcdh_b2_extract_res(kctx, cdh_b2_tres,\n"
      "\t\t\t\t\t\t\t\t   &cdh_b2_tsrc, &cdh_b2_tsw,\n"
      "\t\t\t\t\t\t\t\t   &cdh_b2_tsh, &cdh_b2_tsstride);\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t\tcdh_bridge_cache_put(cdh_b2_tbuf, cdh_b2_tlen,\n"
      "\t\t\t\t\t\t\t     (u32)current->tgid,\n"
      "\t\t\t\t\t\t\t     cdh_b2_tsrc, cdh_b2_tsw,\n"
      "\t\t\t\t\t\t\t     cdh_b2_tsh, cdh_b2_tsstride);\n"
      "\t\t\t\t\tif (atomic_inc_return(&cdh_b2_tprobe) <= 8)\n"
      "\t\t\t\t\t\tdev_info(kbdev->dev,\n"
      "\t\t\t\t\t\t\t \"cdh-mali: B2 bridge cache-put jc=0x%llx off=+0x%x len=%u src=0x%llx %ux%u\\n\",\n"
      "\t\t\t\t\t\t\t cdh_b2_tj, cdh_b2_tw, cdh_b2_tlen,\n"
      "\t\t\t\t\t\t\t cdh_b2_tsrc, cdh_b2_tsw, cdh_b2_tsh);\n"
      "\t\t\t\t\tbreak;\n"
      "\t\t\t\t}\n"
      "\t\t\t\tcdh_b2_tj = cdh_b2_tnext;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tuser_addr = (void __user *)((uintptr_t)user_addr + stride);\n",
      "B2 桥 Tiler atom stage-2 shader 捕获（v110 (28j)）",
      done="cdh-mali: B2 bridge cache-put jc=0x%llx")

# v85 (29a) AtomicCommit 分段计时探针：量化「AtomicCommit 慢」当前是否仍在。
# 背景：solution.md vendor-gpu §15.3 记「AtomicCommit 慢（10s 级）」是 v62 时期
# 病灶；v72 已修通 flip 链（flip_done 超时归零）。run123 实测已无 flip_done
# timed out，但 GPU 提交恒停 ~39s + mali-cmar-backe 用户态自旋（§22.3 DDK
# 死锁定性）→ 需实测 commit 各段耗时，判「慢」是否已消失、慢在哪段。
# 限 24 条、total>200ms 才打（区分常态与慢，防刷屏）。
patch("drivers/gpu/drm/drm_atomic_helper.c",
      "\tdrm_atomic_helper_commit_modeset_disables(dev, old_state);\n"
      "\n"
      "\tdrm_atomic_helper_commit_planes(dev, old_state, 0);\n"
      "\n"
      "\tdrm_atomic_helper_commit_modeset_enables(dev, old_state);\n"
      "\n"
      "\tdrm_atomic_helper_fake_vblank(old_state);\n"
      "\n"
      "\tdrm_atomic_helper_commit_hw_done(old_state);\n"
      "\n"
      "\tdrm_atomic_helper_wait_for_vblanks(dev, old_state);\n"
      "\n"
      "\tdrm_atomic_helper_cleanup_planes(dev, old_state);\n"
      "}\n",
      "\t/* CDH(gold-15): AtomicCommit 分段计时（v85 (29a)）：限 24 条、>200ms 打 */\n"
      "\t{\n"
      "\t\tstatic int cdh_commit_log, cdh_commit_cnt;\n"
      "\t\tstatic long long cdh_commit_max;\n"
      "\t\tktime_t t0 = ktime_get(), t1, t2, t3, t4;\n"
      "\n"
      "\t\tdrm_atomic_helper_commit_modeset_disables(dev, old_state);\n"
      "\n"
      "\t\tt1 = ktime_get();\n"
      "\t\tdrm_atomic_helper_commit_planes(dev, old_state, 0);\n"
      "\n"
      "\t\tdrm_atomic_helper_commit_modeset_enables(dev, old_state);\n"
      "\n"
      "\t\tdrm_atomic_helper_fake_vblank(old_state);\n"
      "\n"
      "\t\tdrm_atomic_helper_commit_hw_done(old_state);\n"
      "\n"
      "\t\tt2 = ktime_get();\n"
      "\t\tdrm_atomic_helper_wait_for_vblanks(dev, old_state);\n"
      "\n"
      "\t\tt3 = ktime_get();\n"
      "\t\tdrm_atomic_helper_cleanup_planes(dev, old_state);\n"
      "\t\tt4 = ktime_get();\n"
      "\t\tif (cdh_commit_log < 24 && ktime_ms_delta(t4, t0) > 200) {\n"
      "\t\t\tcdh_commit_log++;\n"
      "\t\t\tpr_info(\"cdh_commit: total=%lldms disables=%lld planes=%lld vblanks=%lld cleanup=%lld\\n\",\n"
      "\t\t\t\tktime_ms_delta(t4, t0), ktime_ms_delta(t1, t0),\n"
      "\t\t\t\tktime_ms_delta(t2, t1), ktime_ms_delta(t3, t2),\n"
      "\t\t\t\tktime_ms_delta(t4, t3));\n"
      "\t\t}\n"
      "\t\t/* v87 (29c)：无歧义量化——首条立即打 + 每 10 条汇总。\n"
      "\t\t * v86 的 %50 有盲区：commit<50 次时「没跑」与「跑了都快」分不开。 */\n"
      "\t\t{\n"
      "\t\t\tlong long mt = ktime_ms_delta(t4, t0);\n"
      "\n"
      "\t\t\tcdh_commit_cnt++;\n"
      "\t\t\tif (mt > cdh_commit_max)\n"
      "\t\t\t\tcdh_commit_max = mt;\n"
      "\t\t\tif (cdh_commit_cnt == 1 || (cdh_commit_cnt % 10) == 0)\n"
      "\t\t\t\tpr_info(\"cdh_commit: agg count=%d max_total=%lldms last=%lldms disables=%lld planes=%lld vblanks=%lld cleanup=%lld\\n\",\n"
      "\t\t\t\t\tcdh_commit_cnt, cdh_commit_max, mt,\n"
      "\t\t\t\t\tktime_ms_delta(t1, t0), ktime_ms_delta(t2, t1),\n"
      "\t\t\t\t\tktime_ms_delta(t3, t2), ktime_ms_delta(t4, t3));\n"
      "\t\t}\n"
      "\t}\n"
      "}\n",
      "AtomicCommit 分段计时探针（v85 (29a)，v87 (29c) agg 无歧义化）",
      done="cdh_commit: agg count=%d max_total=%lldms last=%lldms disables=")


PY

# 7) Phase C·第八补丁接线：/proc/ged stub 源文件就位（每次覆盖，便于宿主侧迭代）。
#    依据与行为见 ged_stub.c 头注释（run34 实锤：ge_alloc 返回值 = buffer 主 fd，
#    GED 桥缺失 → data[0]=-1 → binder "Passing -1 fd" → 客户端 -129）。
cp -a kernel/modules/mali_vgpu/ged-stub/ged_stub.c drivers/dma-buf/ged_stub.c
if ! grep -qxF 'obj-y += ged_stub.o' drivers/dma-buf/Makefile; then
	echo 'obj-y += ged_stub.o' >> drivers/dma-buf/Makefile
fi

# 8) (28i) B2 渲染桥 mailbox 驱动就位（每次覆盖，便于宿主侧迭代）。
#    ABI 与职责见 bridge/cdh_gpumbox.h 头注释；与 ged-stub 同法接线
#    （drivers/dma-buf/ obj-y 编进内核，EXPORT_SYMBOL_GPL 供 mali_kbase.ko
#    的 (28a-h) 胶水调用）。头文件拷进 include/linux/ 供 <linux/cdh_gpumbox.h>
#    引用（kbase 三个胶水文件同用）。
cp -a kernel/modules/mali_vgpu/bridge/cdh_gpumbox.c drivers/dma-buf/cdh_gpumbox.c
cp -a kernel/modules/mali_vgpu/bridge/cdh_gpumbox.h include/linux/cdh_gpumbox.h
if ! grep -qxF 'obj-y += cdh_gpumbox.o' drivers/dma-buf/Makefile; then
	echo 'obj-y += cdh_gpumbox.o' >> drivers/dma-buf/Makefile
fi

echo "[wire-kbase] in-tree 接线完成（drivers/gpu/arm + Kconfig/Makefile + ccflags 适配）"
