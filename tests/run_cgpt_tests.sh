#!/bin/bash -eu

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Run tests for cgpt utility.

# Load common constants and variables.
. "$(dirname "$0")/common.sh"

CGPT=$(readlink -f "${1:-./cgpt}")
[ -x "$CGPT" ] || error "Can't execute $CGPT"

# Run tests in a dedicated directory for easy cleanup or debugging.
DIR="${TEST_DIR}/cgpt_test_dir"
[ -d "$DIR" ] || mkdir -p "$DIR"
warning "testing $CGPT in $DIR"
cd "$DIR"

DEV=fake_dev.bin
rm -f ${DEV}

echo "Test the cgpt create command..."
# test basic create and extend
$CGPT create -c -s 100 ${DEV} || error
[ $(stat --format=%s ${DEV}) -eq $((100*512)) ] || error
$CGPT create -c -s 200 ${DEV} || error
[ $(stat --format=%s ${DEV}) -eq $((200*512)) ] || error
$CGPT create -s 300 ${DEV} || error
[ $(stat --format=%s ${DEV}) -eq $((300*512)) ] || error
$CGPT create -s 200 ${DEV} || error
[ $(stat --format=%s ${DEV}) -eq $((300*512)) ] || error

# test argument requirements
$CGPT create -c ${DEV} &>/dev/null && error

# boy it'd be nice if dealing with block devices didn't always require root
if [ "$(id -u)" -ne 0 ]; then
  echo "Skipping cgpt create tests w/ block devices (requires root)"
else
  rm -f ${DEV}
  $CGPT create -c -s 100 ${DEV}
  loop=$(losetup -f --show ${DEV}) || error
  trap "losetup -d ${loop}" EXIT
  $CGPT create -c -s 100 ${loop} || error
  $CGPT create -c -s 200 ${loop} && error
  losetup -d ${loop}
  trap - EXIT
fi


echo "Test that cgpt repair handles size changes"
# Use an alternate tool for reading for verification purposes
SGDISK=$(type -p sgdisk || echo /usr/sbin/sgdisk)
[[ -x "${SGDISK}" ]] || SGDISK=""

verify() {
  if [[ -n "$SGDISK" ]]; then
    $SGDISK --verify ${DEV} | grep -q "No problems found." \
        || error "sgdisk dislikes cgpt's disk!"
  else
    echo "Skipping extra verification with sgdisk"
  fi
}

rm -f ${DEV}
$CGPT create -c -s 100 ${DEV} || error
$CGPT boot -p ${DEV} >/dev/null || error
verify

truncate --size=+1M ${DEV}
$CGPT repair ${DEV} || error
verify


echo "Test that cgpt preserves MBR boot code"
dd if=/dev/urandom of=${DEV}.mbr bs=446 count=1 status=noxfer || error
rm -f ${DEV}
$CGPT create -c -s 100 ${DEV} || error
dd if=${DEV}.mbr of=${DEV} conv=notrunc status=noxfer || error
$CGPT add -t rootfs -b 50 -s 1 ${DEV} || error
cmp --bytes=446 ${DEV}.mbr ${DEV} || error
# kill the MBR table and the primary GPT, leave the boot code
dd if=/dev/zero of=${DEV} bs=446 seek=1 count=2 conv=notrunc status=noxfer || error
$CGPT repair ${DEV} || error
verify
cmp --bytes=446 ${DEV}.mbr ${DEV} || error
# try switching between hybrid and protective MBRs
$CGPT add -i1 -B1 ${DEV} || error
verify
cmp --bytes=446 ${DEV}.mbr ${DEV} || error
$CGPT add -i1 -B0 ${DEV} || error
verify
cmp --bytes=446 ${DEV}.mbr ${DEV} || error


# resize requires a partitioned block device
if [ "$(id -u)" -ne 0 ]; then
  echo "Skipping cgpt resize tests w/ block devices (requires root)"
