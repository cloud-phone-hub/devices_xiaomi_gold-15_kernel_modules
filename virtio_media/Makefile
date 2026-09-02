# Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)

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
