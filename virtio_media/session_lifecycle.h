/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0+ */

/* Cloud Droid Hub integration Copyright (c) 2025-2026 fei_cong. */

#ifndef __VIRTIO_MEDIA_SESSION_LIFECYCLE_H
#define __VIRTIO_MEDIA_SESSION_LIFECYCLE_H

#ifdef __KERNEL__
#include <linux/compiler.h>
#include <linux/errno.h>
#include <linux/types.h>
#else
#include <errno.h>
#include <stdbool.h>
#endif

#define VIRTIO_MEDIA_MAX_HOST_ERRNO 4095U

struct virtio_media_session_lifecycle {
	unsigned int error;
};

static inline unsigned int virtio_media_session_error(
	const struct virtio_media_session_lifecycle *lifecycle)
{
#ifdef __KERNEL__
	return READ_ONCE(lifecycle->error);
#else
	return lifecycle->error;
#endif
}

static inline void virtio_media_session_set_error(
	struct virtio_media_session_lifecycle *lifecycle, unsigned int error)
{
#ifdef __KERNEL__
	WRITE_ONCE(lifecycle->error, error);
#else
	lifecycle->error = error;
#endif
}

static inline void virtio_media_session_lifecycle_init(
	struct virtio_media_session_lifecycle *lifecycle)
{
	virtio_media_session_set_error(lifecycle, 0);
}

static inline int virtio_media_session_command_status(
	const struct virtio_media_session_lifecycle *lifecycle)
{
	unsigned int error = virtio_media_session_error(lifecycle);

	return error ? -(int)error : 0;
}

static inline int virtio_media_session_fail(
	struct virtio_media_session_lifecycle *lifecycle,
	unsigned int host_error)
{
	if (!host_error || host_error > VIRTIO_MEDIA_MAX_HOST_ERRNO)
		host_error = EIO;
	if (!virtio_media_session_error(lifecycle))
		virtio_media_session_set_error(lifecycle, host_error);
	return virtio_media_session_command_status(lifecycle);
}

static inline bool virtio_media_session_has_failed(
	const struct virtio_media_session_lifecycle *lifecycle)
{
	return virtio_media_session_error(lifecycle) != 0;
}

static inline bool virtio_media_session_should_notify_close(
	const struct virtio_media_session_lifecycle *lifecycle)
{
	return !virtio_media_session_has_failed(lifecycle);
}

#endif // __VIRTIO_MEDIA_SESSION_LIFECYCLE_H
