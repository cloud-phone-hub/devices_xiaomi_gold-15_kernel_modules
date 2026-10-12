// SPDX-License-Identifier: GPL-2.0
/*
 * CDH: /proc/ged stub —— 为厂商图形栈提供 MTK GED 桥兼容的 ioctl 接口。
 *
 * 根因依据（gold-15 run34，反汇编三链闭环：alloc-mtk.so + gralloc_extra.so +
 * libged.so）：
 *   补丁 (11) 打通 mtk gralloc heap 层后，mali_gralloc_buffer_allocate
 *   （android.hardware.graphics.allocator-V2-mediatek.so @2e8c8）在每次分配时
 *   调 ge_alloc = ged_ge_alloc(count=22, values=rodata 固定参数表)
 *   （gralloc_extra.so @31a0：mov w0,#0x16; adr x1,8010; b ged_ge_alloc），
 *   返回值写入 native_handle data[0]（对象 +12）——即 buffer 的主 fd
 *   （ge_release 将 +12 当 fd 传给 ge_perform_free_sec_hwc，交叉验证）。
 *   GED 走 /proc/ged 桥（libged.so：ged_bridge_open = open("/proc/ged") +
 *   fcntl(FD_CLOEXEC)；ged_bridge_call = ioctl(fd, cmd, 40 字节包
 *   {u32 cmd; u32 size=0x28; void* in; u32 in_len; void* out; u32 out_len})，
 *   cmd 均为 _IOWR('g', nr, 0x28) 编码）。云机无 GED 驱动 → open 失败 →
 *   ged_ge_alloc 返回 -1 → data[0]=-1 → binder 拒绝
 *   "Passing -1 file descriptor as non-@nullable AIDL ParcelFileDescriptor"
 *   → 客户端分配错误 -129。run32（heap 缺失）时 allocator_allocate 先失败
 *   走不到 ge_alloc，故该层是补丁 (11) 之后新暴露的洋葱层。
 *
 * Stub 行为（cmd 取自 libged.so 反汇编逐函数 mov/movk 实测）：
 *   0xc0286764 ALLOC: in={u32 count; u32 values[count]}, out={u32 fd}。
 *       用 system heap 分配一个真实 dma-buf（4KB）安装 fd 返回。
 *       必须是真 dma-buf：该 fd 将经 binder 传递、并被 mali kbase
 *       dma_buf_get 导入，memfd/假 fd 会在下一层失败。
 *       count/values 为 GED 元数据预算表（22 项常量），stub 不解读。
 *   0xc0286765 GET:   in={u32 fd; u32 id; u32 arg; u32 count},
 *                     out={u32 status; u32 values[count]}。
 *       status=0、values 全 0（「特性关闭」默认值）。注意客户端把 out[0]
 *       预填 1（失败），内核不写 = 失败，必须显式写 0。
 *   0xc0286766 SET:   in={u32 fd; u32 id; u32 arg; u32 count; u32 values[]},
 *                     out={u32 status}=0（客户端同样预填 1）。
 *   0xc0286769 QUERY: in={u32 fd}, out={u64 result; u32 status; u32 pad}。
 *       全 0（libged rodata 4f40 客户端预填常量 status=1=失败，必须写 0）。
 *   0xc028676b SETNAME: in={u32 fd; u8 name[48]}, out={u32 status}=0。
 *   其他 cmd 返回 -ENOTTY。
 *
 * SELinux：/proc/ged 动态节点默认标签，若 vendor 域 open/ioctl 被拒，
 * 以 run 日志 avc denied 为准另行补 sepolicy（洋葱法）。
 */

#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

/* 与 libged.so ged_bridge_call 的 40 字节栈包逐字段一致：
 * stp w1,w9,[sp] → +0 cmd / +4 size=0x28
 * stp x2,xzr,[sp,#8] → +8 in；str w3,[sp,#16] → +16 in_len
 * stp x4,xzr,[sp,#24] → +24 out；str w5,[sp,#32] → +32 out_len */
