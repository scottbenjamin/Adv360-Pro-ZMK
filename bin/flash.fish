#!/usr/bin/env fish

set firmware_dir ./firmware
set mount_timeout_sec 90
set mount_roots /run/media/$USER /media/$USER

# Optional override for users with non-standard mount paths.
if set -q MOUNT_POINT
    set mount_override $MOUNT_POINT
else
    set mount_override ""
end

function get_latest_file
    set pattern $argv[1]
    set latest_file ""
    set latest_mtime 0

    set -l matches $firmware_dir/*$pattern* 2>/dev/null
    if test (count $matches) -eq 0
        return
    end

    for file in $matches
        if test -f $file
            set mtime (stat -L -c %Y $file)
            if test $mtime -gt $latest_mtime
                set latest_mtime $mtime
                set latest_file $file
            end
        end
    end

    echo $latest_file
end

function list_uf2_mounts
    set mounts
    for root in $mount_roots
        if not test -d $root
            continue
        end

        for candidate in $root/*
            if test -d $candidate
                if test -f "$candidate/INFO_UF2.TXT"
                    set mounts $mounts $candidate
                end
            end
        end
    end
    if test (count $mounts) -gt 0
        printf "%s\n" $mounts
    end
end

function list_adv360_devices
    set devices

    # Most reliable path when label symlink exists.
    set by_label_dev (readlink -f /dev/disk/by-label/ADV360PRO 2>/dev/null)
    if test -n "$by_label_dev"; and test -b "$by_label_dev"
        set devices $devices $by_label_dev
    end

    # Fallback for systems where /dev/disk/by-label is delayed/unavailable.
    set lsblk_devs (lsblk -rpno NAME,LABEL,TYPE | awk 'toupper($2)=="ADV360PRO" && ($3=="part" || $3=="disk") {print $1}')
    for dev in $lsblk_devs
        if not contains -- $dev $devices
            set devices $devices $dev
        end
    end

    if test (count $devices) -gt 0
        printf "%s\n" $devices
    end
end

function get_mount_for_device
    set dev $argv[1]
    if test -z "$dev"
        return 1
    end

    set mount_from_findmnt (findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -n 1)
    if test -n "$mount_from_findmnt"
        echo $mount_from_findmnt
        return 0
    end

    set mount_from_lsblk (lsblk -rno MOUNTPOINT "$dev" 2>/dev/null | head -n 1)
    if test -n "$mount_from_lsblk"
        echo $mount_from_lsblk
        return 0
    end

    return 1
end

function try_mount_adv360_device
    set dev $argv[1]
    if test -z "$dev"
        return 1
    end

    if command -q udisksctl
        udisksctl mount -b "$dev" >/dev/null 2>&1
    end

    set mp (get_mount_for_device "$dev")
    if test $status -eq 0
        echo $mp
        return 0
    end

    return 1
end

function get_new_mount_point
    set previous_mounts $argv
    set current_mounts (list_uf2_mounts)

    if test (count $current_mounts) -eq 0
        return 1
    end

    if test (count $previous_mounts) -eq 0
        echo $current_mounts[1]
        return 0
    end

    for candidate in $current_mounts
        if not contains -- $candidate $previous_mounts
            echo $candidate
            return 0
        end
    end

    return 1
end

function get_new_device
    set previous_devices $argv
    set current_devices (list_adv360_devices)

    if test (count $current_devices) -eq 0
        return 1
    end

    if test (count $previous_devices) -eq 0
        echo $current_devices[1]
        return 0
    end

    for dev in $current_devices
        if not contains -- $dev $previous_devices
            echo $dev
            return 0
        end
    end

    return 1
end

function get_mount_point
    set previous_mounts $argv[1..-2]
    set previous_devices $argv[-1]

    if test -n "$mount_override"
        if test -d "$mount_override"
            echo "$mount_override"
            return 0
        end
        return 1
    end

    # First try filesystem mount discovery.
    set maybe_mounted (get_new_mount_point $previous_mounts)
    if test $status -eq 0
        echo $maybe_mounted
        return 0
    end

    # Then try device discovery + explicit mount.
    set dev (get_new_device $previous_devices)
    if test $status -ne 0
        set all_devices (list_adv360_devices)
        if test (count $all_devices) -gt 0
            set dev $all_devices[1]
        end
    end

    if test -z "$dev"
        return 1
    end

    try_mount_adv360_device "$dev"
end

function wait_for_mount
    set previous_mounts $argv
    set previous_devices (list_adv360_devices)
    set start_ts (date +%s)
    set last_probe 0

    while true
        set detected_mount (get_mount_point $previous_mounts $previous_devices)
        if test $status -eq 0
            echo $detected_mount
            return 0
        end

        set now_ts (date +%s)
        set elapsed (math "$now_ts - $start_ts")

        # If automount is disabled, proactively try user-space mounting while waiting.
        if test (math "$elapsed - $last_probe") -ge 3
            set mounted_with_udisks (get_mount_point $previous_mounts $previous_devices)
            if test $status -eq 0
                echo $mounted_with_udisks
                return 0
            end
            set last_probe $elapsed
        end

        if test $elapsed -ge $mount_timeout_sec
            return 1
        end

        sleep 1
    end
end

function wait_for_unmount
    set mount_point $argv[1]
    while test -d "$mount_point"
        sleep 1
    end
end

function print_info
    set_color cyan
    echo $argv
    set_color normal
end

function print_success
    set_color green
    echo $argv
    set_color normal
end

function print_error
    set_color red
    echo $argv
    set_color normal
end

function copy_firmware
    set file_path $argv[1]
    set mount_point $argv[2]

    cp "$file_path" "$mount_point"
    if test $status -ne 0
        return 1
    end

    sync
    return 0
end

function print_mount_diagnostics
    print_error "Diagnostic snapshot:"
    print_error "Mounted UF2 paths: "(list_uf2_mounts)
    print_error "Removable/unmounted FAT partitions:"
    lsblk -rpno NAME,RM,FSTYPE,LABEL,TYPE,MOUNTPOINT | awk '$2=="1" || (($3=="vfat" || $3=="msdos") && $5=="part") {print "  " $0}'
end

function flash_half
    set side_name $argv[1]
    set file_path $argv[2]

    set mounted_now (list_uf2_mounts)
    set target_mount ""

    if test (count $mounted_now) -gt 0; and test -n "$mounted_now[1]"
        set target_mount $mounted_now[1]
        print_info "Using already mounted UF2 volume at $target_mount for $side_name."
    else
        set baseline_mounts (list_uf2_mounts)
        print_info "Plug in the $side_name half in bootloader mode..."
        set target_mount (wait_for_mount $baseline_mounts)
        if test $status -ne 0
            print_error "Timed out waiting for UF2 mount."
            print_error "If automount is disabled, rerun with: MOUNT_POINT=/path/to/mount make flash"
            print_error "If no removable FAT device appears below, the keyboard is not enumerating over USB."
            print_mount_diagnostics
            return 1
        end
    end

    print_info "Copying $file_path to $target_mount..."
    copy_firmware $file_path $target_mount
    if test $status -ne 0
        print_error "Copy failed for $side_name half."
        return 1
    end

    print_success "Flashed $side_name half."
    print_info "Now unplug the $side_name half..."
    wait_for_unmount $target_mount
    return 0
end

function any_existing_mount
    set mounts (list_uf2_mounts)
    if test (count $mounts) -gt 0
        return 0
    end
    return 1
end

if test -n "$mount_override"
    print_info "Using mount override: $mount_override"
end

# --- Pre-check for firmware files ---
set left_file (get_latest_file "left")
set right_file (get_latest_file "right")

if test -z "$left_file"
    print_error "❌ No left firmware file found in $firmware_dir"
end

if test -z "$right_file"
    print_error "❌ No right firmware file found in $firmware_dir"
end

if test -z "$left_file"
    print_error "❌ Left firmware is required. Aborting."
    exit 1
end

# --- Prompt user whether to flash right half ---
echo "Do you want to flash the RIGHT half as well? (y/n): "
read -l flash_right

if test "$flash_right" = "y"
    if test -z "$right_file"
        print_error "❌ Right firmware not found, cannot flash right half."
        exit 1
    end
else if test "$flash_right" != "n"
    print_error "Invalid input. Please enter 'y' or 'n'."
    exit 1
end

# --- STEP 1: Flash LEFT side ---
flash_half LEFT $left_file
if test $status -ne 0
    exit 1
end

# --- STEP 2: Flash RIGHT side (optional) ---
if test "$flash_right" = "y"
    flash_half RIGHT $right_file
    if test $status -ne 0
        exit 1
    end
end

print_success "\n🎉 Firmware update complete!"
