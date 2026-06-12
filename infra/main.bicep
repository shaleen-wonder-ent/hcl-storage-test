// Azure Shared-Storage IOPS Test Lab - infrastructure
// Deploys: VNet, NSG, 2 zone-pinned Linux VMs, 2 Premium FileStorage accounts
// (SMB + NFS shares), and an Azure NetApp Files account/pool/volume in zone 1.

@description('Location for all resources. Default westus3 (an ANF-zonal region).')
param location string = 'westus3'

@description('Short prefix used in resource names. Lowercase letters/digits only.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'iopslab'

@description('Linux admin username on the VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key (contents of id_*.pub) for the admin user.')
@secure()
param sshPublicKey string

@description('Source address prefix allowed to SSH to the VMs. Use <your-ip>/32 in production.')
param sshSourceAddressPrefix string = '*'

@description('VM size. Reference run used Standard_D8s_v5.')
param vmSize string = 'Standard_D8s_v5'

@description('Availability zone for the ANF volume and the "aligned" VM.')
@allowed([ '1', '2', '3' ])
param alignedZone string = '1'

@description('Availability zone for the "misaligned" VM. Must differ from alignedZone.')
@allowed([ '1', '2', '3' ])
param misalignedZone string = '2'

@description('Azure NetApp Files service level.')
@allowed([ 'Standard', 'Premium', 'Ultra' ])
param anfServiceLevel string = 'Premium'

@description('ANF capacity pool size in TiB (minimum 1, must be >= volume size).')
@minValue(1)
@maxValue(500)
param anfPoolSizeTiB int = 4

@description('ANF volume size in GiB. 2048 = 2 TiB.')
@minValue(100)
param anfVolumeSizeGiB int = 2048

@description('Azure Files share quota in GiB.')
@minValue(100)
param fileShareQuotaGiB int = 100

// ---------- naming ----------
var suffix = toLower(uniqueString(resourceGroup().id))
var vnetName = '${namePrefix}-vnet'
var vmSubnetName = 'vm-subnet'
var anfSubnetName = 'anf-subnet'
var nsgName = '${namePrefix}-nsg'
var smbAccountName = toLower('${namePrefix}smb${suffix}')
var nfsAccountName = toLower('${namePrefix}nfs${suffix}')
var anfAccountName = '${namePrefix}-anf'
var anfPoolName = 'pool1'
var anfVolumeName = 'vol1'
var shareName = 'storage'

var poolSizeBytes = anfPoolSizeTiB * 1024 * 1024 * 1024 * 1024
var volumeSizeBytes = anfVolumeSizeGiB * 1024 * 1024 * 1024

// ---------- network ----------
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.50.0.0/16' ] }
    subnets: [
      {
        name: vmSubnetName
        properties: {
          addressPrefix: '10.50.1.0/24'
          networkSecurityGroup: { id: nsg.id }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        name: anfSubnetName
        properties: {
          addressPrefix: '10.50.2.0/24'
          delegations: [
            {
              name: 'anf-delegation'
              properties: { serviceName: 'Microsoft.NetApp/volumes' }
            }
          ]
        }
      }
    ]
  }
}

resource vmSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: vmSubnetName
}

resource anfSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: anfSubnetName
}

// ---------- Azure Files: SMB ----------
resource smbAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: smbAccountName
  location: location
  kind: 'FileStorage'
  sku: { name: 'Premium_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    largeFileSharesState: 'Enabled'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        { id: vmSubnet.id, action: 'Allow' }
      ]
    }
  }
}

resource smbShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  name: '${smbAccount.name}/default/${shareName}'
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
    accessTier: 'Premium'
  }
}

// ---------- Azure Files: NFS ----------
resource nfsAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: nfsAccountName
  location: location
  kind: 'FileStorage'
  sku: { name: 'Premium_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    // NFS requires HTTPS-only OFF on the data plane; the property below
    // governs blob/file SMB encryption negotiation, NFS bypasses it.
    supportsHttpsTrafficOnly: false
    allowSharedKeyAccess: true
    largeFileSharesState: 'Enabled'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        { id: vmSubnet.id, action: 'Allow' }
      ]
    }
  }
}

resource nfsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  name: '${nfsAccount.name}/default/${shareName}'
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    accessTier: 'Premium'
  }
}

// ---------- Azure NetApp Files ----------
resource anfAccount 'Microsoft.NetApp/netAppAccounts@2024-03-01' = {
  name: anfAccountName
  location: location
  properties: {}
}

resource anfPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2024-03-01' = {
  parent: anfAccount
  name: anfPoolName
  location: location
  properties: {
    serviceLevel: anfServiceLevel
    size: poolSizeBytes
    qosType: 'Auto'
  }
}

resource anfVolume 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2024-03-01' = {
  parent: anfPool
  name: anfVolumeName
  location: location
  zones: [ alignedZone ]
  properties: {
    creationToken: anfVolumeName
    serviceLevel: anfServiceLevel
    usageThreshold: volumeSizeBytes
    subnetId: anfSubnet.id
    protocolTypes: [ 'NFSv4.1' ]
    networkFeatures: 'Standard'
    exportPolicy: {
      rules: [
        {
          ruleIndex: 1
          unixReadOnly: false
          unixReadWrite: true
          nfsv3: false
          nfsv41: true
          allowedClients: '10.50.0.0/16'
          hasRootAccess: true
        }
      ]
    }
  }
}

// ---------- VMs ----------
module alignedVm 'modules/vm.bicep' = {
  name: 'vm-aligned-deploy'
  params: {
    name: 'vm-aligned'
    location: location
    zone: alignedZone
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    subnetId: vmSubnet.id
  }
}

module misalignedVm 'modules/vm.bicep' = {
  name: 'vm-misaligned-deploy'
  params: {
    name: 'vm-misaligned'
    location: location
    zone: misalignedZone
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    subnetId: vmSubnet.id
  }
}

// ---------- outputs ----------
output alignedVmName string = 'vm-aligned'
output alignedVmIp string = alignedVm.outputs.publicIp
output misalignedVmName string = 'vm-misaligned'
output misalignedVmIp string = misalignedVm.outputs.publicIp
output adminUsername string = adminUsername

output smbAccount string = smbAccount.name
output smbShare string = shareName
output nfsAccount string = nfsAccount.name
output nfsShare string = shareName

output anfMountIp string = anfVolume.properties.mountTargets[0].ipAddress
output anfMountPath string = anfVolume.properties.creationToken
output anfZone string = alignedZone
