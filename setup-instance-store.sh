#!/bin/bash
# This script requires root privileges.
# It will format /dev/nvme1n1, mount it to /mnt/nvme, create subdirectories,
# and then bind mount the subdirectories to /tmp and /var/cache.

set -e

# 1. Check if /dev/nvme1n1 exists
if [ ! -b /dev/nvme1n1 ]; then
    echo "Error: /dev/nvme1n1 does not exist. Exiting."
    exit 1
fi

echo "Device /dev/nvme1n1 found."

# 2. Format /dev/nvme1n1 with an ext4 filesystem
# Note: The -F flag forces formatting. This will erase any data on /dev/nvme1n1.
echo "Formatting /dev/nvme1n1 with ext4 filesystem..."
mkfs.ext4 -F /dev/nvme1n1

# 3. Create the mount point for the NVMe device if it does not exist
echo "Creating mount point /mnt/nvme..."
mkdir -p /mnt/nvme

# 4. Mount /dev/nvme1n1 to /mnt/nvme
echo "Mounting /dev/nvme1n1 to /mnt/nvme..."
mount /dev/nvme1n1 /mnt/nvme

# 5. Create the subdirectories /mnt/nvme/tmp and /mnt/nvme/var/cache if they don't exist
echo "Creating directories /mnt/nvme/tmp and /mnt/nvme/var/cache..."
mkdir -p /mnt/nvme/tmp
mkdir -p /mnt/nvme/var/cache

# 5a. Copy existing /tmp contents to /mnt/nvme/tmp
echo "Copying existing /tmp contents to /mnt/nvme/tmp..."
# The trailing slash on /tmp/ copies the content inside the directory.
rsync -a --delete /tmp/ /mnt/nvme/tmp/

# 5b. Copy existing /var/cache contents to /mnt/nvme/var/cache
echo "Copying existing /var/cache contents to /mnt/nvme/var/cache..."
rsync -a --delete /var/cache/ /mnt/nvme/var/cache/


# 6. Bind mount the directories to /tmp and /var/cache
echo "Bind mounting /mnt/nvme/tmp to /tmp..."
mount --bind /mnt/nvme/tmp /tmp

chmod 1777 /tmp

echo "Bind mounting /mnt/nvme/var/cache to /var/cache..."
mount --bind /mnt/nvme/var/cache /var/cache

echo "All operations completed successfully."