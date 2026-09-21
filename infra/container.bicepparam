using './container.bicep'

param registryName = 'acrclo25steven'
param environmentName = 'cae-clo25-steven'
param containerAppName = 'ca-clo25-steven'
param containerImage = 'acrclo25steven.azurecr.io/beacon:v1'
param minReplicas = 1
param maxReplicas = 5
