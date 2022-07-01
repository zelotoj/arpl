#!/usr/bin/env bash

set -e

. /opt/arpl/include/functions.sh

# Sanity check
loaderIsConfigured || die "Loader is not configured!"

# Print text centralized, if variable ${COLUMNS} is defined
clear
TITLE="BOOTING..."
if [ -z "${COLUMNS}" ]; then
  echo -e "\033[1;33m${TITLE}\033[0m"
else
  printf "\033[1;33m%*s\033[0m\n" $(((${#TITLE}+${COLUMNS})/2)) "${TITLE}"
fi

# Check if DSM zImage changed, patch it if necessary
ZIMAGE_HASH="`readConfigKey "zimage-hash" "${USER_CONFIG_FILE}"`"
if [ "`sha256sum "${ORI_ZIMAGE_FILE}" | awk '{print$1}'`" != "${ZIMAGE_HASH}" ]; then
  echo -e "\033[1;43mDSM zImage changed\033[0m"
  /opt/arpl/zimage-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" \
      --msgbox "zImage not patched:\n`<"${LOG_FILE}"`" 12 70
    return 1
  fi
fi

# Check if DSM ramdisk changed, patch it if necessary
RAMDISK_HASH="`readConfigKey "ramdisk-hash" "${USER_CONFIG_FILE}"`"
if [ "`sha256sum "${ORI_RDGZ_FILE}" | awk '{print$1}'`" != "${RAMDISK_HASH}" ]; then
  echo -e "\033[1;43mDSM Ramdisk changed\033[0m"
  /opt/arpl/ramdisk-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "Error" \
      --msgbox "Ramdisk not patched:\n`<"${LOG_FILE}"`" 12 70
    return 1
  fi
fi

# Load necessary variables
VID="`readConfigKey "vid" "${USER_CONFIG_FILE}"`"
PID="`readConfigKey "pid" "${USER_CONFIG_FILE}"`"
MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"

declare -A CMDLINE

# Fixed values
CMDLINE['netif_num']=0
# Automatic values
CMDLINE['syno_hw_version']="${MODEL}"
[ -z "${VID}" ] && VID="0x0000" # Sanity check
[ -z "${PID}" ] && PID="0x0000" # Sanity check
CMDLINE['vid']="${VID}"
CMDLINE['pid']="${PID}"
CMDLINE['sn']="${SN}"

# Read cmdline
while IFS="=" read KEY VALUE; do
  [ -n "${KEY}" ] && CMDLINE["${KEY}"]="${VALUE}"
done < <(readModelMap "${MODEL}" "builds.${BUILD}.cmdline")
while IFS="=" read KEY VALUE; do
  [ -n "${KEY}" ] && CMDLINE["${KEY}"]="${VALUE}"
done < <(readConfigMap "cmdline" "${USER_CONFIG_FILE}")

# Check if machine has EFI
[ -d /sys/firmware/efi ] && EFI=1 || EFI=0
# Read EFI bug value
EFI_BUG="`readModelKey "${MODEL}" "builds.${BUILD}.efi-bug"`"

LOADER_DISK="`blkid | grep 'LABEL="ARPL3"' | cut -d3 -f1`"
BUS=`udevadm info --query property --name ${LOADER_DISK} | grep ID_BUS | cut -d= -f2`

# Prepare command line
CMDLINE_LINE=""
[ ${EFI} -eq 1 ] && CMDLINE_LINE+="withefi "
[ "${BUS}" = "ata" ] && CMDLINE_LINE+="synoboot_satadom=1 "
CMDLINE_LINE+="console=ttyS0,115200n8 earlyprintk log_buf_len=32M earlycon=uart8250,io,0x3f8,115200n8 elevator=elevator root=/dev/md0 loglevel=15"
for KEY in ${!CMDLINE[@]}; do
  VALUE="${CMDLINE[${KEY}]}"
  CMDLINE_LINE+=" ${KEY}"
  [ -n "${VALUE}" ] && CMDLINE_LINE+="=${VALUE}"
done
# Escape special chars
CMDLINE_LINE=`echo ${CMDLINE_LINE} | sed 's/>/\\\\>/g'`

# Inform user
echo -e "Model: \033[1;36m${MODEL}\033[0m"
echo -e "Build: \033[1;36m${BUILD}\033[0m"
echo -e "Cmdline:\n\033[1;36m${CMDLINE_LINE}\033[0m"
echo -e "\033[1;37mLoading DSM kernel...\033[0m"

# Executes DSM kernel via KEXEC
history -a
sync
if [ "${EFI_BUG}" = "yes" -a ${EFI} -eq 1 ]; then
  echo -e "\033[1;33mWarning, running kexec with --noefi param, strange things will happen!!\033[0m"
  kexec --noefi -l "${MOD_ZIMAGE_FILE}" --initrd "${MOD_RDGZ_FILE}" --command-line="${CMDLINE_LINE}" >"${LOG_FILE}" 2>&1 || dieLog
else
  kexec -l "${MOD_ZIMAGE_FILE}" --initrd "${MOD_RDGZ_FILE}" --command-line="${CMDLINE_LINE}" >"${LOG_FILE}" 2>&1 || dieLog
fi
/sbin/swapoff -a >/dev/null 2>&1 || true
/bin/umount -a -r >/dev/null 2>&1 || true
echo -e "\033[1;37mBooting...\033[0m"
kexec -e -a >"${LOG_FILE}" 2>&1 || dieLog