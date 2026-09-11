// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
 */
#define pr_fmt(fmt) "cdh_device_info: uts: " fmt

#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/utsname.h>

#include "cdh_device_info.h"

#define CDH_UNAME_SYSNAME "Linux"
#define CDH_UNAME_NODENAME "localhost"
#define CDH_UNAME_RELEASE "6.6.89-android15-8-gbe8d201b0d27-ab13762941-4k"
#define CDH_UNAME_VERSION "#1 SMP PREEMPT Thu Jul 10 06:35:14 UTC 2025"
#define CDH_UNAME_MACHINE "aarch64"
#define CDH_UNAME_DOMAINNAME "(none)"

static struct new_utsname cdh_original_uts;
static bool cdh_original_uts_saved;

static void cdh_set_uts_field(char *dst, const char *src)
{
	strscpy(dst, src, __NEW_UTS_LEN + 1);
}

static void cdh_patch_utsname(struct new_utsname *uts)
{
	cdh_set_uts_field(uts->sysname, CDH_UNAME_SYSNAME);
	cdh_set_uts_field(uts->nodename, CDH_UNAME_NODENAME);
	cdh_set_uts_field(uts->release, CDH_UNAME_RELEASE);
	cdh_set_uts_field(uts->version, CDH_UNAME_VERSION);
	cdh_set_uts_field(uts->machine, CDH_UNAME_MACHINE);
	cdh_set_uts_field(uts->domainname, CDH_UNAME_DOMAINNAME);
}

int cdh_uts_init(void)
{
	cdh_original_uts = init_uts_ns.name;
	cdh_original_uts_saved = true;
	cdh_patch_utsname(&init_uts_ns.name);

	pr_info("patched init_uts_ns release=%s version=%s\n",
		init_uts_ns.name.release, init_uts_ns.name.version);
	return 0;
}

void cdh_uts_exit(void)
{
	if (cdh_original_uts_saved)
		init_uts_ns.name = cdh_original_uts;
	pr_info("restored init_uts_ns release=%s version=%s\n",
		init_uts_ns.name.release, init_uts_ns.name.version);
}
