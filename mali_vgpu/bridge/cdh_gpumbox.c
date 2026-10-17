// SPDX-License-Identifier: GPL-2.0
/*
 * CDH gold-15：B2 渲染桥 mailbox 驱动（wire-kbase.sh (28)）。
 *
 * 角色：/dev/cdh_gpumbox（misc 动态 minor）——内核（kbase 提交路径）与
 * guest 用户态桥 helper（out/tmp/p2/gpumbox_bridge.c）之间的请求/响应邮箱。
 * ABI 与 wire 格式详见 <linux/cdh_gpumbox.h> 头注释（[u32 len][payload]，
 * 多字节统一 BE，与 hvc11 帧逐字节一致）。
 *
 * 数据流：
 *   1) kbase 提交 FS atom 时解析 RT + Fragment shader 机器码，
 *      cdh_bridge_submit() 入队 GR01 记录并唤醒 read()（同时 mmget 提交
 *      进程的 mm 供写回用）；kbase 侧把该 job 完成时刻推到 +500ms 兜底；
 *   2) helper read() 取记录 → 组帧写 /dev/hvc11 → host 渲染（va2spirv +
 *      MoltenVK harness）→ 回 RP01 帧 → helper write() 交回本驱动；
 *   3) write() 上下文中用 submit 保存的 mm 把 256x256 RGBA8 像素最近邻
 *      缩放写回 RT（线性 blk=2 逐行 GUP+kmap；AFBC blk=12/13 按 (16d)
 *      的 solid superblock 头布局改写），然后 ops->release(seq) 放行
 *      job 完成；
 *   4) 每条请求 500ms 超时（delayed_work 扫描）：超时放行 job 并记
 *      timeout 日志——此时 RT 上保持 (16d) 已填的兜底图层（绿），不动。
 *
 * dmesg 判据（前缀 cdh-mali:）：
 *   B2 bridge q seq=%u rt=0x%llx %ux%u blk=%u shader=%uB
 *   B2 bridge done seq=%u status=%u wrote=%uB
 *   B2 bridge timeout seq=%u
 *
 * 内存/引用纪律：submit 时 mmget(current->mm)；write/超时/模块退出回收
 * 时 mmput 且恰好一次；GUP 得到的页引用 put_page 且恰好一次；错误路径
 * 不泄漏 mm/页引用。
 */
#define pr_fmt(fmt) "cdh-mali: " fmt

#include <asm/byteorder.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/highmem.h>
#include <linux/jiffies.h>
#include <linux/ktime.h>
#include <linux/proc_fs.h>
#include <linux/spinlock.h>
#include <linux/mm.h>
#include <linux/mmap_lock.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched/mm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

#include <linux/cdh_gpumbox.h>

/* 请求记录状态 */
#define CDH_ST_FREE   0 /* 空闲 */
#define CDH_ST_QUEUED 1 /* 记录已入队，等待 read() 取走 */
#define CDH_ST_WAIT   2 /* 记录已取走（或随 write 释放），等待 RP01 响应/超时 */

/* 一条请求的完整生命周期数据（回收时一次性带走） */
struct cdh_bridge_ent {
	int state;
	u32 seq;
	u8 *rec;      /* [u32 len][GR01 payload]，read() 取走后置 NULL */
	u32 rec_len;
	struct mm_struct *mm; /* submit 时 mmget，回收时 mmput */
	u64 rt_base;
	u32 w, h, row_stride, surf_stride, blk, flags;
	unsigned long deadline_j;
};

static DEFINE_MUTEX(cdh_bridge_lock);
static wait_queue_head_t cdh_bridge_wq;
static atomic_t cdh_bridge_queued = ATOMIC_INIT(0);
static struct cdh_bridge_ent cdh_ring[CDH_BRIDGE_RING_N];
static const struct cdh_bridge_ops *cdh_bridge_ops_ptr;
static struct delayed_work cdh_to_work;

/* ---- BE 编解码（wire 统一大端） ---- */

static void put_be32(u8 *p, u32 v)
{
	__be32 t = cpu_to_be32(v);

	memcpy(p, &t, sizeof(t));
}

static void put_be64(u8 *p, u64 v)
{
	__be64 t = cpu_to_be64(v);

	memcpy(p, &t, sizeof(t));
}

static u32 get_be32(const u8 *p)
{
	__be32 t;

	memcpy(&t, p, sizeof(t));
	return be32_to_cpu(t);
}