else
  echo "Test cgpt resize w/ ext2 filesystem."
  rm -f ${DEV}
  $CGPT create -c -s 1000 ${DEV} || error
  $CGPT add -i 1 -b 40 -s 900 -t data ${DEV} || error
  # FIXME(marineam): cgpt should always write a protective MBR.
  # the boot command should only be for making the MBR bootable.
  $CGPT boot -p ${DEV} || error
  loop=$(losetup -f --show --partscan ${DEV}) || error
  trap "losetup -d ${loop}" EXIT
  loopp1=${loop}p1
  # double check that partitioned loop devices work and have correct size
  [ -b $loopp1 ] || error "$loopp1 is not a block device"
  [ $(blockdev --getsz $loop) -eq 1000 ] || error
  [ $(blockdev --getsz $loopp1) -eq 900 ] || error
  mkfs.ext2 $loopp1 || error
  # this should do nothing
  $CGPT resize $loopp1 || error
  [ $(blockdev --getsz $loop) -eq 1000 ] || error
  [ $(blockdev --getsz $loopp1) -eq 900 ] || error
  # now test a real rezize, up to 4MB in sectors
  truncate --size=$((8192 * 512)) ${DEV} || error
  losetup --set-capacity ${loop} || error
  [ $(blockdev --getsz $loop) -eq 8192 ] || error
  [ $(blockdev --getsz $loopp1) -eq 900 ] || error
  $CGPT resize $loopp1 || error
  [ $(blockdev --getsz $loop) -eq 8192 ] || error
  [ $(blockdev --getsz $loopp1) -gt 8000 ] || error
  losetup -d ${loop}
  trap - EXIT
fi


# test passing partition devices to cgpt
if [ "$(id -u)" -ne 0 ]; then
  echo "Skipping cgpt tests w/ partition block devices (requires root)"
else
  echo "Test cgpt w/ partition block device"
  rm -f ${DEV}
  $CGPT create -c -s 1000 ${DEV} || error
  $CGPT add -i 1 -b 40 -s 900 -t coreos-usr -A 0 ${DEV} || error
  loop=$(losetup -f --show --partscan ${DEV}) || error
  trap "losetup -d ${loop}" EXIT
  loopp1=${loop}p1
  # double check that partitioned loop devices work and have correct size
  [ -b $loopp1 ] || error "$loopp1 is not a block device"
  $CGPT add -S 1 $loopp1 || error
  [ $($CGPT show -S ${loopp1}) -eq 1 ] || error
  [ $($CGPT show -i 1 -S ${DEV}) -eq 1 ] || error
  [ $($CGPT show -P ${loopp1}) -eq 0 ] || error
  [ $($CGPT show -i 1 -P ${DEV}) -eq 0 ] || error
  $CGPT prioritize $loopp1 || error
  [ $($CGPT show -P ${loopp1}) -eq 1 ] || error
  [ $($CGPT show -i 1 -P ${DEV}) -eq 1 ] || error
  losetup -d ${loop}
  trap - EXIT
fi


echo "Create an empty file to use as the device..."
NUM_SECTORS=1000
rm -f ${DEV}
$CGPT create -c -s ${NUM_SECTORS} ${DEV}


echo "Create a bunch of partitions, using the real GUID types..."
DATA_START=100
DATA_SIZE=20
DATA_LABEL="data stuff"
DATA_GUID='0fc63daf-8483-4772-8e79-3d69d8477de4'
DATA_NUM=1

KERN_START=200
KERN_SIZE=30
KERN_LABEL="kernel stuff"
KERN_GUID='fe3a2a5d-4f32-41a7-b725-accc3285a309'
KERN_NUM=2

ROOTFS_START=300
ROOTFS_SIZE=40
ROOTFS_LABEL="rootfs stuff"
ROOTFS_GUID='3cb8e202-3b7e-47dd-8a3c-7ff2a13cfcec'
ROOTFS_NUM=3

ESP_START=400
ESP_SIZE=50
ESP_LABEL="ESP stuff"
ESP_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
ESP_NUM=4

FUTURE_START=500
FUTURE_SIZE=60
FUTURE_LABEL="future stuff"
FUTURE_GUID='2e0a753d-9e48-43b0-8337-b15192cb1b5e'
FUTURE_NUM=5

RANDOM_START=600
RANDOM_SIZE=70
RANDOM_LABEL="random stuff"
RANDOM_GUID='2364a860-bf63-42fb-a83d-9ad3e057fcf5'
RANDOM_NUM=6

$CGPT add -b ${DATA_START} -s ${DATA_SIZE} -t ${DATA_GUID} \
  -l "${DATA_LABEL}" ${DEV}
$CGPT add -b ${KERN_START} -s ${KERN_SIZE} -t ${KERN_GUID} \
  -l "${KERN_LABEL}" ${DEV}
$CGPT add -b ${ROOTFS_START} -s ${ROOTFS_SIZE} -t ${ROOTFS_GUID} \
  -l "${ROOTFS_LABEL}" ${DEV}
$CGPT add -b ${ESP_START} -s ${ESP_SIZE} -t ${ESP_GUID} \
  -l "${ESP_LABEL}" ${DEV}
$CGPT add -b ${FUTURE_START} -s ${FUTURE_SIZE} -t ${FUTURE_GUID} \
  -l "${FUTURE_LABEL}" ${DEV}
