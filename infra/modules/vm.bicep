// Single Linux VM with public IP, zone-pinned, Ubuntu 22.04 LTS.
@description('VM name')
param name string

@description('Region')
param location string

@description('Availability zone (1, 2, or 3)')
param zone string

@description('VM size')
param vmSize string

@description('Admin username')
param adminUsername string

@description('SSH public key contents')
@secure()
param sshPublicKey string

@description('Subnet resource ID for the VM NIC')
param subnetId string

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${name}-pip'
  location: location
  sku: { name: 'Standard' }
  zones: [ zone ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: subnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  zones: [ zone ]
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        diskSizeGB: 64
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

output publicIp string = pip.properties.ipAddress
output vmId string = vm.id
