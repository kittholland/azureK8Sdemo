#requires -Modules Posh-SSH, AzureRM
Param
(
  [Parameter()]
  [Switch]$InstallNginxIngress,

  [Parameter()]
  [Switch]$InstallK8sDashboard

)


$vmCreds = Get-Credential -Message 'Password will not be used'
$username = $vmCreds.UserName
$autoShutdownTime = "1900"
$timeZone = Get-TimeZone

$resourceGroupName = 'k8s'
$location = 'West US 2'
$VMNames = 'master', 'slave'
$VMSize = 'Standard_D2s_v3' # 2 core, 8gb
$subnetName = "$resourceGroupName-subnet"
$subnetRange = '10.0.2.0/24'
$netRange = '10.0.0.0/16'

$sshPublicKey = Get-Content -Raw -Path "$env:USERPROFILE\documents\azurekeypublic"
$sshPrivateKeyPath = "$env:USERPROFILE\documents\azurekeyopenssh"

$outboundIpObj = Invoke-RestMethod -Uri http://ipinfo.io/json
$outboundCidr = "$($outboundIpObj.ip)/32"

$null = Connect-AzureRmAccount
$subscriptionId = (Get-AzureRmContext).Subscription.Id

$null = New-AzureRmResourceGroup -Name $resourceGroupName -Location $location

$subnetConfig = New-AzureRmVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetRange

$networkSplat = @{
  Name              = "$resourceGroupName-net"
  ResourceGroupName = $resourceGroupName
  Location          = $location
  AddressPrefix     = $netRange
  Subnet            = $subnetConfig
}
$network = New-AzureRmVirtualNetwork @networkSplat
$subnet = $network.Subnets | Where-Object Name -EQ -Value $subnetName

$set = New-AzureRmAvailabilitySet "$resourceGroupName-set" -ResourceGroupName $resourceGroupName -Location $location

$ruleSplat = @{
  Name                     = 'inbound-ssh'
  Protocol                 = 'Tcp'
  Direction                = 'Inbound'
  Priority                 = 1022
  SourceAddressPrefix      = $outboundCidr
  SourcePortRange          = '*'
  DestinationAddressPrefix = '*'
  DestinationPortRange     = 22
  Access                   = 'Allow'
}
$sshRule = New-AzureRmNetworkSecurityRuleConfig @ruleSplat

$ruleSplat.Name = 'inbound-http'
$ruleSplat.Priority = '1080'
$ruleSplat.DestinationPortRange = 80
$httpRule = New-AzureRmNetworkSecurityRuleConfig @ruleSplat

$ruleSplat.Name = 'inbound-https'
$ruleSplat.Priority = '1443'
$ruleSplat.DestinationPortRange = 443
$httpsRule = New-AzureRmNetworkSecurityRuleConfig @ruleSplat

$nsg = New-AzureRmNetworkSecurityGroup -Name "$resourceGroupName-nsg" -ResourceGroupName $resourceGroupName -Location $location -SecurityRules $sshRule, $httpRule, $httpsRule

$pipSplat = @{
  Name              = "$resourceGroupName-lb-publicIp"
  ResourceGroupName = $resourceGroupName
  Location          = $location
  AllocationMethod  = 'Dynamic'
  DomainNameLabel = "$resourceGroupName-demo-lb-pub"
}
$publicIpObj = New-AzureRmPublicIpAddress @pipSplat
$frontEndIPConfig = New-AzureRmLoadBalancerFrontendIpConfig -Name "$resourceGroupName-frontendIP" -PublicIpAddress $publicIpObj
$backendPoolConfig = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "$resourceGroupName-backendPool"

$lbRuleSplat = @{
  Name = "$resourceGroupName-lbRule-http"
  FrontEndIpConfiguration = $frontEndIPConfig
  BackendAddressPool = $backendPoolConfig
  Protocol = 'Tcp'
  FrontendPort = 80
  BackendPort = 30080
}

$httpLB = New-AzureRmLoadBalancerRuleConfig @lbRuleSplat

$lbRuleSplat.Name = "$resourceGroupName-lbRule-https"
$lbRuleSplat.FrontendPort = 443
$lbRuleSplat.BackendPort = 30443
$httpsLB = New-AzureRmLoadBalancerRuleConfig @lbRuleSplat

$lbSplat = @{
  Name = "$resourceGroupName-loadBalancer"
  ResourceGroupName = $resourceGroupName
  Location = $location
  FrontEndIPConfiguration = $frontEndIPConfig
  BackendAddressPool = $backendPoolConfig
  LoadBalancingRule = $httpLB, $httpsLB
}

$lb = New-AzureRmLoadBalancer @lbSplat