$CGPT add -b ${RANDOM_START} -s ${RANDOM_SIZE} -t ${RANDOM_GUID} \
  -l "${RANDOM_LABEL}" ${DEV}


echo "Extract the start and size of given partitions..."

X=$($CGPT show -b -i $DATA_NUM ${DEV})
Y=$($CGPT show -s -i $DATA_NUM ${DEV})
[ "$X $Y" = "$DATA_START $DATA_SIZE" ] || error

X=$($CGPT show -b -i $KERN_NUM ${DEV})
Y=$($CGPT show -s -i $KERN_NUM ${DEV})
[ "$X $Y" = "$KERN_START $KERN_SIZE" ] || error

X=$($CGPT show -b -i $ROOTFS_NUM ${DEV})
Y=$($CGPT show -s -i $ROOTFS_NUM ${DEV})
[ "$X $Y" = "$ROOTFS_START $ROOTFS_SIZE" ] || error

X=$($CGPT show -b -i $ESP_NUM ${DEV})
Y=$($CGPT show -s -i $ESP_NUM ${DEV})
[ "$X $Y" = "$ESP_START $ESP_SIZE" ] || error

X=$($CGPT show -b -i $FUTURE_NUM ${DEV})
Y=$($CGPT show -s -i $FUTURE_NUM ${DEV})
[ "$X $Y" = "$FUTURE_START $FUTURE_SIZE" ] || error

X=$($CGPT show -b -i $RANDOM_NUM ${DEV})
Y=$($CGPT show -s -i $RANDOM_NUM ${DEV})
[ "$X $Y" = "$RANDOM_START $RANDOM_SIZE" ] || error


echo "Change the beginning..."
DATA_START=$((DATA_START + 10))
$CGPT add -i 1 -b ${DATA_START} ${DEV} || error
X=$($CGPT show -b -i 1 ${DEV})
[ "$X" = "$DATA_START" ] || error

echo "Change the size..."
DATA_SIZE=$((DATA_SIZE + 10))
$CGPT add -i 1 -s ${DATA_SIZE} ${DEV} || error
X=$($CGPT show -s -i 1 ${DEV})
[ "$X" = "$DATA_SIZE" ] || error

echo "Change the type..."
$CGPT add -i 1 -t reserved ${DEV} || error
X=$($CGPT show -t -i 1 ${DEV} | tr 'A-Z' 'a-z')
[ "$X" = "$FUTURE_GUID" ] || error
# arbitrary value
$CGPT add -i 1 -t 610a563a-a55c-4ae0-ab07-86e5bb9db67f ${DEV} || error
X=$($CGPT show -t -i 1 ${DEV})
[ "$X" = "610A563A-A55C-4AE0-AB07-86E5BB9DB67F" ] || error
$CGPT add -i 1 -t data ${DEV} || error
X=$($CGPT show -t -i 1 ${DEV} | tr 'A-Z' 'a-z')
[ "$X" = "$DATA_GUID" ] || error


echo "Set the boot partition.."
$CGPT boot -i ${KERN_NUM} ${DEV} >/dev/null

echo "Check the PMBR's idea of the boot partition..."
X=$($CGPT boot ${DEV})
Y=$($CGPT show -u -i $KERN_NUM $DEV)
[ "$X" = "$Y" ] || error


echo "Test the cgpt next command..."
ROOT_A=562de070-1539-4edf-ac33-b1028227d525
ROOT_B=839c1172-5036-4efe-9926-7074340d5772
expect_next() {
  local root=$($CGPT next $DEV)
  [ "$root" == "$1" ] || error 1 "expected next to be $1 but got $root"
}

# Basic state, one good rootfs
$CGPT create $DEV || error
$CGPT add -i 1 -t coreos-rootfs -u $ROOT_A -b 100 -s 1 -P 1 -S 1 $DEV || error
$CGPT add -i 2 -t coreos-rootfs -u $ROOT_B -b 101 -s 1 -P 0 -S 0 $DEV || error
expect_next $ROOT_A
expect_next $ROOT_A

# Try the other order
$CGPT add -i 1 -P 0 -S 0 $DEV || error
$CGPT add -i 2 -P 1 -S 1 $DEV || error
expect_next $ROOT_B
expect_next $ROOT_B

# Try B, fall back to A
$CGPT add -i 1 -P 0 -S 1 -T 0 $DEV || error
$CGPT add -i 2 -P 1 -S 0 -T 1 $DEV || error
expect_next $ROOT_B
expect_next $ROOT_A
expect_next $ROOT_A