/* ---- 导出符号：kbase 补丁代码调用 ---- */

int cdh_bridge_register_ops(const struct cdh_bridge_ops *ops)
{
	mutex_lock(&cdh_bridge_lock);
	cdh_bridge_ops_ptr = ops;
	mutex_unlock(&cdh_bridge_lock);
	return 0;
}
EXPORT_SYMBOL_GPL(cdh_bridge_register_ops);

/*
 * 源纹理降采样（GR02 真实纹理数据面）：在提交进程上下文（current->mm 即
 * 图层/纹理所属进程，SAME_VA）按最近邻把 kbase 侧解析出的源纹理
 * （Generic+Linear Plane，(28k) cdh_b2_extract_res）采样成
 * CDH_BRIDGE_IMG_W x CDH_BRIDGE_IMG_H RGBA8，随请求送 host，harness 绑定为
 * binding 3 供 Valhall shader 的 TEX 指令采样——替代此前 host 端硬编码测试纹理。
 * 返回 1=采样成功；源参数非法/读失败返回 0（请求不带纹理，host 走无纹理路径）。
 */
static int cdh_sample_src(const struct cdh_bridge_req *r, u8 *out)
{
	u8 *row;
	u32 x, y, rowlen;

	if (!r->src_base || !r->src_w || !r->src_h || r->src_w > 0x4000 ||
	    r->src_h > 0x4000 || r->src_stride < r->src_w * 4 ||
	    r->src_stride > 0x10000)
		return 0;
	rowlen = r->src_w * 4;
	row = kmalloc(rowlen, GFP_KERNEL);
	if (!row)
		return 0;
	for (y = 0; y < CDH_BRIDGE_IMG_H; y++) {
		u32 sy = (u32)(((u64)y * 2 + 1) * r->src_h / (2 * CDH_BRIDGE_IMG_H));

		if (copy_from_user(row, u64_to_user_ptr(r->src_base +
						       (u64)sy * r->src_stride),
				   rowlen)) {
			kfree(row);
			return 0;
		}
		for (x = 0; x < CDH_BRIDGE_IMG_W; x++) {
			u32 sx = (u32)(((u64)x * 2 + 1) * r->src_w /
				       (2 * CDH_BRIDGE_IMG_W));

			memcpy(out + (y * CDH_BRIDGE_IMG_W + x) * 4, row + sx * 4, 4);
		}
	}
	kfree(row);
	return 1;
}

