// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_pixel6_device_info_cpu: " fmt

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <trace/hooks/cpuinfo.h>
#include <trace/hooks/topology.h>

#include "cdh_pixel6_device_info.h"

static const char cdh_pixel6_cpu_features[] =
	"fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp";
static const char cdh_pixel6_cpu_hardware[] = "gs101 (Tensor)";

struct cdh_pixel6_cpu_core {
	unsigned int cpu;
	const char *bogo_mips;
	const char *implementer;
	unsigned int variant;
	const char *part;
	unsigned int revision;
	unsigned long capacity;
};

static const struct cdh_pixel6_cpu_core cdh_pixel6_cpu_cores[] = {
	/* BogoMIPS 只用于 /proc/cpuinfo 展示，目标取 Pixel6 Android15 真机稳定值。 */
	{ 0, "49.15", "0x41", 0x2, "0xd05", 0, 160 },
	{ 1, "49.15", "0x41", 0x2, "0xd05", 0, 160 },
	{ 2, "49.15", "0x41", 0x2, "0xd05", 0, 160 },
	{ 3, "49.15", "0x41", 0x2, "0xd05", 0, 160 },
	{ 4, "49.15", "0x41", 0x4, "0xd0b", 0, 498 },
	{ 5, "49.15", "0x41", 0x4, "0xd0b", 0, 498 },
	{ 6, "49.15", "0x41", 0x1, "0xd44", 0, 1024 },
	{ 7, "49.15", "0x41", 0x1, "0xd44", 0, 1024 },
};

static bool cdh_pixel6_cpuinfo_registered;
static bool cdh_pixel6_cpu_capacity_registered;
static bool cdh_pixel6_cpu_display_pinned;

static const struct cdh_pixel6_cpu_core *cdh_pixel6_cpu_target(unsigned int cpu)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cdh_pixel6_cpu_cores); i++) {
		if (cdh_pixel6_cpu_cores[i].cpu == cpu)
			return &cdh_pixel6_cpu_cores[i];
	}
	return NULL;
}

static void cdh_pixel6_cpuinfo_show(void *data, struct seq_file *m)
{
	size_t i;

	m->count = 0;
	m->from = 0;
	for (i = 0; i < ARRAY_SIZE(cdh_pixel6_cpu_cores); i++) {
		const struct cdh_pixel6_cpu_core *core = &cdh_pixel6_cpu_cores[i];

		seq_printf(m, "processor\t: %u\n", core->cpu);
		seq_printf(m, "BogoMIPS\t: %s\n", core->bogo_mips);
		seq_printf(m, "Features\t: %s\n", cdh_pixel6_cpu_features);
		seq_printf(m, "CPU implementer\t: %s\n", core->implementer);
		seq_puts(m, "CPU architecture: 8\n");
		seq_printf(m, "CPU variant\t: 0x%x\n", core->variant);
		seq_printf(m, "CPU part\t: %s\n", core->part);
		seq_printf(m, "CPU revision\t: %u\n\n", core->revision);
	}
	/* DevCheck 和 AIDA64 都会读取 /proc/cpuinfo 的 Hardware，统一底层来源比 App hook 稳。 */
	seq_printf(m, "Hardware\t: %s\n", cdh_pixel6_cpu_hardware);
}

static void cdh_pixel6_cpu_capacity_show(void *data, unsigned long *capacity, int cpu)
{
	const struct cdh_pixel6_cpu_core *core;

	if (!capacity || cpu < 0)
		return;
	core = cdh_pixel6_cpu_target((unsigned int)cpu);
	if (!core)
		return;
	*capacity = core->capacity;
}

int cdh_pixel6_cpu_display_init(void)
{
	int ret;

	ret = register_trace_android_rvh_cpuinfo_c_show(cdh_pixel6_cpuinfo_show, NULL);
	if (ret)
		return ret;
	cdh_pixel6_cpuinfo_registered = true;

	ret = register_trace_android_rvh_cpu_capacity_show(cdh_pixel6_cpu_capacity_show, NULL);
	if (ret) {
		pr_err("registered /proc/cpuinfo hook but cpu_capacity hook failed:%d\n", ret);
		__module_get(THIS_MODULE);
		cdh_pixel6_cpu_display_pinned = true;
		return 0;
	}
	cdh_pixel6_cpu_capacity_registered = true;

	__module_get(THIS_MODULE);
	cdh_pixel6_cpu_display_pinned = true;
	pr_info("registered permanent /proc/cpuinfo and cpu_capacity display hooks\n");
	return 0;
}

void cdh_pixel6_cpu_display_exit(void)
{
	if (!cdh_pixel6_cpuinfo_registered && !cdh_pixel6_cpu_capacity_registered)
		return;

	pr_info("restricted CPU display hooks are permanent; pinned=%d\n",
		cdh_pixel6_cpu_display_pinned);
}