# Try A, fall back to B
$CGPT add -i 1 -P 1 -S 0 -T 1 $DEV || error
$CGPT add -i 2 -P 0 -S 1 -T 0 $DEV || error
expect_next $ROOT_A
expect_next $ROOT_B
expect_next $ROOT_B

echo "Verify that common GPT types have the correct GUID."
# This list should come directly from external documentation.
declare -A GPT_TYPES

# General GPT/UEFI types.
# See UEFI spec "5.3.3 GPT Partition Entry Array"
# http://www.uefi.org/sites/default/files/resources/2_4_Errata_A.pdf
GPT_TYPES[efi]="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

# BIOS Boot Partition for GRUB
# https://www.gnu.org/software/grub/manual/html_node/BIOS-installation.html
GPT_TYPES[bios]="21686148-6449-6E6F-744E-656564454649"

# MS Windows basic data
GPT_TYPES[mswin-data]="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

# General Linux types.
# http://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
# http://www.freedesktop.org/software/systemd/man/systemd-gpt-auto-generator.html
# http://www.freedesktop.org/wiki/Specifications/BootLoaderSpec/
GPT_TYPES[linux-data]="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
GPT_TYPES[linux-swap]="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
GPT_TYPES[linux-boot]="BC13C2FF-59E6-4262-A352-B275FD6F7172"
GPT_TYPES[linux-home]="933AC7E1-2EB4-4F13-B844-0E14E2AEF915"
GPT_TYPES[linux-lvm]="E6D6D379-F507-44C2-A23C-238F2A3DF928"
GPT_TYPES[linux-raid]="A19D880F-05FC-4D3B-A006-743F0F84911E"
GPT_TYPES[linux-reserved]="8DA63339-0007-60C0-C436-083AC8230908"
GPT_TYPES[data]=${GPT_TYPES[linux-data]}

get_guid() {
    $SGDISK --info $1 ${DEV} | awk '/^Partition GUID code:/ {print $4}'
}

if [[ -n "$SGDISK" ]]; then
    for type_name in "${!GPT_TYPES[@]}"; do
        type_guid="${GPT_TYPES[$type_name]}"
        $CGPT create ${DEV}
        $CGPT add -t $type_name -b 100 -s 1 ${DEV}
        cgpt_guid=$(get_guid 1)
        if [[ $cgpt_guid != $type_guid ]]; then
            echo "$type_name should be $type_guid" >&2
            echo "instead got $cgpt_guid" >&2
            error "Invalid GUID for $type_name!"
        fi
    done
else
    echo "Skipping GUID tests because sgdisk wasn't found"
fi

echo "Test the cgpt prioritize command..."

# Input: sequence of priorities
# Output: ${DEV} has coreos-rootfs partitions with the given priorities
make_pri() {
  local idx=0
  $CGPT create ${DEV}
  for pri in "$@"; do
    idx=$((idx+1))
    $CGPT add -t coreos-rootfs -l "root$idx" -b $((100 + 2 * $idx)) -s 1 -P $pri ${DEV}
  done
}

# Output: returns string containing priorities of all kernels
get_pri() {
  echo $(
  for idx in $($CGPT find -t coreos-rootfs ${DEV} | sed -e s@${DEV}@@); do
    $CGPT show -i $idx -P ${DEV}
  done
  )
}

# Input: list of priorities
# Operation: expects ${DEV} to contain those kernel priorities
assert_pri() {
  local expected="$*"
  local actual=$(get_pri)
  [ "$actual" = "$expected" ] || \
    error 1 "expected priority \"$expected\", actual priority \"$actual\""
}


# no coreos-rootfs at all. This should do nothing.
$CGPT create ${DEV}
$CGPT add -t rootfs -b 100 -s 1 ${DEV}
$CGPT prioritize ${DEV}
assert_pri ""

# common install/upgrade sequence
make_pri   2 0 0
$CGPT prioritize -i 1 ${DEV}
assert_pri 1 0 0
$CGPT prioritize -i 2 ${DEV}
assert_pri 1 2 0
$CGPT prioritize -i 1 ${DEV}
assert_pri 2 1 0
$CGPT prioritize -i 2 ${DEV}
assert_pri 1 2 0

# lots of coreos-rootfs, all same starting priority, should go to priority 1
make_pri   8 8 8 8 8 8 8 8 8 8 8 0 0 8
$CGPT prioritize ${DEV}
assert_pri 1 1 1 1 1 1 1 1 1 1 1 0 0 1

# now raise them all up again
$CGPT prioritize -P 4 ${DEV}
assert_pri 4 4 4 4 4 4 4 4 4 4 4 0 0 4

# set one of them higher, should leave the rest alone
$CGPT prioritize -P 5 -i 3 ${DEV}
assert_pri 4 4 5 4 4 4 4 4 4 4 4 0 0 4

