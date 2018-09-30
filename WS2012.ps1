param(
    [switch] $Clean
)

<#
TODO:
    Set up SQL
    Set up SQL AG
    Create SQL accounts
    Create SecurityPolicyDsc permissions
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
# How to set up WAN routing
Install-RemoteAccess -VpnType Vpn
cmd.exe /c 'netsh routing ip nat install'
cmd.exe /c 'netsh routing ip nat add interface $ExternalInterface'
$ExternalInterface = 'External'
$InternalInterface1 = 'LAN1'
$InternalInterface2 = 'LAN2'
$InternalInterface3 = 'LAN3'
$InternalInterface4 = 'LAN4'
cmd.exe /c 'netsh routing ip nat set interface $ExternalInterface mode=full'
cmd.exe /c 'netsh routing ip nat add interface $InternalInterface1'
cmd.exe /c 'netsh routing ip nat add interface $InternalInterface2'
cmd.exe /c 'netsh routing ip nat add interface $InternalInterface3'
cmd.exe /c 'netsh routing ip nat add interface $InternalInterface4'
#>

# Outgoing interface on host needs an IP - maybe this would be better with DHCP enabled
Configuration WS2012 {
    param (
    )
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xPSDesiredStateConfiguration
    Import-DscResource -ModuleName ComputerManagementDsc
    Import-DscResource -ModuleName NetworkingDsc
    Import-DscResource -ModuleName xActiveDirectory
    Import-DscResource -ModuleName xFailOverCluster
    Import-DscResource -ModuleName xDnsServer
    Import-DscResource -ModuleName xRemoteDesktopAdmin
    Import-DscResource -ModuleName xSmbShare

    Node $AllNodes.NodeName {
        $domainAdministrator = New-Object System.Management.Automation.PSCredential('LAB\Administrator', ('Admin2018!' | ConvertTo-SecureString -AsPlainText -Force))
        $safemodeAdministrator = New-Object System.Management.Automation.PSCredential('Administrator', ('Safe2018!' | ConvertTo-SecureString -AsPlainText -Force))

        LocalConfigurationManager {
            RebootNodeIfNeeded   = $true
            AllowModuleOverwrite = $true
            CertificateID        = $node.Thumbprint

            # This retries the configration every 15 minutes (the minimum) until it has entirely passed once
            ConfigurationMode    = 'ApplyOnly'
            ConfigurationModeFrequencyMins = 15
        }

        # Windows will cache "not found" results for 15 minutes which slows down configurations
        # that check for a Cluster being alive, so we disable caching
        Registry 'DisableNegativeCacheTtl' {
            Ensure = 'Present'
            Key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
            ValueName = 'MaxNegativeCacheTtl'
            ValueData = '0'
            ValueType = 'DWord'
        }
        
        # Windows cycles machine passwords in a domain which prevents you from restoring a
        # snapshot older than 30 days, so we disable this
        Registry 'DisableMachineAccountPasswordChange' {
            Ensure = 'Present'
            Key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
            ValueName = 'DisablePasswordChange'
            ValueData = '1'
            ValueType = 'DWord'
        }

        # Enable ping requests and incoming Remote Desktop
        foreach ($firewallRule in @('FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In', 'RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
            # In current versions of DSC you can pass a built-in rule name and enable it without
            # specifying all of the other details
            Firewall "EnableFirewallRule$($firewallRule.Replace('-', ''))" {
                Name    = $firewallRule
                Ensure  = 'Present'
                Enabled = 'True'
            }    
        }

        # Enable Remote Desktop 
        xRemoteDesktopAdmin 'EnableRemoteDesktop' {
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
        }

        # Enable windows features
        $windowsFeatures = 'RSAT-AD-Tools', 'RSAT-AD-PowerShell', 'RSAT-Clustering', 'RSAT-Clustering-CmdInterface', 'RSAT-DNS-Server', 'RSAT-RemoteAccess'
        if ($node.ContainsKey('Role') -and $node.Role.ContainsKey('DomainController')) {
            $windowsFeatures += 'AD-Domain-Services', 'DNS', 'Routing'
        }
        if ($node.ContainsKey('Role') -and $node.Role.ContainsKey('Cluster')) {
            $windowsFeatures += 'Failover-Clustering'
        }

        foreach ($windowsFeature in $windowsFeatures) {
            WindowsFeature "AddWindowsFeature$($windowsFeature.Replace('-', ''))" {
                Ensure = 'Present'
                Name   = $windowsFeature
            }
        }

        # Define each network adapter name, IP address, default gateway address, DNS server address, and DNS connection suffix
        if ($node.ContainsKey('Network')) {
            for ($i = 0; $i -lt $node.Network.Count; $i++) {
                $network = $node.Network[$i]

                NetAdapterName "RenameNetAdapterName$($network.NetAdapterName)" {
                    NewName = $network.NetAdapterName
                    MacAddress = $node.Lability_MACAddress[$i].Replace(':', '-')
                }

                if ($network.ContainsKey('IPAddress')) {
                    IPAddress "SetIPAddress$($network.NetAdapterName)" {
                        AddressFamily = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        IPAddress = $network.IPAddress
                        DependsOn = "[NetAdapterName]RenameNetAdapterName$($network.NetAdapterName)"
                    }
                }

                if ($network.ContainsKey('DefaultGatewayAddress')) {
                    DefaultGatewayAddress "SetDefaultGatewayAddress$($network.NetAdapterName)" {
                        AddressFamily = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        Address = $network.DefaultGatewayAddress
                        DependsOn = "[NetAdapterName]RenameNetAdapterName$($network.NetAdapterName)"
                    }
                }

                if ($network.ContainsKey('DnsServerAddress')) {
                    DnsServerAddress "SetDnsServerAddress$($network.NetAdapterName)" {
                        AddressFamily  = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        Address        = $network.DnsServerAddress
                        DependsOn = "[NetAdapterName]RenameNetAdapterName$($network.NetAdapterName)"
                    }        
                }

                DnsConnectionSuffix "SetDnsConnectionSuffix$($network.NetAdapterName)" {
                    InterfaceAlias           = $network.NetAdapterName
                    ConnectionSpecificSuffix = $node.DomainName
                    DependsOn = "[NetAdapterName]RenameNetAdapterName$($network.NetAdapterName)"
                }
            }
        }

        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('DomainController')) {
                Computer 'RenameComputer' {
                    Name = $node.NodeName
                }
    
                Script 'SetNetIPInterfaceForwardingEnabled' {
                    GetScript = {
                    }
                    TestScript = {
                        if (Get-NetIPInterface | Where-Object { $_.Forwarding -ne 'Enabled' }) {
                            $false
                        } else {
                            $true
                        }
                    }
                    SetScript = {
                        Get-NetIPInterface | Where-Object { $_.Forwarding -ne 'Enabled' } | Set-NetIPInterface -Forwarding Enabled
                    }

                    DependsOn      = '[Computer]RenameComputer'
                }
    
                xADDomain 'CreateDomain' {
                    DomainName                    = $node.DomainName
                    DomainAdministratorCredential = $domainAdministrator
                    SafemodeAdministratorPassword = $safemodeAdministrator
    
                    DependsOn                     = '[WindowsFeature]AddWindowsFeatureADDomainServices'
                }
    
                # Define a share with all of our Lability_Resources so clients can use them for installs
                xSmbShare 'AddResourceShare' {
                    Name = 'Resources'
                    Ensure = 'Present'
                
                    Path = 'C:\Resources'
                    ReadAccess = 'Everyone'
                
                    DependsOn = '[xADDomain]CreateDomain'
                }    
            } else {
                xWaitForADDomain 'WaitForCreateDomain' {
                    DomainName           = $node.DomainName
                    DomainUserCredential = $domainAdministrator
                    # 30 Minutes
                    RetryIntervalSec     = 15
                    RetryCount           = 120
                }

                Computer 'RenameComputer' {
                    Name       = $node.NodeName
                    DomainName = $node.DomainName
                    Credential = $domainAdministrator
                    DependsOn  = '[xWaitForADDomain]WaitForCreateDomain'
                }
            }

            if ($node.Role.ContainsKey('Cluster')) {
                $cluster = $node.Role.Cluster
                $clusterIPAddress = $cluster.IPAddress

                if ($cluster.ContainsKey('First') -and $cluster.First) {
                    xCluster "CreateCluster$($cluster.Name)" {
                        Name                          = $cluster.Name
                        DomainAdministratorCredential = $domainAdministrator
                        StaticIPAddress               = $clusterIPAddress

                        # If RSAT-Clustering is not installed the cluster can not be created
                        DependsOn                     = '[WindowsFeature]AddWindowsFeatureFailoverClustering', '[WindowsFeature]AddWindowsFeatureRSATClustering', '[Computer]RenameComputer'
                    }    
                } else {
                    xWaitForCluster "WaitForCluster$($cluster.Name)" {
                        Name             = $cluster.Name

                        # 30 Minutes
                        RetryIntervalSec = 15
                        RetryCount       = 120

                        DependsOn        = '[WindowsFeature]AddWindowsFeatureFailoverClustering', '[WindowsFeature]AddWindowsFeatureRSATClustering', '[Computer]RenameComputer'
                    }
    
                    xCluster "AddNodeToCluster$($cluster.Name)" {
                        Name                          = $cluster.Name
                        DomainAdministratorCredential = $domainAdministrator
                        StaticIPAddress               = $clusterIPAddress

                        # If RSAT-Clustering is not installed the cluster can not be created
                        DependsOn                     = "[xWaitForCluster]WaitForCluster$($cluster.Name)"
                    }
    
                    Script "AddStaticIPToCluster$($cluster.Name)" {
                        GetScript = {
                        }
                        TestScript = {
                            $clusterIPAddress = ($using:clusterIPAddress -split '/')[0]
                            if (Get-ClusterResource | Where-Object { $_.ResourceType -eq 'IP Address' } | Get-ClusterParameter -Name Address | Where-Object { $_.Value -eq $clusterIPAddress }) {
                                $true
                            } else {
                                $false
                            }
                        }
                        SetScript = {
                            $clusterIPAddress = ($using:clusterIPAddress -split '/')[0]
                            Get-Cluster | Add-ClusterResource -Name 'IP Address $clusterIPAddress' -Group 'Cluster Group' -ResourceType 'IP Address'
                            $clusterNetwork = Get-Cluster | Get-ClusterNetwork | Where-Object { (([Net.IPAddress] $_.Address).Address -band ([Net.IPAddress] $_.AddressMask).Address) -eq (([Net.IPAddress] $clusterIPAddress).Address -band ([Net.IPAddress] $_.AddressMask).Address)}
                            Get-ClusterResource -Name 'IP Address $clusterIPAddress' | Set-ClusterParameter -Multiple @{ Address = $clusterIPAddress; Network = $clusterNetwork.Name; SubnetMask = $clusterNetwork.AddressMask; }
                            $dependencyExpression = (Get-Cluster | Get-ClusterResourceDependency -Resource 'Cluster Name').DependencyExpression
                            if ($dependencyExpression -match '^\((.*)\)$') {
                                $dependencyExpression = $Matches[1] + ' or [IP Address $clusterIPAddress]'
                            } else {
                                $dependencyExpression = $dependencyExpression + " or [IP Address $clusterIPAddress]"
                            }
                            Get-Cluster | Set-ClusterResourceDependency -Resource 'Cluster Name' -Dependency $dependencyExpression
                            # Without this, it won't start automatically on first try
                            (Get-Cluster | Get-ClusterResource -Name "IP Address $clusterIPAddress").PersistentState = 1
                        }

                        DependsOn = "[xCluster]AddNodeToCluster$($cluster.Name)"
                    }    
                }
            }
        }
    }
}

