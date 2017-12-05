paramaters interper

```
// init
drive_new
    // loop for geting throttling parameters
    value = qemu_opt_get(all_opts, "cache");
    bdrv_parse_cache_mode(value, &flags, &writethrough)
        // first store value in all_opts, then bs_opts
    blockdev_init
        throttle_enable(&cfg);
        blk_set_enable_write_cache(blk, writethrough);
            blk->enable_write_cache = wce; // !!qemu_opt_get_bool(opts, BDRV_OPT_CACHE_WB, true);

// flush
blk_aio_write_entry
blk_co_pwritev
    /* throttling disk I/O */
    if (blk->public.throttle_group_member.throttle_state) {
        throttle_group_co_io_limits_intercept(&blk->public.throttle_group_member,
                bytes, true);
    }

    if (!blk->enable_write_cache) {
        flags |= BDRV_REQ_FUA;
    }
    bdrv_co_pwritev
        bdrv_aligned_pwritev
            bdrv_driver_pwritev
                emulate_flags:
                    if (ret == 0 && (flags & BDRV_REQ_FUA)) {
                        ret = bdrv_co_flush(bs);
                    }


int coroutine_fn bdrv_co_flush(BlockDriverState *bs)
{
...
    /* Write back all layers by calling one driver function */
    if (bs->drv->bdrv_co_flush) {
        ret = bs->drv->bdrv_co_flush(bs);
        goto out;
    }
    /*
     *  .bdrv_co_flush = throttle_co_flush
     *  ...
     *      bdrv_co_flush
     */

    /* Write back cached data to the OS even with cache=unsafe */
    BLKDBG_EVENT(bs->file, BLKDBG_FLUSH_TO_OS);
    if (bs->drv->bdrv_co_flush_to_os) {
        ret = bs->drv->bdrv_co_flush_to_os(bs);
        if (ret < 0) {
            goto out;
        }
    }
    /*
     *  .bdrv_co_flush_to_os = qcow2_co_flush_to_os
     *  ...
     *      qcow2_cache_write
     *          qcow2_cache_entry_flush (qcow2_cache_flush_dependency is the same except more steps)
     *              bdrv_flush
     *                  bdrv_flush_co_entry
     *                      bdrv_co_flush
     */

    /* But don't actually force it to the disk with cache=unsafe */
    if (bs->open_flags & BDRV_O_NO_FLUSH) {
        goto flush_parent;
    }

    /* Check if we really need to flush anything */
    if (bs->flushed_gen == current_gen) {
        goto flush_parent;
    }

    BLKDBG_EVENT(bs->file, BLKDBG_FLUSH_TO_DISK);
    if (!bs->drv) {
        /* bs->drv->bdrv_co_flush() might have ejected the BDS
         * (even in case of apparent success) */
        ret = -ENOMEDIUM;
        goto out;
    }
    if (bs->drv->bdrv_co_flush_to_disk) {
        ret = bs->drv->bdrv_co_flush_to_disk(bs);
        /*
         *  for QCOW2, it's NULL
         */
    } else if (bs->drv->bdrv_aio_flush) {
        BlockAIOCB *acb;
        CoroutineIOCompletion co = {
            .coroutine = qemu_coroutine_self(),
        };

        acb = bs->drv->bdrv_aio_flush(bs, bdrv_co_io_em_complete, &co);
        /*
         * block/file-posix.c
         *  .bdrv_aio_flush = raw_aio_flush
         *      paio_submit 两种AIO: POSIX AIO 与 Native AIO, 这里是 POSIX AIO
         *          thread_pool_submit_aio(pool, aio_worker, acb, cb, opaque) // run aio_worker
         *              handle_aiocb_flush
         *                  qemu_fdatasync
         *                      fdatasync or fsync
         */

        if (acb == NULL) {
            ret = -EIO;
        } else {
            qemu_coroutine_yield();
            ret = co.ret;
        }
    } else {
        /*
         * Some block drivers always operate in either writethrough or unsafe
         * mode and don't support bdrv_flush therefore. Usually qemu doesn't
         * know how the server works (because the behaviour is hardcoded or
         * depends on server-side configuration), so we can't ensure that
         * everything is safe on disk. Returning an error doesn't work because
         * that would break guests even if the server operates in writethrough
         * mode.
         *
         * Let's hope the user knows what he's doing.
         */
        ret = 0;
    }

    if (ret < 0) {
        goto out;
    }

    /* Now flush the underlying protocol.  It will also have BDRV_O_NO_FLUSH
     * in the case of cache=unsafe, so there are no useless flushes.
     */
flush_parent:
    ret = bs->file ? bdrv_co_flush(bs->file->bs) : 0;
    ...
}
```

```
// block/file-posix.c
.bdrv_file_open = raw_open
    raw_open_common
        raw_parse_flags(bdrv_flags, &s->open_flags);
                /* Use O_DSYNC for write-through caching, no flags for write-back caching,
                 * and O_DIRECT for no caching. */
                if ((bdrv_flags & BDRV_O_NOCACHE)) {
                    *open_flags |= O_DIRECT;
                }
        fd = qemu_open(filename, s->open_flags, 0644);
            open
```

static int coroutine_fn raw_co_prw(BlockDriverState *bs, uint64_t offset,
                                   uint64_t bytes, QEMUIOVector *qiov, int type)
{
    BDRVRawState *s = bs->opaque;

    if (fd_open(bs) < 0)
        return -EIO;

    /*
     * Check if the underlying device requires requests to be aligned,
     * and if the request we are trying to submit is aligned or not.
     * If this is the case tell the low-level driver that it needs
     * to copy the buffer.
     */
    if (s->needs_alignment) {
        if (!bdrv_qiov_is_aligned(bs, qiov)) {
            type |= QEMU_AIO_MISALIGNED;
#ifdef CONFIG_LINUX_AIO
        } else if (s->use_linux_aio) {
            LinuxAioState *aio = aio_get_linux_aio(bdrv_get_aio_context(bs));
            assert(qiov->size == bytes);
            return laio_co_submit(bs, aio, s->fd, offset, qiov, type);
#endif
        }
    }

    return paio_submit_co(bs, s->fd, offset, qiov, bytes, type);
}

