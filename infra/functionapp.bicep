@description('Region. Standard är resursgruppens egen.')
param location string = resourceGroup().location

@description('Namn på lagringskontot. Globalt unikt, bara gemener och siffror, 3-24 tecken.')
param storageAccountName string

@description('Namn på Flex Consumption-planen.')
param planName string

@description('Namn på funktionsappen. Ingår i adressen, måste vara globalt unikt.')
param functionAppName string

@description('Owner-tagg.')
param owner string

var tags = {
  owner: owner
  course: 'clo25'
  environment: 'dev'
  'managed-by': 'bicep'
}

resource storage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-04-01' = {
  name: '${storage.name}/default/app-package'
}

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // true = Linux, samma konvention som i App Service-spåret
  }
}

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: plan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}app-package'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

output functionAppHost string = functionApp.properties.defaultHostName