# Load the data so we can do our own manipulation
$configurationData = Import-PowerShellDataFile -Path C:\Lability\Configurations\WS2012.psd1
$configurationData.AllNodes | Where-Object { $_.NodeName -eq '*' } | ForEach-Object {
    $PSItem.CertificateFile = "$env:AllUsersProfile\Lability\Certificates\LabClient.cer"
}

# Lability creates one NIC per entry in a SwitchName array. We also creat a Lability_MACAddress array
# to assign AdapterName to each NIC as their default names are assigned randomly < Server 2012.
foreach ($node in $configurationData.AllNodes) {
    if ($node.ContainsKey('Network')) {
        $switchName = @()
        $macAddress = @()

        foreach ($network in $node.Network) {
            $switchName += $network.SwitchName
            # It's important to limit what MAC are used otherwise you will get confusing errors during VM creation
            $macAddress += ('00', '03', (0..3 | ForEach-Object { '{0:x}{1:x}' -f (Get-Random -Minimum 0 -Maximum 15),(Get-Random -Minimum 0 -Maximum 15) }) | ForEach-Object { $_ }) -join ':'
        }

        $node.Lability_SwitchName = $switchName
        $node.Lability_MACAddress = $macAddress
    }
}

# Compile it
WS2012 -ConfigurationData $configurationData -OutputPath C:\Lability\Configurations

# Clean up
if ($Clean) {
    Remove-LabConfiguration -ConfigurationData C:\Lability\Configurations\WS2012.psd1 -ErrorAction:SilentlyContinue -Confirm:$false
    Remove-Item C:\Lability\VMVirtualHardDisks\*
    $error.Clear()
}

# Build
$administrator = New-Object System.Management.Automation.PSCredential('Administrator', ('Admin2018!' | ConvertTo-SecureString -AsPlainText -Force))
Start-LabConfiguration -ConfigurationData $configurationData -IgnorePendingReboot -Credential $administrator -NoSnapshot

# Start
Start-Lab -ConfigurationData $configurationData

# Fix local RDP client
if (!(Test-Path HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP)) {
    New-Item HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP
}
if (!(Test-Path HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters)) {
    New-Item HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters
}
Set-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Name 'AllowEncryptionOracle' 2 -Type DWord
