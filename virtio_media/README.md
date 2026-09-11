<!-- Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course) -->

# Pixel6-15 virtio-media驱动源码

本目录保存Pixel6 Android15 Guest使用的virtio-media内核驱动源码。初始代码来自
`https://github.com/chromeos/virtio-media.git`的`v0.0.8`标签，并保留上游
`BSD-3-Clause OR GPL-2.0+`双许可证与原始版权声明。

设备仓在上游驱动基础上维护以下集成变化：

- Kbuild输出名称固定为`cdh_media.ko`，对应`modinfo name=cdh_media`；
- Guest通过模块参数`allow_userptr=1`启用Android Codec2所需的USERPTR队列；
- 宿主上报不可恢复的会话错误后，驱动保存首次错误并停止该会话后续ioctl与mmap；
- 错误事件唤醒阻塞中的DQBUF与poll，poll回读`EPOLLERR`；
- 会话内存、描述符表和V4L2文件状态保留到应用关闭文件时再释放，避免仍在运行的
  Codec2线程访问已释放资源；终止错误已经关闭宿主会话，因此文件关闭时不重复发送命令。

事件处理与文件关闭均使用设备命令锁保护会话生命周期，事件锁只在设备命令锁内部获取。
订阅初始V4L2事件时调用已持锁入口，异步事件工作线程则先获取设备命令锁，从而保持固定锁序。

## 构建与发布

`tools/kernel/build-kernel.sh`从设备仓当前工作树和`kernel/`当前分支构建
Pixel6 Android15内核与全部设备模块。当前构建配方为
`lineage-22.1-gki-virtio-wifi-pixel6-modules-v12`，发布模块必须带
`6.6.127-4k-cdh` vermagic，并与同目录`Module.symvers`完成MODPOST。

正式产物发布到
`prebuilts/kernel/15/lineage-22.1-pixel6-15/modules/cdh_media.ko`，由发布目录的
`SHA256SUMS`校验产物。项目不保存源码内容摘要元数据；源码版本由设备仓当前工作树和
已登记的内核子仓分支确定。
