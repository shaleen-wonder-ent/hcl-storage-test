#!/usr/bin/env bash
# setup-vm.sh - Installs tools and mounts the 3 shares used by the lab.
#
# Usage (run with sudo):
#   sudo bash setup-vm.sh <SMB_ACCOUNT> <SMB_KEY> <NFS_ACCOUNT> <ANF_MOUNT_IP> <ANF_MOUNT_PATH>
#
# Result:
#   /mnt/fileshare  -> Azure Files SMB
#   /mnt/nfsshare   -> Azure Files NFS
#   /mnt/netapp     -> Azure NetApp Files NFS

set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo "Usage: $0 <SMB_ACCOUNT> <SMB_KEY> <NFS_ACCOUNT> <ANF_MOUNT_IP> <ANF_MOUNT_PATH>"
    exit 1
fi

SMB_ACCOUNT=$1
SMB_KEY=$2
NFS_ACCOUNT=$3
ANF_IP=$4
ANF_PATH=$5
SHARE_NAME=storage

echo "==> Installing cifs-utils, nfs-common, fio"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cifs-utils nfs-common fio jq >/dev/null

mkdir -p /mnt/fileshare /mnt/nfsshare /mnt/netapp

# ---------- Azure Files SMB ----------
echo "==> Mounting Azure Files SMB at /mnt/fileshare"
CREDS=/etc/smbcredentials/${SMB_ACCOUNT}.cred
mkdir -p /etc/smbcredentials
cat > "$CREDS" <<EOF
username=${SMB_ACCOUNT}
password=${SMB_KEY}
EOF
chmod 600 "$CREDS"

SMB_HOST=${SMB_ACCOUNT}.file.core.windows.net
mount -t cifs "//${SMB_HOST}/${SHARE_NAME}" /mnt/fileshare \
    -o "credentials=${CREDS},dir_mode=0777,file_mode=0777,serverino,nosharesock,actimeo=30,vers=3.1.1"

# ---------- Azure Files NFS ----------
echo "==> Mounting Azure Files NFS at /mnt/nfsshare"
NFS_HOST=${NFS_ACCOUNT}.file.core.windows.net
mount -t nfs "${NFS_HOST}:/${NFS_ACCOUNT}/${SHARE_NAME}" /mnt/nfsshare \
    -o "vers=4,minorversion=1,sec=sys,nconnect=4"

# ---------- Azure NetApp Files NFS ----------
echo "==> Mounting Azure NetApp Files NFS at /mnt/netapp"
mount -t nfs "${ANF_IP}:/${ANF_PATH}" /mnt/netapp \
    -o "vers=4.1,sec=sys,nconnect=8,rsize=262144,wsize=262144,hard,timeo=600,retrans=2"

# ---------- Create the storage/ subdirs the fio commands write into ----------
mkdir -p /mnt/fileshare/storage /mnt/nfsshare/storage /mnt/netapp/storage
chmod 777 /mnt/fileshare/storage /mnt/nfsshare/storage /mnt/netapp/storage

echo
echo "==> Mounts:"
df -hT | grep -E 'cifs|nfs' || true
echo
echo "==> Setup complete. You can now run: bash /tmp/run-fio-tests.sh"
