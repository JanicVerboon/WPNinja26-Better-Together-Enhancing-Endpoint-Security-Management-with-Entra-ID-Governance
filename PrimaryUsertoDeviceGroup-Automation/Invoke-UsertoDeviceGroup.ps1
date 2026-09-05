#Requires -Modules Microsoft.Graph.Authentication,Microsoft.Graph.Groups,Microsoft.Graph.DeviceManagement,Microsoft.Graph.Identity.DirectoryManagement,Microsoft.Graph.Users

param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UserId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UserGroup,

    [Parameter(Mandatory = $true)]
    [ValidateSet("userAdd", "adminAdd", "userRemove", "adminRemove")]
    [string]$Action
)

function Add-GroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceGroup,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceObjectId
    )

    process {
        if ($PSCmdlet.ShouldProcess($DeviceObjectId, "Add device to group $DeviceGroup")) {
            New-MgGroupMember -GroupId $DeviceGroup -DirectoryObjectId $DeviceObjectId
        }
    }
}

function Remove-GroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceGroup,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceObjectId
    )

    process {
        if ($PSCmdlet.ShouldProcess($DeviceObjectId, "Remove device from group $DeviceGroup")) {
            Remove-MgGroupMemberByRef -GroupId $DeviceGroup -DirectoryObjectId $DeviceObjectId
        }
    }
}