int cdh_bridge_submit(const struct cdh_bridge_req *r)
{
	struct cdh_bridge_ent *e = NULL;
	u8 *rec;
	u8 *tex = NULL;
	u32 payload_len, rec_len, shader_len, hdr_len, tex_len = 0;
	int i, ret = 0;

	if (!r || !current->mm)
		return -EINVAL;

	/* shader 有界（(19) 的 vmap 上限 4KB，这里放宽到 64KB 防呆） */
	shader_len = r->shader_len;
	if (shader_len > CDH_BRIDGE_SHADER_MAX)
		return -EINVAL;
	if (shader_len && !r->shader)
		return -EINVAL;

	/* 有源纹理 → GR02（带降采样纹理）；否则 GR01（与旧 host 兼容） */
	if (r->src_base) {
		tex = kvmalloc(CDH_BRIDGE_PIX_LEN, GFP_KERNEL);
		if (tex && cdh_sample_src(r, tex)) {
			tex_len = CDH_BRIDGE_PIX_LEN;
		} else {
			kvfree(tex);
			tex = NULL;
		}
	}
	hdr_len = tex_len ? CDH_BRIDGE_REQ2_HDR_LEN : CDH_BRIDGE_REQ_HDR_LEN;
	payload_len = hdr_len + shader_len + tex_len;
	rec_len = 4 + payload_len;
	rec = kvmalloc(rec_len, GFP_KERNEL);
	if (!rec) {
		kvfree(tex);
		return -ENOMEM;
	}

	/* [u32 len][GR01|GR02 payload]，字段全 BE */
	put_be32(rec, payload_len);
	memcpy(rec + 4, tex_len ? "GR02" : "GR01", 4);
	put_be32(rec + 8, r->seq);
	put_be64(rec + 12, r->rt_base);
	put_be32(rec + 20, r->w);
	put_be32(rec + 24, r->h);
	put_be32(rec + 28, r->row_stride);
	put_be32(rec + 32, r->surf_stride);
	put_be32(rec + 36, r->blk);
	put_be32(rec + 40, r->flags);
	put_be32(rec + 44, shader_len);
	if (tex_len) {
		put_be32(rec + 48, CDH_BRIDGE_IMG_W);
		put_be32(rec + 52, CDH_BRIDGE_IMG_H);
		put_be32(rec + 56, tex_len);
	}
	if (shader_len)
		memcpy(rec + 4 + hdr_len, r->shader, shader_len);
	if (tex_len)
		memcpy(rec + 4 + hdr_len + shader_len, tex, tex_len);
	kvfree(tex);

	mutex_lock(&cdh_bridge_lock);
	for (i = 0; i < CDH_BRIDGE_RING_N; i++) {
		if (cdh_ring[i].state == CDH_ST_FREE) {
			e = &cdh_ring[i];
			break;
		}
	}
	if (!e) {
		mutex_unlock(&cdh_bridge_lock);
		kvfree(rec);
		return -ENOSPC;
	}

	e->seq = r->seq;
	e->rec = rec;
	e->rec_len = rec_len;
	e->rt_base = r->rt_base;
	e->w = r->w;
	e->h = r->h;
	e->row_stride = r->row_stride;
	e->surf_stride = r->surf_stride;
	e->blk = r->blk;
	e->flags = r->flags;
	e->mm = current->mm;
	mmget(e->mm);
	e->deadline_j = jiffies + msecs_to_jiffies(CDH_BRIDGE_TIMEOUT_MS);
	e->state = CDH_ST_QUEUED;
	atomic_inc(&cdh_bridge_queued);
	/* 兜底超时扫描：已在队列则不动到期（防高频提交把到期无限推后） */
	schedule_delayed_work(&cdh_to_work, msecs_to_jiffies(CDH_BRIDGE_TIMEOUT_MS));
	mutex_unlock(&cdh_bridge_lock);

	wake_up_interruptible(&cdh_bridge_wq);
	pr_info("B2 bridge q seq=%u rt=0x%llx %ux%u blk=%u shader=%uB tex=%s src=0x%llx %ux%u\n",
		r->seq, (unsigned long long)r->rt_base, r->w, r->h,
		r->blk, shader_len, tex_len ? "real" : "none",
		(unsigned long long)r->src_base, r->src_w, r->src_h);
	return ret;
}
EXPORT_SYMBOL_GPL(cdh_bridge_submit);

/* ---- 像素写回（write()/超时上下文，用 submit 保存的 mm） ---- */

/*
 * 向提交进程用户地址写一段字节：逐页 get_user_pages_remote + kmap 写。
 * 调用上下文：进程上下文（write()/delayed_work），mm 属于别的进程。
 * 错误即中止并返回负值；页引用与 mmap 锁不泄漏。
 */
/*
 * PFNMAP/IO 映射页直写（B2 回执段 run122 定案）：kbase 用 vmf_insert_pfn_prot
 * 惰性映射 GPU 缓冲区（VM_PFNMAP|VM_IO，无 struct page），get_user_pages_remote
 * 对其恒拒不触发 fault（err=-14）→ 走页表：fixup_user_fault 触发 vma fault
 * （kbase_cpu_vm_fault → vmf_insert_pfn_prot 装 PTE）后 follow_pte 取 pfn
 * 写真实页。pfn_valid 检查兜底（device 内存 PFN 直接拒绝，防 kmap 崩）。
 * 成功返回 0；失败返回负值。*locked 由 fixup_user_fault 会话管理。
 */
