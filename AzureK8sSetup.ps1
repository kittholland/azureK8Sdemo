#requires -Modules Posh-SSH, AzureRM
Param
(
  [Parameter(Mandatory)]
  [String]$DNSName,

  [Parameter()]
  [String]$SSHPublicKeyPath = "$HOME\.ssh\id_rsa.pub",

  [Parameter()]
  [String]$SSHPrivateKeyPath = "$HOME\.ssh\id_rsa",

  [Parameter()]
  [Switch]$AutoShutdown
)

$ErrorActionPreference = 'Stop'

$resourceGroupName = 'k8s'
$location = 'West US 2'
$VMNames = 'master', 'slave'
$VMSize = 'Standard_D2s_v3' # 2 core, 8gb
$subnetName = "$resourceGroupName-subnet"
$subnetRange = '10.0.2.0/24'
$netRange = '10.0.0.0/16'
$autoShutdownTime = '1900'

Try 
{
  $null = Resolve-DnsName -Name "$DNSName.$($location -replace ' ').cloudapp.azure.com"
}
Catch
{
  If($PSItem.Exception.Message.EndsWith('DNS name does not exist'))
  {
    $nameAvailable = $true
  }
  Else
  {
    Throw $PSItem
  }
}
If(!$nameAvailable)
{
  Throw "DNS Name $DNSName is unavailable, please select another name."
}

$sshPublicKey = Get-Content -Raw -Path $SSHPublicKeyPath

$vmCreds = Get-Credential -Message 'Username for VM login, Password for SSH private key'
$username = $vmCreds.UserName
$timeZone = Get-TimeZone

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

$setSplat = @{
  Name              = "$resourceGroupName-set"
  ResourceGroupName = $resourceGroupName
  Location          = $location
  Sku = 'Aligned'
  PlatformFaultDomainCount = 2
  PlatformUpdateDomainCount = 2
}
$set = New-AzureRmAvailabilitySet @setSplat

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

$ruleSplat.Name = 'ingress-http'
$ruleSplat.Priority = '1080'
$ruleSplat.DestinationPortRange = 30080
$httpRule = New-AzureRmNetworkSecurityRuleConfig @ruleSplat

$ruleSplat.Name = 'ingress-https'
$ruleSplat.Priority = '1443'
$ruleSplat.DestinationPortRange = 30443
$httpsRule = New-AzureRmNetworkSecurityRuleConfig @ruleSplat

$nsg = New-AzureRmNetworkSecurityGroup -Name "$resourceGroupName-nsg" -ResourceGroupName $resourceGroupName -Location $location -SecurityRules $sshRule, $httpRule, $httpsRule

$pipSplat = @{
  Name              = "$resourceGroupName-lb-publicIp"
  ResourceGroupName = $resourceGroupName
  Location          = $location
  AllocationMethod  = 'Dynamic'
  DomainNameLabel   = $dnsName
}
$lbPublicIpObj = New-AzureRmPublicIpAddress @pipSplat
$frontEndIPConfig = New-AzureRmLoadBalancerFrontendIpConfig -Name "$resourceGroupName-frontendIP" -PublicIpAddress $lbPublicIpObj
$backendPoolConfig = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "$resourceGroupName-backendPool"

$probeSplat = @{
  Name = "$resourceGroupName-probe-tcp-30080"
  Protocol = 'Tcp'
  Port = 30080
  IntervalInSeconds = 16
  ProbeCount = 2
}

$httpProbe = New-AzureRmLoadBalancerProbeConfig @probeSplat

$probeSplat.Name = "$resourceGroupName-probe-tcp-30443"
$probeSplat.Port = 30443

$httpsProbe = New-AzureRmLoadBalancerProbeConfig @probeSplat


$lbRuleSplat = @{
  Name                    = "$resourceGroupName-lbRule-http"
  FrontEndIpConfiguration = $frontEndIPConfig
  BackendAddressPool      = $backendPoolConfig
  Protocol                = 'Tcp'
  FrontendPort            = 80
  BackendPort             = 30080
  Probe = $httpProbe
}

$httpLB = New-AzureRmLoadBalancerRuleConfig @lbRuleSplat

$lbRuleSplat.Name = "$resourceGroupName-lbRule-https"
$lbRuleSplat.FrontendPort = 443
$lbRuleSplat.BackendPort = 30443
$lbRuleSplat.Probe = $httpsProbe
$httpsLB = New-AzureRmLoadBalancerRuleConfig @lbRuleSplat

$lbSplat = @{
  Name                    = "$resourceGroupName-loadBalancer"
  ResourceGroupName       = $resourceGroupName
  Location                = $location
  FrontEndIPConfiguration = $frontEndIPConfig
  BackendAddressPool      = $backendPoolConfig
  LoadBalancingRule       = $httpLB, $httpsLB
  Probe = $httpProbe, $httpsProbe
}

$null = New-AzureRmLoadBalancer @lbSplat