struct ged_bridge_pkt {
	__u32 cmd;
	__u32 size;
	__u64 in_ptr;
	__u32 in_len;
	__u32 pad0;
	__u64 out_ptr;
	__u32 out_len;
	__u32 pad1;
};

#define GED_BRIDGE_CMD_ALLOC	0xc0286764
#define GED_BRIDGE_CMD_GET	0xc0286765
#define GED_BRIDGE_CMD_SET	0xc0286766
#define GED_BRIDGE_CMD_QUERY	0xc0286769
#define GED_BRIDGE_CMD_SETNAME	0xc028676b

/* ged_ge_get 的 count 客户端实测 15/16/56/643，防御性上限 */
#define GED_MAX_COUNT		4096

/* dma-heap.c 内部符号（built-in 直链，无需导出）：分配真实 dma-buf 用 */
extern struct dma_buf *dma_heap_buffer_alloc(struct dma_heap *heap,
					     size_t len, u32 fd_flags,
					     u64 heap_flags);

static int ged_stub_open(struct inode *inode, struct file *file)
{
	pr_info("cdh_ged: opened by pid %d (%s)\n", current->pid,
		current->comm);
	return 0;
}

static long ged_stub_ioctl(struct file *file, unsigned int cmd,
			   unsigned long arg)
{
	struct ged_bridge_pkt pkt;

	if (copy_from_user(&pkt, (void __user *)arg, sizeof(pkt)))
		return -EFAULT;

	/* 包首字段 cmd 与 ioctl 第二参恒一致（ged_bridge_call 同值双写），
	 * 以包内字段为准（更贴近 GED 桥语义）。 */
	switch (pkt.cmd) {
	case GED_BRIDGE_CMD_ALLOC: {
		struct dma_heap *heap;
		struct dma_buf *dmabuf;
		u32 count = 0;
		int fd;

		if (pkt.in_len < sizeof(count) || pkt.out_len < sizeof(count))
			return -EINVAL;
		if (copy_from_user(&count, u64_to_user_ptr(pkt.in_ptr),
				   sizeof(count)))
			return -EFAULT;

		heap = dma_heap_find("system");
		if (!heap)
			return -ENODEV;
		dmabuf = dma_heap_buffer_alloc(heap, PAGE_SIZE,
					       O_RDWR | O_CLOEXEC, 0);
		if (IS_ERR(dmabuf))
			return PTR_ERR(dmabuf);
		fd = dma_buf_fd(dmabuf, O_CLOEXEC);
		if (fd < 0) {
			dma_buf_put(dmabuf);
			return fd;
		}
		if (copy_to_user(u64_to_user_ptr(pkt.out_ptr), &fd,
				 sizeof(fd)))
			/* fd 已 install；copy_to_user 失败即进程页表异常，
			 * 用户态将按预填 -1 处理，此处不回滚 */
			return -EFAULT;
		pr_info("cdh_ged: ALLOC count=%u -> fd=%d (pid %d)\n",
			count, fd, current->pid);
		return 0;
	}
	case GED_BRIDGE_CMD_GET: {
		u32 hdr[4]; /* {fd, id, arg, count} */
		u32 count, total;
		u32 *buf;

		if (pkt.in_len < sizeof(hdr) || pkt.out_len < sizeof(u32))
			return -EINVAL;
		if (copy_from_user(hdr, u64_to_user_ptr(pkt.in_ptr),
				   sizeof(hdr)))
			return -EFAULT;
		count = hdr[3];
		if (count > GED_MAX_COUNT)
			return -EINVAL;
		total = (count + 1) * sizeof(u32);
		if (pkt.out_len < total)
			return -EINVAL;
		buf = kzalloc(total, GFP_KERNEL);
		if (!buf)
			return -ENOMEM;
		/* status=0 + values 全 0：gralloc extra 各属性按「特性关闭」应答 */
		if (copy_to_user(u64_to_user_ptr(pkt.out_ptr), buf, total)) {
			kfree(buf);
			return -EFAULT;
		}
		kfree(buf);
		return 0;
	}
	case GED_BRIDGE_CMD_SET: {
		u32 status = 0;

		if (pkt.in_len < 4 * sizeof(u32) || pkt.out_len < sizeof(status))
			return -EINVAL;
		if (copy_to_user(u64_to_user_ptr(pkt.out_ptr), &status,
				 sizeof(status)))
			return -EFAULT;
		return 0;
	}
	case GED_BRIDGE_CMD_QUERY: {
		u64 zero[2] = { 0, 0 }; /* {u64 result; u32 status; u32 pad} */
		size_t n = min_t(size_t, pkt.out_len, sizeof(zero));

		if (pkt.in_len < sizeof(u32) || pkt.out_len < 3 * sizeof(u32))
			return -EINVAL;
		if (copy_to_user(u64_to_user_ptr(pkt.out_ptr), zero, n))
			return -EFAULT;
		return 0;
	}
	case GED_BRIDGE_CMD_SETNAME: {
		u32 status = 0;

		if (pkt.in_len < 0x34 || pkt.out_len < sizeof(status))
			return -EINVAL;
		if (copy_to_user(u64_to_user_ptr(pkt.out_ptr), &status,
				 sizeof(status)))
			return -EFAULT;
		return 0;
	}
	default:
		return -ENOTTY;
	}
}