__maybe_unused static int cdh_write_pfnmap(struct mm_struct *mm, unsigned long uaddr,
			    const u8 *src, u32 chunk, int *locked)
{
	unsigned long page_addr = uaddr & PAGE_MASK;
	unsigned long off = uaddr & (PAGE_SIZE - 1);
	struct vm_area_struct *vma = find_vma(mm, page_addr);
	pte_t *ptep = NULL;
	spinlock_t *ptl = NULL;
	struct page *page;
	unsigned long pfn;
	void *k;
	bool held = (*locked != 0);   /* 进入时 mmap_lock 持有状态 */
	int ret;

	if (!vma || vma->vm_start > page_addr ||
	    !(vma->vm_flags & (VM_PFNMAP | VM_IO)) ||
	    !(vma->vm_flags & VM_WRITE))
		return -EFAULT;

	/* 触发 fault 装 PTE（kbase_cpu_vm_fault → vmf_insert_pfn_prot）。
	 * fixup_user_fault 签名：locked 为 bool *（内核 6.6），语义=进入时
	 * 是否持有 mmap_lock；fault 过程可能释放锁（置 false）。 */
	ret = fixup_user_fault(mm, page_addr,
			       FAULT_FLAG_WRITE | FAULT_FLAG_REMOTE, &held);
	if (ret)
		return ret;
	*locked = held ? 1 : 0;
	if (!*locked) {
		mmap_read_lock(mm);
		*locked = 1;
	}
	if (follow_pte(mm, page_addr, &ptep, &ptl))
		return -EFAULT;
	pfn = pte_pfn(*ptep);
	if (!pfn_valid(pfn)) {
		pte_unmap_unlock(ptep, ptl);
		pr_info("B2 bridge wb pfnmap bad pfn=0x%lx addr=0x%lx\n",
			pfn, page_addr);
		return -EFAULT;
	}
	page = pfn_to_page(pfn);
	k = kmap(page);
	memcpy(k + off, src, chunk);
	kunmap(page);
	pte_unmap_unlock(ptep, ptl);
	return 0;
}

__maybe_unused static int cdh_write_user(struct mm_struct *mm, u64 uaddr, const u8 *src, u32 len)
{
	int ret = 0;
	int locked = 1;

	mmap_read_lock(mm);
	while (len) {
		unsigned long page_addr = (unsigned long)uaddr & PAGE_MASK;
		unsigned long off = (unsigned long)uaddr & (PAGE_SIZE - 1);
		size_t chunk = min_t(size_t, PAGE_SIZE - off, len);
		struct page *page = NULL;
		void *k;
		long n;

		n = get_user_pages_remote(mm, page_addr, 1, FOLL_WRITE, &page,
					  &locked);
		if (n == 1) {
			k = kmap(page);
			memcpy(k + off, src, chunk);
			kunmap(page);
			put_page(page);
			/* fault 重试路径可能放掉 mmap 锁（locked==0）：重取再继续 */
			if (!locked) {
				mmap_read_lock(mm);
				locked = 1;
			}
		} else {
			/* GUP 拒绝（PFNMAP/IO 无 struct page）→ 页表直写 */
			if (!locked) {
				mmap_read_lock(mm);
				locked = 1;
			}
			ret = cdh_write_pfnmap(mm, (unsigned long)uaddr, src, (u32)chunk,
					       &locked);
			if (ret)
				break;
		}
		src += chunk;
		uaddr += chunk;
		len -= chunk;
	}
	if (locked)
		mmap_read_unlock(mm);
	return ret;
}

/*
 * 最近邻取源像素：缩放图 dst(x,y) ← src(x*256/w, y*256/h)，越界钳到边缘。
 * img 为 256x256 RGBA8 行主序。
 */
__maybe_unused static const u8 *cdh_src_pixel(const u8 *img, u32 w, u32 h, u32 x, u32 y)
{
	u32 sx = (u32)((u64)x * CDH_BRIDGE_IMG_W / w);
	u32 sy = (u32)((u64)y * CDH_BRIDGE_IMG_H / h);

	if (sx >= CDH_BRIDGE_IMG_W)
		sx = CDH_BRIDGE_IMG_W - 1;
	if (sy >= CDH_BRIDGE_IMG_H)
		sy = CDH_BRIDGE_IMG_H - 1;
	return img + ((u64)sy * CDH_BRIDGE_IMG_W + sx) * 4;
}

/*
 * AFBC solid superblock 头（(16d) 实测定案布局）：
 *   头 16B = u64[0] 全 0（subblock0=0 即 solid）+ u8[8..11] = R,G,B,A。
 * 取缩放图对应块中心像素为 solid 色。
 * 支持标准 16x16 Superblock 与 Wide Superblock（32x8）。
 */
static void __maybe_unused cdh_afbc_hdr(const u8 *img, u32 w, u32 h, u32 rr, u32 cc,
					u32 sb_w, u32 sb_h, u8 *hdr)
{
	u32 cx = min_t(u32, cc * sb_w + sb_w / 2, w - 1);
	u32 cy = min_t(u32, rr * sb_h + sb_h / 2, h - 1);
	const u8 *p = cdh_src_pixel(img, w, h, cx, cy);

	memset(hdr, 0, 16);
	hdr[8] = p[0];  /* R */
	hdr[9] = p[1];  /* G */
	hdr[10] = p[2]; /* B */
	hdr[11] = p[3]; /* A */
}

