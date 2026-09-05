#Requires -Modules Microsoft.Graph.Authentication,Microsoft.Graph.Groups,Microsoft.Graph.DeviceManagement,Microsoft.Graph.Identity.DirectoryManagement

function Add-GroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        #DeviceGroup
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $devicegroup,

        #DeviceObjectId
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $DeviceObjectId
    )

    process {
        if ($PSCmdlet.ShouldProcess("Adding $DeviceObjectId to $devicegroup")) {
            New-MgGroupMember -GroupId $devicegroup -DirectoryObjectId $DeviceObjectId
        }
    }
}

function Remove-GroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        #DeviceGroup
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $Devicegroup,

        #DeviceObjectId
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $DeviceObjectId
    )

    process {
        if ($PSCmdlet.ShouldProcess("Removing $DeviceObjectId from $devicegroup")) {
            Remove-MgGroupMemberByRef -GroupId $Devicegroup -DirectoryObjectId $DeviceObjectId
        }
    }
}

function Invoke-PrimaryUsertoDeviceGroup {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        #DeviceGroup = the Id of the Device Group
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $DeviceGroup,

        #UserGroup = the Id of the User Group
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $UserGroup
    )

    begin {

        #Checking if the user groups exist
        Write-Output "Checking if the user group exists..."
        try {
            $UserGroupInformation = Get-MgGroup -GroupId $UserGroup
            Write-Output "The user group $($UserGroupInformation.DisplayName) exists..."
        }
        catch {
            Throw "The user group $($UserGroupInformation.DisplayName) does not exist..."
        }

        #checking if the device group exists
        Write-Output "Checking if the device group exists..."
        try {
            $DeviceGroupInformation = Get-MgGroup -GroupId $DeviceGroup
            Write-Output "The device group $($DeviceGroupInformation.DisplayName) exists..."
        }
        catch {
            Throw "The user group $($DeviceGroupInformation.DisplayName) does not exist..."
        }

        #Getting all Managed Windows Devices
        try {
            $AllManagedWindowsDevices = Get-MgDeviceManagementManagedDevice -Property Id, AzureADDeviceId, DeviceName, OperatingSystem, UserId -All | Where-Object { ($_.OperatingSystem -eq "Windows") -and ($_.UserId -ne "") }
            Write-Output "Retrieved $($AllManagedWindowsDevices.Count) Windows devices which have a primary user..."
        }
        catch {
            Throw "Could not obtain all Managed Windows Devices... Error $_"
        }

        #Getting All Devices from Entra ID
        try {
            $AllEntraDevices = Get-MgDevice -All -Property Id, DeviceId | Group-Object -Property DeviceId -AsHashTable -AsString
        }
        catch {
            throw "Couldn't get all Entra devices... Error: $_"
        }

    }
    process {
              
        #Start section Get User Group Members
        Write-Output "Getting all Members of the user group $($UserGroupInformation.DisplayName)..."
        try {
            $AllUserGroupMembers = Get-MgGroupMember -GroupId $UserGroup -All
            Write-Output "The group $($UserGroupInformation.DisplayName) has $($AllUserGroupMembers.Count) Members..."
        }
        catch {
            Throw "Could not retrieve the members of the usergroup $($UserGroupInformation.DisplayName)... Error: $_"
        }
        #End Section Get User Group Members

        #Checking if the User group has more than 0 members 
        If ($AllUserGroupMembers.Count -gt 0) {

            Write-Output "The $($UserGroupInformation.DisplayName) has more than 0 members.. starting further process"

            $AllManagedWindowsDevicesinScope = $AllManagedWindowsDevices | Where-Object { $_.UserId -in $AllUserGroupMembers.id }

            #Checking if the the users have devices in scope
            If ($AllManagedWindowsDevicesinScope.Count -gt 0) {
                Write-Output "There are $($AllManagedWindowsDevicesinScope.Count) devices where a member of the user group is the primary user..."

                #Building the custom object to merge the Entraobject id with the information about the device, this is needed for the adding and removal of the device from the group
                [System.Collections.Generic.List[PSCustomObject]] $deviceInfos = [System.Collections.Generic.List[PSCustomObject]]::new()

                foreach ($ManagedWindowsDeviceInScope in $AllManagedWindowsDevicesinScope) {

                    Write-Verbose "Processing Device $($ManagedWindowsDeviceInScope.DeviceName)"

                    $deviceInfo = @{
                        DeviceName    = $ManagedWindowsDeviceInScope.DeviceName
                        EntraDeviceID = $ManagedWindowsDeviceInScope.AzureAdDeviceId
                        EntraObjectID = $AllEntraDevices[$ManagedWindowsDeviceInScope.AzureAdDeviceId].Id
                    }
                    $deviceInfos.Add([PSCustomObject]$deviceInfo)
                }

                #Building the inScope object and validating that all objects have an EntraObjectId
                [System.Collections.Generic.HashSet[string]] $inScopeDevices = [System.Collections.Generic.HashSet[string]]::new()
                Write-Output "Adding devices to the scope"
                $deviceInfos | Where-Object { $null -ne $_.EntraObjectID } | ForEach-Object {
                    $null = $inScopeDevices.Add($_.EntraObjectID)
                }

                Write-Output "Obtaining the current device group $($DeviceGroupInformation.DisplayName) members"
                try {
                    [System.Collections.Generic.HashSet[string]] $DeviceGroupMembers = [System.Collections.Generic.HashSet[string]]::new()
                    Get-MgGroupMember -GroupId $DeviceGroup -All -ErrorAction Stop | ForEach-Object { $null = $DeviceGroupMembers.Add($_.Id) }
                }
                catch {
                    Throw "Couldn't obtain the members of the group $($DeviceGroupInformation.DisplayName)"
                }

                [System.Collections.Generic.HashSet[string]] $membersToAdd = [System.Collections.Generic.HashSet[string]]::new($InScopeDevices)
                $memberstoAdd.ExceptWith($DeviceGroupMembers)
                $membersToAdd = $membersToAdd | Where-Object { $_.Length -gt 0 }

                [System.Collections.Generic.HashSet[string]] $membersToRemove = [System.Collections.Generic.HashSet[string]]::new($DeviceGroupMembers)
                $membersToRemove.ExceptWith($InScopeDevices)

                Write-Output "There are $($membersToAdd.Count) devices to add and $($membersToRemove.Count) devices to remove from group $($DeviceGroupInformation.DisplayName)"
                If ($membersToAdd.Count -gt 0) {

                    $memberstoAdd | ForEach-Object {
                        try {
                            Write-Verbose "Adding device $($_) to group $($DeviceGroupInformation.DisplayName)"
                            Add-GroupMember -devicegroup $DeviceGroup -DeviceObjectId $_
                        }
                        catch {
                            Write-Error "Couldn't add device $($_) to group $($DeviceGroupInformation.DisplayName) Error $_"
                        }
                    }           
                }
                If ($membersToRemove.Count -gt 0) {
                    $membersToRemove | ForEach-Object {
                        try {
                            Write-Verbose "Removing device $($_) from group $($DeviceGroupInformation.DisplayName))"
                            Remove-GroupMember -devicegroup $DeviceGroup -DeviceObjectId $_
                        }
                        catch {
                            Write-Error "Couldn't remove device $($_) from group $($DeviceGroupInformation.DisplayName) Error: $_"
                        }
                    }
                }       
            }
            Else {
                Write-Output "There are no devices in scope... nothing to do"
            }
            
        }
        Else {
            Write-Output "The user group $($UserGroupInformation.DisplayName) has 0 members... "
            Write-Output "checking if any devices are in the device group and removing them..."
            #Checking if the device group still has any members
            try {
                $AllDeviceGroupMembers = Get-MgGroupMember -GroupId $DeviceGroup -All
            }
            catch {
                Throw "Could not retrieve the members of the devicegroup $($DeviceGroupInformation.DisplayName)... Error: $_"
            }
            
            #Checking if the Device Group has more than 0 members
            If ($AllDeviceGroupMembers.Count -gt 0) {
                Write-Output "The group $($DeviceGroupInformation.DisplayName) has $($AllDeviceGroupMembers.Count) members... removing them..."

                foreach ($Device in $AllDeviceGroupMembers) {
                    #Removing each member 
                    try {
                        Remove-GroupMember -Devicegroup $DeviceGroup -DeviceObjectId $device.Id
                    }
                    catch {
                        Throw "Could not remove the member with id $($Device.Id) from the group $($DeviceGroupInformation.DisplayName)... Error $_"
                    }
                        
                }
            }
            Else {
                Write-Output "The devicegroup $($DeviceGroupInformation.DisplayName) is currently empty... nothing to do"
            }
        }
    }
}
### Start

try {
    Connect-MgGraph -Identity
}
catch {
    throw Could not connect to Graph... Error: $_
}

#Add Invoke-PrimaryUsertoDeviceGroup according to the different options in the readme file!