static const struct proc_ops ged_stub_proc_ops = {
	.proc_open		= ged_stub_open,
	.proc_ioctl		= ged_stub_ioctl,
#ifdef CONFIG_COMPAT
	.proc_compat_ioctl	= ged_stub_ioctl,
#endif
};

static int __init ged_stub_init(void)
{
	if (!proc_create("ged", 0666, NULL, &ged_stub_proc_ops)) {
		pr_err("cdh_ged: failed to create /proc/ged\n");
		return -ENOMEM;
	}
	pr_info("cdh_ged: /proc/ged stub ready (MTK GED bridge compat)\n");
	return 0;
}
device_initcall(ged_stub_init);

MODULE_LICENSE("GPL");

/* ============================================================
 * CDH: mi_display stub —— xiaomi 私有显示节点桩（run46 取证）。
 *
 * 根因（gold-15 run46，tombstone_31 + 反汇编闭环）：
 *   vendor.displayfeature-hal-1-0 服务在
 *   DisplayFeatureHal::init → RhyEyeCare::init
 *   → MiParseXml::parseXml(index, tag, buf, out_str, out_uint)
 *   中，对空 XML 值 ParseLine(strtok_r 无 token) 返回 0 但不写
 *   out_str → atoi(NULL) SIGSEGV（SEGV_MAPERR 0x0，5s 拉起即崩循环）。
 *   云机无 /sys/class/mi_display/disp-DSI-0/panel_info →
 *   MiParseXml::getPanelName 失败 → panel 专用 XML
 *   vendor/etc/<panel_name>_cn_mi.xml 打不开（云机 ro.boot.hwc
 *   未设，property_get 默认 "CN" → 后缀 _cn）→ 只剩 df_default.xml，
 *   而其内没有 <rhyeyecare> 节（实测 grep = 0）→ getXmlValue 空
 *   → 上述空指针。真机由 xiaomi mi_display 驱动提供 panel_info
 *   （key=value 行，getPanelName 逐行按 "=\n" 拆、strncmp
 *   "panel_name"、value 空格转 '_'）。
 *
 * Stub 布局（与官方 vendor_file_contexts 正则同构，标签免补）：
 *   class mi_display
 *   ├─ device "disp_feature"（chrdev，devnode 前缀 mi_display/ →
 *   │  /dev/mi_display/disp_feature，标签 vendor_displayfeature_device）
 *   │   └─ device "disp-DSI-0"（挂 panel_info/doze_brightness/
 *   │      mipi_rw/wp_info 属性；sysfs 真实路径
 *   │      /sys/devices/virtual/mi_display/disp_feature/disp-DSI-0 下各节点
 *   │      匹配 vendor_sysfs_displayfeature 正则；
 *   │      /sys/class/mi_display/disp-DSI-0 软链同时满足库的 open 路径）
 *
 * panel_name 取值依据：vendor/etc/ 内 4 个 dsi_n17_*_mi.xml，其中
 * dsi_n17_36_0f_0c_dsc_vdo_cn/gl_mi.xml 双版本并存（全球版 gold 主屏），
 * 内容含完整 <rhyeyecare> 18 参数（df_default.xml 没有）。
 * ============================================================ */

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/miscdevice.h>
#include <linux/sysfs.h>