/* 把 256x256 RGBA 最近邻缩放写回 RT，返回写入字节数（负值=失败中止） */
static long cdh_writeback(struct cdh_bridge_ent *e, const u8 *img)
{
	struct mm_struct *mm = e->mm;
	u32 w = e->w, h = e->h;
	long wrote = 0;
	int ret = 0;

	/* RT 参数防呆（与 (16d) 同口径）：非法参数不写，兜底图层生效 */
	if (!e->rt_base || !w || w > 0x4000 || !h || h > 0x4000 ||
	    !e->row_stride || e->row_stride > 0x10000) {
		pr_info("B2 bridge wb skip seq=%u bad rt 0x%llx %ux%u rows=%u\n",
			e->seq, (unsigned long long)e->rt_base, w, h,
			e->row_stride);
		return 0;
	}

	if (e->blk == 2) {
		/* 线性面：逐行 GUP+kmap 写，行址 rt_base + y*row_stride */
		u32 row_len = w * 4;
		u8 *row = kmalloc(row_len, GFP_KERNEL);
		u32 x, y;

		if (!row)
			return -ENOMEM;
		for (y = 0; y < h && !ret; y++) {
			for (x = 0; x < w; x++)
				memcpy(row + (u64)x * 4,
				       cdh_src_pixel(img, w, h, x, y), 4);
			ret = cdh_write_user(mm,
					     e->rt_base + (u64)y * e->row_stride,
					     row, row_len);
			if (!ret)
				wrote += row_len;
		}
		kfree(row);
	} else if (e->blk == 12 || e->blk == 13) {
		/* AFBC 面：改写 solid superblock 头（合法纯色压缩面，body 不动）。
		 * 支持标准 16x16 superblock 与 wide block（32x8）。 */
		u32 sb_w = (e->flags & CDH_BRIDGE_FLAG_WIDE_SB) ? 32 : 16;
		u32 sb_h = (e->flags & CDH_BRIDGE_FLAG_WIDE_SB) ? 8 : 16;
		u32 scols, srows, r, c;
		u8 hdr[16];

		scols = (w + sb_w - 1) / sb_w;
		srows = (h + sb_h - 1) / sb_h;
		if (e->blk == 12) {
			/* 非平铺：头行主序，行步长=Row Stride */
			for (r = 0; r < srows && !ret; r++) {
				for (c = 0; c < scols && !ret; c++) {
					cdh_afbc_hdr(img, w, h, r, c, sb_w, sb_h, hdr);
					ret = cdh_write_user(
						mm,
						e->rt_base +
							(u64)r * e->row_stride +
							(u64)c * 16,
						hdr, 16);
					if (!ret)
						wrote += 16;
				}
			}
		} else {
			/* 平铺：8x8 SB 为一 tile（tile 头 1024B），tile 行
			 * 主序、行步长=Row Stride；头在 tb+(j*8+i)*16
			 * （与 (16d) 完全一致） */
			u32 txs = (scols + 7) / 8;
			u32 tys = (srows + 7) / 8;
			u32 tx, ty, i, j;

			for (ty = 0; ty < tys && !ret; ty++) {
				for (tx = 0; tx < txs && !ret; tx++) {
					u64 tb = e->rt_base +
						 (u64)ty * e->row_stride +
						 (u64)tx * 1024;

					for (j = 0; j < 8 && !ret; j++) {
						for (i = 0; i < 8 && !ret; i++) {
							u32 cc = tx * 8 + i;
							u32 rr = ty * 8 + j;

							if (cc >= scols ||
							    rr >= srows)
								continue;
							cdh_afbc_hdr(img, w, h,
								     rr, cc, sb_w, sb_h, hdr);
							ret = cdh_write_user(
								mm,
								tb + (u64)(j * 8 + i) * 16,
								hdr, 16);
							if (!ret)
								wrote += 16;
						}
					}
				}
			}
		}
	} else {
		/* 其他 blk（0=NoWrite 1=Tiled 等）：不写，只记日志 */
		pr_info("B2 bridge wb skip seq=%u blk=%u\n", e->seq, e->blk);
		return 0;
	}

	if (ret) {
		pr_info("B2 bridge wb abort seq=%u err=%d wrote=%ldB\n",
			e->seq, ret, wrote);
		return ret;
	}
	return wrote;
}

