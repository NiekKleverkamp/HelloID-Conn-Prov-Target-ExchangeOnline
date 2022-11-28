#####################################################
# HelloID-Conn-Prov-Target-ExchangeOnline-DynamicPermissions-Groups
#
# Version: 1.2.0
#####################################################

#region Initialize default properties
$c = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$pp = $previousPerson | ConvertFrom-Json
$pd = $personDifferences | ConvertFrom-Json
$m = $manager | ConvertFrom-Json
$aRef = $accountReference | ConvertFrom-Json
$mRef = $managerAccountReference | ConvertFrom-Json

$success = $True
$auditLogs = New-Object Collections.Generic.List[PSCustomObject]

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($c.isDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}
$InformationPreference = "Continue"
$WarningPreference = "Continue"

# Operation is a script parameter which contains the action HelloID wants to perform for this permission
# It has one of the following values: "grant", "revoke", "update"
$o = $operation | ConvertFrom-Json

# The permissionReference contains the Identification object provided in the retrieve permissions call
$pRef = $permissionReference | ConvertFrom-Json

# The entitlementContext contains the sub permissions (Previously the $permissionReference variable)
$eRef = $entitlementContext | ConvertFrom-Json

$currentPermissions = @{}
foreach ($permission in $eRef.CurrentPermissions) {
    $currentPermissions[$permission.Reference.Id] = $permission.DisplayName
}

# Determine all the sub-permissions that needs to be Granted/Updated/Revoked
$subPermissions = New-Object Collections.Generic.List[PSCustomObject]

# Used to connect to Exchange Online in an unattended scripting scenario using a certificate.
# Follow the Microsoft Docs on how to set up the Azure App Registration: https://docs.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps
$AADOrganization = $c.AzureADOrganization
$AADAppID = $c.AzureADAppId
$AADCertificateThumbprint = $c.AzureADCertificateThumbprint # Certificate has to be locally installed

# PowerShell commands to import
$commands = @(
    "Get-User" # Always required
    , "Get-DistributionGroup"
    , "Add-DistributionGroupMember"
    , "Remove-DistributionGroupMember"
)

# Troubleshooting
$dryRun = $false

#region Change mapping here
$desiredPermissions = @{}
if ($o -ne "revoke") {
    # Example: Contract Based Logic:
    foreach ($contract in $p.Contracts) {
        Write-Verbose ("Contract in condition: {0}" -f $contract.Context.InConditions)
        if ($contract.Context.InConditions -OR ($dryRun -eq $True)) {
            # Example: department_<departmentname>
            $groupName = "department_" + $contract.Department.DisplayName
            $desiredPermissions[$groupName] = $groupName
          
            # Example: title_<titlename>
            # $groupName = "title_" + $contract.Title.Name
            # $desiredPermissions[$groupName] = $groupName
        }
    }
    
    # Example: Person Based Logic:
    # Example: location_<locationname>
    # $groupName = "location_" + $p.Location.Name
    # $desiredPermissions[$groupName] = $groupName
}
Write-Information ("Defined Permissions: {0}" -f ($desiredPermissions.keys | ConvertTo-Json))
#endregion Change mapping here

#region functions
function Resolve-HTTPError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId
            MyCommand             = $ErrorObject.InvocationInfo.MyCommand
            RequestUri            = $ErrorObject.TargetObject.RequestUri
            ScriptStackTrace      = $ErrorObject.ScriptStackTrace
            ErrorMessage          = ''
        }
        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $httpErrorObj.ErrorMessage = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            $httpErrorObj.ErrorMessage = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
        }
        Write-Output $httpErrorObj
    }
}

