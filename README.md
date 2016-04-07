# Zabbix-proxmox integration

## Background idea

I want to make vm related things configurable in one single place. Thus, to link
Proxmox VE and Zabbix monitoring system, I need a script that will work with two 
API's to make zabbix hosts and elements be automatically created according to 
current state of Proxmox VE server.

The idea is to have (or script will create for you) a separate host group 
(called "Proxmox nodes") which holds all the hypervisor machines you run.
Than for these machines script fidns at least one IP address and adds them into 
group. For each machine it gets list of virtual machines and creates a list of 
parameters to be monitored (see policy hash).

## Installation


  cpan install Net::Proxmox::VE


## Execution 

  ./pve-discover --zabbix\_user=USER --zabbix\_pass=PASS --zabbix\_host=HOST --proxmox\_user=USER --proxmox\_pass=PASS --proxmox\_host=HOST --proxmox\_realm=(pve|pam)
