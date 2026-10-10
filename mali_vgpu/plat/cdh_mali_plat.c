// SPDX-License-Identifier: GPL-2.0
/*
 * CDH gold-15：为「虚拟 Mali」注册 platform_device，让 kbase 的 probe 命中。
 *
 * 背景（实测依据见 build/doc/gpu.md §7.13）
 * ----------------------------------------
 * ARM kbase 以 CONFIG_MALI_NO_MALI 编译时是**纯软件模拟**：
 *   - kbase_common_reg_map() 直接 return 0（不 request_mem_region、不 ioremap）；
 *   - kbase_gpu_device_create() 仅 midgard_model_create() + spin_lock_init；
 *   - kbase_install_interrupts() 用 workqueue 模拟 3 个中断（无需真 IRQ）；
 *   - dummy model 已实现 job slot 状态机：写 JS_COMMAND_NEXT=START 即
 *     signal_int -> gpu_device_raise_irq(JOB_IRQ)，job「立即完成」。
 * 因此内核侧不需要任何真实 GPU 资源，唯一缺的是**一个能被 kbase 匹配到的设备**。
 *
 * kbase 是 platform_driver：
 *   .driver.name = KBASE_DRV_NAME = "mali"，of_match_table 含 "arm,mali-valhall"。
 * QEMU virt 的 DTB 没有该节点，但 platform_bus_type 的匹配顺序最后一条是
 *   strcmp(pdev->name, drv->driver.name) == 0
 * 故注册一个 name="mali" 的 platform_device 即可命中 probe，**无需伪造 DT 节点**
 * （kbase 里所有 of_property_read_* / of_clk_get / regulator_get_optional
 *   在 of_node==NULL 时均被容错忽略）。
 *
 * registers_map() 硬性要求 platform_get_resource(pdev, IORESOURCE_MEM, 0) 非空
 * （为空即 -ENOENT），所以必须给一个 MEM resource。NO_MALI 下该地址不会被映射，
 * 仅作占位：取一段 QEMU virt 上不存在的空洞，避免与任何真实设备窗口冲突。
 *
 * 设备节点名由 kbase 生成：scnprintf(devname, "%s%d", KBASE_DRV_NAME, nr)
 * → 「/dev/mali0」，与厂商 Mali DDK（libGLES_mali.so）打开的路径一致。
 */

#include <linux/dma-mapping.h>
#include <linux/ioport.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>

/* 必须与 kbase 的 KBASE_DRV_NAME 一致（mali_kbase.h:88） */
#define CDH_MALI_DRV_NAME "mali"

/*
 * 占位寄存器窗口。NO_MALI 下 kbase 不会 ioremap 它，只有 registers_map()
 * 会把 start/size 记进 kbdev->reg_start / reg_size（后续不再使用）。
 * 选 0x40000000000（4 TiB 处）：远超 QEMU virt 的内存与 MMIO 布局，
 * 确保不与 RAM、PCI ECAM、GIC、flash 等任何真实窗口重叠。
 */
#define CDH_MALI_FAKE_REG_BASE 0x40000000000ULL
#define CDH_MALI_FAKE_REG_SIZE 0x00000100000ULL

static struct platform_device *cdh_mali_pdev;

static const struct resource cdh_mali_res[] = {
	DEFINE_RES_MEM(CDH_MALI_FAKE_REG_BASE, CDH_MALI_FAKE_REG_SIZE),
};

static int __init cdh_mali_plat_init(void)
{
	struct platform_device_info pinfo = {
		.name = CDH_MALI_DRV_NAME,
		.id = 0,
		.res = cdh_mali_res,
		.num_res = ARRAY_SIZE(cdh_mali_res),
		/* kbase 的内存管理会对 kbdev->dev 走 dma 接口，给足掩码 */
		.dma_mask = DMA_BIT_MASK(32),
	};

	cdh_mali_pdev = platform_device_register_full(&pinfo);
	if (IS_ERR(cdh_mali_pdev)) {
		pr_err("cdh_mali_plat: 注册 platform_device '%s' 失败: %ld\n",
		       CDH_MALI_DRV_NAME, PTR_ERR(cdh_mali_pdev));
		return PTR_ERR(cdh_mali_pdev);
	}

	pr_info("cdh_mali_plat: 已注册 '%s'（占位寄存器窗口 %llx+%llx，NO_MALI 下不映射）\n",
		CDH_MALI_DRV_NAME, (unsigned long long)CDH_MALI_FAKE_REG_BASE,
		(unsigned long long)CDH_MALI_FAKE_REG_SIZE);
	return 0;
}

static void __exit cdh_mali_plat_exit(void)
{
	if (!IS_ERR_OR_NULL(cdh_mali_pdev)) {
		platform_device_unregister(cdh_mali_pdev);
		cdh_mali_pdev = NULL;
		pr_info("cdh_mali_plat: 已注销 '%s'\n", CDH_MALI_DRV_NAME);
	}
}

module_init(cdh_mali_plat_init);
module_exit(cdh_mali_plat_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("cloud-phone-hub");
MODULE_DESCRIPTION("CDH: 为 kbase(NO_MALI) 虚拟 Mali 注册 platform_device（gold-15）");
MODULE_VERSION("1.0");