/* ---- 回收：放行 job + 释放 mm/记录（write/超时/退出三路互斥） ---- */

static void cdh_reclaim(u32 seq, u8 *rec, struct mm_struct *mm)
{
	const struct cdh_bridge_ops *ops;

	mutex_lock(&cdh_bridge_lock);
	ops = cdh_bridge_ops_ptr;
	mutex_unlock(&cdh_bridge_lock);

	/* 先放行后释放：写回已完成（或超时走兜底图层），job 可以收尾 */
	if (ops && ops->release)
		ops->release(seq);
	if (mm)
		mmput(mm);
	kvfree(rec);
}

/* 超时扫描：到期请求放行 job（兜底图层=(16d) 填色，不动）并回收 */
static void cdh_bridge_tick(struct work_struct *work)
{
	unsigned long now = jiffies;
	unsigned long next = 0;
	int i;

	for (i = 0; i < CDH_BRIDGE_RING_N; i++) {
		struct cdh_bridge_ent *e = &cdh_ring[i];
		u32 seq;
		u8 *rec;
		struct mm_struct *mm;

		mutex_lock(&cdh_bridge_lock);
		if (e->state == CDH_ST_FREE) {
			mutex_unlock(&cdh_bridge_lock);
			continue;
		}
		if (time_before(now, e->deadline_j)) {
			unsigned long left = e->deadline_j - now;

			if (!next || time_before(left, next))
				next = left;
			mutex_unlock(&cdh_bridge_lock);
			continue;
		}
		seq = e->seq;
		rec = e->rec;
		mm = e->mm;
		e->rec = NULL;
		e->mm = NULL;
		e->state = CDH_ST_FREE;
		if (rec)
			atomic_dec(&cdh_bridge_queued);
		mutex_unlock(&cdh_bridge_lock);

		pr_info("B2 bridge timeout seq=%u\n", seq);
		cdh_reclaim(seq, rec, mm);
	}

	if (next)
		schedule_delayed_work(&cdh_to_work, next);
}

/* ---- misc 字符设备 ---- */

static ssize_t cdh_bridge_read(struct file *filp, char __user *ubuf,
			       size_t count, loff_t *ppos)
{
	for (;;) {
		u8 *rec = NULL;
		u32 rec_len = 0;
		int i;

		mutex_lock(&cdh_bridge_lock);
		for (i = 0; i < CDH_BRIDGE_RING_N; i++) {
			struct cdh_bridge_ent *e = &cdh_ring[i];

			if (e->state != CDH_ST_QUEUED)
				continue;
			rec = e->rec;
			rec_len = e->rec_len;
			/* 用户缓冲小于整条记录：-EINVAL（记录保留可重试） */
			if (count < rec_len) {
				mutex_unlock(&cdh_bridge_lock);
				return -EINVAL;
			}
			/* 记录间原子：整条 [u32 len][GR01 payload] 一次出队 */
			e->rec = NULL;
			e->rec_len = 0;
			e->state = CDH_ST_WAIT;
			atomic_dec(&cdh_bridge_queued);
			break;
		}
		mutex_unlock(&cdh_bridge_lock);

		if (rec) {
			ssize_t ret = rec_len;

			if (copy_to_user(ubuf, rec, rec_len)) {
				/* 记录已出队但送达失败：丢弃，500ms 超时兜底
				 * 会放行 job（RT 保持兜底图层） */
				pr_info("B2 bridge read efault len=%u\n",
					rec_len);
				ret = -EFAULT;
			}
			kvfree(rec);
			return ret;
		}

		if (filp->f_flags & O_NONBLOCK)
			return -EAGAIN;
		/* 无记录：阻塞在 wait_queue，被信号打断则上报 */
		if (wait_event_interruptible(cdh_bridge_wq,
					     atomic_read(&cdh_bridge_queued) > 0))
			return -ERESTARTSYS;
	}
}

