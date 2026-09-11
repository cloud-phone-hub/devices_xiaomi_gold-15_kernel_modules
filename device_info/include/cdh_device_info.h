/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */

#ifndef CDH_DEVICE_INFO_H
#define CDH_DEVICE_INFO_H

int cdh_uts_init(void);
void cdh_uts_exit(void);

int cdh_meminfo_init(void);
void cdh_meminfo_exit(void);

int cdh_cpu_display_init(void);
void cdh_cpu_display_exit(void);

int cdh_cpu_topology_init(void);
void cdh_cpu_topology_exit(void);

int cdh_cpu_midr_sysfs_init(void);
void cdh_cpu_midr_sysfs_exit(void);

int cdh_cpu_cache_sysfs_init(void);
void cdh_cpu_cache_sysfs_exit(void);

int cdh_cpufreq_sysfs_init(void);
void cdh_cpufreq_sysfs_exit(void);

int cdh_time_uptime_init(void);
void cdh_time_uptime_exit(void);

#endif
