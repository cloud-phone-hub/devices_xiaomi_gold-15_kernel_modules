# SPDX-License-Identifier: GPL-2.0
# 与 device_info 等同构：out-of-tree 构建入口，须由 build-kernel.sh 以
# `make M=/src/kernel/modules/mali_vgpu modules` 调用（KDIR 指向内核输出树）。
KERNEL_SRC ?= $(KDIR)

ifeq ($(strip $(KERNEL_SRC)),)
$(error KERNEL_SRC or KDIR is required; run this project through `dddk build --target android15-6.6`)
endif

M := $(CURDIR)

.PHONY: modules clean

modules:
	$(MAKE) -C $(KERNEL_SRC) M=$(M) modules

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(M) clean