function Invoke-UsertoDeviceGroup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        # Object ID of the Entra ID device group to update.
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DeviceGroup,

        # Object ID of the Entra ID user whose managed devices should be changed.
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserId,

        # Object ID of the Entra ID user group used to verify membership.
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserGroup,

        # Add devices when the user is a member; remove devices when the user is no longer a member.
        [Parameter(Mandatory = $true)]
        [ValidateSet("userAdd", "adminAdd", "userRemove", "adminRemove")]
        [string]$Action
    )

    begin {
        $SkipProcessing = $false
        
        $ResolvedAction = switch ($Action) {
            "userAdd"     { "Add" }
            "adminAdd"    { "Add" }
            "userRemove"  { "Remove" }
            "adminRemove" { "Remove" }
        }

        $DeviceGroup = $DeviceGroup.Trim()
        $UserId = $UserId.Trim()
        $UserGroup = $UserGroup.Trim()

        foreach ($ObjectId in @{
            DeviceGroup = $DeviceGroup
            UserId      = $UserId
            UserGroup   = $UserGroup
        }.GetEnumerator()) {
            $ParsedObjectId = [guid]::Empty
            if (-not [guid]::TryParse($ObjectId.Value, [ref]$ParsedObjectId)) {
                throw "$($ObjectId.Key) must be a valid Entra ID object ID (GUID). Received '$($ObjectId.Value)'."
            }
        }

        Write-Output "Checking if the user exists..."
        try {
            $UserInformation = Get-MgUser -UserId $UserId -Property Id, DisplayName, UserPrincipalName -ErrorAction Stop
            Write-Output "The user $($UserInformation.DisplayName) ($($UserInformation.UserPrincipalName)) exists..."
        }
        catch {
            throw "The user with ID $UserId could not be found. Error: $_"
        }

        Write-Output "Checking if the device group exists..."
        try {
            $DeviceGroupInformation = Get-MgGroup -GroupId $DeviceGroup -ErrorAction Stop
            Write-Output "The device group $($DeviceGroupInformation.DisplayName) exists..."
        }
        catch {
            throw "The device group with ID $DeviceGroup could not be found. Error: $_"
        }

        Write-Output "Checking if the user group exists..."
        try {
            $UserGroupInformation = Get-MgGroup -GroupId $UserGroup -ErrorAction Stop
            Write-Output "The user group $($UserGroupInformation.DisplayName) exists..."
        }
        catch {
            throw "The user group with ID $UserGroup could not be found. Error: $_"
        }

        try {
            $UserGroupMembers = @(Get-MgGroupMember -GroupId $UserGroup -All -ErrorAction Stop)
            $UserIsGroupMember = $null -ne ($UserGroupMembers | Where-Object { $_.Id -eq $UserId })
        }
        catch {
            throw "Could not obtain the members of user group $($UserGroupInformation.DisplayName). Error: $_"
        }

        if ($ResolvedAction -eq "Remove" -and $UserIsGroupMember) {
            Write-Output "User $UserId is still a member of user group $($UserGroupInformation.DisplayName). No devices will be removed."
            $SkipProcessing = $true
        }

        if ($SkipProcessing) {
            Write-Output "Skipping device processing..."
            return
        }

        try {
            $ManagedDevices = @(
                Get-MgDeviceManagementManagedDevice `
                    -Property Id, AzureADDeviceId, DeviceName, OperatingSystem, UserId `
                    -All -ErrorAction Stop |
                    Where-Object { $_.UserId -eq $UserId }
            )
            Write-Output "Retrieved $($ManagedDevices.Count) managed devices for user $UserId..."
        }
        catch {
            throw "Could not obtain the managed devices for user $UserId. Error: $_"
        }

        if ($ManagedDevices.Count -eq 0) {
            Write-Output "No managed devices were found for user $UserId... nothing to do"
            $SkipProcessing = $true
            return
        }

        try {
            $AllEntraDevices = @(
                Get-MgDevice -All -Property Id, DeviceId -ErrorAction Stop
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceId) } | Group-Object -Property DeviceId -AsHashTable -AsString
        }
        catch {
            throw "Could not obtain Entra devices. Error: $_"
        }

        try {
            [System.Collections.Generic.HashSet[string]]$DeviceGroupMembers = [System.Collections.Generic.HashSet[string]]::new()
            $CurrentDeviceGroupMembers = @(Get-MgGroupMember -GroupId $DeviceGroup -All -ErrorAction Stop)

            if ($CurrentDeviceGroupMembers.Count -eq 0) {
                Write-Output "The device group $($DeviceGroupInformation.DisplayName) is empty."
            }
            else {
                Write-Output "The device group $($DeviceGroupInformation.DisplayName) has $($CurrentDeviceGroupMembers.Count) members."
            }

            $CurrentDeviceGroupMembers | ForEach-Object {
                $null = $DeviceGroupMembers.Add($_.Id)
            }
        }
        catch {
            throw "Could not obtain the members of device group $($DeviceGroupInformation.DisplayName). Error: $_"
        }
    }

    process {
        if ($SkipProcessing) {
            return
        }

        [System.Collections.Generic.HashSet[string]]$DeviceObjectIds = [System.Collections.Generic.HashSet[string]]::new()

        if ($ResolvedAction -eq "Remove" -and $DeviceGroupMembers.Count -eq 0) {
            Write-Output "The device group $($DeviceGroupInformation.DisplayName) is empty. No devices will be removed."
            return
        }

        foreach ($ManagedDevice in $ManagedDevices) {
            if ([string]::IsNullOrWhiteSpace($ManagedDevice.AzureADDeviceId)) {
                Write-Warning "Skipping device '$($ManagedDevice.DeviceName)' because it has no Azure AD device ID."
                continue
            }

            $EntraDevice = $AllEntraDevices[$ManagedDevice.AzureADDeviceId]
            if ($null -eq $EntraDevice) {
                Write-Warning "Skipping device '$($ManagedDevice.DeviceName)' because no matching Entra device was found."
                continue
            }

            $EntraDeviceObjectId = $EntraDevice.Id
            if (-not [string]::IsNullOrWhiteSpace($EntraDeviceObjectId)) {
                $null = $DeviceObjectIds.Add($EntraDeviceObjectId)
            }
        }

        if ($ResolvedAction -eq "Add") {
            $DeviceObjectIds.ExceptWith($DeviceGroupMembers)
            Write-Output "There are $($DeviceObjectIds.Count) devices to add to group $($DeviceGroupInformation.DisplayName)..."

            foreach ($DeviceObjectId in $DeviceObjectIds) {
                try {
                    Add-GroupMember -DeviceGroup $DeviceGroup -DeviceObjectId $DeviceObjectId
                }
                catch {
                    Write-Error "Could not add device $DeviceObjectId to group $($DeviceGroupInformation.DisplayName). Error: $_"
                }
            }
        }
        else {
            $DeviceObjectIds.IntersectWith($DeviceGroupMembers)
            Write-Output "There are $($DeviceObjectIds.Count) devices to remove from group $($DeviceGroupInformation.DisplayName)..."

            foreach ($DeviceObjectId in $DeviceObjectIds) {
                try {
                    Remove-GroupMember -DeviceGroup $DeviceGroup -DeviceObjectId $DeviceObjectId
                }
                catch {
                    Write-Error "Could not remove device $DeviceObjectId from group $($DeviceGroupInformation.DisplayName). Error: $_"
                }
            }
        }
    }
}

try {
    Connect-MgGraph -Identity -ErrorAction Stop
}
catch {
    throw "Could not connect to Microsoft Graph using the managed identity. Error: $_"
}

Invoke-UsertoDeviceGroup `
    -DeviceGroup $DeviceGroup `
    -UserId $UserId `
    -UserGroup $UserGroup `
    -Action $Action