function Set-PSSession {
    <#
    .SYNOPSIS
        Get or create a "remote" Powershell session
    .DESCRIPTION
        Get or create a "remote" Powershell session at the local computer
    .EXAMPLE
        PS C:\> $remoteSession = Set-PSSession -PSSessionName ($psSessionName + $mutex.Number) # Test1
       Get or Create a "remote" Powershell session at the local computer with computername and number: Test1 And assign to a $varaible which can be used to make remote calls.
    .OUTPUTS
        $remoteSession [System.Management.Automation.Runspaces.PSSession]
    .NOTES
        Make sure you always disconnect the PSSession, otherwise the PSSession is blocked to reconnect. 
        Place the following code in the finally block to make sure the session will be disconnected
        if ($null -ne $remoteSession) {  
            Disconnect-PSSession $remoteSession 
        }
    #>
    [OutputType([System.Management.Automation.Runspaces.PSSession])]  
    param(       
        [Parameter(mandatory)]
        [string]$PSSessionName
    )
    try {       
        $sessionObject = $null              
        $sessionObject = Get-PSSession -ComputerName $env:computername -Name $PSSessionName -ErrorAction stop
        if ($null -eq $sessionObject) {
            # Due to some inconsistency, the Get-PSSession does not always throw an error  
            throw "The command cannot find a PSSession that has the name '$PSSessionName'."
        }
        # To Avoid using mutliple sessions at the same time.
        if ($sessionObject.length -gt 1) {
            Remove-PSSession -Id ($sessionObject.id | Sort-Object | Select-Object -first 1)
            $sessionObject = Get-PSSession -ComputerName $env:computername -Name $PSSessionName -ErrorAction stop
        }        
        Write-Verbose "Remote Powershell session is found, Name: $($sessionObject.Name), ComputerName: $($sessionObject.ComputerName)"
    }
    catch {
        Write-Verbose "Remote Powershell session not found: $($_)"
    }

    if ($null -eq $sessionObject) { 
        try {
            $remotePSSessionOption = New-PSSessionOption -IdleTimeout (New-TimeSpan -Minutes 5).TotalMilliseconds
            $sessionObject = New-PSSession -ComputerName $env:computername -EnableNetworkAccess:$true -Name $PSSessionName -SessionOption $remotePSSessionOption
            Write-Verbose "Successfully created new Remote Powershell session, Name: $($sessionObject.Name), ComputerName: $($sessionObject.ComputerName)"
        }
        catch {
            throw "Could not create PowerShell Session with name '$PSSessionName' at computer with name '$env:computername': $($_.Exception.Message)"
        }
    }

    Write-Verbose "Remote Powershell Session '$($sessionObject.Name)' State: '$($sessionObject.State)' Availability: '$($sessionObject.Availability)'"
    if ($sessionObject.Availability -eq "Busy") {
        throw "Remote Powershell Session '$($sessionObject.Name)' is in Use"
    }

    Write-Output $sessionObject
}
#endregion functions

#region Execute
Write-Information ("Existing Permissions: {0}" -f ($eRef.CurrentPermissions.DisplayName | ConvertTo-Json))

$remoteSession = Set-PSSession -PSSessionName 'HelloID_Prov_Exchange_Online_PermissionsGrantRevoke'
Connect-PSSession $remoteSession | out-null

