#include <linux/mm.h>
#include <linux/kprobes.h>

typedef int (*shmem_zero_setup_ptr_t)(struct vm_area_struct *);
static shmem_zero_setup_ptr_t shmem_zero_setup_ptr = NULL;

static int resolve_shmem_zero_setup(void)
{
	struct kprobe kp = { .symbol_name = "shmem_zero_setup" };
	int ret = register_kprobe(&kp);

	if (ret < 0)
		return ret;
	shmem_zero_setup_ptr = (shmem_zero_setup_ptr_t) kp.addr;
	unregister_kprobe(&kp);
	return shmem_zero_setup_ptr ? 0 : -ENOENT;
}

int shmem_zero_setup(struct vm_area_struct *vma)
{
	if (!shmem_zero_setup_ptr) {
		int ret = resolve_shmem_zero_setup();

		if (ret)
			return ret;
	}
	return shmem_zero_setup_ptr(vma);
}
