#!/bin/sh

mnt_fs() {
  mount -t devtmpfs -o mode=0755 dev /dev
  mount -t sysfs sys /sys
  mount -t proc proc /proc

  # Read /etc/fstab (Commented out since we don't have one)
  # mount -a
}

coldplug() {
  # Execute mdev every time a device node related event is triggered
  echo /sbin/mdev > /proc/sys/kernel/hotplug

  # The -s flag tells mdev to trigger events for initial node population
  # which would then be handled by mdev itself when it is fork+exec'd by the kernel
  /sbin/mdev -s
}

misc() {
  echo "installgentoo" > /proc/sys/kernel/hostname
  ip link set up dev lo

  # Print out the time taken for the boot process
  IFS=. read -r boot_time _ < /proc/uptime
  echo "Boot stage completed in ${boot_time}s"
}

# Call the functions
mnt_fs
coldplug
misc
