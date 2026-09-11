// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_device_info_cache: " fmt

#include <linux/compiler.h>
#include <linux/cpumask.h>
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>

#include "cdh_device_info.h"

#define CDH_CPU_COUNT 8

typedef unsigned long (*cdh_kallsyms_lookup_name_t)(const char *name);
typedef void (*cdh_cpu_cache_sysfs_exit_t)(unsigned int cpu);
typedef int (*cdh_cacheinfo_cpu_online_t)(unsigned int cpu);

static cdh_cpu_cache_sysfs_exit_t cdh_cpu_cache_sysfs_exit_fn;
static cdh_cacheinfo_cpu_online_t cdh_cacheinfo_cpu_online_fn;
static cpumask_t *cdh_cache_dev_map;
static bool cdh_cache_hidden[CDH_CPU_COUNT];
static bool cdh_cache_registered;

// Android15 GKI enables kCFI; private cacheinfo callbacks must be called through nocfi wrappers.
static void __nocfi cdh_call_cpu_cache_sysfs_exit(unsigned int cpu)
{
	cdh_cpu_cache_sysfs_exit_fn(cpu);
}

static int __nocfi cdh_call_cacheinfo_cpu_online(unsigned int cpu)
{
	return cdh_cacheinfo_cpu_online_fn(cpu);
}

static unsigned long cdh_lookup_private_symbol(const char *name)
{
	cdh_kallsyms_lookup_name_t lookup;
	struct kprobe kp = {
		.symbol_name = "kallsyms_lookup_name",
	};
	int ret;

	// kprobe resolves Android GKI private cacheinfo symbols; no probe handler remains installed.
	ret = register_kprobe(&kp);
	if (ret)
		return 0;
	lookup = (cdh_kallsyms_lookup_name_t)kp.addr;
	unregister_kprobe(&kp);
	if (!lookup)
		return 0;
	return lookup(name);
}

static int cdh_resolve_cacheinfo_symbols(void)
{
	unsigned long exit_addr;
	unsigned long online_addr;
	unsigned long map_addr;

	exit_addr = cdh_lookup_private_symbol("cpu_cache_sysfs_exit");
	online_addr = cdh_lookup_private_symbol("cacheinfo_cpu_online");
	map_addr = cdh_lookup_private_symbol("cache_dev_map");
	if (!exit_addr || !online_addr || !map_addr) {
		pr_err("failed to resolve cacheinfo private symbols exit=%px online=%px map=%px\n",
		       (void *)exit_addr, (void *)online_addr, (void *)map_addr);
		return -ENOENT;
	}

	cdh_cpu_cache_sysfs_exit_fn = (cdh_cpu_cache_sysfs_exit_t)exit_addr;
	cdh_cacheinfo_cpu_online_fn = (cdh_cacheinfo_cpu_online_t)online_addr;
	cdh_cache_dev_map = (cpumask_t *)map_addr;
	return 0;
}

static void cdh_restore_cache_sysfs(unsigned int cpu)
{
	int ret;

	if (!cdh_cache_hidden[cpu])
		return;
	if (cpumask_test_cpu(cpu, cdh_cache_dev_map)) {
		cdh_cache_hidden[cpu] = false;
		return;
	}
	/*
	 * cacheinfo_cpu_online() is the same callback used by CPU hotplug to
	 * rebuild cpuN/cache and index devices, so restore uses the kernel's own
	 * registration path instead of manually recreating kobjects.
	 */
	ret = cdh_call_cacheinfo_cpu_online(cpu);
	if (ret)
		pr_err("failed to restore cpu%u cache sysfs:%d\n", cpu, ret);
	else
		cdh_cache_hidden[cpu] = false;
}

void cdh_cpu_cache_sysfs_exit(void)
{
	unsigned int cpu;

	if (!cdh_cache_registered)
		return;
	for (cpu = 0; cpu < CDH_CPU_COUNT; cpu++)
		cdh_restore_cache_sysfs(cpu);
	cdh_cache_registered = false;
	pr_info("restored cpu cache sysfs devices\n");
}

int cdh_cpu_cache_sysfs_init(void)
{
	unsigned int cpu;
	int ret;

	ret = cdh_resolve_cacheinfo_symbols();
	if (ret)
		return ret;

	for (cpu = 0; cpu < CDH_CPU_COUNT; cpu++) {
		if (!cpumask_test_cpu(cpu, cdh_cache_dev_map))
			continue;
		/*
		 * cpu_cache_sysfs_exit() removes cpuN/cache/index* and the
		 * parent cache device, then clears the per-cpu cache device
		 * pointers. Clear cache_dev_map as cacheinfo_cpu_pre_down()
		 * would, otherwise a later CPU hotplug teardown could run the
		 * private exit path a second time.
		 */
		cdh_call_cpu_cache_sysfs_exit(cpu);
		cpumask_clear_cpu(cpu, cdh_cache_dev_map);
		cdh_cache_hidden[cpu] = true;
	}
	cdh_cache_registered = true;
	pr_info("hid cpu cache sysfs devices for  Android15 profile\n");
	return 0;
}
