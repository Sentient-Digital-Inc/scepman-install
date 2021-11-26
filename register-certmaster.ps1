# for testing
$env:CERTMASTER_APP_SERVICE_NAME = "as-certmaster-askjvljweklraesr"
$env:SCEPMAN_RESOURCE_GROUP = "rg-SCEPman"


$CertMasterAppServiceName = $env:CERTMASTER_APP_SERVICE_NAME
$CertMasterBaseURL = "https://$CertMasterAppServiceName.azurewebsites.net"
$SCEPmanResourceGroup = $env:SCEPMAN_RESOURCE_GROUP

az login

# Some hard-coded definitions
$MSGraphAppId = "00000003-0000-0000-c000-000000000000"
$MSGraphDirectoryReadAllPermission = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
$MSGraphDeviceManagementReadPermission = "2f51be20-0bb4-4fed-bf7b-db946066c75e"
$MSGraphUserReadPermission = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"

# "0000000a-0000-0000-c000-000000000000" # Service Principal App Id of Intune, not required here
$IntuneAppId = "c161e42e-d4df-4a3d-9b42-e7a3c31f59d4" # Well-known App ID of the Intune API
$IntuneSCEPChallengePermission = "39d724e8-6a34-4930-9a36-364082c35716"

$MAX_RETRY_COUNT = 4  # for some operations, retry a couple of times

# Getting tenant details
$tenantlines = az account show
$tenantjson = [System.String]::Concat($tenantlines)
$tenant = ConvertFrom-Json $tenantjson

# It is intended to use for az cli add permissions and az cli add permissions admin
# $azCommand - The command to execute. 
# 
function ExecuteAzCommandRobustly($azCommand, $principalId = $null, $appRoleId = $null) {
  $azErrorCode = 1 # A number not null
  $retryCount = 0
  while ($azErrorCode -ne 0 -and $retryCount -le $MAX_RETRY_COUNT) {
    $lastAzOutput = Invoke-Expression $azCommand # the output is often empty in case of error :-(. az just writes to the console then
    $azErrorCode = $LastExitCode
    if($null -ne $appRoleId -and $azErrorCode -eq 0) {
      $appRoleAssignmentsResponse = az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments"
      $appRoleAssignmentsResponseJson = [System.String]::Concat($appRoleAssignmentsResponse)
      $appRoleAssignments = ConvertFrom-Json($appRoleAssignmentsResponseJson)
      $grantedPermission = $appRoleAssignments.value | ? { $_.appRoleId -eq $appRoleId }
      if ($null -eq $grantedPermission) {
        $azErrorCode = 999 # A number not 0
      }
    }
    if ($azErrorCode -ne 0) {
      ++$retryCount
      Write-Debug "Retry $retryCount for $azCommand"
      Start-Sleep $retryCount # Sleep for some seconds, as the grant sometimes only works after some time
    }
  }
  if ($azErrorCode -ne 0 ) {
    Write-Error "Error $azErrorCode when executing $azCommand : $lastAzOutput"
    #exit $lastAzError
  }
  else {
    return $lastAzOutput
  }
}

### SCEPman App Registration
# JSON defining App Role that CertMaster uses to authenticate against SCEPman
$ScepmanManifest = '[{ 
    \"allowedMemberTypes\": [
      \"Application\"
    ],
    \"description\": \"Request certificates via the raw CSR API\",
    \"displayName\": \"CSR Requesters\",
    \"isEnabled\": \"true\",
    \"value\": \"CSR.Request\"
}]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

# Register SCEPman App
$appreglinessc = ExecuteAzCommandRobustly -azCommand "az ad app create --display-name SCEPman-xyz2 --app-roles '$ScepmanManifest'"
$appregjsonsc = [System.String]::Concat($appreglinessc)
$appregsc = ConvertFrom-Json $appregjsonsc

