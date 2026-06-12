#!/usr/bin/env bash
# Deploys the Azure shared-storage IOPS lab. Mirrors deploy.ps1 for bash users.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]
  --subscription <id>          Azure subscription ID (required)
  --resource-group <name>      Resource group name (required)
  --location <region>          Azure region (default: westus3)
  --ssh-public-key <path>      Path to your SSH public key (required)
  --ssh-source <cidr>          Source CIDR allowed to SSH (default: *)
  --name-prefix <s>            Resource name prefix (default: iopslab)
  --vm-size <sku>              VM size (default: Standard_D8s_v5)
  --aligned-zone <1|2|3>       Zone for ANF + aligned VM (default: 1)
  --misaligned-zone <1|2|3>    Zone for the misaligned VM (default: 2)
  --anf-service-level <s>      Standard|Premium|Ultra (default: Premium)
  --anf-pool-tib <n>           Capacity pool size in TiB (default: 4)
  --anf-volume-gib <n>         ANF volume size in GiB (default: 2048)
  --file-share-gib <n>         Azure Files share quota in GiB (default: 100)
EOF
}

LOCATION=westus3
SSH_SOURCE='*'
NAME_PREFIX=iopslab
VM_SIZE=Standard_D8s_v5
ALIGNED_ZONE=1
MISALIGNED_ZONE=2
ANF_SVC=Premium
ANF_POOL_TIB=4
ANF_VOL_GIB=2048
FILE_SHARE_GIB=100

while [[ $# -gt 0 ]]; do
    case $1 in
        --subscription)        SUBSCRIPTION=$2;       shift 2;;
        --resource-group)      RG=$2;                 shift 2;;
        --location)            LOCATION=$2;           shift 2;;
        --ssh-public-key)      SSH_PUB=$2;            shift 2;;
        --ssh-source)          SSH_SOURCE=$2;         shift 2;;
        --name-prefix)         NAME_PREFIX=$2;        shift 2;;
        --vm-size)             VM_SIZE=$2;            shift 2;;
        --aligned-zone)        ALIGNED_ZONE=$2;       shift 2;;
        --misaligned-zone)     MISALIGNED_ZONE=$2;    shift 2;;
        --anf-service-level)   ANF_SVC=$2;            shift 2;;
        --anf-pool-tib)        ANF_POOL_TIB=$2;       shift 2;;
        --anf-volume-gib)      ANF_VOL_GIB=$2;        shift 2;;
        --file-share-gib)      FILE_SHARE_GIB=$2;     shift 2;;
        -h|--help)             usage; exit 0;;
        *) echo "Unknown arg: $1"; usage; exit 1;;
    esac
done

: "${SUBSCRIPTION:?--subscription is required}"
: "${RG:?--resource-group is required}"
: "${SSH_PUB:?--ssh-public-key is required}"
[[ -f "$SSH_PUB" ]] || { echo "SSH public key not found at $SSH_PUB"; exit 1; }
SSH_KEY=$(<"$SSH_PUB")

HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> Selecting subscription $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION"

echo "==> Registering required resource providers"
for p in Microsoft.NetApp Microsoft.Storage Microsoft.Compute Microsoft.Network; do
    az provider register --namespace "$p" --wait >/dev/null
done

echo "==> Creating resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" >/dev/null

DEPLOY_NAME="storage-iops-lab-$(date +%Y%m%d%H%M%S)"
echo "==> Deploying Bicep ($DEPLOY_NAME) - ~15-20 minutes"