Foreach($vmName in $VMNames)
{
  $computerName = "$resourceGroupName-$vmName"
  $publicIpName = "$computerName-publicIp"
  
  $pipSplat = @{
    Name              = $publicIpName
    ResourceGroupName = $resourceGroupName
    Location          = $location
    AllocationMethod  = 'Dynamic'
  }
  $publicIp = New-AzureRmPublicIpAddress @pipSplat
  
  $nicSplat = @{
    Name                   = "$resourceGroupName-$vmName-nic"
    ResourceGroupName      = $resourceGroupName
    Location               = $location
    SubnetId               = $subnet.Id
    PublicIpAddressId      = $publicIp.Id
    NetworkSecurityGroupId = $nsg.Id
    FrontendIpConfiguration = $frontEndIPConfig
    LoadBalancingRule = $httpLB, $httpsLB
    LoadBalancerBackendAddressPool = $backendPoolConfig
  }
  $nic = New-AzureRmNetworkInterface @nicSplat
  
  $vmConfigSplat = @{
    VMName = $computerName
    VMSize = $VMSize
    AvailabilitySetId = $set.Id
  }
  $vmConfig = New-AzureRmVMConfig @vmConfigSplat
  
  $vmOperatingSystemSplat = @{
    VM                            = $vmConfig
    Linux                         = $true
    Credential                    = $vmCreds
    DisablePasswordAuthentication = $true
    ComputerName                  = $computerName
  }
  $null = Set-AzureRmVMOperatingSystem @vmOperatingSystemSplat
  
  $vmSourceImageSplat = @{
    VM            = $vmConfig
    PublisherName = 'Canonical'
    Offer         = 'UbuntuServer'
    Skus          = '18.04-LTS'
    Version       = 'latest'
  }
  $null = Set-AzureRmVMSourceImage @vmSourceImageSplat
  
  $null = Add-AzureRmVMNetworkInterface -VM $vmConfig -Id $nic.Id
  
  $null = Add-AzureRmVMSshPublicKey -VM $vmConfig -KeyData $sshPublicKey -Path "/home/$username/.ssh/authorized_keys"
  
  $null = Set-AzureRmVMBootDiagnostics -VM $vmConfig -Disable
  
  $null = New-AzureRmVM -ResourceGroupName $resourceGroupName -Location $location -VM $vmConfig
    
  $autoShutdownProperties = @{
    status = "Enabled"
    taskType = "ComputeVmShutdownTask"
    dailyRecurrence = @{"time" = $autoShutdownTime }
    timeZoneId = $timeZone.id
    notificationSettings = @{
      status = "Disabled"
      timeInMinutes = 30
    }
    targetResourceId = (Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $computerName).Id
  }

  $autoShutdownSplat = @{
    ResourceId = "/subscriptions/{0}/resourceGroups/{1}/providers/microsoft.devtestlab/schedules/shutdown-computevm-{2}" -f $subscriptionId, $resourceGroupName, $computerName
    Location = $location
    Properties = $autoShutdownProperties
    Force = $true
  }

  $null = New-AzureRmResource @autoShutdownSplat
    
  $publicIpObj = Get-AzureRmPublicIpAddress -Name $publicIpName -ResourceGroupName $resourceGroupName
  $publicIp = $publicIpObj.IpAddress
  Write-Host -Object "Public IP for $computerName`: $publicIp"
  
  $sshCommandSplat = @{
    ComputerName = $publicIp
    KeyFile      = $sshPrivateKeyPath
    Credential   = $vmCreds
    AcceptKey    = $true
  }

  $sshSession = New-SSHSession @sshCommandSplat

  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt install docker.io -y'
  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo systemctl enable docker'
  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add'
  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"'
  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo swapoff -a'
  $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt install kubeadm -y'
  
  Switch ($vmName)
  {
    'Master'
    {
      $masterSshSession = $sshSession
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo kubeadm init --pod-network-cidr=10.244.0.0/16' -TimeOut 300
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'mkdir -p $HOME/.kube'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo chown $(id -u):$(id -g) $HOME/.kube/config'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml'
      
      $kubeJoin = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo kubeadm token create --print-join-command'    
    }
    default
    {
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command "sudo $($kubeJoin.Output[0])" -TimeOut 300
    }
  }
}

If($InstallNginxIngress)
{
  $null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml'
  $null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/provider/baremetal/service-nodeport.yaml'
}

If($InstallK8sDashboard)
{
  $null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml'
}


#Run the line below to destroy the resource group you created. This will remove everything including other items you have added to that resource group.
#Remove-AzureRmResourceGroup -Name $resourceGroupName -Confirm:$false -Force