$splinessc = ExecuteAzCommandRobustly -azCommand "az ad sp create --id $($appregsc.appId)"
$spjsonsc = [System.String]::Concat($splinessc)
$spsc = ConvertFrom-Json $spjsonsc

$ScepManSubmitCSRPermission = $appregsc.appRoles[0].id

# Expose SCEPman API
az ad app update --id $appregsc.appId --identifier-uris "api://$($appregsc.appId)"

# Add Microsoft Graph's Directory.Read.All and DeviceManagementManagedDevices.Read as app permission for SCEPman
az ad app permission add --id $appregsc.appId --api $MSGraphAppId --api-permissions "$MSGraphDirectoryReadAllPermission=Role"
az ad app permission add --id $appregsc.appId --api $MSGraphAppId --api-permissions "$MSGraphDeviceManagementReadPermission=Role"
ExecuteAzCommandRobustly -azCommand "az ad app permission grant --id $($appregsc.appId) --api $MSGraphAppId"

# Add Intune SCEP Challenge for SCEPman
az ad app permission add --id $appregsc.appId --api $IntuneAppId --api-permissions "$IntuneSCEPChallengePermission=Role"
ExecuteAzCommandRobustly -azCommand "az ad app permission grant --id $($appregsc.appId) --api $IntuneAppId"

# Grant Admin consent. Seems to be required and require granting individual consents, too. But wait until the app is available.
ExecuteAzCommandRobustly -azCommand "az ad app permission admin-consent --id $($appregsc.appId)" -principalId $spsc.objectId -appRoleId $IntuneSCEPChallengePermission


### CertMaster App Registration
# JSON defining App Role that User can have to when authenticating against CertMaster
$CertmasterManifest = '[{ 
    \"allowedMemberTypes\": [
      \"User\"
    ],
    \"description\": \"Full access to all SCEPman CertMaster functions like requesting and managing certificates\",
    \"displayName\": \"Full Admin\",
    \"isEnabled\": \"true\",
    \"value\": \"Admin.Full\"
}]'.Replace("`r", [String]::Empty).Replace("`n", [String]::Empty)

# Register CertMaster App
$appreglinescm = az ad app create --display-name SCEPman-CertMaster-xyz3 --reply-urls "$CertMasterBaseURL/signin-oidc" --app-roles $CertmasterManifest 
$appregjsoncm = [System.String]::Concat($appreglinescm)
$appregcm = ConvertFrom-Json $appregjsoncm
az ad sp create --id $appregcm.appId

# Set Certmaster Client Secret
$expirationDate = (Get-Date).AddYears(10).ToString('yyyy-MM-dd')
$appsecretlinescm = az ad app credential reset --id $appregcm.appId --end-date $expirationDate --credential-description "SCEPman app" --append
$appsecretjsoncm = [System.String]::Concat($appsecretlinescm)
$appsecretcm = ConvertFrom-Json $appsecretjsoncm


# Add Microsoft Graph's User.Read as delegated permission for CertMaster
az ad app permission add --id $appregcm.appId --api $MSGraphAppId --api-permissions "$MSGraphUserReadPermission=Scope"
az ad app permission grant --id $appregcm.appId --api $MSGraphAppId --scope "User.Read"

# Allow CertMaster to submit CSR requests to SCEPman
az ad app permission add --id $appregcm.appId --api $appregsc.appId --api-permissions "$ScepManSubmitCSRPermission=Role"
az ad app permission grant --id $appregcm.appId --api $appregsc.appId


### Add CertMaster app service authentication
# Use v2 auth commands
az extension add --name authV2

# Enable the authentication
az webapp auth microsoft update --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --client-id $appregcm.appId --client-secret $appsecretcm.password --issuer "https://sts.windows.net/$($tenant.tenantId)/v2.0" --yes

# Add the Redirect To
az webapp auth update --name $CertMasterAppServiceName --resource-group $SCEPmanResourceGroup --redirect-provider AzureActiveDirectory
