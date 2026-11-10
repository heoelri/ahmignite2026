targetScope = 'resourceGroup'

@minLength(3)
@maxLength(16)
@description('Lowercase letters and numbers only; use a new name for each demo.')
param name string = 'ignitecoffee'
param location string = resourceGroup().location
param nodeVmSize string = 'Standard_D2s_v5'
@description('Entra user object ID granted Kubernetes RBAC Cluster Admin on this demo cluster.')
param operatorPrincipalId string

var suffix = uniqueString(resourceGroup().id, name)
var tags = { purpose: 'ignite-health-model-demo' }

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource metrics 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: '${name}-metrics'
  location: location
  tags: tags
  properties: { publicNetworkAccess: 'Enabled' }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-app'
  location: location
  tags: tags
}

resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-cluster'
  location: location
  tags: tags
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${name}-nsg'
  location: location
  tags: tags
  properties: { securityRules: [] }
}

resource network 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [
      {
        name: 'aks'
        properties: {
          addressPrefix: '10.20.0.0/22'
          defaultOutboundAccess: false
          networkSecurityGroup: { id: networkSecurityGroup.id }
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.20.4.0/27'
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: { id: networkSecurityGroup.id }
        }
      }
    ]
  }
}

resource clusterNetworkAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: network
  name: guid(network.id, clusterIdentity.id, 'network')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4d97b98b-1d4f-4787-a291-c67834d212e7'
    )
    principalId: clusterIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: '${name}-aks'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${clusterIdentity.id}': {} }
  }
  sku: { name: 'Base', tier: 'Free' }
  properties: {
    dnsPrefix: '${name}-${suffix}'
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    azureMonitorProfile: { metrics: { enabled: true } }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 2
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osDiskSizeGB: 64
        vnetSubnetID: '${network.id}/subnets/aks'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logs.id
          useAADAuth: 'true'
        }
      }
    }
  }
  dependsOn: [clusterNetworkAccess]
}

resource operatorAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aks
  name: guid(aks.id, operatorPrincipalId, 'operator')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
    )
    principalId: operatorPrincipalId
    principalType: 'User'
  }
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: appIdentity
  name: 'aks-demo'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:ignite-demo:app'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, aks.id, 'AcrPull')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource events 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: '${name}-${suffix}-events'
  location: location
  tags: tags
  sku: { name: 'Basic', tier: 'Basic', capacity: 1 }
  properties: {
    minimumTlsVersion: '1.2'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource ordersHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: events
  name: 'orders'
  properties: {
    partitionCount: 1
    messageRetentionInDays: 1
  }
}

resource eventRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in [
    '2b629674-e913-4c01-ae53-ef4638d8f975' // Event Hubs Data Sender
    'a638d3c7-ab3a-418d-83e6-5f17a39d4fde' // Event Hubs Data Receiver
  ]: {
    scope: events
    name: guid(events.id, appIdentity.id, role)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
      principalId: appIdentity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${suffix}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { name: 'standard', family: 'A' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}

resource vaultEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${name}-vault-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${network.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource vaultDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource vaultDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: vaultDns
  name: '${name}-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: network.id }
  }
}

resource vaultDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: vaultEndpoint
  name: 'vault'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'vault', properties: { privateDnsZoneId: vaultDns.id } }
    ]
  }
}

resource brand 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'store-name'
  // Deliberately non-sensitive sample configuration, not a credential.
  properties: { value: 'Ignite Coffee' }
}

resource secretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, appIdentity.id, 'secrets')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource ordersContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'orders'
  properties: { publicAccess: 'None' }
}

resource blobWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, appIdentity.id, 'blobs')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource collection 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${name}-containers'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: ['Microsoft-ContainerLogV2']
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Include'
              namespaces: ['ignite-demo']
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [{ name: 'logs', workspaceResourceId: logs.id }]
    }
    dataFlows: [
      { streams: ['Microsoft-ContainerLogV2'], destinations: ['logs'] }
    ]
  }
}

resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  scope: aks
  name: 'ContainerInsightsExtension'
  properties: { dataCollectionRuleId: collection.id }
}

resource metricsEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: '${name}-prometheus'
  location: location
  tags: tags
  kind: 'Linux'
  properties: { networkAcls: { publicNetworkAccess: 'Enabled' } }
}

resource metricsCollection 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${name}-prometheus'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: metricsEndpoint.id
    dataSources: {
      prometheusForwarder: [
        { name: 'prometheus', streams: ['Microsoft-PrometheusMetrics'] }
      ]
    }
    destinations: {
      monitoringAccounts: [{ name: 'metrics', accountResourceId: metrics.id }]
    }
    dataFlows: [
      { streams: ['Microsoft-PrometheusMetrics'], destinations: ['metrics'] }
    ]
  }
}

resource metricsAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  scope: aks
  name: 'MSProm-${location}-${aks.name}'
  properties: { dataCollectionRuleId: metricsCollection.id }
}

resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aks
  name: 'log-analytics'
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource eventDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: events
  name: 'log-analytics'
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vault
  name: 'log-analytics'
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storage
  name: 'log-analytics'
  properties: {
    workspaceId: logs.id
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

// Storage operation logs are emitted by the Blob service, not the account.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobs
  name: 'log-analytics'
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

output config object = {
  aksName: aks.name
  aksId: aks.id
  registryName: registry.name
  registryServer: registry.properties.loginServer
  clientId: appIdentity.properties.clientId
  eventNamespace: '${events.name}.servicebus.windows.net'
  eventHub: ordersHub.name
  vaultUrl: vault.properties.vaultUri
  blobUrl: storage.properties.primaryEndpoints.blob
  workspaceId: logs.id
  workspaceCustomerId: logs.properties.customerId
  metricsWorkspaceId: metrics.id
  vaultId: vault.id
  eventNamespaceId: events.id
  storageId: storage.id
}