# Connect to Exchange Online
try {                                                                    
    # if it does not exist create new session to exchange online in remote session     
    $createSessionResult = Invoke-Command -Session $remoteSession -ScriptBlock {
        try {
            # Set TLS to accept TLS, TLS 1.1 and TLS 1.2
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

            # Create array for logging since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands
            $verboseLogs = [System.Collections.ArrayList]::new()
            $informationLogs = [System.Collections.ArrayList]::new()
            $warningLogs = [System.Collections.ArrayList]::new()
                
            # Import module
            $moduleName = "ExchangeOnlineManagement"
            $commands = $using:commands

            # If module is imported say that and do nothing
            if (Get-Module | Where-Object { $_.Name -eq $ModuleName }) {
                [Void]$verboseLogs.Add("Module $ModuleName is already imported.")
            }
            else {
                # If module is not imported, but available on disk then import
                if (Get-Module -ListAvailable | Where-Object { $_.Name -eq $ModuleName }) {
                    $module = Import-Module $ModuleName -Cmdlet $commands
                    [Void]$verboseLogs.Add("Imported module $ModuleName")
                }
                else {
                    # If the module is not imported, not available and not in the online gallery then abort
                    throw "Module $ModuleName not imported, not available. Please install the module using: Install-Module -Name $ModuleName -Force"
                }
            }

            # Check if Exchange Connection already exists
            try {
                $checkCmd = Get-User -ResultSize 1 -ErrorAction Stop | Out-Null
                $connectedToExchange = $true
            }
            catch {
                if ($_.Exception.Message -like "The term 'Get-User' is not recognized as the name of a cmdlet, function, script file, or operable program.*") {
                    $connectedToExchange = $false
                }
            }
            
            # Connect to Exchange
            try {
                if ($connectedToExchange -eq $false) {
                    [Void]$verboseLogs.Add("Connecting to Exchange Online..")

                    # Connect to Exchange Online in an unattended scripting scenario using a certificate thumbprint (certificate has to be locally installed).
                    $exchangeSessionParams = @{
                        Organization          = $using:AADOrganization
                        AppID                 = $using:AADAppID
                        CertificateThumbPrint = $using:AADCertificateThumbprint
                        CommandName           = $commands
                        ShowBanner            = $false
                        ShowProgress          = $false
                        TrackPerformance      = $false
                        ErrorAction           = 'Stop'
                    }
                    $exchangeSession = Connect-ExchangeOnline @exchangeSessionParams
                    
                    [Void]$verboseLogs.Add("Successfully connected to Exchange Online")
                }
                else {
                    [Void]$verboseLogs.Add("Successfully connected to Exchange Online (already connected)")
                }
            }
            catch {
                $ex = $PSItem
                if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                    $errorObject = Resolve-HTTPError -Error $ex
            
                    $verboseErrorMessage = $errorObject.ErrorMessage
            
                    $auditErrorMessage = $errorObject.ErrorMessage
                }
            
                # If error message empty, fall back on $ex.Exception.Message
                if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                    $verboseErrorMessage = $ex.Exception.Message
                }
                if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                    $auditErrorMessage = $ex.Exception.Message
                }

                [Void]$verboseLogs.Add("Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)")
                $success = $false 
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Error connecting to Exchange Online. Error Message: $auditErrorMessage"
                        IsError = $True
                    })

                # Clean up error variables
                Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
                Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
            }
        }
        finally {
            $returnobject = @{
                success         = $success
                auditLogs       = $auditLogs
                verboseLogs     = $verboseLogs
                informationLogs = $informationLogs
                warningLogs     = $warningLogs
            }
            $returnobject.Keys | ForEach-Object { Remove-Variable $_ -ErrorAction SilentlyContinue }
            Write-Output $returnobject
        }
    }
}
catch {
    $ex = $PSItem
    if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObject = Resolve-HTTPError -Error $ex

        $verboseErrorMessage = $errorObject.ErrorMessage

        $auditErrorMessage = $errorObject.ErrorMessage
    }

    # If error message empty, fall back on $ex.Exception.Message
    if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
        $verboseErrorMessage = $ex.Exception.Message
    }
    if ([String]::IsNullOrEmpty($auditErrorMessage)) {
        $auditErrorMessage = $ex.Exception.Message
    }

    Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"
    $success = $false 
    $auditLogs.Add([PSCustomObject]@{
            Message = "Error connecting to Exchange Online. Error Message: $auditErrorMessage"
            IsError = $True
        })

    # Clean up error variables
    Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
    Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
}
finally {
    # Log the data from logging arrays (since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands)
    $verboseLogs = $createSessionResult.verboseLogs
    foreach ($verboseLog in $verboseLogs) { Write-Verbose $verboseLog }
    $informationLogs = $createSessionResult.informationLogs
    foreach ($informationLog in $informationLogs) { Write-Information $informationLog }
    $warningLogs = $createSessionResult.warningLogs
    foreach ($warningLog in $warningLogs) { Write-Warning $warningLog }
}