#define MI_PANEL_NAME	"dsi_n17_36_0f_0c_dsc_vdo"

static struct class *mi_disp_class;
static struct device *mi_disp_feature_dev;
static struct device *mi_disp_dsi0_dev;
static dev_t mi_disp_devt;

/* panel_info：getPanelName 只认 panel_name 行（key=value，值内空格会被
 * 上层替换为 '_'；本值无空格）。 */
static ssize_t mi_panel_info_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "panel_name=%s\n", MI_PANEL_NAME);
}
static DEVICE_ATTR(panel_info, 0444, mi_panel_info_show, NULL);

static ssize_t mi_doze_brightness_show(struct device *dev,
				       struct device_attribute *attr,
				       char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "0\n");
}
static ssize_t mi_doze_brightness_store(struct device *dev,
					struct device_attribute *attr,
					const char *buf, size_t count)
{
	return count;
}
static DEVICE_ATTR(doze_brightness, 0644, mi_doze_brightness_show,
		   mi_doze_brightness_store);

static ssize_t mi_mipi_rw_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	return 0; /* EOF：无寄存器数据可读 */
}
static ssize_t mi_mipi_rw_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	return count;
}
static DEVICE_ATTR(mipi_rw, 0644, mi_mipi_rw_show, mi_mipi_rw_store);

static ssize_t mi_wp_info_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	return 0; /* EOF：无白点校准数据 */
}
static DEVICE_ATTR(wp_info, 0444, mi_wp_info_show, NULL);

static struct attribute *mi_disp_dsi0_attrs[] = {
	&dev_attr_panel_info.attr,
	&dev_attr_doze_brightness.attr,
	&dev_attr_mipi_rw.attr,
	&dev_attr_wp_info.attr,
	NULL,
};
ATTRIBUTE_GROUPS(mi_disp_dsi0);

/* /dev/mi_display/disp_feature：displayfeature HAL 的私有 ioctl 面。
 * 云机无 mi_display 驱动语义，ioctl 一律 -ENOTTY（HAL 应按失败降级；
 * 若有调用方对返回值空指针解引用，将暴露下一层，按 tombstone 再补）。 */
static int mi_disp_feature_open(struct inode *inode, struct file *file)
{
	return 0;
}
static int mi_disp_feature_release(struct inode *inode, struct file *file)
{
	return 0;
}
static long mi_disp_feature_ioctl(struct file *file, unsigned int cmd,
				  unsigned long arg)
{
	return -ENOTTY;
}
static ssize_t mi_disp_feature_read(struct file *file, char __user *buf,
				    size_t count, loff_t *ppos)
{
	return -EINVAL;
}
static ssize_t mi_disp_feature_write(struct file *file,
				     const char __user *buf, size_t count,
				     loff_t *ppos)
{
	return -EINVAL;
}
static const struct file_operations mi_disp_feature_fops = {
	.owner		= THIS_MODULE,
	.open		= mi_disp_feature_open,
	.release	= mi_disp_feature_release,
	.unlocked_ioctl	= mi_disp_feature_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl	= mi_disp_feature_ioctl,
#endif
	.read		= mi_disp_feature_read,
	.write		= mi_disp_feature_write,
};

