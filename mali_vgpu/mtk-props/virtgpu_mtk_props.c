// SPDX-License-Identifier: GPL-2.0
/*
 * CDH gold-15: 在 virtio-gpu 的 CRTC 上注册 MTK HWC 所需的私有 KMS 属性。
 *
 * 依据（实测，实例 gold-15/21，composer pid 596 启动日志）：MTK HWC
 * (hwcomposer.mt6833.so) 的 DrmDevice::getCaps() 对 card0 每个 CRTC 按名字查
 * 下列属性；全部缺失时打印
 *     [DRMDEV] getCaps(), crtc[id=33|pipe=0x0]
 *     property[OVERLAP_LAYER_NUM] does not do initialize …（49 个）
 * 并给 CRTC 分配 pipe=0x0 → DrmModeResource::connectAllDisplay() 里
 * "[x19+284]" 的 caps 闸门为 0 → 不创建任何 display → SF 拿 BadDisplay →
 * (MIUI 改造的) SurfaceFlinger::configureLocked → dispatchHotplugError NULL deref。
 *
 * 方案：49 个属性名逐字对齐，全部以 drm range 属性挂到 virtio CRTC 上，
 * 并给合理初值（分辨率/overlay 层数等），让 getCaps 能读到；并给
 * virtio_gpu_crtc_funcs 补 atomic_get/set_property 回调（见文件尾）。
 *
 * 本文件由 kernel/modules/mali_vgpu/wire-kbase.sh 拷入 drivers/gpu/drm/virtio/
 * 并接线（Makefile + virtgpu_display.c），宿主内核树保持 git 干净。
 *
 * 第二版（实例 24 取证）：仅挂属性后 MTK HWC 反而打
 *     [DRMDEV] failed to get 0xcccccccc[33] properties
 *     [DRMDEV] failed to init crtc[id=33|pipe=0x0] property: errno[-19]
 * （0xcccccccc = DRM_MODE_OBJECT_CRTC）。根因：virtio-gpu 是 atomic driver，
 * drmModeGetObjectProperties 枚举每个非 IMMUTABLE 属性都经
 * drm_atomic_crtc_get_property() 读值，非标准属性落到 crtc->funcs->
 * atomic_get_property——virtio-gpu 未实现该回调 → -EINVAL，而
 * drm_mode_object_get_properties() 里单属性读值失败即整体 ioctl 失败
 * （21 轮未挂属性时只有 ACTIVE/MODE_ID/VRR/OUT_FENCE_PTR 四个标准属性全命中，
 * 故枚举成功、49 条 "does not do initialize"）。
 * 修复：给 virtio_gpu_crtc_funcs 补 atomic_get/set_property 回调，对非标准
 * 属性做 obj->properties->values[] 软件值读写闭环（标准属性不会进回调）。
 */

#include <linux/kernel.h>
#include <drm/drm_property.h>

#include "virtgpu_drv.h"

struct cdh_mtk_prop {
	const char *name;
	u64 init;
};

/*
 * 49 项：名称逐字取自 gold-15/21 实测 "does not do initialize" 清单（去重）。
 * 初值：OUTPUT_ 与 DST_ 前缀的项给 1080x2400（与 QEMU EDID 注入的 mode 一致），
 * OVERLAP_LAYER_NUM 给 4（MTK 典型 OVL 层数），PRESENT_FENCE 等 fence/sync
 * 类给 0（HWC 会写值进来），其余给 0/1 的中性值。
 */
