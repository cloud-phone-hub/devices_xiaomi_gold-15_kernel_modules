// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_pixel6_device_info_cpufreq: " fmt

#include <linux/cpu.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/string.h>
#include <linux/sysfs.h>

#include "cdh_pixel6_device_info.h"

struct cdh_pixel6_cpufreq_target {
	unsigned int cpu;
	const char *affected;
	const char *related;
	const char *min_freq;
	const char *max_freq;
	const char *cur_freq;
	const char *governor;
	struct kobject *kobj;
};

static struct cdh_pixel6_cpufreq_target cdh_pixel6_cpufreq_targets[] = {
	/* Pixel6 三簇频率目标：cpu0-3 小核、cpu4-5 中核、cpu6-7 大核。 */
	{ 0, "0 1 2 3", "0 1 2 3", "300000", "1803000", "1803000", "sched_pixel" },
	{ 1, "0 1 2 3", "0 1 2 3", "300000", "1803000", "1803000", "sched_pixel" },
	{ 2, "0 1 2 3", "0 1 2 3", "300000", "1803000", "1803000", "sched_pixel" },
	{ 3, "0 1 2 3", "0 1 2 3", "300000", "1803000", "1803000", "sched_pixel" },
	{ 4, "4 5", "4 5", "400000", "2253000", "2253000", "sched_pixel" },
	{ 5, "4 5", "4 5", "400000", "2253000", "2253000", "sched_pixel" },
	{ 6, "6 7", "6 7", "500000", "2802000", "851000", "sched_pixel" },
	{ 7, "6 7", "6 7", "500000", "2802000", "851000", "sched_pixel" },
};

/*
 * The virtio GSI base exposes CPU devices but no cpufreq policy directory.
 * Several Android userspace services still read cpuN/cpufreq directly, so we
 * create read-only Pixel6-shaped files under the existing CPU device kobjects.
 */
static struct cdh_pixel6_cpufreq_target *cdh_pixel6_cpufreq_target_for_kobj(struct kobject *kobj)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cdh_pixel6_cpufreq_targets); i++) {
		if (cdh_pixel6_cpufreq_targets[i].kobj == kobj)
			return &cdh_pixel6_cpufreq_targets[i];
	}
	return NULL;
}

static const char *cdh_pixel6_cpufreq_value(const struct cdh_pixel6_cpufreq_target *target,
					    const char *name)
{
	/* 所有 cpufreq 文件共用 show 回调，按属性名映射到同一份目标数据。 */
	if (!strcmp(name, "affected_cpus"))
		return target->affected;
	if (!strcmp(name, "related_cpus"))
		return target->related;
	if (!strcmp(name, "cpuinfo_min_freq") || !strcmp(name, "scaling_min_freq"))
		return target->min_freq;
	if (!strcmp(name, "cpuinfo_max_freq") || !strcmp(name, "scaling_max_freq"))
		return target->max_freq;
	if (!strcmp(name, "cpuinfo_cur_freq") || !strcmp(name, "scaling_cur_freq"))
		return target->cur_freq;
	if (!strcmp(name, "scaling_governor"))
		return target->governor;
	if (!strcmp(name, "scaling_available_governors"))
		return "sched_pixel";
	return "0";
}

static ssize_t cdh_pixel6_cpufreq_show(struct kobject *kobj, struct kobj_attribute *attr,
				       char *buf)
{
	const struct cdh_pixel6_cpufreq_target *target;

	target = cdh_pixel6_cpufreq_target_for_kobj(kobj);
	if (!target)
		return -ENODEV;
	return sysfs_emit(buf, "%s\n", cdh_pixel6_cpufreq_value(target, attr->attr.name));
}

static struct kobj_attribute affected_cpus_attr =
	__ATTR(affected_cpus, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute related_cpus_attr =
	__ATTR(related_cpus, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute cpuinfo_min_freq_attr =
	__ATTR(cpuinfo_min_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute cpuinfo_max_freq_attr =
	__ATTR(cpuinfo_max_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute cpuinfo_cur_freq_attr =
	__ATTR(cpuinfo_cur_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute scaling_min_freq_attr =
	__ATTR(scaling_min_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute scaling_max_freq_attr =
	__ATTR(scaling_max_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute scaling_cur_freq_attr =
	__ATTR(scaling_cur_freq, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute scaling_governor_attr =
	__ATTR(scaling_governor, 0444, cdh_pixel6_cpufreq_show, NULL);
static struct kobj_attribute scaling_available_governors_attr =
	__ATTR(scaling_available_governors, 0444, cdh_pixel6_cpufreq_show, NULL);

static struct attribute *cdh_pixel6_cpufreq_attrs[] = {
	&affected_cpus_attr.attr,
	&related_cpus_attr.attr,
	&cpuinfo_min_freq_attr.attr,
	&cpuinfo_max_freq_attr.attr,
	&cpuinfo_cur_freq_attr.attr,
	&scaling_min_freq_attr.attr,
	&scaling_max_freq_attr.attr,
	&scaling_cur_freq_attr.attr,
	&scaling_governor_attr.attr,
	&scaling_available_governors_attr.attr,
	NULL,
};

static const struct attribute_group cdh_pixel6_cpufreq_attr_group = {
	.attrs = cdh_pixel6_cpufreq_attrs,
};

/* Keep cleanup symmetric with partial init failure; each CPU owns one child kobj. */
void cdh_pixel6_cpufreq_sysfs_exit(void)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cdh_pixel6_cpufreq_targets); i++) {
		struct cdh_pixel6_cpufreq_target *target = &cdh_pixel6_cpufreq_targets[i];

		if (!target->kobj)
			continue;
		sysfs_remove_group(target->kobj, &cdh_pixel6_cpufreq_attr_group);
		kobject_put(target->kobj);
		target->kobj = NULL;
	}
	pr_info("removed readonly cpufreq sysfs nodes\n");
}

int cdh_pixel6_cpufreq_sysfs_init(void)
{
	size_t i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(cdh_pixel6_cpufreq_targets); i++) {
		struct cdh_pixel6_cpufreq_target *target = &cdh_pixel6_cpufreq_targets[i];
		struct device *cpu_dev;

		cpu_dev = get_cpu_device(target->cpu);
		if (!cpu_dev) {
			ret = -ENODEV;
			goto fail;
		}
		/* Attach below /sys/devices/system/cpu/cpuN so file readers see the canonical path. */
		target->kobj = kobject_create_and_add("cpufreq", &cpu_dev->kobj);
		if (!target->kobj) {
			ret = -ENOMEM;
			goto fail;
		}
		ret = sysfs_create_group(target->kobj, &cdh_pixel6_cpufreq_attr_group);
		if (ret)
			goto fail;
	}
	pr_info("created readonly cpufreq sysfs nodes for Pixel6 targets\n");
	return 0;

fail:
	pr_err("failed to create cpufreq sysfs nodes:%d\n", ret);
	cdh_pixel6_cpufreq_sysfs_exit();
	return ret;
}
