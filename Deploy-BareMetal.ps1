[cmdletbinding()]
param
(
    [parameter(Mandatory=$true)]
    [string]$BMCAddress,

    [parameter(Mandatory=$true)]
    [string]$BMCRunAsAccountName,

    [parameter(Mandatory=$true)]
    [string]$HostName,

    [parameter(Mandatory=$false)]
    [switch]$ReverseSMBiosGuid
)

function GetYesNoAnswer($caption, $message)
{
    $yes = new-Object System.Management.Automation.Host.ChoiceDescription "&Yes"
    $no = new-Object System.Management.Automation.Host.ChoiceDescription "&No"
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]($yes,$no)
    $answer = $host.ui.PromptForChoice($caption,$message,$choices,1);

    return $answer
}

function WaitVMMJob($vmmJobID)
{
    $job = Get-SCJob -ID $vmmJobID -Full
    do
    {
        Start-Sleep -Seconds 1
        $progress = $job.Progress
        $step = $job.CurrentStep.Name
        $stepProgress = $job.CurrentStep.Progress
        Write-Host "Overral progress: $progress. Current step: $step. Current step progress: $stepProgress                                                                    `r" -NoNewline
    } while($job.Status -eq 'Running')

    if ($job.ErrorInfo.DetailedCode -ne 0 -or $job.ErrorInfo.DisplayableErrorCode -ne 0)
    {
        Write-Host "`nHost deployment failed! Details: $($job.ErrorInfo.Problem)" -ForegroundColor Red
        return $false
    }

    Write-Host "`nJob completed" -ForegroundColor Green
    return $true
}

Import-Module ActiveDirectory
Import-Module VirtualMachineManager

$ErrorActionPreference = "Stop"
$VMMostGroupName = "All hosts"

# strip domain from hostname
$domainDNSName = (Get-WmiObject -Class Win32_ComputerSystem).Domain
$HostName = $HostName.Replace($domainDNSName, "")

# VMM
$vmHost = Get-SCVMHost $HostName -ErrorAction SilentlyContinue
if ($vmHost -ne $null)
{
    Write-Host "Host $HostName registered in VMM. Removing..." -ForegroundColor Yellow
    [void]($vmHost | Remove-SCVMHost -Force)

    Write-Host "Revoking unassigned IP addresses..." -ForegroundColor Yellow
    [void](Get-SCIPAddress -UnAssigned | Revoke-SCIPAddress)
}

Write-Host "Check for presence $HostName in Active Directory..."
# check and delete AD computer object
$samName = "$HostName$"
$serverADObject = Get-ADObject -Filter {SamAccountName -eq $samName}
if ($serverADObject -ne $null)
{
    #if (!$Force)
    #{ 
    #    $answer = GetYesNoAnswer "Confirm remove" "$HostName$ account already exist in Active Directory. Confirm remove?"
    #    if ($answer -ne 0)
    #    {
	#        return
    #    }
        Write-Host "$HostName$ account already exist in Active Directory. Removing..."
        Remove-ADObject $serverADObject -Recursive -Confirm:$false
    #}
}

Write-Host "Remove DNS records for $HostName..."
while ( $(Resolve-DnsName $HostName -ErrorAction SilentlyContinue) -ne $null )
{
    [void](Invoke-Expression "cmd /c dnscmd $domainDNSName /recorddelete $domainDNSName $HostName A /f 2>&1")
    #Write-Host "cmd /c dnscmd $domainDNSName /recorddelete $domainDNSName $HostName A /f"
    #Invoke-Expression "cmd /c dnscmd $domainDNSName /recorddelete $domainDNSName $HostName A /f"
    Clear-DnsClientCache
    Start-Sleep -Seconds 5
}

