/* SPDX-License-Identifier: GPL-2.0 */
/*
 * CDH gold-15：B2 渲染桥 mailbox ABI（wire-kbase.sh (28)）。
 *
 * /dev/cdh_gpumbox 是内核（kbase 提交路径）与 guest 用户态桥 helper
 * （out/tmp/p2/gpumbox_bridge.c）之间的请求/响应邮箱：
 *   内核 → helper：GR01 请求记录（RT 参数 + Fragment shader 机器码），
 *                  helper 组帧经 /dev/hvc11 送 host 渲染服务
 *                  （out/tmp/p2/gpurender_host.py）；
 *   helper → 内核：RP01 响应记录（status + 256x256 RGBA8 像素），
 *                  内核缩放写回 RT 并放行 job 完成。
 *
 * 记录格式（read()/write() 各一次一条完整记录）：
 *   [u32 len][payload] —— len = payload 字节数，与 payload 内多字节字段
 *   统一 **大端（BE）**，与 hvc11 帧（[4B BE len][payload]）逐字节一致，
 *   helper 可零换算转发。
 *
 * GR01 payload（内核→helper，44B 头 + shader）：
 *   u8  magic[4] = "GR01"
 *   u32 seq            （内核原子递增生成）
 *   u64 rt_base        （RT 基址，用户/GPU SAME_VA）
 *   u32 w, h           （RT 尺寸）
 *   u32 row_stride, surf_stride
 *   u32 blk            （Writeback Block Format：2=Linear 12=AFBC 13=AFBC Tiled）
 *   u32 flags          （CDH_BRIDGE_FLAG_*）
 *   u32 shader_len
 *   u8  shader[shader_len]（Fragment shader 机器码）
 *
 * GR02 payload（内核→helper，带真实源纹理，56B 头 + shader + 纹理）：
 *   GR01 的 44B 头（magic="GR02"，字段/偏移完全相同）后追加：
 *   u32 tex_w, tex_h   （降采样纹理尺寸，恒 CDH_BRIDGE_IMG_W x IMG_H）
 *   u32 tex_len        （= tex_w * tex_h * 4）
 *   u8  shader[shader_len]
 *   u8  tex[tex_len]   （RGBA8 行主序：kbase (28k) 从 Valhall Texture→
 *                       Plane 描述符解析出的源纹理，在提交进程上下文最近邻
 *                       降采样；host harness 绑定为 binding 3 供 TEX 采样）
 *   无可用源纹理时仍发 GR01（host 走无纹理路径），不伪造纹理。
 *
 * RP01 payload（helper→内核，24B 头 + 像素）：
 *   u8  magic[4] = "RP01"
 *   u32 seq            （必须与请求 seq 一致）
 *   u32 status         （0=渲染成功带像素；1=翻译/渲染失败，内核走兜底图层）
 *   u32 img_w, img_h   （恒 256x256）
 *   u32 pix_len        （status=0 时为 256*256*4，否则 0）
 *   u8  rgba[pix_len]  （RGBA8，行主序）
 */
#ifndef CDH_GPUMBOX_H
#define CDH_GPUMBOX_H

#include <linux/types.h>

/* GR01/RP01 头长度（不含 shader/像素载荷） */
#define CDH_BRIDGE_REQ_HDR_LEN  44u
#define CDH_BRIDGE_REQ2_HDR_LEN 56u
#define CDH_BRIDGE_RESP_HDR_LEN 24u

/* 响应图尺寸（host 渲染分辨率，内核最近邻缩放到 RT） */
#define CDH_BRIDGE_IMG_W    256u
#define CDH_BRIDGE_IMG_H    256u
#define CDH_BRIDGE_PIX_LEN  (CDH_BRIDGE_IMG_W * CDH_BRIDGE_IMG_H * 4u)

/* mailbox 环容量（与 kbase 侧 seq→slot 映射表容量对应） */
#define CDH_BRIDGE_RING_N      8
/* 每条请求的兜底超时：超时后放行 job，兜底图层（(16d) 填色）生效 */
/* 兜底超时须大于 host 渲染延迟（va2spirv + harness/MoltenVK 冷启动实测 >3s，
 * B2 回执段 run110 定案：3s 窗被渲染时间吃穿 → 全部兜底、RP01 迟到错位）。 */
#define CDH_BRIDGE_TIMEOUT_MS  15000
/* shader 机器码上限（(19) vmap 防呆上限 4KB，这里放宽到 64KB） */
#define CDH_BRIDGE_SHADER_MAX  65536u

/* flags 位 */
#define CDH_BRIDGE_FLAG_WIDE_SB 0x1u /* RT word2 bit2：AFBC wide block（32x8），桥侧跳过写回 */

/* GR01 请求（内核侧入队参数；wire 格式见头注释） */
struct cdh_bridge_req {
	u32 seq;
	u64 rt_base;
	u32 w, h, row_stride, surf_stride, blk, flags;
	u64 src_base;
	u32 src_w, src_h, src_stride;
	const u8 *shader;
	u32 shader_len;
};

/* 放行回调：RP01 写回完成或超时时由内核调用，把对应 job 的完成时刻拉回 */
struct cdh_bridge_ops {
	void (*release)(u32 seq); /* 放行 job 完成 */
};

/* 入队 + 唤醒读端。队满返回 -ENOSPC（环容量 CDH_BRIDGE_RING_N）；
 * 提交在 kbase 提交路径（用户进程上下文）调用，内部 mmget(current->mm)
 * 供后续写回使用，write()/超时时 mmput。
 * 返回值：0=入队成功（host 渲染后经 RP01 写回），负值=错误。
 * 有 src_base 时附带降采样真实纹理（GR02）。 */
int cdh_bridge_submit(const struct cdh_bridge_req *r);

/* kbase 模块 init 注册放行回调；传 NULL 注销。 */
int cdh_bridge_register_ops(const struct cdh_bridge_ops *ops);

/* stage-2 fragment shader 捕获缓存（(28j) Tiler atom 写入 →
 * (28h-c) FS 周转取用）：单条目、同 tgid、2s 内有效。 */
void cdh_bridge_cache_put(const u8 *code, u32 len, u32 tgid,
			  u64 src_base, u32 src_w, u32 src_h, u32 src_stride);
int cdh_bridge_cache_get(u8 *buf, u32 *len, u32 tgid,
			 u64 *src_base, u32 *src_w, u32 *src_h, u32 *src_stride);

#endif /* CDH_GPUMBOX_H */
