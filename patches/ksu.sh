# Patches author: weishu <twsxtd@gmail.com>
# Shell author: xiaoleGun <1592501605@qq.com>
# Adapted from https://github.com/xiaoleGun/KernelSU_Action/

# fs/ changes
## exec.c
if [ -z "$(grep "ksu" fs/exec.c)" ]; then
    sed -i '/static int do_execveat_common/i\#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n                        void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n                         void *argv, void *envp, int *flags);\n#endif' fs/exec.c
    if grep -q "return __do_execve_file(fd, filename, argv, envp, flags, NULL);" fs/exec.c; then
        sed -i '/return __do_execve_file(fd, filename, argv, envp, flags, NULL);/i\    #ifdef CONFIG_KSU\n    if (unlikely(ksu_execveat_hook))\n        ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n    else\n        ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n    #endif' fs/exec.c
    else
        sed -i '/if (IS_ERR(filename))/i\    #ifdef CONFIG_KSU\n    if (unlikely(ksu_execveat_hook))\n        ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n    else\n        ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n    #endif\n' fs/exec.c
    fi
fi

## open.c
if [ -z "$(grep "ksu" fs/open.c)" ]; then
    if grep -q "long do_faccessat(int dfd, const char __user \*filename, int mode)" fs/open.c; then
        sed -i '/long do_faccessat(int dfd, const char __user \*filename, int mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
    else
        sed -i '/SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
    fi
    sed -i '/if (mode & ~S_IRWXO)/i\    #ifdef CONFIG_KSU\n    ksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n    #endif\n' fs/open.c
fi

## read_write.c
if [ -z "$(grep "ksu" fs/read_write.c)" ]; then
    sed -i '/ssize_t vfs_read(struct file/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n        size_t *count_ptr, loff_t **pos);\n#endif' fs/read_write.c
    sed -i '/if (unlikely(!access_ok(VERIFY_WRITE, buf, count)))/i\    #ifdef CONFIG_KSU\n    if (unlikely(ksu_vfs_read_hook))\n        ksu_handle_vfs_read(&file, &buf, &count, &pos);\n    #endif' fs/read_write.c
fi

## stat.c
if [ -z "$(grep "ksu" fs/stat.c)" ]; then
    if grep -q "int vfs_statx(int dfd, const char __user \*filename, int flags," fs/stat.c; then
        sed -i '/int vfs_statx(int dfd, const char __user \*filename, int flags,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
        sed -i '/unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\\n    #ifdef CONFIG_KSU\n    ksu_handle_stat(&dfd, &filename, &flags);\n    #endif' fs/stat.c
    else
        sed -i '/int vfs_fstatat(int dfd, const char __user \*filename, struct kstat *stat,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
        sed -i '/if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |/i\\n    #ifdef CONFIG_KSU\n    ksu_handle_stat(&dfd, &filename, &flag);\n    #endif\n' fs/stat.c
    fi
fi

# drivers/input changes
## input.c
if [ -z "$(grep "ksu" drivers/input/input.c)" ]; then
    sed -i '/static void input_handle_event/i\#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif' drivers/input/input.c
    sed -i '/if (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)/i\    #ifdef CONFIG_KSU\n    if (unlikely(ksu_input_hook))\n        ksu_handle_input_handle_event(&type, &code, &value);\n    #endif' drivers/input/input.c
fi

echo "Kernel is patched for KernelSU"
