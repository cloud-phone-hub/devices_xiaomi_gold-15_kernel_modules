// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_pixel6_device_info_topology: " fmt

#include <linux/arch_topology.h>
#include <linux/cpumask.h>
#include <linux/kernel.h>

#include "cdh_pixel6_device_info.h"

struct cdh_pixel6_topology_saved {
	int thread_id;
	int core_id;
	int cluster_id;
	int package_id;
	cpumask_t thread_sibling;
	cpumask_t core_sibling;
	cpumask_t cluster_sibling;
	cpumask_t llc_sibling;
};

/* 卸载时恢复原始 topology，避免调试 rmmod 后把 guest 内核拓扑永久留在 Pixel6 画像。 */
static struct cdh_pixel6_topology_saved cdh_pixel6_saved_topology[8];
static bool cdh_pixel6_topology_registered;

static void cdh_pixel6_save_cpu_topology(unsigned int cpu)
{
	struct cdh_pixel6_topology_saved *saved = &cdh_pixel6_saved_topology[cpu];

	saved->thread_id = cpu_topology[cpu].thread_id;
	saved->core_id = cpu_topology[cpu].core_id;
	saved->cluster_id = cpu_topology[cpu].cluster_id;
	saved->package_id = cpu_topology[cpu].package_id;
	cpumask_copy(&saved->thread_sibling, &cpu_topology[cpu].thread_sibling);
	cpumask_copy(&saved->core_sibling, &cpu_topology[cpu].core_sibling);
	cpumask_copy(&saved->cluster_sibling, &cpu_topology[cpu].cluster_sibling);
	cpumask_copy(&saved->llc_sibling, &cpu_topology[cpu].llc_sibling);
}

static void cdh_pixel6_restore_cpu_topology(unsigned int cpu)
{
	const struct cdh_pixel6_topology_saved *saved = &cdh_pixel6_saved_topology[cpu];

	cpu_topology[cpu].thread_id = saved->thread_id;
	cpu_topology[cpu].core_id = saved->core_id;
	cpu_topology[cpu].cluster_id = saved->cluster_id;
	cpu_topology[cpu].package_id = saved->package_id;
	cpumask_copy(&cpu_topology[cpu].thread_sibling, &saved->thread_sibling);
	cpumask_copy(&cpu_topology[cpu].core_sibling, &saved->core_sibling);
	cpumask_copy(&cpu_topology[cpu].cluster_sibling, &saved->cluster_sibling);
	cpumask_copy(&cpu_topology[cpu].llc_sibling, &saved->llc_sibling);
}

static void cdh_pixel6_set_cluster_mask(cpumask_t *mask, unsigned int first, unsigned int last)
{
	unsigned int cpu;

	cpumask_clear(mask);
	for (cpu = first; cpu <= last; cpu++)
		cpumask_set_cpu(cpu, mask);
}

static void cdh_pixel6_apply_cpu_topology(unsigned int cpu)
{
	/*
	 * topology sysfs 文件直接读 cpu_topology[]，因此修改这份 canonical
	 * source 能同时覆盖 physical_package_id、cluster_id 和 sibling mask。
	 * Pixel6 Android15 的 core_siblings 和 cluster_cpus 对所有 CPU 都是
	 * ff/0-7；4+2+2 分组只属于 cpufreq policy，不是 topology sibling。
	 */
	cpu_topology[cpu].package_id = 0;
	cpu_topology[cpu].cluster_id = 0;
	cpu_topology[cpu].core_id = (int)cpu;
	cpu_topology[cpu].thread_id = -1;
	cpumask_clear(&cpu_topology[cpu].thread_sibling);
	cpumask_set_cpu(cpu, &cpu_topology[cpu].thread_sibling);
	cdh_pixel6_set_cluster_mask(&cpu_topology[cpu].core_sibling, 0, 7);
	cdh_pixel6_set_cluster_mask(&cpu_topology[cpu].cluster_sibling, 0, 7);
	cdh_pixel6_set_cluster_mask(&cpu_topology[cpu].llc_sibling, 0, 7);
}

int cdh_pixel6_cpu_topology_init(void)
{
	unsigned int cpu;

	for (cpu = 0; cpu < ARRAY_SIZE(cdh_pixel6_saved_topology); cpu++) {
		cdh_pixel6_save_cpu_topology(cpu);
		cdh_pixel6_apply_cpu_topology(cpu);
	}
	cdh_pixel6_topology_registered = true;
	pr_info("updated cpu_topology for Pixel6 package and cluster ids\n");
	return 0;
}

void cdh_pixel6_cpu_topology_exit(void)
{
	unsigned int cpu;

	if (!cdh_pixel6_topology_registered)
		return;
	for (cpu = 0; cpu < ARRAY_SIZE(cdh_pixel6_saved_topology); cpu++)
		cdh_pixel6_restore_cpu_topology(cpu);
	cdh_pixel6_topology_registered = false;
	pr_info("restored cpu_topology values\n");
}