/* devtmpfs 节点名 = mi_display/<dev name>（仿 input class 的 devnode 前缀法） */
static char *mi_disp_devnode(const struct device *dev, umode_t *mode)
{
	return kasprintf(GFP_KERNEL, "mi_display/%s", dev_name(dev));
}

static int __init mi_display_stub_init(void)
{
	int ret;

	ret = alloc_chrdev_region(&mi_disp_devt, 0, 1, "mi_display");
	if (ret)
		return ret;

	mi_disp_class = class_create("mi_display");
	if (IS_ERR(mi_disp_class)) {
		ret = PTR_ERR(mi_disp_class);
		goto err_region;
	}
	mi_disp_class->devnode = mi_disp_devnode;

	mi_disp_feature_dev = device_create(mi_disp_class, NULL, mi_disp_devt,
					    NULL, "disp_feature");
	if (IS_ERR(mi_disp_feature_dev)) {
		ret = PTR_ERR(mi_disp_feature_dev);
		goto err_class;
	}

	/* disp-DSI-0 挂在 disp_feature 之下：sysfs 真实路径与 vendor
	 * sepolicy 正则（.../mi_display/disp_feature/disp-DSI-[0-1]）一致，
	 * /sys/class/mi_display/disp-DSI-0 软链满足用户态库的 open 路径。 */
	mi_disp_dsi0_dev = device_create_with_groups(mi_disp_class,
						     mi_disp_feature_dev, 0,
						     NULL, mi_disp_dsi0_groups,
						     "disp-DSI-0");
	if (IS_ERR(mi_disp_dsi0_dev)) {
		ret = PTR_ERR(mi_disp_dsi0_dev);
		goto err_feature;
	}

	pr_info("cdh_mi_display: stub ready (panel_name=%s, "
		"/dev/mi_display/disp_feature, DSI-0 sysfs)\n", MI_PANEL_NAME);
	return 0;

err_feature:
	device_destroy(mi_disp_class, mi_disp_devt);
err_class:
	class_destroy(mi_disp_class);
err_region:
	unregister_chrdev_region(mi_disp_devt, 1);
	return ret;
}
/* 先于 displayfeature HAL（vendor 服务）起：device_initcall 顺序在
 * initcall 层面早于 init.rc 的 vendor 服务拉起，天然满足。 */
device_initcall(mi_display_stub_init);

/* ============================================================
 * CDH: SF/HWC 挂死自动取证（run60/61：SF 主线程在首个真实 UI 渲染期
 * 用户态卡死，dumpsys/debuggerd 全挂、hung task 抓不到（S 状态 futex/
 * poll），需要内核侧直读用户态现场）。
 *
 * 机制：每 15s 采样 comm 为 surfaceflinger / composer@3.3 的进程全部
 * 线程 (state, 用户态 pc)；某进程全部线程的 (state,pc) 连续 3 次采样
 * 完全不变（说明冻结）→ printk 全线程现场（comm/state/pc/lr/sp），一次
 * 进程只 dump 一次。pc 取 task_pt_regs 的用户态现场（pstate 用户态或
 * 陷入内核前的 pc），撕裂读不影响定位。
 * ============================================================ */

#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kthread.h>
#include <linux/mm.h>
#include <linux/sched/task.h>
#include <linux/sched/signal.h>
#include <linux/stacktrace.h>

struct cdh_thr_snap {
	pid_t tid;
	char comm[TASK_COMM_LEN];
	unsigned long state;
	unsigned long pc, lr, sp;
	/* pc/lr 所属映射（d_path basename + 页内偏移），一次性格式化 */
	char pc_map[96];
	char lr_map[96];
	/* 内核栈（v3）：frozen dump 时抓取 */
	unsigned int kstack_n;
	unsigned long kstack[12];
};

