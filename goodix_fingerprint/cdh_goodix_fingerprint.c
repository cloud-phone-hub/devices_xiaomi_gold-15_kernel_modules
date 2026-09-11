// Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
#include <linux/init.h>
#include <linux/input.h>
#include <linux/module.h>
#include <linux/platform_device.h>

#define CDH_GOODIX_DRIVER_NAME "goodix_fp"
#define CDH_GOODIX_INPUT_NAME "goodix_fingerprint"

static struct input_dev *cdh_goodix_input;

static struct platform_driver cdh_goodix_platform_driver = {
    .driver =
        {
            .name = "goodix_fp",
            .owner = THIS_MODULE,
        },
};

static const unsigned int cdh_goodix_keys[] = {
    KEY_HOME,       KEY_UP,       KEY_LEFT,   KEY_RIGHT, KEY_DOWN,
    KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_POWER,  KEY_MENU,  KEY_BACK,
    KEY_CAMERA,     KEY_CHAT,     KEY_SEARCH,
};

static int cdh_goodix_register_input(void) {
  struct input_dev *input;
  int ret;
  size_t i;

  input = input_allocate_device();
  if (!input)
    return -ENOMEM;

  input->name = CDH_GOODIX_INPUT_NAME;
  input->phys = "cdh/goodix_fingerprint/input0";
  input->id.bustype = 0;
  input->id.vendor = 0;
  input->id.product = 0;
  input->id.version = 0;

  for (i = 0; i < ARRAY_SIZE(cdh_goodix_keys); i++)
    input_set_capability(input, EV_KEY, cdh_goodix_keys[i]);

  ret = input_register_device(input);
  if (ret) {
    input_free_device(input);
    return ret;
  }

  cdh_goodix_input = input;
  return 0;
}

static void cdh_goodix_unregister_input(void) {
  if (!cdh_goodix_input)
    return;
  input_unregister_device(cdh_goodix_input);
  cdh_goodix_input = NULL;
}

static int __init cdh_goodix_init(void) {
  int ret;

  ret = platform_driver_register(&cdh_goodix_platform_driver);
  if (ret)
    return ret;

  ret = cdh_goodix_register_input();
  if (ret) {
    platform_driver_unregister(&cdh_goodix_platform_driver);
    return ret;
  }

  pr_info("cdh_goodix_fingerprint: registered %s and %s\n",
          CDH_GOODIX_DRIVER_NAME, CDH_GOODIX_INPUT_NAME);
  return 0;
}

static void __exit cdh_goodix_exit(void) {
  cdh_goodix_unregister_input();
  platform_driver_unregister(&cdh_goodix_platform_driver);
  pr_info("cdh_goodix_fingerprint: removed\n");
}

module_init(cdh_goodix_init);
module_exit(cdh_goodix_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("fei_cong <fei_cong@hotmail.com>");
MODULE_DESCRIPTION("Read-only  Android15 Goodix fingerprint sysfs/input "
                   "enumerator for CDH");