static const struct cdh_mtk_prop cdh_mtk_crtc_props[] = {
	{ "OUTPUT_ENABLE", 1 },
	{ "OUTPUT_X", 0 },
	{ "OUTPUT_Y", 0 },
	{ "OUTPUT_WIDTH", 1080 },
	{ "OUTPUT_HEIGHT", 2400 },
	{ "OUTPUT_DST_WIDTH", 1080 },
	{ "OUTPUT_DST_HEIGHT", 2400 },
	{ "OUTPUT_BUFF_IDX", 0 },
	{ "OUTPUT_FB_ID", 0 },
	{ "OUTPUT_SCENARIO", 0 },
	{ "OVERLAP_LAYER_NUM", 4 },
	{ "LAYERING_IDX", 0 },
	{ "PRESENT_FENCE", 0 },
	{ "INTF_BUFF_IDX", 0 },
	{ "DISP_MODE_IDX", 0 },
	{ "COLOR_TRANSFORM", 0 },
	{ "USER_SCEN", 0 },
	{ "HBM_ENABLE", 0 },
	{ "HDR_ENABLE", 0 },
	{ "MSYNC2_0_ENABLE", 0 },
	{ "MSYNC2_0_EPT", 0 },
	{ "OVL_DSI_SEQ", 0 },
	{ "CAPS_BLOB_ID", 0 },
	{ "AOSP_CCORR_LINEAR", 0 },
	{ "PARTIAL_UPDATE_ENABLE", 0 },
	{ "BL_SYNC_GAMMA_GAIN", 0 },
	{ "DYNAMIC_WCG_OFF", 0 },
	{ "WCG_BY_COLOR_MODE", 0 },
	{ "DIM_COLOR", 0 },
	{ "STYLUS_MODE", 0 },
	{ "PANEL_NITS", 0 },
	{ "OVL_CSC_SET_BRIGHTNESS", 0 },
	{ "OVL_CSC_SET_COLORTRANSFORM", 0 },
	{ "DOZE_ACTIVE", 0 },
	{ "DIRTY_ROI_X", 0 },
	{ "DIRTY_ROI_Y", 0 },
	{ "DIRTY_ROI_W", 0 },
	{ "DIRTY_ROI_H", 0 },
	{ "DIRTY_ROI_NUM", 0 },
	{ "BUFFER_ALLOC_ID", 0 },
	{ "NEXT_BUFF_IDX", 0 },
	{ "COMPRESS", 0 },
	{ "CSC_BL", 0 },
	{ "DATASPACE", 0 },
	{ "IS_MML", 0 },
	{ "MML_SUBMIT", 0 },
	{ "PLANE_PROP_ALPHA_CON", 0 },
	{ "PLANE_PROP_PLANE_ALPHA", 0 },
	{ "VPITCH", 0 },
};

void virtio_gpu_mtk_attach_crtc_props(struct drm_device *dev, struct drm_crtc *crtc)
{
	struct drm_property *prop;
	int i;

	for (i = 0; i < ARRAY_SIZE(cdh_mtk_crtc_props); i++) {
		prop = drm_property_create_range(dev, DRM_MODE_PROP_ATOMIC,
						 cdh_mtk_crtc_props[i].name,
						 0, ~(u64)0);
		if (!prop) {
			DRM_ERROR("cdh_mtk: create prop %s failed\n",
				  cdh_mtk_crtc_props[i].name);
			continue;
		}
		drm_object_attach_property(&crtc->base, prop,
					    cdh_mtk_crtc_props[i].init);
	}
	DRM_INFO("cdh_mtk: attached %zu MTK props to crtc\n",
		 ARRAY_SIZE(cdh_mtk_crtc_props));
}

/*
 * 非标准（MTK 私有）CRTC 属性的 atomic 读写回调。
 * drm_atomic_crtc_get/set_property() 对标准属性（ACTIVE/MODE_ID/…）自行处理后，
 * 其余属性落到这里；用 obj->properties->values[] 的软件值读写闭环。
 * atomic driver 的惯例是把值放 crtc_state 私有字段，virtio-gpu 的 crtc state
 * 无扩展字段，软件值方案对 HWC 的「写-读回」语义一致（每次 commit 全量重设）。
 */
int virtio_gpu_mtk_crtc_atomic_get_property(struct drm_crtc *crtc,
					    const struct drm_crtc_state *state,
					    struct drm_property *property,
					    u64 *val)
{
	struct drm_mode_object *obj = &crtc->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			*val = obj->properties->values[i];
			return 0;
		}
	}
	return -EINVAL;
}

int virtio_gpu_mtk_crtc_atomic_set_property(struct drm_crtc *crtc,
					    struct drm_crtc_state *state,
					    struct drm_property *property,
					    u64 val)
{
	struct drm_mode_object *obj = &crtc->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			obj->properties->values[i] = val;
			return 0;
		}
	}
	return -EINVAL;
}