If($AutoShutdown)
{
  $registrationState = {
      Get-AzureRmResourceProvider -ProviderNamespace Microsoft.DevTestLab |
          Select-Object -ExpandProperty RegistrationState -Unique
  }

  $registrationStatus = & $registrationState
  
  while ('Registered' -ne $registrationStatus)
  {
      $null = Register-AzureRmResourceProvider -ProviderNamespace Microsoft.DevTestLab
      Start-Sleep -Seconds 30
      $registrationStatus = & $registrationState
  }
}

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
    Name                           = "$resourceGroupName-$vmName-nic"
    ResourceGroupName              = $resourceGroupName
    Location                       = $location
    Subnet                         = $subnet
    PublicIpAddress                = $publicIp
    NetworkSecurityGroup           = $nsg
    LoadBalancerBackendAddressPool = $backendPoolConfig
  }
  $nic = New-AzureRmNetworkInterface @nicSplat
  
  $vmConfigSplat = @{
    VMName            = $computerName
    VMSize            = $VMSize
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
  
  If($AutoShutdown)
  {
    $autoShutdownProperties = @{
      status               = 'Enabled'
      taskType             = 'ComputeVmShutdownTask'
      dailyRecurrence      = @{
        'time' = $autoShutdownTime
      }
      timeZoneId           = $timeZone.id
      notificationSettings = @{
        status        = 'Disabled'
        timeInMinutes = 30
      }
      targetResourceId     = (Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $computerName).Id
    }

    $autoShutdownSplat = @{
      ResourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/microsoft.devtestlab/schedules/shutdown-computevm-{2}' -f $subscriptionId, $resourceGroupName, $computerName
      Location   = $location
      Properties = $autoShutdownProperties
      Force      = $true
    }

    $null = New-AzureRmResource @autoShutdownSplat
  }
  
  $publicIpObj = Get-AzureRmPublicIpAddress -Name $publicIpName -ResourceGroupName $resourceGroupName
  $publicIp = $publicIpObj.IpAddress
  Write-Host -Object "Public IP for $computerName`: $publicIp"
  
  $sshCommandSplat = @{
    ComputerName = $publicIp
    KeyFile      = $sshPrivateKeyPath
    Credential   = $vmCreds
    AcceptKey    = $true
  }

  Write-Host -Object "Creating SSH Session to $computerName"
  $sshSession = New-SSHSession @sshCommandSplat

  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt install docker.io -y'
  Write-Verbose -Message "  -Installed Docker - Output: $($sshResponse.Output)"
  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo systemctl enable docker'
  Write-Verbose -Message "  -Enabled Docker as a Service - Output: $($sshResponse.Output)"
  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add'
  Write-Verbose -Message "  -Installed google cloud package repository gpg key - Output: $($sshResponse.Output)"
  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"'
  Write-Verbose -Message "  -Added Kubernetes package repository - Output: $($sshResponse.Output)"
  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo swapoff -a'
  Write-Verbose -Message "  -Turned swap off - Output: $($sshResponse.Output)"
  $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo apt install kubeadm -y'
  Write-Verbose -Message "  -Installed Kubernetes - Output: $($sshResponse.Output)"
    
  Switch ($vmName)
  {
    'Master'
    {
      $masterSshSession = $sshSession
      $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo kubeadm init --pod-network-cidr=10.244.0.0/16' -TimeOut 300
      Write-Verbose -Message "  -Initialized Kubernetes network - Output: $($sshResponse.Output)"      
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'mkdir -p $HOME/.kube'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo chown $(id -u):$(id -g) $HOME/.kube/config'
      $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml'
      Write-Verbose -Message "  -Installed Flannel - Output: $($sshResponse.Output)"
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'kubectl config set-context ks --user=kubernetes-admin --cluster=kubernetes --namespace=kube-system'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'kubectl config set-context nginx --user=kubernetes-admin --cluster=kubernetes --namespace=ingress-nginx'
      $null = Invoke-SSHCommand -SSHSession $sshSession -Command 'kubectl config set-context default --user=kubernetes-admin --cluster=kubernetes --namespace=default'      
      
      $kubeJoin = Invoke-SSHCommand -SSHSession $sshSession -Command 'sudo kubeadm token create --print-join-command'    
    }
    default
    {
      $sshResponse = Invoke-SSHCommand -SSHSession $sshSession -Command "sudo $($kubeJoin.Output[0])" -TimeOut 300
      Write-Verbose -Message "  -Joined Kubernetes cluster - Output: $($sshResponse.Output)"      
    }
  }
}

Write-Verbose -Message "Installing Nginx Ingress"
$null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml'
$null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kittholland/azureK8Sdemo/master/nginx-service-nodeport.yaml'
$null = Invoke-SSHCommand -SSHSession $masterSshSession -Command "curl -s https://raw.githubusercontent.com/kittholland/azureK8Sdemo/master/nginx-ingress.yaml | sed s/k8s-demo-lb-pub.westus2.cloudapp.azure.com/$($lbPublicIpObj.DnsSettings.Fqdn)/g | kubectl apply -f -"

Write-Verbose -Message "Installing Kubernetes Dashboard"
$null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/alternative/kubernetes-dashboard.yaml'
$null = Invoke-SSHCommand -SSHSession $masterSshSession -Command 'kubectl apply -f https://raw.githubusercontent.com/kittholland/azureK8Sdemo/master/dashboard-rbac.yml'

$publicIpObj = Get-AzureRmPublicIpAddress -Name $lbPublicIpObj.Name -ResourceGroupName $resourceGroupName
$publicIp = $publicIpObj.IpAddress
Write-Host -Object "Public IP for Load Balancer`: $($publicIpObj.IpAddress)"
Write-Host -Object "Public DNS Name: $($publicIpObj.DnsSettings.Fqdn)"


#Run the line below to destroy the resource group you created. This will remove everything including other items you have added to that resource group.
#Remove-AzureRmResourceGroup -Name $resourceGroupName -Confirm:$false -Force