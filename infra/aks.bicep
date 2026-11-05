// One AKS cluster with a single small node: the cheapest cluster the course uses.
param name string

param location string = resourceGroup().location

@description('2 vCPUs and 8 GiB. AKS does not support the B series for a cluster\'s only node pool.')
param nodeVmSize string = 'Standard_D2as_v7'

resource aks 'Microsoft.ContainerService/managedClusters@2026-05-01' = {
  name: name
  location: location
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: '1.36'
    dnsPrefix: name
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        mode: 'System'
        osType: 'Linux'
        count: 1
        vmSize: nodeVmSize
        osDiskSizeGB: 32
      }
    ]
  }
}

output provisioningState string = aks.properties.provisioningState