static ssize_t cdh_bridge_write(struct file *filp, const char __user *ubuf,
				size_t count, loff_t *ppos)
{
	struct cdh_bridge_ent *e = NULL;
	struct cdh_bridge_ent carry;
	u8 rec_hdr[4 + CDH_BRIDGE_RESP_HDR_LEN];
	u8 *pix = NULL;
	struct mm_struct *mm = NULL;
	u8 *rec;
	u32 seq, status, img_w, img_h, pix_len, payload_len;
	u32 i, wrote = 0;
	long wb;

	if (count < 4 + CDH_BRIDGE_RESP_HDR_LEN) {
		pr_info("B2 bridge reject seq=? count=%zu too short\n", count);
		return -EINVAL;
	}
	/* [u32 len][RP01 payload]：一次性取长度前缀 + 头，len 须与写入量一致 */
	if (copy_from_user(rec_hdr, ubuf, sizeof(rec_hdr)))
		return -EFAULT;
	payload_len = get_be32(rec_hdr);
	if (payload_len != count - 4 ||
	    payload_len < CDH_BRIDGE_RESP_HDR_LEN) {
		pr_info("B2 bridge reject len=%u count=%zu mismatch\n",
			payload_len, count);
		return -EINVAL;
	}
	if (memcmp(rec_hdr + 4, "RP01", 4)) {
		pr_info("B2 bridge reject bad magic\n");
		return -EINVAL;
	}
	seq = get_be32(rec_hdr + 8);
	status = get_be32(rec_hdr + 12);
	img_w = get_be32(rec_hdr + 16);
	img_h = get_be32(rec_hdr + 20);
	pix_len = get_be32(rec_hdr + 24);
	if (status == 0) {
		/* status=0：必须是 256x256 RGBA8 满图 */
		if (img_w != CDH_BRIDGE_IMG_W || img_h != CDH_BRIDGE_IMG_H ||
		    pix_len != CDH_BRIDGE_PIX_LEN ||
		    payload_len != CDH_BRIDGE_RESP_HDR_LEN + pix_len) {
			pr_info("B2 bridge reject seq=%u img=%ux%u pix=%u payload=%u\n",
				seq, img_w, img_h, pix_len, payload_len);
			return -EINVAL;
		}
		pix = kvmalloc(pix_len, GFP_KERNEL);
		if (!pix)
			return -ENOMEM;
		if (copy_from_user(pix, ubuf + 4 + CDH_BRIDGE_RESP_HDR_LEN,
				   pix_len)) {
			kvfree(pix);
			return -EFAULT;
		}
	} else if (status == 1) {
		/* status=1：翻译/渲染失败，无像素（兜底图层生效） */
		if (pix_len || payload_len != CDH_BRIDGE_RESP_HDR_LEN) {
			pr_info("B2 bridge reject seq=%u status=1 pix=%u payload=%u\n",
				seq, pix_len, payload_len);
			return -EINVAL;
		}
	} else {
		pr_info("B2 bridge reject seq=%u bad status=%u\n", seq, status);
		return -EINVAL;
	}

	/* 认领请求：与超时/退出互斥，恰好回收一次 */
	mutex_lock(&cdh_bridge_lock);
	for (i = 0; i < CDH_BRIDGE_RING_N; i++) {
		if (cdh_ring[i].state != CDH_ST_FREE &&
		    cdh_ring[i].seq == seq) {
			e = &cdh_ring[i];
			break;
		}
	}
	if (!e) {
		mutex_unlock(&cdh_bridge_lock);
		kvfree(pix);
		pr_info("B2 bridge reject seq=%u not found (late after timeout?)\n",
			seq);
		return -EINVAL;
	}
	carry = *e;
	if (e->rec)
		atomic_dec(&cdh_bridge_queued);
	e->rec = NULL;
	e->mm = NULL;
	e->state = CDH_ST_FREE;
	mutex_unlock(&cdh_bridge_lock);

	mm = carry.mm;
	rec = carry.rec;
	if (status == 0) {
		wb = cdh_writeback(&carry, pix);
		if (wb > 0)
			wrote = (u32)wb;
	}
	/* 写回完成后（或 status=1）放行 job 完成 */
	cdh_reclaim(seq, rec, mm);
	kvfree(pix);

	pr_info("B2 bridge done seq=%u status=%u wrote=%uB\n", seq, status,
		wrote);
	return count;
}

/* CDH(gold-15): stage-2 fragment shader 捕获缓存（wire-kbase.sh (28j)
 * Tiler atom DCD 捕获写入 → (28h-c) FS 周转取用）。单条目：同 tgid、
 * 2s 内有效。多 shader 精确关联归 B2 后续（见 solution.md 遗留）。 */
