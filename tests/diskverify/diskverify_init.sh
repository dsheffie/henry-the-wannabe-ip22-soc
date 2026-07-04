#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s
mount -t proc  proc  /proc 2>/dev/null
mount -t sysfs sysfs /sys  2>/dev/null
echo "=== DISKVERIFY START ==="
mknod /dev/sda b 8 0 2>/dev/null
/bin/diskverify /dev/sda
echo "=== DISKVERIFY DONE ==="
echo "fpga_done"
exec setsid cttyhack sh
