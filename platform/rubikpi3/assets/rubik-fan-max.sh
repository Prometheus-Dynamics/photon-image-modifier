#!/bin/sh
hwmon_dir=$(readlink -f /sys/devices/platform/pwm-fan/hwmon/hwmon*)
echo 0 > "$hwmon_dir/pwm1_enable"
echo 255 > "$hwmon_dir/pwm1"
