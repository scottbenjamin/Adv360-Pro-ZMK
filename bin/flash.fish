#!/usr/bin/env fish

set firmware_dir ./firmware
set mount_point /run/media/scott/ADV360PRO

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

function wait_for_mount
    while not test -d $mount_point
        sleep 1
    end
end

function wait_for_unmount
    while test -d $mount_point
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
wait_for_mount

print_info "Copying $left_file to $mount_point..."
cp $left_file $mount_point
and print_success "✅ Left firmware copied successfully."

print_info "📤 Now unplug the LEFT half..."
wait_for_unmount

# --- STEP 2: Flash RIGHT side (optional) ---
if test "$flash_right" = "y"
    print_info "📥 Please plug in the RIGHT half in bootloader mode..."
    wait_for_mount

    print_info "Copying $right_file to $mount_point..."
    cp $right_file $mount_point
    and print_success "✅ Right firmware copied successfully."

    print_info "📤 Unplug the RIGHT half to complete the update..."
    wait_for_unmount
end

print_success "\n🎉 Firmware update complete!"