$BMCRunAsAccount = Get-SCRunasAccount $BMCRunAsAccountName
if ($BMCRunAsAccount -eq $null)
{
    Write-Host "Unable to get RunAs account `"$BMCRunAsAccountName`"!" -ForegroundColor Red
    return
}

Write-Host "Discovering server `"$($BMCAddress)`"..."
$deployBlade = Find-SCComputer -BMCAddress $BMCAddress –BMCRunAsAccount $BMCRunAsAccount -BMCProtocol “IPMI” -ErrorAction Stop

# This is workaroung for incorrect SMBios report from Huawei BMC (big endian instead little)
if ($ReverseSMBiosGuid)
{
    $SMBiosGuidBytes = New-Object Byte[] 16
    $badGuidBytes = $deployBlade.SMBiosGUID.ToByteArray()
    $SMBiosGuidBytes[0] = $badGuidBytes[12]
    $SMBiosGuidBytes[1] = $badGuidBytes[13]
    $SMBiosGuidBytes[2] = $badGuidBytes[14]
    $SMBiosGuidBytes[3] = $badGuidBytes[15]
    $SMBiosGuidBytes[4] = $badGuidBytes[10]
    $SMBiosGuidBytes[5] = $badGuidBytes[11]

    $SMBiosGuidBytes[6] = $badGuidBytes[8]
    $SMBiosGuidBytes[7] = $badGuidBytes[9]
    for($i = 8; $i -le 15; $i++)
    {
        $SMBiosGuidBytes[$i] = $badGuidBytes[15 - $i]
    }
    $SMBiosGuid = [Guid]$SMBiosGuidBytes
}
else
{
    $SMBiosGuid = $deployBlade.SMBiosGUID
}
# end of workAroung

Write-Host "SMBiosGuid is `"$SMBiosGuid`""

$startDiscoveryTime = Get-Date
Write-Host "Deep discovering server `"$($BMCAddress)`". This is long process (about 10-30 minutes) please be patient..." -ForegroundColor Yellow
$deployBlade = Find-SCComputer -DeepDiscovery -BMCAddress $BMCAddress -BMCRunAsAccount $BMCRunAsAccount -BMCProtocol "IPMI" -SMBIOSGUID $SMBiosGuid
$endDiscoveryTime = Get-Date
$totalDiscovery = ($endDiscoveryTime - $startDiscoveryTime).Minutes
Write-Host "Deep discovery server `"$($BMCAddress)`" finished in $totalDiscovery minutes" -ForegroundColor Cyan

if ($deployBlade.PhysicalMachine.NetworkAdapters.Count -eq 0)
{
    Write-Host "No network adapters discovered on server!" -ForegroundColor Red
    return
}

#Write-Host "$($deployBlade.PhysicalMachine.NetworkAdapters[0].ProductName)"

$bladeNetworkAdapters = $deployBlade.PhysicalMachine.NetworkAdapters
$bladeNetworkAdaptersCount = $deployBlade.PhysicalMachine.NetworkAdapters.Count

Write-Host "Finding physical computer profile with $bladeNetworkAdaptersCount physical adapters..."
$bladePhysicalProfile = $null
$physicalProfiles = @(Get-SCPhysicalComputerProfile)
for($i = 0; $i -lt $physicalProfiles.Count -and $bladePhysicalProfile -eq $null; $i++)
{
    $profileAdaptersCount = @($physicalProfiles[$i].VMHostNetworkAdapterProfiles | ? IsVirtualNetworkAdapter -eq $false).Count
    if ($profileAdaptersCount -eq $bladeNetworkAdaptersCount)
    {
        $bladePhysicalProfile = $physicalProfiles[$i]
    }
}
if ($bladePhysicalProfile -eq $null)
{
    Write-Host "Unable to find physical computer profile with $bladeNetworkAdaptersCount physical adapters!" -ForegroundColor Red
    return
}

# !!!TEMP!!!
#$deployBlade.PhysicalMachine.Disks | ft  Name,DeviceName,Bus,BusType,Lun,SerialNumber,Target,@{N="Size";E={[Math]::Ceiling($_.Capacity/1gb)}}
#$firstDisk
#return
# !!!TEMP!!!

# get disk for OS deployment
#$firstDisk = $deployBlade.PhysicalMachine.Disks | ? DeviceName -eq "\\.\PHYSICALDRIVE0" #[1]#
#$firstDisk | ft  Name,DeviceName,Bus,BusType,Lun,SerialNumber,Target,@{N="Size";E={$_.Capacity/1gb}}
Write-Host "Finding disk suitable for OS deployment..." -ForegroundColor Cyan
$firstDisk = $deployBlade.PhysicalMachine.Disks | ?{[Math]::Ceiling($($_.Capacity/1gb)) -eq 60 -and $_.Name -match "HUAWEI"} | Select -First 1

if ($firstDisk -eq $null)
{
    Write-Host "Unable to find disk suitable for OS deployment!" -ForegroundColor Red
    return
}

$deployOSDisk = $firstDisk.DeviceName
#if ($firstDisk.SerialNumber -ne "2102351CMA10H80000070025")
#{
#    Write-Host "Wrong disk `"$($firstDisk.Name) $([Math]::Round($firstDisk.Capacity / 1Gb))Gb`" with device name `"$deployOSDisk`"!! You ass will be burned!" -ForegroundColor Red
#    return
#}
$answer = GetYesNoAnswer "Confirm deployment" "Are you sure to use `"$($firstDisk.Name) $([Math]::Ceiling($firstDisk.Capacity / 1Gb))Gb`" with device name `"$deployOSDisk`" for OS deployment?"
if ($answer -ne 0)
{
	return
}

Write-Host "Using `"$($firstDisk.Name) $([Math]::Ceiling($firstDisk.Capacity / 1Gb))Gb`" with device name `"$deployOSDisk`" for OS deployment"
Write-Host "Press enter to start..."
Read-Host

Write-Host "Configuring network..."
# configure network adapters
$profilePhysicalNetworkAdapters = $bladePhysicalProfile.VMHostNetworkAdapterProfiles | ? IsVirtualNetworkAdapter -eq $false
$oneAdapter = ($profilePhysicalNetworkAdapters | ? IsManagementNic -eq $false | select -First 1)
$profileLogicalSwitch = $oneAdapter.LogicalSwitch
$profileUplink = $oneAdapter.UplinkPortProfileSet
$profileVirtualNetworkAdapters = $profileUplink | Get-SCLogicalSwitchVirtualNetworkAdapter

# configure physical network adapters
$physicalManagement = $null
$deploymentNetworkAdapters = @()
for($i = 0; $i -lt $bladeNetworkAdapters.Count; $i++)
{
    $phParams = @{
        SetAsPhysicalNetworkAdapter = $true
        MACAddress = $($bladeNetworkAdapters[$i].MacAddress) 
    }

    if ($profilePhysicalNetworkAdapters[$i].IsManagementNic)
    {
        #$phParams.Add("SetAsManagementNIC", $true)
        #$phParams.Add("UseDhcpForIPConfiguration", $true )
        $phParams.Add("LogicalSwitch", $profileLogicalSwitch)
        $phParams.Add("UplinkPortProfileSet", $profileUplink)
        $phParams.Add("DisableAdapterDNSRegistration", $false)
    }
    else
    {
        $phParams.Add("DisableAdapterDNSRegistration", $false)
        $phParams.Add("LogicalSwitch", $profileLogicalSwitch)
        $phParams.Add("UplinkPortProfileSet", $profileUplink)
    }
    
    $adapter = New-SCPhysicalComputerNetworkAdapterConfig @phParams
    if ($profilePhysicalNetworkAdapters[$i].IsManagementNic -ne $true -and $physicalManagement -eq $null)
    {
        $physicalManagement = $adapter
    }
    $deploymentNetworkAdapters += $adapter
}

#$managementVNICName = $null
# configure virtual network adapters
foreach($vn in $profileVirtualNetworkAdapters)
{
    $vnParams = @{
        UseStaticIPForIPConfiguration = $true
        SetAsVirtualNetworkAdapter = $true 
        MACAddress = "00:00:00:00:00:00" 
        IPv4Subnet = $vn.VMSubnet.SubnetVLans.Subnet 
        LogicalSwitch = $profileLogicalSwitch
        VMNetwork = $($vn.VMNetwork)
        AdapterName = $($vn.Name)
    }

    if ($vn.IsUsedForHostManagement)
    {
        $vnParams.Add("SetAsManagementNIC", $true)
        $vnParams.Add("TransientManagementNetworkAdapter", $physicalManagement)
    }
    else
    {
        $vnParams.Add("SetAsGenericNIC", $true)
    }

    if ($vn.PortClassification -ne $null)
    {
        $vnParams.Add("PortClassification", $($vn.PortClassification))
    }
    
    $deploymentNetworkAdapters += New-SCPhysicalComputerNetworkAdapterConfig @vnParams
}

$VMMostGroup = Get-SCVMHostGroup $VMMostGroupName
$physicalConfigParams = @{
    BMCAddress = $BMCAddress
    BMCPort = 623 
    BMCProtocol = "IPMI"
    BMCRunAsAccount = $BMCRunAsAccount
    ComputerName = $HostName 
    SMBiosGuid = $SMBiosGuid
    PhysicalComputerProfile = $bladePhysicalProfile
    VMHostGroup = $VMMostGroup 
    PhysicalComputerNetworkAdapterConfig = $deploymentNetworkAdapters
    BootDiskVolume = $deployOSDisk
    BypassADMachineAccountCheck = $true
    Description = ""
}

Write-Host "Deploying host `"$HostName`"..."
$startDeployTime = Get-Date
$PhysicalComputerConfig = New-SCPhysicalComputerConfig @physicalConfigParams
$newHostJob = New-SCVMHost -VMHostConfig $PhysicalComputerConfig -RunAsynchronously

Write-Host "Wait for start of deployment job..."
while($newHostJob.MostRecentTaskUIState -ne 'Running')
{
    Start-Sleep -Seconds 5
}

if ( WaitVMMJob($($newHostJob.MostRecentTaskID)) -eq $true)
{
    $endDeployTime = Get-Date
    $totalDeploy = ($endDeployTime - $startDeployTime).Minutes
    Write-Host "Host deployment finished in $totalDiscovery minutes" -ForegroundColor Green
}
