// Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/sysfs.h>

#define CDH_CPU_PROC_NAME "cdh_cpu_profile"
#define CDH_CPU_PROC_PATH "/proc/cdh_cpu_profile"
#define CDH_CPU_SYSFS_NAME "cdh_cpu"
#define CDH_CPU_SYSFS_PATH "/sys/kernel/cdh_cpu"

static struct proc_dir_entry *cdh_cpu_proc;
static struct kobject *cdh_cpu_kobj;

static const char cdh_cpu_profile[] =
	"device=note13-5g-15\n"
	"android=15\n"
	"source= Redmi Note 13 5G (gold) OS3.0.9.0.VNQCNXM real device\n"
	"features=fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp\n"
	"cluster0=cpu0-5 cortex-a55 capacity=356 min=500000 max=2000000 midr=0x00000000412fd050\n"
	"cluster1=cpu6-7 cortex-a76 capacity=1024 min=725000 max=2400000 midr=0x00000000414fd0b0\n";

static const char cdh_cpu_clusters[] =
	"cpu0-5 affected=0 1 2 3 4 5 related=0 1 2 3 4 5 capacity=356\n"
	"cpu6-7 affected=6 7 related=6 7 capacity=1024\n";

static const char cdh_cpu_midr_el1[] =
	"cpu0=0x00000000412fd050\n"
	"cpu1=0x00000000412fd050\n"
	"cpu2=0x00000000412fd050\n"
	"cpu3=0x00000000412fd050\n"
	"cpu4=0x00000000412fd050\n"
	"cpu5=0x00000000412fd050\n"
	"cpu6=0x00000000414fd0b0\n"
	"cpu7=0x00000000414fd0b0\n";

static const char cdh_cpu_cpufreq[] =
	"cpu0-5 governor=schedutil min=500000 max=2000000 cur=2000000\n"
	"cpu6-7 governor=schedutil min=725000 max=2400000 cur=2400000\n";

static int cdh_cpu_proc_show(struct seq_file *m, void *v)
{
	seq_puts(m, cdh_cpu_profile);
	return 0;
}

static int cdh_cpu_proc_open(struct inode *inode, struct file *file)
{
	return single_open(file, cdh_cpu_proc_show, NULL);
}

static const struct proc_ops cdh_cpu_proc_ops = {
	.proc_open = cdh_cpu_proc_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static ssize_t profile_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s", cdh_cpu_profile);
}

static ssize_t clusters_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s", cdh_cpu_clusters);
}

static ssize_t midr_el1_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s", cdh_cpu_midr_el1);
}

static ssize_t cpufreq_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s", cdh_cpu_cpufreq);
}

static struct kobj_attribute profile_attr = __ATTR_RO(profile);
static struct kobj_attribute clusters_attr = __ATTR_RO(clusters);
static struct kobj_attribute midr_el1_attr = __ATTR_RO(midr_el1);
static struct kobj_attribute cpufreq_attr = __ATTR_RO(cpufreq);

static struct attribute *cdh_cpu_attrs[] = {
	&profile_attr.attr,
	&clusters_attr.attr,
	&midr_el1_attr.attr,
	&cpufreq_attr.attr,
	NULL,
};

static const struct attribute_group cdh_cpu_attr_group = {
	.attrs = cdh_cpu_attrs,
};

static int __init cdh_cpu_probe_init(void)
{
	int ret;

	cdh_cpu_proc = proc_create(CDH_CPU_PROC_NAME, 0444, NULL, &cdh_cpu_proc_ops);
	if (!cdh_cpu_proc)
		return -ENOMEM;

	cdh_cpu_kobj = kobject_create_and_add(CDH_CPU_SYSFS_NAME, kernel_kobj);
	if (!cdh_cpu_kobj) {
		proc_remove(cdh_cpu_proc);
		cdh_cpu_proc = NULL;
		return -ENOMEM;
	}

	ret = sysfs_create_group(cdh_cpu_kobj, &cdh_cpu_attr_group);
	if (ret) {
		kobject_put(cdh_cpu_kobj);
		cdh_cpu_kobj = NULL;
		proc_remove(cdh_cpu_proc);
		cdh_cpu_proc = NULL;
		return ret;
	}

	pr_info("cdh_cpu_probe: registered %s and %s\n",
		CDH_CPU_PROC_PATH, CDH_CPU_SYSFS_PATH);
	return 0;
}

static void __exit cdh_cpu_probe_exit(void)
{
	if (cdh_cpu_kobj) {
		sysfs_remove_group(cdh_cpu_kobj, &cdh_cpu_attr_group);
		kobject_put(cdh_cpu_kobj);
		cdh_cpu_kobj = NULL;
	}
	if (cdh_cpu_proc) {
		proc_remove(cdh_cpu_proc);
		cdh_cpu_proc = NULL;
	}
	pr_info("cdh_cpu_probe: removed\n");
}

module_init(cdh_cpu_probe_init);
module_exit(cdh_cpu_probe_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("fei_cong <fei_cong@hotmail.com>");
MODULE_DESCRIPTION("Read-only Android15 CPU profile probe for CDH");
