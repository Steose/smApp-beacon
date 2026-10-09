using './container.bicep'

param registryName = 'acrclo25steve'
param environmentName = 'cae-clo25-steven'
param containerAppName = 'ca-clo25-steven'
param containerImage = 'acrclo25steve.azurecr.io/beacon:v1'
param minReplicas = 1
param maxReplicas = 5
