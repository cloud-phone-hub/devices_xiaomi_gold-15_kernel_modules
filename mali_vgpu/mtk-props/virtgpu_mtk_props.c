// SPDX-License-Identifier: GPL-2.0
/*
 * CDH gold-15: 在 virtio-gpu 的 CRTC, Plane, Connector 上注册 MTK HWC 所需的私有 KMS 属性。
 *
 * 依据：MTK HWC (hwcomposer.mt6833.so) 的 DrmModeResource, DrmModeCrtc,
 * DrmModePlane, DrmModeConnector 初始化时对每个 KMS 对象按名字检查专有属性。
 * 若任一必需属性缺失，DrmObject::checkProperty() 返回 -22 (EINVAL)，导致：
 *   [DRMDEV] failed to check plane[31] property: error=-22
 *   [DRMDEV] failed to initialize plane[0]: 31
 *   [DRMDEV] failed to initialize all plane: -19
 *   [DRMDEV] failed to initialize connector[0]: 85
 *   [DRMDEV] failed to initialize all connector: -19
 * 进而导致后续 drmModeAtomicCommit 全部失败 ret=-22，HWC 无法呈现真画面。
 *
 * 本文件由 kernel/modules/mali_vgpu/wire-kbase.sh 拷入 drivers/gpu/drm/virtio/。
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <drm/drm_property.h>
#include <drm/drm_plane.h>
#include <drm/drm_crtc.h>
#include <drm/drm_connector.h>
#include <drm/drm_blend.h>

#include "virtgpu_drv.h"

struct cdh_mtk_prop {
	const char *name;
	u64 init;
};

/*
 * CRTC 属性表（49项，对齐 MTK HWC DrmModeCrtc 检查清单）
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

/*
 * Plane 私有属性表（17项，由 hwcomposer.so DrmModePlane::DrmModePlane 精确提取）
 */
static const struct cdh_mtk_prop cdh_mtk_plane_props[] = {
	{ "NEXT_BUFF_IDX", 0 },
	{ "DATASPACE", 0 },
	{ "VPITCH", 0 },
	{ "COMPRESS", 0 },
	{ "PLANE_PROP_PLANE_ALPHA", 0xff },
	{ "PLANE_PROP_ALPHA_CON", 0 },
	{ "DIM_COLOR", 0 },
	{ "IS_MML", 0 },
	{ "MML_SUBMIT", 0 },
	{ "BUFFER_ALLOC_ID", 0 },
	{ "OVL_CSC_SET_BRIGHTNESS", 0 },
	{ "OVL_CSC_SET_COLORTRANSFORM", 0 },
	{ "DIRTY_ROI_NUM", 0 },
	{ "DIRTY_ROI_X", 0 },
	{ "DIRTY_ROI_Y", 0 },
	{ "DIRTY_ROI_W", 0 },
	{ "DIRTY_ROI_H", 0 },
};

/*
 * Connector 私有属性表（3项，由 hwcomposer.so DrmModeConnector::DrmModeConnector 精确提取）
 */
static const struct cdh_mtk_prop cdh_mtk_connector_props[] = {
	{ "CAPS_BLOB_ID", 0 },
	{ "CSC_BL", 0 },
	{ "PANEL_NITS", 1000 },
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
			DRM_ERROR("cdh_mtk: create crtc prop %s failed\n",
				  cdh_mtk_crtc_props[i].name);
			continue;
		}
		drm_object_attach_property(&crtc->base, prop,
					   cdh_mtk_crtc_props[i].init);
	}
	DRM_INFO("cdh_mtk: attached %zu MTK props to crtc\n",
		 ARRAY_SIZE(cdh_mtk_crtc_props));
}

void virtio_gpu_mtk_attach_plane_props(struct drm_device *dev, struct drm_plane *plane)
{
	struct drm_property *prop;
	int i;

	/* 1. 标准 DRM plane 属性：alpha, blend mode, zpos */
	drm_plane_create_alpha_property(plane);
	drm_plane_create_blend_mode_property(plane,
					     BIT(DRM_MODE_BLEND_PIXEL_NONE) |
					     BIT(DRM_MODE_BLEND_PREMULTI) |
					     BIT(DRM_MODE_BLEND_COVERAGE));
	drm_plane_create_zpos_property(plane, 0, 0, 16);

	/* 2. MTK 专有 plane 属性 */
	for (i = 0; i < ARRAY_SIZE(cdh_mtk_plane_props); i++) {
		prop = drm_property_create_range(dev, DRM_MODE_PROP_ATOMIC,
						 cdh_mtk_plane_props[i].name,
						 0, ~(u64)0);
		if (!prop) {
			DRM_ERROR("cdh_mtk: create plane prop %s failed\n",
				  cdh_mtk_plane_props[i].name);
			continue;
		}
		drm_object_attach_property(&plane->base, prop,
					   cdh_mtk_plane_props[i].init);
	}
	DRM_INFO("cdh_mtk: attached %zu MTK props to plane %d\n",
		 ARRAY_SIZE(cdh_mtk_plane_props), plane->base.id);
}

void virtio_gpu_mtk_attach_connector_props(struct drm_device *dev, struct drm_connector *conn)
{
	struct drm_property *prop;
	int i;

	for (i = 0; i < ARRAY_SIZE(cdh_mtk_connector_props); i++) {
		prop = drm_property_create_range(dev, DRM_MODE_PROP_ATOMIC,
						 cdh_mtk_connector_props[i].name,
						 0, ~(u64)0);
		if (!prop) {
			DRM_ERROR("cdh_mtk: create conn prop %s failed\n",
				  cdh_mtk_connector_props[i].name);
			continue;
		}
		drm_object_attach_property(&conn->base, prop,
					   cdh_mtk_connector_props[i].init);
	}
	DRM_INFO("cdh_mtk: attached %zu MTK props to connector %d\n",
		 ARRAY_SIZE(cdh_mtk_connector_props), conn->base.id);
}

/*
 * CRTC 属性 atomic 读写闭环
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

/*
 * Plane 属性 atomic 读写闭环
 */
int virtio_gpu_mtk_plane_atomic_get_property(struct drm_plane *plane,
					     const struct drm_plane_state *state,
					     struct drm_property *property,
					     u64 *val)
{
	struct drm_mode_object *obj = &plane->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			*val = obj->properties->values[i];
			return 0;
		}
	}
	return -EINVAL;
}

int virtio_gpu_mtk_plane_atomic_set_property(struct drm_plane *plane,
					     struct drm_plane_state *state,
					     struct drm_property *property,
					     u64 val)
{
	struct drm_mode_object *obj = &plane->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			obj->properties->values[i] = val;
			return 0;
		}
	}
	return -EINVAL;
}

/*
 * Connector 属性 atomic 读写闭环
 */
int virtio_gpu_mtk_connector_atomic_get_property(struct drm_connector *conn,
						 const struct drm_connector_state *state,
						 struct drm_property *property,
						 u64 *val)
{
	struct drm_mode_object *obj = &conn->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			*val = obj->properties->values[i];
			return 0;
		}
	}
	return -EINVAL;
}

int virtio_gpu_mtk_connector_atomic_set_property(struct drm_connector *conn,
						 struct drm_connector_state *state,
						 struct drm_property *property,
						 u64 val)
{
	struct drm_mode_object *obj = &conn->base;
	int i;

	for (i = 0; i < obj->properties->count; i++) {
		if (obj->properties->properties[i] == property) {
			obj->properties->values[i] = val;
			return 0;
		}
	}
	return -EINVAL;
}