# set one of them lower, should bring the rest down
$CGPT prioritize -P 3 -i 4 ${DEV}
assert_pri 1 1 2 3 1 1 1 1 1 1 1 0 0 1

# raise a group by including the friends of one partition
$CGPT prioritize -P 6 -i 1 -f ${DEV}
assert_pri 6 6 4 5 6 6 6 6 6 6 6 0 0 6

# resurrect one, should not affect the others
make_pri   0 0 0 0 0 0 0 0 0 0 0 0 0 0
$CGPT prioritize -i 2 ${DEV}
assert_pri 0 1 0 0 0 0 0 0 0 0 0 0 0 0

# resurrect one and all its friends
make_pri   0 0 0 0 0 0 0 0 1 2 0 0 0 0
$CGPT prioritize -P 5 -i 2 -f ${DEV}
assert_pri 5 5 5 5 5 5 5 5 3 4 5 5 5 5

# no options should maintain the same order
$CGPT prioritize ${DEV}
assert_pri 3 3 3 3 3 3 3 3 1 2 3 3 3 3

# squish all the ranks
make_pri   1 1 2 2 3 3 4 4 5 5 0 6 7 7
$CGPT prioritize -P 6 ${DEV}
assert_pri 1 1 1 1 2 2 3 3 4 4 0 5 6 6

# squish the ranks by not leaving room
make_pri   1 1 2 2 3 3 4 4 5 5 0 6 7 7
$CGPT prioritize -P 7 -i 3 ${DEV}
assert_pri 1 1 7 1 2 2 3 3 4 4 0 5 6 6

# squish the ranks while bringing the friends along
make_pri   1 1 2 2 3 3 4 4 5 5 0 6 7 7
$CGPT prioritize -P 6 -i 3 -f ${DEV}
assert_pri 1 1 6 6 1 1 2 2 3 3 0 4 5 5

# squish them pretty hard
make_pri   1 1 2 2 3 3 4 4 5 5 0 6 7 7
$CGPT prioritize -P 2 ${DEV}
assert_pri 1 1 1 1 1 1 1 1 1 1 0 1 2 2

# squish them really really hard (nobody gets reduced to zero, though)
make_pri   1 1 2 2 3 3 4 4 5 5 0 6 7 7
$CGPT prioritize -P 1 -i 3 ${DEV}
assert_pri 1 1 1 1 1 1 1 1 1 1 0 1 1 1

# squish if we try to go too high
make_pri   15 15 14 14 13 13 12 12 11 11 10 10 9 9 8 8 7 7 6 6 5 5 4 4 3 3 2 2 1 1 0
$CGPT prioritize -i 3 ${DEV}
assert_pri 14 14 15 13 12 12 11 11 10 10  9  9 8 8 7 7 6 6 5 5 4 4 3 3 2 2 1 1 1 1 0
$CGPT prioritize -i 5 ${DEV}
assert_pri 13 13 14 12 15 11 10 10  9  9  8  8 7 7 6 6 5 5 4 4 3 3 2 2 1 1 1 1 1 1 0
# but if I bring friends I don't have to squish
$CGPT prioritize -i 1 -f ${DEV}
assert_pri 15 15 13 12 14 11 10 10  9  9  8  8 7 7 6 6 5 5 4 4 3 3 2 2 1 1 1 1 1 1 0

# Now make sure that we don't need write access if we're just looking.
if [ "$(id -u)" -eq 0 ]; then
  echo "Skipping read vs read-write access tests (doesn't work as root)"
else
  echo "Test read vs read-write access..."
  chmod 0444 ${DEV} || error

  # These should fail
  $CGPT create -z ${DEV} 2>/dev/null && error
  $CGPT add -i 2 -P 3 ${DEV} 2>/dev/null && error
  $CGPT repair ${DEV} 2>/dev/null && error
  $CGPT prioritize -i 3 ${DEV} 2>/dev/null && error

  # Most 'boot' usage should fail too.
  $CGPT boot -p ${DEV} 2>/dev/null && error
  dd if=/dev/zero of=fake_mbr.bin bs=100 count=1 2>/dev/null || error
  $CGPT boot -b fake_mbr.bin ${DEV} 2>/dev/null && error
  $CGPT boot -i 2 ${DEV} 2>/dev/null && error

  # These shoulfd pass
  $CGPT boot ${DEV} >/dev/null || error
  $CGPT show ${DEV} >/dev/null || error
  $CGPT find -t coreos-rootfs ${DEV} >/dev/null || error

  echo "Done."
fi

happy "All tests passed."
