param healthModelName string = 'ignitecoffee-health'
param location string
@description('The config output from the infrastructure deployment.')
param config object
@description('Optional notification destinations. Empty means portal alerts only.')
param actionGroupIds array = []

var catalog = loadJsonContent('signals.json')
var cpuSpec = catalog.cpu

resource model 'Microsoft.CloudHealth/healthmodels@2026-11-01' = {
  name: healthModelName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {}
}

// Update the automatically created root, using its existing entity name.
resource root 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = {
  parent: model
  name: healthModelName
  properties: {
    displayName: 'Ignite Coffee'
    canvasPosition: { x: 1125, y: 0 }
    tags: {
      application: 'Ignite Coffee'
      environment: 'Demo'
      scenario: 'Worker hosting fault is isolated with suppressed impact; green journeys do not prove fulfillment'
    }
  }
}

var canvasPositions = {
  browse: { x: 1500, y: 194 }
  order: { x: 500, y: 194 }
  'browse-web': { x: 1250, y: 388 }
  'browse-api': { x: 1625, y: 388 }
  'order-web': { x: 500, y: 388 }
  'order-api': { x: 875, y: 388 }
  'order-worker': { x: 125, y: 388 }
  'browse-web-aks': { x: 1250, y: 582 }
  'browse-api-aks': { x: 1500, y: 582 }
  'order-web-aks': { x: 500, y: 582 }
  'order-api-aks': { x: 750, y: 582 }
  'order-worker-aks': { x: 250, y: 582 }
  'menu-vault': { x: 1750, y: 582 }
  'order-events': { x: 1000, y: 582 }
  'order-storage': { x: 0, y: 582 }
}

