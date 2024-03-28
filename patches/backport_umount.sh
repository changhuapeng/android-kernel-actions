#!/bin/bash

# Patches author: OnlyTomInSecond <q2781273965@gmail.com>
# Adapted from https://github.com/tiann/KernelSU/discussions/955#discussioncomment-7854955

# fs/namespace.c
PATCH=$(cat <<__EOF__
static int can_umount(const struct path *path, int flags)
{
        struct mount *mnt = real_mount(path->mnt);

        if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
                return -EINVAL;
        if (!may_mount())
                return -EPERM;
        if (path->dentry != path->mnt->mnt_root)
                return -EINVAL;
        if (!check_mnt(mnt))
                return -EINVAL;
        if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
                return -EINVAL;
        if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
                return -EPERM;
        return 0;
}

int path_umount(struct path *path, int flags)
{
        struct mount *mnt = real_mount(path->mnt);
        int ret;

        ret = can_umount(path, flags);
        if (!ret)
                ret = do_umount(mnt, flags);

        /* we mustn't call path_put() as that would clear mnt_expiry_mark */
        dput(path->dentry);
        mntput_no_expire(mnt);
        return ret;
}
__EOF__
)

if ! grep -q "int path_umount" fs/namespace.c; then
    ns_line_num=$(grep -n "\*.*Now umount can handle mount points as well as block devices\." fs/namespace.c | awk -F: '{print $1}')

    if [[ $(sed "$((ns_line_num - 1))"'!d' fs/namespace.c) = "/*" ]]; then
        preprocessed_PATCH=$(printf '%s\n' "$PATCH" | sed 's/\\/&&/g;s/^[[:blank:]]/\\&/;s/$/\\/')
        sed -i -e "$((ns_line_num - 1))"'i \'"${preprocessed_PATCH%?}" fs/namespace.c
    fi
else
    echo "Warning: Found path_umount function in kernel"
fi
