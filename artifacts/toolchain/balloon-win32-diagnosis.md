# Windows ARM64 ballooning is disabled after failed validation

The runtime's live balloon request from 6144 MiB to 4096 MiB made SSH and ADB unresponsive. Restoring the target did not restore responsiveness. The Windows process working set fell, but the QMP actual-memory reading did not establish a completed, healthy guest memory adjustment. This is a failed experiment, not validated memory reclamation.

The failed QEMU log, preserved as `artifacts/acceptance/balloon-qemu-errors.log`, records unsupported host RAM discard during inflation and an unsupported page hint during deflation. Counts are retained in `balloon-win32-evidence.json`. The beginning of the log reports `MADVISE not available` for individual guest RAM pages. This directly establishes that the host discard operation was unavailable in this build.

QEMU 11.1.2 `system/physmem.c`, `ram_block_discard_shared_range()`, returns `-ENOSYS` on its ordinary anonymous-RAM discard path when `CONFIG_MADVISE` is absent. The observed inflate errors match that path. In `include/qemu/madvise.h`, platforms without supported POSIX memory-advice APIs map `QEMU_MADV_WILLNEED` to an invalid sentinel. `util/osdep.c`, `qemu_madvise()`, turns that sentinel into `EINVAL`. `hw/virtio/virtio-balloon.c`, `balloon_deflate_page()`, logs the matching warning and ignores the failed hint as nonfatal. This code does not implement a Windows `PrefetchVirtualMemory` replacement for that hint.

These source paths explain the memory-advice errors. They do not prove the exact guest hang mechanism. Guest memory pressure, balloon completion behavior, or a further interaction with WHPX would require a separate controlled diagnostic. An apparent process working-set reduction alone cannot demonstrate correct host memory reclamation or acceptable guest health.

The working package should omit `virtio-balloon-pci` and reject live reclamation on this backend. Use fixed boot-time memory sizes for its performance profiles. No automatic ballooning, working dynamic memory reclamation, or memory-reclaim efficiency gain is claimed. No unverified memory-management patch was applied.

Sources:

- [QEMU 11.1.2 RAM discard implementation](https://github.com/qemu/qemu/blob/v11.1.2/system/physmem.c)
- [Memory advice constants](https://github.com/qemu/qemu/blob/v11.1.2/include/qemu/madvise.h)
- [Memory advice wrapper](https://github.com/qemu/qemu/blob/v11.1.2/util/osdep.c)
- [VirtIO balloon implementation](https://github.com/qemu/qemu/blob/v11.1.2/hw/virtio/virtio-balloon.c)

Downloaded source excerpts remain under `artifacts/toolchain/sources`.