resource roles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in [
    'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  ]: {
    name: guid(resourceGroup().id, model.id, role)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
      principalId: model.identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource auth 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-11-01' = {
  parent: model
  name: 'system-assigned'
  properties: {
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
  dependsOn: [roles]
}

resource cpu 'Microsoft.CloudHealth/healthmodels/signaldefinitions@2026-11-01' = {
  parent: model
  name: cpuSpec.name
  properties: {
    signalKind: 'AzureResourceMetric'
    displayName: cpuSpec.label
    metricNamespace: cpuSpec.namespace
    metricName: cpuSpec.metric
    aggregationType: cpuSpec.aggregation
    timeGrain: cpuSpec.timeGrain
    refreshInterval: 'PT1M'
    dataUnit: cpuSpec.unit
    evaluationRules: {
      degradedRule: { operator: cpuSpec.operator, threshold: cpuSpec.degraded }
      unhealthyRule: { operator: cpuSpec.operator, threshold: cpuSpec.unhealthy }
    }
  }
}

var flowNames = ['browse', 'order']
var flowLabels = ['Browse the menu', 'Receive a coffee order']
resource flows 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [
  for (flow, i) in flowNames: {
    parent: model
    name: flow
    properties: {
      displayName: flowLabels[i]
      canvasPosition: canvasPositions[flow]
      icon: { iconName: 'UserFlow' }
      healthObjective: json('99.9')
      tags: {
        journey: flow
        successCriteria: flow == 'browse' ? 'Menu and store name can be read' : 'Accepted coffee order is prepared and persisted'
      }
      alerts: {
        unhealthy: union(
          {
            severity: 'Sev2'
            description: '${flowLabels[i]} is not working'
          },
          empty(actionGroupIds) ? {} : { actionGroupIds: actionGroupIds }
        )
      }
      signalGroups: { dependencies: { aggregationType: 'WorstOf' } }
    }
  }
]

var components = catalog.components
var queryFiles = {
  failures: loadTextContent('queries/failures.kql')
  heartbeat: loadTextContent('queries/heartbeat.kql')
}
var querySpecs = catalog.logSignals
var componentLogSources = [for component in components: { role: component.role, flow: component.flow }]
var logSources = concat(
  componentLogSources,
  catalog.additionalLogSources
)
var workerLogIndex = length(components) * 2
var eventHubLogIndex = workerLogIndex + 2
var logSignals = [
  for i in range(0, length(logSources) * 2): {
    name: querySpecs[i % 2].name
    signalKind: 'LogAnalyticsQuery'
    displayName: querySpecs[i % 2].name
    queryText: replace(
      replace(replace(queryFiles[querySpecs[i % 2].kind], '__CLUSTER_ID__', config.aksId), '__ROLE__', logSources[i / 2].role),
      '__FLOW__',
      logSources[i / 2].flow
    )
    valueColumnName: 'value'
    timeGrain: 'PT15M'
    refreshInterval: 'PT1M'
    dataUnit: querySpecs[i % 2].unit
    evaluationRules: {
      degradedRule: { operator: querySpecs[i % 2].operator, threshold: querySpecs[i % 2].degraded }
      unhealthyRule: { operator: querySpecs[i % 2].operator, threshold: querySpecs[i % 2].unhealthy }
    }
  }
]

resource services 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [
  for (component, i) in components: {
    parent: model
    name: component.name
    properties: {
      displayName: component.label
      canvasPosition: canvasPositions[component.name]
      icon: { iconName: 'SystemComponent' }
      tags: { journey: component.parent, purpose: component.purpose }
      signalGroups: {
        dependencies: { aggregationType: 'WorstOf' }
        azureLogAnalytics: {
          authenticationSetting: auth.name
          logAnalyticsWorkspaceResourceId: config.workspaceId
          signals: [
            logSignals[i * 2]
            logSignals[i * 2 + 1]
          ]
        }
      }
    }
  }
]

resource hosting 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [
  for component in components: {
    parent: model
    name: '${component.name}-aks'
    properties: {
      displayName: 'AKS: ${config.aksName} (${component.name})'
      canvasPosition: canvasPositions['${component.name}-aks']
      tags: { namespace: 'ignite-demo', workload: component.role }
      // Isolate the intentional worker fault; do not propagate it into the journeys.
      impact: component.role == 'worker' ? 'Suppressed' : 'Standard'
      signalGroups: {
        azureLogAnalytics: {
          authenticationSetting: auth.name
          logAnalyticsWorkspaceResourceId: config.workspaceId
          signals: component.role == 'worker' ? [logSignals[workerLogIndex], logSignals[workerLogIndex + 1]] : []
        }
        azureResource: {
          authenticationSetting: auth.name
          azureResourceId: config.aksId
          resourceHealth: { enabled: 'Disabled' }
          signals: [{ name: 'node-cpu', signalKind: 'AzureResourceMetric', signalDefinitionName: cpu.name }]
        }
      }
    }
  }
]

var dependencies = catalog.dependencies
resource backing 'Microsoft.CloudHealth/healthmodels/entities@2026-11-01' = [
  for dependency in dependencies: {
    parent: model
    name: dependency.name
    properties: {
      displayName: dependency.label
      canvasPosition: canvasPositions[dependency.name]
      tags: { purpose: dependency.purpose, access: dependency.access }
      signalGroups: {
        azureLogAnalytics: {
          authenticationSetting: auth.name
          logAnalyticsWorkspaceResourceId: config.workspaceId
          signals: dependency.name == 'order-events' ? [logSignals[eventHubLogIndex], logSignals[eventHubLogIndex + 1]] : []
        }
        azureResource: {
          authenticationSetting: auth.name
          azureResourceId: config[dependency.resourceIdKey]
          resourceHealth: { enabled: dependency.resourceHealth }
          signals: [
            for signal in dependency.signals: {
              name: signal.name
              signalKind: 'AzureResourceMetric'
              displayName: signal.label
              metricNamespace: signal.namespace
              metricName: signal.metric
              aggregationType: signal.aggregation
              timeGrain: signal.timeGrain
              refreshInterval: 'PT1M'
              dataUnit: signal.unit
              evaluationRules: {
                degradedRule: { operator: signal.operator, threshold: signal.degraded }
                unhealthyRule: { operator: signal.operator, threshold: signal.unhealthy }
              }
            }
          ]
        }
      }
    }
  }
]

var rootEdges = [
  for (flow, i) in flowNames: {
    parent: healthModelName
    child: flow
    label: flowLabels[i]
    kind: 'Customer journey'
  }
]
var componentEdges = [
  for component in components: {
    parent: component.parent
    child: component.name
    label: component.purpose
    kind: 'Application component'
  }
]
var hostingEdges = [
  for component in components: {
    parent: component.name
    child: '${component.name}-aks'
    label: 'Hosted on AKS'
    kind: 'Hosting'
  }
]
var backingEdges = [
  for dependency in dependencies: {
    parent: dependency.parent
    child: dependency.name
    label: dependency.purpose
    kind: 'Backing service'
  }
]
var edges = concat(rootEdges, componentEdges, hostingEdges, backingEdges)
resource relationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-11-01' = [
  for edge in edges: {
    parent: model
    name: '${edge.parent}-${edge.child}'
    properties: {
      parentEntityName: edge.parent
      childEntityName: edge.child
      displayName: edge.label
      tags: { dependencyType: edge.kind }
    }
    dependsOn: [flows, services, hosting, backing]
  }
]

output healthModelId string = model.id
output principalId string = model.identity.principalId
