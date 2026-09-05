# Primary User to Device Group Automation

This PowerShell automation synchronizes an Entra ID device group with the primary users in an Entra ID user group.

For every managed Windows device with a primary user, the script checks whether that user is a member of the source user group. Devices that belong in scope are added to the target device group. Devices that are no longer in scope are removed from the target device group.

## How It Works

The `Invoke-PrimaryUsertoDeviceGroup` function performs the following steps:

1. Validates that the source user group and target device group exist.
2. Retrieves all Intune managed devices running Windows that have a primary user.
3. Retrieves Entra ID devices and maps each Intune device to its Entra device object ID.
4. Reads the members of the source user group.
5. Selects devices whose Intune primary user is a member of that source group.
6. Compares the selected devices with the current target device group membership.
7. Adds missing devices and removes devices that are no longer in scope.

If the source user group is empty, all members currently in the target device group are removed. If no matching managed Windows devices are found, the target group is left unchanged.

## Requirements

- PowerShell 7 or later is recommended.
- The following Microsoft Graph PowerShell modules must be installed:
	- `Microsoft.Graph.Authentication`
	- `Microsoft.Graph.Groups`
	- `Microsoft.Graph.DeviceManagement`
	- `Microsoft.Graph.Identity.DirectoryManagement`
- The script must run in a context that supports managed identity authentication, such as an Azure Automation runbook, Azure Function, or another Azure-hosted workload with an assigned managed identity.
- The managed identity must have access to the required Microsoft Graph application permissions.

Install the required modules with:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

The script uses `Connect-MgGraph -Identity`; it does not prompt for delegated user sign-in.

## Required Graph Permissions

Assign these Microsoft Graph application permissions to the managed identity that runs the script:

- `DeviceManagementManagedDevices.Read.All`
- `Device.Read.All`
- `GroupMember.ReadWrite.All`

The included `assign_MI_permissions.ps1` script assigns the permissions to the managed identity. Replace `<Managed Identity Object ID>` before running it:

```powershell
#requires -module Microsoft.Graph.Applications

Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"

$managedIdentityObjectId = "<Managed Identity Object ID>"
$permissions = "DeviceManagementManagedDevices.Read.All", "Device.Read.All", "GroupMember.ReadWrite.All"

$graphApi = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$permissions = $graphApi.AppRoles | Where-Object {
	$_.Value -in $permissions -and $_.AllowedMemberTypes -contains "Application"
}

$permissions | ForEach-Object {
	$appRoleAssignment = @{
		ServicePrincipalId = $managedIdentityObjectId
		PrincipalId        = $managedIdentityObjectId
		ResourceId         = $graphApi.Id
		AppRoleId          = $_.Id
	}

	New-MgServicePrincipalAppRoleAssignment @appRoleAssignment
}
```

The identity performing the assignment needs sufficient permission to create app role assignments, such as `AppRoleAssignment.ReadWrite.All` together with `Application.Read.All`. The assignment script requires the `Microsoft.Graph.Applications` module.

### Scoped Alternatives to `GroupMember.ReadWrite.All`

Instead of granting the managed identity the tenant-wide `GroupMember.ReadWrite.All` application permission, group membership management can be scoped through Entra ID:

1. Set the Automation Account managed identity as an owner of the source and target groups. Group ownership should be used only when the managed identity must manage those specific groups.
2. Add the source and target groups to an administrative unit, then assign the managed identity an appropriate group administration role scoped to that administrative unit.

These approaches reduce the scope of group administration, but the managed identity must still be able to read the relevant group memberships and update the target group through Microsoft Graph. Validate the resulting permissions with a test run in the tenant, because supported group types, role assignment configuration, and Microsoft Graph authorization behavior can affect the outcome. Do not grant `GroupMember.ReadWrite.All` if the scoped ownership or administrative-unit configuration provides all access required by this automation.

## Usage

The script defines the function and connects to Microsoft Graph when it is loaded. Dot-source the script, then call the function with the object IDs of the source user group and target device group:

```powershell
. .\Invoke-PrimaryUsertoDeviceGroup.ps1

Invoke-PrimaryUsertoDeviceGroup `
		-UserGroup "11111111-1111-1111-1111-111111111111" `
		-DeviceGroup "22222222-2222-2222-2222-222222222222"
```

The parameters are:

| Parameter | Required | Description |
| --- | --- | --- |
| `UserGroup` | Yes | Object ID of the Entra ID user group whose members define the device scope. |
| `DeviceGroup` | Yes | Object ID of the Entra ID device group to synchronize. |

To resolve a group object ID by display name:

```powershell
Connect-MgGraph -Scopes "Group.Read.All"
Get-MgGroup -Filter "displayName eq 'Example Group'" | Select-Object DisplayName, Id
```

## Example Automation Runbook

In an Azure Automation PowerShell runbook, store the script in the runbook or load it from the repository, then invoke it with the configured group IDs:

```powershell
. .\Invoke-PrimaryUsertoDeviceGroup.ps1

$parameters = @{
		UserGroup   = $env:PRIMARY_USER_GROUP_ID
		DeviceGroup = $env:DEVICE_GROUP_ID
}

Invoke-PrimaryUsertoDeviceGroup @parameters
```

Ensure the runbook worker has the required Microsoft Graph modules and that the Automation Account managed identity has the permissions listed above.

## Operational Notes

- The comparison uses the Intune managed device `UserId` and the members of the source user group.
- Only devices with `OperatingSystem` equal to `Windows` and a non-empty primary user are considered.
- Device membership is written using the Entra device object ID, not the Intune device ID or Azure AD device ID.
- The script calculates additions and removals before changing the target group, so the target group represents the current scope after a successful run.
- Devices that cannot be mapped from an Intune Azure AD device ID to an Entra device object ID are ignored.
- Group membership changes can take time to become visible to downstream Intune and Entra ID features.
- Review the output and error messages from each run. Individual add or remove failures are reported, while failures retrieving groups, devices, or memberships stop the relevant operation.

## Device Platform Scope

The current script retrieves only Windows devices that have a primary user. This behavior is controlled by the `Where-Object` filter in `Invoke-PrimaryUsertoDeviceGroup.ps1`:

```powershell
$AllManagedWindowsDevices = Get-MgDeviceManagementManagedDevice `
	-Property Id, AzureADDeviceId, DeviceName, OperatingSystem, UserId `
	-All | Where-Object {
		($_.OperatingSystem -eq "Windows") -and ($_.UserId -ne "")
	}
```

To target a single platform, change the `OperatingSystem` value:

```powershell
# Windows devices
($_.OperatingSystem -eq "Windows") -and ($_.UserId -ne "")

# Android devices
($_.OperatingSystem -eq "Android") -and ($_.UserId -ne "")

# macOS devices
($_.OperatingSystem -eq "macOS") -and ($_.UserId -ne "")
```

To include multiple platforms, use the `-in` operator:

```powershell
($_.OperatingSystem -in @("Windows", "Android", "macOS")) -and ($_.UserId -ne "")
```

To retrieve all managed devices regardless of platform, remove the operating-system condition:

```powershell
$AllManagedDevices = Get-MgDeviceManagementManagedDevice `
	-Property Id, AzureADDeviceId, DeviceName, OperatingSystem, UserId `
	-All | Where-Object {
		$_.UserId -ne ""
	}
```

## Related Files

- `Invoke-PrimaryUsertoDeviceGroup.ps1` contains the synchronization logic.
- `assign_MI_permissions.ps1` assigns the required Microsoft Graph application permissions to a managed identity.