struct cdh_proc_snap {
	char comm[TASK_COMM_LEN];
	int nthreads;
	bool frozen;
	bool dumped;
	struct cdh_thr_snap thr[64];
};

static struct delayed_work cdh_sfdump_work;
static struct cdh_proc_snap cdh_prev[3], cdh_cur[3];
static int cdh_streak[3];
static unsigned long cdh_heal_next;

/* 目标进程：SF / composer / system_server（v52：client 端挂点取证） */
static const char *const cdh_targets[] = {
	"surfaceflinger", "composer@3.3-se", "system_server"
};

/* 解析 addr 所属 VMA："<basename>+0x<offset>"；匿名映射 "(anon)+0x<offset>"；
 * 找不到 "(none)"。仅在 dump 路径调用（低频）。 */
static void cdh_vma_of(struct task_struct *t, unsigned long addr, char *out,
		       size_t outlen)
{
	struct mm_struct *mm;
	struct vm_area_struct *vma;

	out[0] = '\0';
	if (!addr)
		return;
	mm = get_task_mm(t);
	if (!mm) {
		scnprintf(out, outlen, "(nomm)");
		return;
	}
	if (mmap_read_lock_killable(mm)) {
		mmput(mm);
		scnprintf(out, outlen, "(lock)");
		return;
	}
	vma = find_vma(mm, addr);
	if (vma && addr >= vma->vm_start) {
		unsigned long off = addr - vma->vm_start +
				    (vma->vm_pgoff << PAGE_SHIFT);
		if (vma->vm_file) {
			char *p, *buf;

			buf = kmalloc(PATH_MAX, GFP_KERNEL);
			if (buf) {
				p = d_path(&vma->vm_file->f_path, buf,
					   PATH_MAX);
				if (!IS_ERR(p)) {
					const char *b = strrchr(p, '/');

					scnprintf(out, outlen, "%s+0x%lx",
						  b ? b + 1 : p, off);
				}
				kfree(buf);
			}
			if (!out[0])
				scnprintf(out, outlen, "(file)+0x%lx", off);
		} else {
			scnprintf(out, outlen, "(anon)+0x%lx", off);
		}
	} else {
		scnprintf(out, outlen, "(none)");
	}
	mmap_read_unlock(mm);
	mmput(mm);
}

static void cdh_snapshot_one(struct cdh_proc_snap *snap,
			     struct task_struct *leader, bool resolve)
{
	struct task_struct *t;

	snap->nthreads = 0;
	strscpy(snap->comm, leader->comm, TASK_COMM_LEN);
	rcu_read_lock();
	for_each_thread(leader, t) {
		struct pt_regs *regs;
		int i = snap->nthreads;

		if (i >= 64)
			break;
		get_task_struct(t);
		snap->thr[i].tid = t->pid;
		strscpy(snap->thr[i].comm, t->comm, TASK_COMM_LEN);
		snap->thr[i].state = t->__state;
		regs = task_pt_regs(t);
		if (regs) {
			snap->thr[i].pc = regs->pc;
			snap->thr[i].lr = regs->regs[30];
			snap->thr[i].sp = regs->sp;
		} else {
			snap->thr[i].pc = snap->thr[i].lr = 0;
			snap->thr[i].sp = 0;
		}
		put_task_struct(t);
		snap->nthreads++;
	}
	rcu_read_unlock();

