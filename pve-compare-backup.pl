#!/usr/bin/perl
use strict;
use YAML::Tiny;
use Data::Dumper;

my $yamlconfig = "$ENV{HOME}/.pve-zabbix.yml" ;
my %C=();

if ( -f $yamlconfig ) {
   my $yaml = YAML::Tiny->read( $yamlconfig );
   %C=%{$yaml->[0]};   
};


my %P=%{$C->{PROXMOX}};
my %B=%{$C->{BACKUP}};

my $list_pve=`./pve-list-backuped-hosts "--proxmox_host=$P{HOST}" "--proxmox_user=$P{USER}" "--proxmox_pass=$P{PASS}"`;
my $list_bak=`ssh $B{USER}\@$B{HOST} ls -la  --time-style=+%s  $B{DIR}`;
my $files;
for my $line (split(/\n/,$list_bak) ) {

    my ($mode,$hz,$owner,$group,$size,$time,$name) = split(/\s+/,$line);
    if($name=~/vzdump-qemu-(\d+)-.*vma(\.gz|\.bz2|\.lzo)?/) {
        $files->{$1}->{$name}->{size} = $size;
        $files->{$1}->{$name}->{time} = $time;
    };
};

for my $line (split(/\n/,$list_pve) ) { 
    my($node,$vmid,$status,$uptime,$name) = split (/\t/,$line);
    my @files=keys(%{$files->{$vmid}});
    if ($#files == -1) { 
        print "No backups for vm $vmid, but should be\n";
    } else {
        my @g=sort { $files->{$vmid}->{$b}->{time} <=> $files->{$vmid}->{$a}->{time} } @files;
        print $vmid."\t".
              $status."\t".
              $uptime."\t".
              $files->{$vmid}->{$g[0]}->{size}."\t".
              localtime($files->{$vmid}->{$g[0]}->{time})."\t".
              $name."\n";
    };
    
};