try {
    # Compare desired with current permissions and grant permissions
    foreach ($permission in $desiredPermissions.GetEnumerator()) {
        $subPermissions.Add([PSCustomObject]@{
                DisplayName = $permission.Value
                Reference   = [PSCustomObject]@{ Id = $permission.Name }
            })

        if (-Not $currentPermissions.ContainsKey($permission.Name)) {
            try {
                # Grant Exchange Online Groupmembership
                $addExoGroupMembership = Invoke-Command -Session $remoteSession -ScriptBlock {
                    try {
                        # Set TLS to accept TLS, TLS 1.1 and TLS 1.2
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

                        $success = $using:success
                        $auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

                        $dryRun = $using:dryRun
                        $aRef = $using:aRef
                        $permission = $using:permission

                        # Create array for logging since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands
                        $verboseLogs = [System.Collections.ArrayList]::new()
                        $informationLogs = [System.Collections.ArrayList]::new()
                        $warningLogs = [System.Collections.ArrayList]::new()

                        # Set mailbox folder permission
                        $dgSplatParams = @{
                            Identity                        = $permission.Name
                            Member                          = $aRef.Guid
                            # BypassSecurityGroupManagerCheck = $true
                        }

                        [Void]$verboseLogs.Add("Granting permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))'")

                        if ($dryRun -eq $false) {
                            $addDGMember = Add-DistributionGroupMember @dgSplatParams -Confirm:$false -ErrorAction Stop

                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = "Successfully granted permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))'"
                                    IsError = $false
                                })
                        }
                        else {
                            [Void]$warningLogs.Add("DryRun: would grant permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))'")
                        }
                    }
                    catch {
                        $ex = $PSItem
                        if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                            $errorObject = Resolve-HTTPError -Error $ex
                        
                            $verboseErrorMessage = $errorObject.ErrorMessage
                        
                            $auditErrorMessage = $errorObject.ErrorMessage
                        }
                        
                        # If error message empty, fall back on $ex.Exception.Message
                        if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                            $verboseErrorMessage = $ex.Exception.Message
                        }
                        if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                            $auditErrorMessage = $ex.Exception.Message
                        }

                        [Void]$verboseLogs.Add("Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)")

                        if ($auditErrorMessage -like "*already a member of the group*") {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = "Successfully granted permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))' (Already a member of the group)"
                                    IsError = $false
                                }
                            )
                        }
                        else {
                            $success = $false
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "GrantPermission"
                                    Message = "Error granting permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))'. Error Message: $auditErrorMessage"
                                    IsError = $True
                                })
                        }

                        # Clean up error variables
                        Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
                        Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
                    }
                    finally {
                        $returnobject = @{
                            success         = $success
                            auditLogs       = $auditLogs
                            verboseLogs     = $verboseLogs
                            informationLogs = $informationLogs
                            warningLogs     = $warningLogs
                        }
                        $returnobject.Keys | ForEach-Object { Remove-Variable $_ -ErrorAction SilentlyContinue }
                        Write-Output $returnobject 
                    }
                }
            }
            catch {
                $ex = $PSItem
                if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                    $errorObject = Resolve-HTTPError -Error $ex
            
                    $verboseErrorMessage = $errorObject.ErrorMessage
            
                    $auditErrorMessage = $errorObject.ErrorMessage
                }
            
                # If error message empty, fall back on $ex.Exception.Message
                if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                    $verboseErrorMessage = $ex.Exception.Message
                }
                if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                    $auditErrorMessage = $ex.Exception.Message
                }
            
                Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"

                $success = $false 
                $auditLogs.Add([PSCustomObject]@{
                        Action  = "GrantPermission"
                        Message = "Error granting permission for group '$($permission.Name)' to user '$($aRef.UserPrincipalName) ($($aRef.Guid))'. Error Message: $auditErrorMessage"
                        IsError = $True
                    })

                # Clean up error variables
                Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
                Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
            }
            finally {
                $success = $addExoGroupMembership.success
                $auditLogs += $addExoGroupMembership.auditLogs

                # Log the data from logging arrays (since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands)
                $verboseLogs = $addExoGroupMembership.verboseLogs
                foreach ($verboseLog in $verboseLogs) { Write-Verbose $verboseLog }
                $informationLogs = $addExoGroupMembership.informationLogs
                foreach ($informationLog in $informationLogs) { Write-Information $informationLog }
                $warningLogs = $addExoGroupMembership.warningLogs
                foreach ($warningLog in $warningLogs) { Write-Warning $warningLog }
            }
        }    
    }

    # Compare current with desired permissions and revoke permissions
    $newCurrentPermissions = @{}
    foreach ($permission in $currentPermissions.GetEnumerator()) {    
        if (-Not $desiredPermissions.ContainsKey($permission.Name) -AND $permission.Name -ne "No Groups Defined") {
            try {
                # Revoke Exchange Online Groupmembership
                $removeExoGroupMembership = Invoke-Command -Session $remoteSession -ScriptBlock {
                    try {
                        # Set TLS to accept TLS, TLS 1.1 and TLS 1.2
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

                        $success = $using:success
                        $auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

                        $dryRun = $using:dryRun
                        $aRef = $using:aRef
                        $permission = $using:permission

                        # Create array for logging since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands
                        $verboseLogs = [System.Collections.ArrayList]::new()
                        $informationLogs = [System.Collections.ArrayList]::new()
                        $warningLogs = [System.Collections.ArrayList]::new()

                        # Set mailbox folder permission
                        $dgSplatParams = @{
                            Identity                        = $permission.Name
                            Member                          = $aRef.Guid
                            # BypassSecurityGroupManagerCheck = $true
                        } 

                        [Void]$verboseLogs.Add("Revoking permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))'")

                        if ($dryRun -eq $false) {
                            $removeDGMember = Remove-DistributionGroupMember @dgSplatParams -Confirm:$false -ErrorAction Stop

                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Successfully revoked permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))'"
                                    IsError = $false
                                })
                        }
                        else {
                            [Void]$warningLogs.Add("DryRun: would revoke permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))'")
                        }
                    }
                    catch {
                        $ex = $PSItem
                        if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                            $errorObject = Resolve-HTTPError -Error $ex
                        
                            $verboseErrorMessage = $errorObject.ErrorMessage
                        
                            $auditErrorMessage = $errorObject.ErrorMessage
                        }
                        
                        # If error message empty, fall back on $ex.Exception.Message
                        if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                            $verboseErrorMessage = $ex.Exception.Message
                        }
                        if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                            $auditErrorMessage = $ex.Exception.Message
                        }

                        [Void]$verboseLogs.Add("Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)")

                        if ($auditErrorMessage -like "*isn't a member of the group*") {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Successfully revoked permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))' (Already no longer a member of the group)"
                                    IsError = $false
                                }
                            )
                        }
                        elseif ($auditErrorMessage -like "*object '*' couldn't be found*") {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Successfully revoked permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))' (Group '$($permission.Name)' couldn't be found. Possibly no longer exists. Skipping action)"
                                    IsError = $false
                                }
                            )
                        }
                        elseif ($auditErrorMessage -like "*Couldn't find object ""$($aRef.Guid)""*") {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Successfully revoked permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))' (User $($aRef.UserPrincipalName) ($($aRef.Guid)) couldn't be found. Possibly no longer exists. Skipping action)"
                                    IsError = $false
                                }
                            )
                        }
                        else {
                            $success = $false
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = "RevokePermission"
                                    Message = "Error revoking permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))'. Error Message: $auditErrorMessage"
                                    IsError = $True
                                })
                        }

                        # Clean up error variables
                        Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
                        Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
                    }
                    finally {
                        $returnobject = @{
                            success         = $success
                            auditLogs       = $auditLogs
                            verboseLogs     = $verboseLogs
                            informationLogs = $informationLogs
                            warningLogs     = $warningLogs
                        }
                        $returnobject.Keys | ForEach-Object { Remove-Variable $_ -ErrorAction SilentlyContinue }
                        Write-Output $returnobject 
                    }
                }
            }
            catch {
                $ex = $PSItem
                if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                    $errorObject = Resolve-HTTPError -Error $ex
            
                    $verboseErrorMessage = $errorObject.ErrorMessage
            
                    $auditErrorMessage = $errorObject.ErrorMessage
                }
            
                # If error message empty, fall back on $ex.Exception.Message
                if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                    $verboseErrorMessage = $ex.Exception.Message
                }
                if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                    $auditErrorMessage = $ex.Exception.Message
                }
            
                Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"

                $success = $false 
                $auditLogs.Add([PSCustomObject]@{
                        Action  = "RevokePermission"
                        Message = "Error revoking permission for group '$($permission.Name)' from user '$($aRef.UserPrincipalName) ($($aRef.Guid))'. Error Message: $auditErrorMessage"
                        IsError = $True
                    })

                # Clean up error variables
                Remove-Variable 'verboseErrorMessage' -ErrorAction SilentlyContinue
                Remove-Variable 'auditErrorMessage' -ErrorAction SilentlyContinue
            }
            finally {
                $success = $removeExoGroupMembership.success
                $auditLogs += $removeExoGroupMembership.auditLogs

                # Log the data from logging arrays (since the "normal" Write-Information isn't sent to HelloID as another PS session performs the commands)
                $verboseLogs = $removeExoGroupMembership.verboseLogs
                foreach ($verboseLog in $verboseLogs) { Write-Verbose $verboseLog }
                $informationLogs = $removeExoGroupMembership.informationLogs
                foreach ($informationLog in $informationLogs) { Write-Information $informationLog }
                $warningLogs = $removeExoGroupMembership.warningLogs
                foreach ($warningLog in $warningLogs) { Write-Warning $warningLog }     
            }
        }
        else {
            $newCurrentPermissions[$permission.Name] = $permission.Value
        }
    }

    # Update current permissions
    <# Updates not needed for Group Memberships.
    if ($o -eq "update") {
        foreach($permission in $newCurrentPermissions.GetEnumerator()) {    
            $auditLogs.Add([PSCustomObject]@{
                Action = "UpdatePermission"
                Message = "Updated access to department share $($permission.Value)"
                IsError = $False
            })
        }
    }
    #>

    # Handle case of empty defined dynamic permissions.  Without this the entitlement will error.
    if ($o -match "update|grant" -AND $subPermissions.count -eq 0) {
        $subPermissions.Add([PSCustomObject]@{
                DisplayName = "No Groups Defined"
                Reference   = [PSCustomObject]@{ Id = "No Groups Defined" }
            })
    }
    #endregion Execute
}
finally {
    Start-Sleep 1
    if ($null -ne $remoteSession) {
        Disconnect-PSSession $remoteSession -WarningAction SilentlyContinue | out-null # Suppress Warning: PSSession Connection was created using the EnableNetworkAccess parameter and can only be reconnected from the local computer. # to fix the warning the session must be created with a elevated prompt
        Write-Verbose "Remote Powershell Session '$($remoteSession.Name)' State: '$($remoteSession.State)' Availability: '$($remoteSession.Availability)'"
    }

    # Check if auditLogs contains errors, if so, set success to false
    if ($auditLogs.IsError -contains $true) {
        $success = $false
    }

    #region Build up result
    $result = [PSCustomObject]@{
        Success        = $success
        SubPermissions = $subPermissions
        AuditLogs      = $auditLogs
    }
    Write-Output ($result | ConvertTo-Json -Depth 10)
    #endregion Build up result
}
