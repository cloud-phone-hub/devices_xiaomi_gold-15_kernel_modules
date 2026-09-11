// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_device_info: " fmt

#include <linux/module.h>

#include "cdh_device_info.h"

#define CDH_GKI_ABI_RELEASE "6.6.127-4k-cdh"

static char cdh_gki_abi_release[] = CDH_GKI_ABI_RELEASE;

module_param_string(gki_abi_release, cdh_gki_abi_release, sizeof(cdh_gki_abi_release), 0444);
MODULE_PARM_DESC(gki_abi_release, "GKI release required by this loaded  device info module");

static int __init cdh_device_info_init(void)
{
	int ret;

	// Init order mirrors teardown dependencies; failure branches unwind registered hooks/sysfs.
	ret = cdh_uts_init();
	if (ret)
		return ret;

	ret = cdh_meminfo_init();
	if (ret) {
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_cpu_display_init();
	if (ret) {
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_cpu_topology_init();
	if (ret) {
		cdh_cpu_display_exit();
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_cpu_midr_sysfs_init();
	if (ret) {
		cdh_cpu_topology_exit();
		cdh_cpu_display_exit();
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_cpu_cache_sysfs_init();
	if (ret) {
		cdh_cpu_midr_sysfs_exit();
		cdh_cpu_topology_exit();
		cdh_cpu_display_exit();
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_cpufreq_sysfs_init();
	if (ret) {
		cdh_cpu_cache_sysfs_exit();
		cdh_cpu_midr_sysfs_exit();
		cdh_cpu_topology_exit();
		cdh_cpu_display_exit();
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	ret = cdh_time_uptime_init();
	if (ret) {
		cdh_cpufreq_sysfs_exit();
		cdh_cpu_cache_sysfs_exit();
		cdh_cpu_midr_sysfs_exit();
		cdh_cpu_topology_exit();
		cdh_cpu_display_exit();
		cdh_meminfo_exit();
		cdh_uts_exit();
		return ret;
	}

	pr_info("loaded gki_abi_release=%s\n", cdh_gki_abi_release);
	return 0;
}

static void __exit cdh_device_info_exit(void)
{
	cdh_time_uptime_exit();
	cdh_cpufreq_sysfs_exit();
	cdh_cpu_cache_sysfs_exit();
	cdh_cpu_midr_sysfs_exit();
	cdh_cpu_topology_exit();
	cdh_cpu_display_exit();
	cdh_meminfo_exit();
	cdh_uts_exit();
	pr_info("unloaded\n");
}

module_init(cdh_device_info_init);
module_exit(cdh_device_info_exit);

MODULE_DESCRIPTION(" Android15 device information display alignment module");
MODULE_AUTHOR("feicong <fei_cong@hotmail.com>");
MODULE_LICENSE("GPL");
