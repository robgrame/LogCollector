// Deploys custom Log Analytics tables into a workspace that may live in a different
// resource group/subscription than the caller. Kept as a separate module because a
// resource of type "workspaces/tables" cannot declare an explicit "scope" itself;
// only the enclosing module deployment can be scoped to another resource group.

@description('Name of the Log Analytics workspace (existing or just-created) that will receive the tables.')
param workspaceName string

@description('Table definitions: array of { name, columns }.')
param tableDefinitions array

@description('Retention (days) applied to each table.')
param retentionInDays int

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource tables 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for table in tableDefinitions: {
  parent: workspace
  name: table.name
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
    schema: {
      name: table.name
      columns: table.columns
    }
  }
}]