	/* 映射归属 + 内核栈解析：仅 frozen 判定后执行（resolve 参数控制） */
	if (resolve) {
		struct task_struct *refs[64];
		int nrefs = 0, i, j;

		rcu_read_lock();
		for_each_thread(leader, t) {
			if (nrefs >= 64)
				break;
			refs[nrefs++] = get_task_struct(t);
		}
		rcu_read_unlock();

		for (j = 0; j < nrefs; j++) {
			for (i = 0; i < snap->nthreads; i++) {
				if (snap->thr[i].tid == refs[j]->pid) {
					cdh_vma_of(refs[j], snap->thr[i].pc,
						   snap->thr[i].pc_map,
						   sizeof(snap->thr[i].pc_map));
					cdh_vma_of(refs[j], snap->thr[i].lr,
						   snap->thr[i].lr_map,
						   sizeof(snap->thr[i].lr_map));
					/* 内核栈：等待者等点直接可见 */
					snap->thr[i].kstack_n =
						stack_trace_save_tsk(
							refs[j],
							snap->thr[i].kstack,
							ARRAY_SIZE(snap->thr[i].kstack),
							0);
					break;
				}
			}
			put_task_struct(refs[j]);
		}
	}
}

static bool cdh_snap_equal(const struct cdh_proc_snap *a,
			   const struct cdh_proc_snap *b)
{
	int i;

	if (a->nthreads != b->nthreads || a->nthreads == 0)
		return false;
	for (i = 0; i < a->nthreads; i++) {
		if (a->thr[i].tid != b->thr[i].tid ||
		    a->thr[i].state != b->thr[i].state ||
		    a->thr[i].pc != b->thr[i].pc)
			return false;
	}
	return true;
}

static void cdh_dump_snap(const struct cdh_proc_snap *s)
{
	int i;

	pr_info("cdh_sfdump: ===== %s frozen (%d threads) =====\n",
		s->comm, s->nthreads);
	for (i = 0; i < s->nthreads; i++) {
		pr_info("cdh_sfdump: tid=%d %-16s state=%lu\n",
			s->thr[i].tid, s->thr[i].comm, s->thr[i].state);
		pr_info("cdh_sfdump:    pc=0x%lx [%s] lr=0x%lx [%s]\n",
			s->thr[i].pc,
			s->thr[i].pc_map[0] ? s->thr[i].pc_map : "?",
			s->thr[i].lr,
			s->thr[i].lr_map[0] ? s->thr[i].lr_map : "?");
		/* 用户态内核栈（v3）：该线程当前内核调用栈——S 态等待者
		 * 的等点（fence/ioctl/futex）直接可见。撕裂读可接受。 */
		if (s->thr[i].kstack_n > 0) {
			int k;

			for (k = 0; k < s->thr[i].kstack_n; k++)
				pr_info("cdh_sfdump:    k[%d]=%pS\n",
					k, (void *)s->thr[i].kstack[k]);
		}
	}
}

