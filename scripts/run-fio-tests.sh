#!/usr/bin/env bash
# run-fio-tests.sh - Runs the reference 75/25 randrw 4k fio burst test against
# all 3 shares, then runs a 60s sustained variant for a more realistic read.

set -euo pipefail

MOUNTS=(
    "azurefiles_smb=/mnt/fileshare"
    "azurefiles_nfs=/mnt/nfsshare"
    "netapp_nfs=/mnt/netapp"
)

HOSTNAME_OUT=$(hostname)
echo "=========================================================="
echo "  fio results on $HOSTNAME_OUT  ($(date -u +%FT%TZ))"
echo "=========================================================="

# Where is this VM running (zone)? Pulled from instance metadata so we can
# tag results clearly.
ZONE=$(curl -fsS -H Metadata:true --max-time 3 \
    "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-02-01&format=text" \
    || echo unknown)
echo "VM zone: $ZONE"
echo

run_burst() {
    local label=$1 mount=$2
    local file="${mount}/storage/rrw.fio"
    rm -f "$file"
    echo "--- [$label] Burst test (75/25 randrw, 4k, iodepth=64, size=1M) ---"
    fio --randrepeat=1 --direct=1 --gtod_reduce=1 --name=test \
        --filename="$file" --bs=4k --iodepth=64 --size=1M \
        --readwrite=randrw --rwmixread=75 | grep -E 'IOPS|BW='
    echo
}

run_sustained() {
    local label=$1 mount=$2
    local file="${mount}/storage/rrw_sustained.fio"
    rm -f "$file"
    echo "--- [$label] Sustained test (75/25 randrw, 4k, iodepth=64, 60s, 4 jobs) ---"
    fio --randrepeat=1 --direct=1 --gtod_reduce=1 --name=sustained \
        --filename="$file" --bs=4k --iodepth=64 \
        --size=4G --runtime=60 --time_based \
        --numjobs=4 --group_reporting \
        --readwrite=randrw --rwmixread=75 | grep -E 'IOPS|BW='
    echo
}

echo "##########  BURST TEST (75/25 randrw, 4k, iodepth=64, size=1M)  ##########"
for entry in "${MOUNTS[@]}"; do
    label=${entry%=*}; path=${entry#*=}
    run_burst "$label" "$path"
done

echo "##########  SUSTAINED 60s TEST  ##########"
for entry in "${MOUNTS[@]}"; do
    label=${entry%=*}; path=${entry#*=}
    run_sustained "$label" "$path"
done

echo "=========================================================="
echo "  Done on $HOSTNAME_OUT (zone $ZONE)"
echo "=========================================================="
