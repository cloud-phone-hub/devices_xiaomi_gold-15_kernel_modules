/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0+ */

/* Cloud Droid Hub integration Copyright (c) 2025-2026 fei_cong. */

#ifndef __VIRTIO_MEDIA_CREATE_BUFS_RANGE_H
#define __VIRTIO_MEDIA_CREATE_BUFS_RANGE_H

#ifdef __KERNEL__
#include <linux/errno.h>
#include <linux/types.h>
typedef u32 vm_u32;
#else
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t vm_u32;
#endif

#include "session_lifecycle.h"

static inline int vm_buf_range(size_t allocated, vm_u32 index, vm_u32 count,
			       size_t element_size, size_t *new_count,
			       size_t *new_bytes)
{
	const vm_u32 max_index = (vm_u32)~0U;
	size_t total;

	if (!element_size || !new_count || !new_bytes)
		return -EINVAL;
	if (allocated > max_index || index != allocated)
		return -EPROTO;
	if (count > max_index - index ||
	    (size_t)count > (size_t)-1 - allocated)
		return -EOVERFLOW;

	total = allocated + count;
	if (total > (size_t)-1 / element_size)
		return -EOVERFLOW;

	*new_count = total;
	*new_bytes = total * element_size;
	return 0;
}

static inline int vm_check_range(
	struct virtio_media_session_lifecycle *lifecycle, size_t allocated,
	vm_u32 index, vm_u32 count, size_t element_size, size_t *new_count,
	size_t *new_bytes)
{
	int ret = vm_buf_range(allocated, index, count, element_size, new_count,
			       new_bytes);

	if (!ret)
		return 0;
	return virtio_media_session_fail(lifecycle, (unsigned int)-ret);
}

#endif // __VIRTIO_MEDIA_CREATE_BUFS_RANGE_H
