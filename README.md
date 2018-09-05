# azureK8Sdemo
K8S lab setup on Ubuntu 18.04LTS on Azure VMs

Prerequisties:
  Modules:
    AzureRM
    Posh-SSH
  Other:
    Valid Azure Account (by default uses Standard_D2s_v3 in WestUS2 region)
    SSH Public key
    OpenSSH private key
    both default to $HOME\.ssh but accepts parameters for a different path
    
Parameters:
  DnsName: DNS Name for your azure load balancer, must be unique across your region
  AutoShutdown: Configures an automatic shutdown resource for each VM at 7 PM local time from where you execute the script.
  SSHPublicKeyPath: Path to your Public Key
  SSHPrivateKeyPath: Path to your Private Key
