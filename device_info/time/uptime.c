// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_device_info_uptime: " fmt

#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/limits.h>
#include <linux/moduleparam.h>
#include <linux/ptrace.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/sysinfo.h>
#include <linux/uaccess.h>
#include <uapi/linux/kernel.h>

#include "cdh_device_info.h"

#define CDH_UPTIME_OFFSET_SECONDS (2 * 24 * 60 * 60L)
#define CDH_UPTIME_KRETPROBE_MAXACTIVE 64

static long cdh_uptime_offset_seconds = CDH_UPTIME_OFFSET_SECONDS;
module_param_named(uptime_offset_seconds, cdh_uptime_offset_seconds, long, 0444);
MODULE_PARM_DESC(uptime_offset_seconds, "Seconds added to app-visible  uptime sources");

struct cdh_sysinfo_data {
	struct sysinfo __user *user_info;
};

struct cdh_uptime_proc_data {
	struct seq_file *seq;
};

static bool cdh_sysinfo_registered;
static bool cdh_uptime_proc_registered;

static long cdh_adjust_uptime(long uptime)
{
	if (cdh_uptime_offset_seconds <= 0 || uptime < 0)
		return uptime;
	if (uptime > LONG_MAX - cdh_uptime_offset_seconds)
		return uptime;
	return uptime + cdh_uptime_offset_seconds;
}

static int cdh_sysinfo_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cdh_sysinfo_data *data = (struct cdh_sysinfo_data *)ri->data;

	data->user_info = NULL;
#ifdef CONFIG_ARM64
	if (regs->regs[0]) {
		struct pt_regs *syscall_regs = (struct pt_regs *)regs->regs[0];

		/*
		 * __arm64_sys_sysinfo() receives the syscall pt_regs as x0; the
		 * userspace struct sysinfo pointer is the original syscall x0.
		 */
		data->user_info = (struct sysinfo __user *)syscall_regs->regs[0];
	}
#else
	return -EOPNOTSUPP;
#endif
	return 0;
}

static int cdh_sysinfo_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cdh_sysinfo_data *data = (struct cdh_sysinfo_data *)ri->data;
	struct sysinfo info;
	long old_uptime;
	long new_uptime;

	if (regs_return_value(regs) != 0 || !data->user_info)
		return 0;
	if (copy_from_user(&info, data->user_info, sizeof(info)))
		return 0;

	old_uptime = info.uptime;
	new_uptime = cdh_adjust_uptime(old_uptime);
	if (new_uptime == old_uptime)
		return 0;

	info.uptime = new_uptime;
	if (copy_to_user(data->user_info, &info, sizeof(info)))
		pr_warn_once("failed to copy adjusted sysinfo uptime to userspace\n");
	return 0;
}

static struct kretprobe cdh_sysinfo_kretprobe = {
	.handler = cdh_sysinfo_ret,
	.entry_handler = cdh_sysinfo_entry,
	.data_size = sizeof(struct cdh_sysinfo_data),
	.maxactive = CDH_UPTIME_KRETPROBE_MAXACTIVE,
	.kp = {
		.symbol_name = "__arm64_sys_sysinfo",
	},
};

static int cdh_uptime_proc_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cdh_uptime_proc_data *data = (struct cdh_uptime_proc_data *)ri->data;

#ifdef CONFIG_ARM64
	data->seq = (struct seq_file *)regs->regs[0];
#else
	data->seq = NULL;
	return -EOPNOTSUPP;
#endif
	return 0;
}

static bool cdh_parse_proc_uptime(const char *buf, size_t count,
					 unsigned long *seconds,
					 unsigned int *centiseconds,
					 const char **rest, size_t *rest_len)
{
	size_t i = 0;
	unsigned long sec = 0;
	unsigned int frac = 0;
	unsigned int frac_digits = 0;

	if (!buf || !count || !seconds || !centiseconds || !rest || !rest_len)
		return false;
	while (i < count && buf[i] >= '0' && buf[i] <= '9') {
		sec = sec * 10 + (buf[i] - '0');
		i++;
	}
	if (i >= count || buf[i] != '.')
		return false;
	i++;
	while (i < count && buf[i] >= '0' && buf[i] <= '9') {
		if (frac_digits < 2)
			frac = frac * 10 + (buf[i] - '0');
		frac_digits++;
		i++;
	}
	while (frac_digits < 2) {
		frac *= 10;
		frac_digits++;
	}
	if (i >= count || buf[i] != ' ')
		return false;
	*seconds = sec;
	*centiseconds = frac;
	*rest = buf + i;
	*rest_len = count - i;
	return true;
}

static int cdh_uptime_proc_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cdh_uptime_proc_data *data = (struct cdh_uptime_proc_data *)ri->data;
	struct seq_file *m = data->seq;
	unsigned long seconds;
	unsigned int centiseconds;
	const char *rest;
	size_t rest_len;
	long adjusted;
	char line[128];
	int line_len;

	if (regs_return_value(regs) != 0 || !m || !m->buf || !m->count)
		return 0;
	if (!cdh_parse_proc_uptime(m->buf, m->count, &seconds,
					  &centiseconds, &rest, &rest_len))
		return 0;

	adjusted = cdh_adjust_uptime((long)seconds);
	if (adjusted < 0 || adjusted == (long)seconds)
		return 0;

	/*
	 * Keep the idle-time column intact and rewrite only the first column so
	 * /proc/uptime agrees with sysinfo(2) for app-visible boot age checks.
	 */
	line_len = scnprintf(line, sizeof(line), "%ld.%02u%.*s",
			     adjusted, centiseconds, (int)rest_len, rest);
	if (line_len <= 0 || line_len >= sizeof(line) || line_len > m->size) {
		pr_warn_once("cannot rewrite /proc/uptime line len=%d size=%zu\n",
			     line_len, m->size);
		return 0;
	}
	memcpy(m->buf, line, line_len);
	m->count = line_len;
	return 0;
}

static struct kretprobe cdh_uptime_proc_kretprobe = {
	.handler = cdh_uptime_proc_ret,
	.entry_handler = cdh_uptime_proc_entry,
	.data_size = sizeof(struct cdh_uptime_proc_data),
	.maxactive = CDH_UPTIME_KRETPROBE_MAXACTIVE,
	.kp = {
		.symbol_name = "uptime_proc_show",
	},
};

int cdh_time_uptime_init(void)
{
	int ret;

	ret = register_kretprobe(&cdh_sysinfo_kretprobe);
	if (ret) {
		pr_err("failed to register sysinfo kretprobe:%d\n", ret);
		return ret;
	}
	cdh_sysinfo_registered = true;

	ret = register_kretprobe(&cdh_uptime_proc_kretprobe);
	if (ret) {
		unregister_kretprobe(&cdh_sysinfo_kretprobe);
		cdh_sysinfo_registered = false;
		pr_err("failed to register uptime_proc_show kretprobe:%d\n", ret);
		return ret;
	}
	cdh_uptime_proc_registered = true;
	pr_info("registered uptime offset hooks offset_seconds=%ld\n",
		cdh_uptime_offset_seconds);
	return 0;
}

void cdh_time_uptime_exit(void)
{
	if (cdh_uptime_proc_registered) {
		unregister_kretprobe(&cdh_uptime_proc_kretprobe);
		cdh_uptime_proc_registered = false;
	}
	if (cdh_sysinfo_registered) {
		unregister_kretprobe(&cdh_sysinfo_kretprobe);
		cdh_sysinfo_registered = false;
	}
	pr_info("unregistered uptime offset hooks\n");
}