if ! az deployment group create \
    --name "$DEPLOY_NAME" \
    --resource-group "$RG" \
    --template-file "$HERE/main.bicep" \
    --parameters \
        location="$LOCATION" \
        namePrefix="$NAME_PREFIX" \
        sshPublicKey="$SSH_KEY" \
        sshSourceAddressPrefix="$SSH_SOURCE" \
        vmSize="$VM_SIZE" \
        alignedZone="$ALIGNED_ZONE" \
        misalignedZone="$MISALIGNED_ZONE" \
        anfServiceLevel="$ANF_SVC" \
        anfPoolSizeTiB="$ANF_POOL_TIB" \
        anfVolumeSizeGiB="$ANF_VOL_GIB" \
        fileShareQuotaGiB="$FILE_SHARE_GIB" \
    --output json > "$HERE/.deploy.json"; then
    echo "ERROR: Bicep deployment failed. See error above. Aborting." >&2
    rm -f "$HERE/.deploy.json"
    exit 1
fi

jq_get() { jq -r ".properties.outputs.$1.value" "$HERE/.deploy.json"; }

ALIGNED_NAME=$(jq_get alignedVmName)
ALIGNED_IP=$(jq_get alignedVmIp)
MISALIGNED_NAME=$(jq_get misalignedVmName)
MISALIGNED_IP=$(jq_get misalignedVmIp)
ADMIN=$(jq_get adminUsername)
SMB_ACCT=$(jq_get smbAccount)
SMB_SHARE=$(jq_get smbShare)
NFS_ACCT=$(jq_get nfsAccount)
NFS_SHARE=$(jq_get nfsShare)
ANF_IP=$(jq_get anfMountIp)
ANF_PATH=$(jq_get anfMountPath)
ANF_ZONE=$(jq_get anfZone)

echo "==> Reading storage account keys"
SMB_KEY=$(az storage account keys list --account-name "$SMB_ACCT" --resource-group "$RG" --query '[0].value' -o tsv)

cat > "$HERE/lab-output.json" <<JSON
{
    "resourceGroup":    "$RG",
    "location":         "$LOCATION",
    "alignedVmName":    "$ALIGNED_NAME",
    "alignedVmIp":      "$ALIGNED_IP",
    "misalignedVmName": "$MISALIGNED_NAME",
    "misalignedVmIp":   "$MISALIGNED_IP",
    "adminUsername":    "$ADMIN",
    "smbAccount":       "$SMB_ACCT",
    "smbShare":         "$SMB_SHARE",
    "smbKey":           "$SMB_KEY",
    "nfsAccount":       "$NFS_ACCT",
    "nfsShare":         "$NFS_SHARE",
    "anfMountIp":       "$ANF_IP",
    "anfMountPath":     "$ANF_PATH",
    "anfZone":          "$ANF_ZONE"
}
JSON
rm -f "$HERE/.deploy.json"

echo
echo "==> Deployment complete. Connection info written to lab-output.json"
echo
SSH_PRIV=${SSH_PUB%.pub}
SCRIPTS_DIR=$(cd "$HERE/../scripts" && pwd)

for pair in "$ALIGNED_NAME|$ALIGNED_IP" "$MISALIGNED_NAME|$MISALIGNED_IP"; do
    name=${pair%|*}; ip=${pair#*|}
    echo "==> Copying helper scripts to $name ($ip)"
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    scp -i "$SSH_PRIV" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$SCRIPTS_DIR/setup-vm.sh" "$SCRIPTS_DIR/run-fio-tests.sh" \
        "$ADMIN@$ip:/tmp/"
done

cat <<NEXT

==> Next steps:

1) Mount shares on both VMs (run on each):
     ssh -i $SSH_PRIV $ADMIN@$ALIGNED_IP \\
       "sudo bash /tmp/setup-vm.sh '$SMB_ACCT' '<SMB_KEY>' '$NFS_ACCT' '$ANF_IP' '$ANF_PATH'"

   Get <SMB_KEY> from lab-output.json (the smbKey field).

2) Run the fio tests on both VMs:
     ssh -i $SSH_PRIV $ADMIN@$ALIGNED_IP    "bash /tmp/run-fio-tests.sh"
     ssh -i $SSH_PRIV $ADMIN@$MISALIGNED_IP "bash /tmp/run-fio-tests.sh"
NEXT
