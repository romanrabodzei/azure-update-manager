/*
.Synopsis
    Main Bicep template for Azure Update Manager components.

.NOTES
    Author     : Roman Rabodzei
    Version    : 1.0.240619
*/

////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////// Deployment scope /////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////

targetScope = 'subscription'

////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////// Parameters and variables ///////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////

@description('The location where the resources will be deployed.')
param deploymentLocation string = deployment().location
@description('The environment where the resources will be deployed.')
param deploymentEnvironment string = 'poc'
@description('The UTC date and time when the deployment is executed.')
param deploymentDate string = utcNow('yyyyMMddHHmm')

@description('Name of the resource group for the Azure Update Manager components.')
param azureUpdateManagerResourceGroupName string = 'az-${deploymentEnvironment}-update-manager-rg'

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string = 'az-${deploymentEnvironment}-update-manager-law'
param logAnalyticsWorkspaceRetentionInDays int = 30
@description('Daily quota for the Log Analytics workspace in GB. -1 means that there is no cap on the data ingestion.')
param logAnalyticsWorkspaceDailyQuotaGb int = -1

@description('Name of the automation account.')
param automationAccountName string = 'az-${deploymentEnvironment}-update-manager-aa'
@description('URI of the runbooks location. The repository URl where the runbooks are stored.')
param automationAccountRunbooksLocationUri string = 'https://raw.githubusercontent.com/romanrabodzei/azure-update-manager/main'

@description('Name of the user-assigned managed identity.')
param userAssignedIdentityName string = 'az-${deploymentEnvironment}-update-manager-mi'

@description('Name of the maintenance configuration.')
param maintenanceConfigName string = 'az-${deploymentEnvironment}-update-manager-mc'

@description('Name of the maintenance configuration assignment.')
param maintenanceConfigAssignmentName string = 'az-${deploymentEnvironment}-update-manager-mca'

@description('Custom start date for maintenance window. If not provided, current start date will be used. Format: yyyy-MM-dd')
param maintenanceStartDate string = ''
param currentStartDate string = utcNow('yyyy-MM-dd 00:00')

@description('Due to limitations of the Bicep language, the error "StartDateTime should be after 15 minutes of creation" may occur. The following code is used to calculate the next day. If the date is 28, the next day will be 01 next month. February has only 28 days, and 28 was taken just because of it.')
func calculateStartDate(currentStartDate string) object => {
  day: int(take(skip(currentStartDate, 8), 2)) < 28 ? string(int(take(skip(currentStartDate, 8), 2)) + 1) : '01'
  month: int(take(skip(currentStartDate, 8), 2)) < 28
    ? int(take(skip(currentStartDate, 5), 2)) <= 12 ? take(skip(currentStartDate, 5), 2) : '01'
    : int(take(skip(currentStartDate, 5), 2)) + 1 < 9
        ? '0${string(int(take(skip(currentStartDate, 5), 2)) + 1)}'
        : int(take(skip(currentStartDate, 5), 2)) + 1 > 12 ? '01' : string(int(take(skip(currentStartDate, 5), 2)) + 1)
  year: int(take(skip(currentStartDate, 5), 2)) < 12
    ? string(take(currentStartDate, 4))
    : string(int(take(currentStartDate, 4)) + 1)
}
func newStartDate(currentStartDate string) string =>
  '${calculateStartDate(currentStartDate).year}-${calculateStartDate(currentStartDate).month}-${calculateStartDate(currentStartDate).day} 00:00'

var maintenanceStartTime = maintenanceStartDate == '' ? newStartDate(currentStartDate) : '${maintenanceStartDate} 00:00'

@description('Custom start day for maintenance window. If not provided, Thursday is used.')
param maintenanceStartDay string = 'Thursday'
@description('The name of the policy initiative.')
param policyInitiativeName string = 'az-${deploymentEnvironment}-update-manager-initiative'
param policyAssignmentName string = 'az-${deploymentEnvironment}-update-manager-assignment'

/// tags
param tagKey string = 'environment'
param tagValue string = deploymentEnvironment
var tags = {
  '${tagKey}': tagValue
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////// Resources //////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////

resource resourceGroup_resource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: toLower(azureUpdateManagerResourceGroupName)
  location: deploymentLocation
  tags: tags
}

module managedIdentity_module './resources/managedIdentity.bicep' = {
  scope: resourceGroup_resource
  name: toLower('managedIdentity-${deploymentDate}')
  params: {
    location: deploymentLocation
    userAssignedIdentityName: userAssignedIdentityName
    tags: tags
  }
}

var roleDefinition = 'b24988ac-6180-42a0-ab88-20f7382dd24c' // 'Contributor'
resource roleDefinition_resource 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: roleDefinition
  scope: subscription()
}

resource roleAssignment_resource 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(roleDefinition_resource.name)
  scope: subscription()
  properties: {
    principalId: managedIdentity_module.outputs.userAssignedIdentityClientId
    roleDefinitionId: roleDefinition_resource.id
  }
}

module logAnalyticsWorkspace_module './resources/logAnalyticsWorkspace.bicep' = {
  scope: resourceGroup_resource
  name: toLower('logAnalyticsWorkspace-${deploymentDate}')
  params: {
    location: deploymentLocation
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    logAnalyticsWorkspaceRetentionInDays: logAnalyticsWorkspaceRetentionInDays
    logAnalyticsWorkspaceDailyQuotaGb: logAnalyticsWorkspaceDailyQuotaGb
    automationAccountName: automationAccountName
    automationAccountRunbooksLocationUri: automationAccountRunbooksLocationUri
    policyInitiativeName: policyInitiativeName
    userAssignedIdentityName: userAssignedIdentityName
    tags: tags
  }
  dependsOn: [managedIdentity_module]
}

module maintenanceConfiguration_module './resources/maintenanceConfigurations.bicep' = {
  scope: resourceGroup_resource
  name: toLower('maintenanceConfiguration-${deploymentDate}')
  params: {
    maintenanceConfigName: maintenanceConfigName
    location: deploymentLocation
    maintenanceStartDay: maintenanceStartDay
    maintenanceStartTime: maintenanceStartTime
    maintenanceReboot: 'IfRequired'
    tags: tags
  }
}

module configurationAssignment_module './resources/configurationAssignments.bicep' = {
  name: toLower('configurationAssignment-${deploymentDate}')
  params: {
    maintenanceConfigName: maintenanceConfigName
    maintenanceConfigResourceGroupName: azureUpdateManagerResourceGroupName
    maintenanceConfigAssignmentName: maintenanceConfigAssignmentName
    tagKey: tagKey
    tagValue: tagValue
  }
  dependsOn: [
    maintenanceConfiguration_module
  ]
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////// Policies ///////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////

module policies_module './policies/initiatives/initiativeDefinition.bicep' = {
  name: toLower('policies-${deploymentDate}')
  params: {
    deploymentEnvironment: deploymentEnvironment
    policyInitiativeName: policyInitiativeName
    policyAssignmentName: policyAssignmentName
    userAssignedIdentitiesId: managedIdentity_module.outputs.userAssignedIdentityId
    maintenanceConfigurationResourceId: maintenanceConfiguration_module.outputs.maintenanceConfigurationId
    tagKey: tagKey
    tagValue: tagValue
  }
}