static DEFINE_SPINLOCK(cdh_cache_lock);
static u8 cdh_cache_bin[4096];
static u32 cdh_cache_len;
static u32 cdh_cache_tgid;
static u64 cdh_cache_ns;
static u64 cdh_cache_src_base;
static u32 cdh_cache_src_w;
static u32 cdh_cache_src_h;
static u32 cdh_cache_src_stride;

void cdh_bridge_cache_put(const u8 *code, u32 len, u32 tgid,
			  u64 src_base, u32 src_w, u32 src_h, u32 src_stride)
{
	unsigned long flags;

	if (!code || !len)
		return;
	if (len > sizeof(cdh_cache_bin))
		len = sizeof(cdh_cache_bin);
	spin_lock_irqsave(&cdh_cache_lock, flags);
	memcpy(cdh_cache_bin, code, len);
	cdh_cache_len = len;
	cdh_cache_tgid = tgid;
	cdh_cache_src_base = src_base;
	cdh_cache_src_w = src_w;
	cdh_cache_src_h = src_h;
	cdh_cache_src_stride = src_stride;
	cdh_cache_ns = ktime_get_ns();
	spin_unlock_irqrestore(&cdh_cache_lock, flags);
}
EXPORT_SYMBOL_GPL(cdh_bridge_cache_put);

int cdh_bridge_cache_get(u8 *buf, u32 *len, u32 tgid,
			 u64 *src_base, u32 *src_w, u32 *src_h, u32 *src_stride)
{
	unsigned long flags;
	int ok = 0;

	spin_lock_irqsave(&cdh_cache_lock, flags);
	if (cdh_cache_len && cdh_cache_tgid == tgid &&
	    ktime_get_ns() - cdh_cache_ns < 2ULL * NSEC_PER_SEC) {
		memcpy(buf, cdh_cache_bin, cdh_cache_len);
		*len = cdh_cache_len;
		if (src_base)
			*src_base = cdh_cache_src_base;
		if (src_w)
			*src_w = cdh_cache_src_w;
		if (src_h)
			*src_h = cdh_cache_src_h;
		if (src_stride)
			*src_stride = cdh_cache_src_stride;
		ok = 1;
	}
	spin_unlock_irqrestore(&cdh_cache_lock, flags);
	return ok;
}
EXPORT_SYMBOL_GPL(cdh_bridge_cache_get);

static const struct proc_ops cdh_bridge_pops = {
	.proc_read = cdh_bridge_read,
	.proc_write = cdh_bridge_write,
};

static struct proc_dir_entry *cdh_bridge_pde;

static int __init cdh_gpumbox_init(void)
{
	init_waitqueue_head(&cdh_bridge_wq);
	INIT_DELAYED_WORK(&cdh_to_work, cdh_bridge_tick);
	/* procfs 通道：/proc/cdh_gpumbox 0666 权限直达（Android ueventd
	 * 会把 misc 设备节点重置 0600，shell 用户 helper 打不开（run102
	 * 实证 Permission denied）；/proc/ged 0666 先例证明 procfs 不受
	 * ueventd 管、pioneer 域 shell 可开）。 */
	cdh_bridge_pde = proc_create("cdh_gpumbox", 0666, NULL,
				     &cdh_bridge_pops);
	if (!cdh_bridge_pde) {
		pr_info("B2 bridge proc register failed\n");
		return -ENOMEM;
	}
	return 0;
}

static void __exit cdh_gpumbox_exit(void)
{
	int i;

	remove_proc_entry("cdh_gpumbox", NULL);
	cancel_delayed_work_sync(&cdh_to_work);
	/* 残留请求一律放行（job 走兜底图层收尾）并回收 mm/记录 */
	for (i = 0; i < CDH_BRIDGE_RING_N; i++) {
		struct cdh_bridge_ent *e = &cdh_ring[i];
		u32 seq;
		u8 *rec;
		struct mm_struct *mm;

		mutex_lock(&cdh_bridge_lock);
		if (e->state == CDH_ST_FREE) {
			mutex_unlock(&cdh_bridge_lock);
			continue;
		}
		seq = e->seq;
		rec = e->rec;
		mm = e->mm;
		e->rec = NULL;
		e->mm = NULL;
		e->state = CDH_ST_FREE;
		mutex_unlock(&cdh_bridge_lock);
		cdh_reclaim(seq, rec, mm);
	}
}

module_init(cdh_gpumbox_init);
module_exit(cdh_gpumbox_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("CDH gold-15 B2 render bridge mailbox");
MODULE_AUTHOR("CDH");
