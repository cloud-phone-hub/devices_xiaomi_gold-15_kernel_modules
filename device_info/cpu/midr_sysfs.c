// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_device_info_midr: " fmt

#include <asm/cpu.h>
#include <linux/compiler.h>
#include <linux/cpu.h>
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/percpu.h>

#include "cdh_device_info.h"

struct cdh_midr_target {
	unsigned int cpu;
	u64 midr;
};

static const struct cdh_midr_target cdh_midr_targets[] = {
	{ 0, 0x00000000412fd050ULL },
	{ 1, 0x00000000412fd050ULL },
	{ 2, 0x00000000412fd050ULL },
	{ 3, 0x00000000412fd050ULL },
	{ 4, 0x00000000412fd050ULL },
	{ 5, 0x00000000412fd050ULL },
	{ 6, 0x00000000414fd0b0ULL },
	{ 7, 0x00000000414fd0b0ULL },
};

typedef unsigned long (*cdh_kallsyms_lookup_name_t)(const char *name);

/*
 * cpu_data is the canonical source used by arm64 midr_el1 sysfs, but Android
 * GKI does not export it as KMI. Resolve it explicitly and fail module load
 * if the private symbol path is unavailable; no auxiliary-node fallback is
 * accepted for AIDA64-visible MIDR alignment.
 */
static struct cpuinfo_arm64 __percpu *cdh_cpu_data;
static u64 cdh_saved_midr[ARRAY_SIZE(cdh_midr_targets)];
static bool cdh_midr_registered;

static unsigned long cdh_lookup_private_symbol(const char *name)
{
	cdh_kallsyms_lookup_name_t lookup;
	struct kprobe kp = {
		.symbol_name = "kallsyms_lookup_name",
	};
	int ret;

	/* kprobe is only used as a resolver for private GKI symbols; no runtime hook is installed. */
	ret = register_kprobe(&kp);
	if (ret)
		return 0;
	lookup = (cdh_kallsyms_lookup_name_t)kp.addr;
	unregister_kprobe(&kp);
	if (!lookup)
		return 0;
	return lookup(name);
}

static struct cpuinfo_arm64 *cdh_cpuinfo(unsigned int cpu)
{
	if (!cdh_cpu_data || cpu >= nr_cpu_ids)
		return NULL;
	return per_cpu_ptr(cdh_cpu_data, cpu);
}

static void cdh_restore_midr_values(size_t count)
{
	size_t i;

	for (i = 0; i < count; i++) {
		const struct cdh_midr_target *target = &cdh_midr_targets[i];
		struct cpuinfo_arm64 *info = cdh_cpuinfo(target->cpu);

		if (info)
			WRITE_ONCE(info->reg_midr, cdh_saved_midr[i]);
	}
}

int cdh_cpu_midr_sysfs_init(void)
{
	unsigned long cpu_data_addr;
	size_t i;

	cpu_data_addr = cdh_lookup_private_symbol("cpu_data");
	if (!cpu_data_addr) {
		pr_err("failed to resolve cpu_data private symbol\n");
		return -ENOENT;
	}
	cdh_cpu_data = (struct cpuinfo_arm64 __percpu *)cpu_data_addr;

	for (i = 0; i < ARRAY_SIZE(cdh_midr_targets); i++) {
		const struct cdh_midr_target *target = &cdh_midr_targets[i];
		struct cpuinfo_arm64 *info = cdh_cpuinfo(target->cpu);

		if (!info) {
			pr_err("missing cpuinfo for cpu%u\n", target->cpu);
			cdh_restore_midr_values(i);
			return -ENODEV;
		}
		/* midr_el1 sysfs show reads reg_midr live, so update the shared source in place. */
		cdh_saved_midr[i] = READ_ONCE(info->reg_midr);
		WRITE_ONCE(info->reg_midr, target->midr);
	}
	cdh_midr_registered = true;
	pr_info("updated cpu_data reg_midr for  MIDR sysfs\n");
	return 0;
}

void cdh_cpu_midr_sysfs_exit(void)
{
	if (!cdh_midr_registered)
		return;
	/* Restore the original KVM/QEMU MIDR values when the module is unloaded or rolled back. */
	cdh_restore_midr_values(ARRAY_SIZE(cdh_midr_targets));
	cdh_midr_registered = false;
	pr_info("restored cpu_data reg_midr values\n");
}