static void cdh_sfdump_fn(struct work_struct *work)
{
	const char *const *targets = cdh_targets;
	struct task_struct *g, *t;
	int k;

	for (k = 0; k < 3; k++) {
		struct cdh_proc_snap *cur = &cdh_cur[k];
		bool found = false;

		/* —— v5 自愈：主线程被 ptrace 冻结（tracing stop）超阈值 →
			 * 内核 SIGKILL tracer（MIUI crash_dump64 读 guest state
			 * EFAULT 挂死不 detach，SF 主线程+binder 线程永久冻结，
			 * run65 实锤 TracerPid=crash_dump / State=t）→ tracer 死亡
			 * 内核自动 detach → SF 复活。
			 * v5.1（run68 教训）：限频 60s → 5s。原 60s 限频使冻结窗口
			 * 长达 45-75s，击穿 system_server watchdog 67s 阈值
			 * （12:46:19 WATCHDOG KILLING SYSTEM PROCESS 实锤）；
			 * 且 MIUIScout ping（code 1）在冻结窗口悬挂 → 判 hang →
			 * 再触发 crash_dump64，恶性循环。冻结窗口压到 ~10s 内断链。 */
		if (k < 2 && time_after(jiffies, cdh_heal_next)) {
			struct task_struct *leader = NULL;

			rcu_read_lock();
			for_each_process_thread(g, t) {
				if (!strcmp(t->comm, targets[k]) ||
				    (k == 1 && !strcmp(t->comm,
						       "composer@3.3-se"))) {
					leader = t->group_leader;
					if (leader)
						get_task_struct(leader);
					break;
				}
			}
			rcu_read_unlock();
			if (leader && (READ_ONCE(leader->__state) & TASK_TRACED)) {
				struct task_struct *tracer;

				rcu_read_lock();
				tracer = rcu_dereference(leader->parent);
				if (tracer && tracer != leader &&
				    (tracer->flags & PF_EXITING) == 0) {
					get_task_struct(tracer);
					rcu_read_unlock();
					pr_info("cdh_sfdump: %s frozen by tracer "
						"pid=%d (%s) -> SIGKILL\n",
						leader->comm, tracer->pid,
						tracer->comm);
					send_sig_info(SIGKILL, SEND_SIG_PRIV,
						      tracer);
					put_task_struct(tracer);
				} else {
					rcu_read_unlock();
				}
				cdh_heal_next = jiffies + msecs_to_jiffies(5000);
			}
			if (leader)
				put_task_struct(leader);
		}

		memset(cur, 0, sizeof(*cur));
		rcu_read_lock();
		for_each_process_thread(g, t) {
			/* composer 主进程 comm 为 "android.hardwar"（截断），
			 * 内部线程名 "composer@3.3-se"；匹配任一后取 group_leader */
			if (!strcmp(t->comm, targets[k]) ||
			    (k == 1 && !strcmp(t->comm, "composer@3.3-se"))) {
				struct task_struct *leader = t->group_leader;

				if (leader) {
					get_task_struct(leader);
					rcu_read_unlock();
					cdh_snapshot_one(cur, leader, false);
					put_task_struct(leader);
					found = true;
					rcu_read_lock();
				}
				break;
			}
		}
		rcu_read_unlock();

		if (!found) {
			cdh_streak[k] = 0;
			cdh_prev[k].dumped = false;
			continue;
		}
		if (cdh_prev[k].nthreads && cdh_snap_equal(cur, &cdh_prev[k])) {
			cdh_streak[k]++;
			if (cdh_streak[k] >= 3 && !cur->dumped &&
			    !cdh_prev[k].dumped) {
				/* 重新快照并带符号/内核栈解析后 dump */
				struct task_struct *g2, *t2, *leader2 = NULL;

				rcu_read_lock();
				for_each_process_thread(g2, t2) {
					if (!strcmp(t2->comm, targets[k]) ||
					    (k == 1 && !strcmp(t2->comm,
							       "composer@3.3-se")) ||
					    (k == 2 && !strcmp(t2->comm,
							       "system_server"))) {
						leader2 = t2->group_leader;
						if (leader2)
							get_task_struct(leader2);
						break;
					}
				}
				rcu_read_unlock();
				if (leader2) {
					memset(cur, 0, sizeof(*cur));
					cdh_snapshot_one(cur, leader2, true);
					put_task_struct(leader2);
				}
				cdh_dump_snap(cur);
				cur->dumped = true;
			}
		} else {
			cdh_streak[k] = 1;
			cur->dumped = false;
		}
		cdh_prev[k] = *cur;
	}

	schedule_delayed_work(&cdh_sfdump_work, msecs_to_jiffies(5000));
}

static int __init cdh_sfdump_init(void)
{
	INIT_DELAYED_WORK(&cdh_sfdump_work, cdh_sfdump_fn);
	schedule_delayed_work(&cdh_sfdump_work, msecs_to_jiffies(60000));
	pr_info("cdh_sfdump: SF/HWC frozen-thread prober ready (5s interval, 3-streak, 5s heal throttle)\n");
	return 0;
}
late_initcall(cdh_sfdump_init);
