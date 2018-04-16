#!/usr/bin/perl
use strict;
use YAML::Tiny;
use Data::Dumper;
use Getopt::Long;
use Pod::Usage;
use Net::Proxmox::VE;
no warnings 'experimental';

=head1 pve-run-tester.pl

    pve-run-tester.pl - Run tesing virtual machine (proxmox inside proxmox!), wait for it too boot, than restore backups into it.

=head1  SYNOPSIS
     
    pve-run-tester.pl [-h] [--operation=(all|run|check|mount|test|shutdown)] [--vm=VMID]

=head1 OPTIONS

=over 4

=item B<-help>

    Print a brief help message and exits.

=item B<-operation>

    Performs requested operation

=back

=cut

my $yamlconfig = "$ENV{HOME}/.pve-zabbix.yml" ;
my %C=();

if ( -f $yamlconfig ) {
   my $yaml = YAML::Tiny->read( $yamlconfig );
   %C=%{$yaml->[0]};   
};

my $help = 0;
my $op = "";
my $vmid=undef;
GetOptions("help|?" => \$help ,
           "operation|o=s" => \$op,
           "vm|v=s" => \$vmid
          );
pod2usage(-verbose => 2) if $help;

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME}=0;

my %PG= %{$C{PROXMOX}};
my %T = %{$C{TESTER}};
my %B = %{$C{BACKUP}};

my $proxmox_global = Net::Proxmox::VE->new ( { 
      host => $PG{HOST}, 
      username => $PG{USER}, 
      password => $PG{PASS}, 
      realm => $PG{REALM},
      ssl_opts => { verify_hostnames => 0 ,SSL_verify_mode => 0x00 }
  } );


my $proxmox_tester = Net::Proxmox::VE->new ( { 
      host => $T{HOST}, 
      username => $T{USER}, 
      password => $T{PASS}, 
      realm => $T{REALM},
      ssl_opts => { verify_hostnames => 0 ,SSL_verify_mode => 0x00 }
  } );


=head2 run
 
 Operation run - check that virtual proxmox is running, execute if not 

=cut

sub do_run {
  my $state = $proxmox_global->get('/nodes/'.$T{NODE}.'/qemu/'.$T{VM}.'/status/current');
  if($state->{status} eq 'running') {
    print "Already running\n";
  } else {
    print "Trying to start...\n";
    my $report = $proxmox_global->post('/nodes/'.$T{NODE}.'/qemu/'.$T{VM}.'/status/start');
    print Dumper($report);
    sleep(1);
    my $state = $proxmox_global->get('/nodes/'.$T{NODE}.'/qemu/'.$T{VM}.'/status/current');
    print "Status: ".$state->{status}."\n";
    sleep(1);
  };
#  print Dumper($state);
};

=head2 check

 Operation check - checks that virtual proxmox is already running, if it does - 
 tries to log in (repeats 20 times with interval of 10 seconds).
 Than logs into virtual proxmox over ssh.

=cut

sub do_check {
  my $state = $proxmox_global->get('/nodes/'.$T{NODE}.'/qemu/'.$T{VM}.'/status/current');
  if($state->{status} ne 'running' ) {
    die("Virtual proxmox vm ".$T{VM}." on node ".$T{NODE}." not running\n");
  };
  my $i=0; 
  my $maxi=20;
  while(($i<$maxi) and not($proxmox_tester->login())) {
    $i++;
    print "Tester login failed. Waiting 10s ($i of $maxi)\n";
    sleep(10);
  };
  if($i == $maxi) {
    die("Can not log in to tester!\n");
  };
  my $sshrep = `ssh $T{USER}\@$T{HOST} uptime`;
  if($sshrep ne '') {
    print "ssh possible";
  } else {
    die("ssh not possible. can't continue\n");
  };
};

=head2 mount

  Operation mount - mount backup directory on remote running virtual proxmox

=cut

sub do_mount {
  if($proxmox_tester->login()) {
     system("ssh $T{USER}\@$T{HOST} mkdir /var/backup");

     my $updir = $B{DIR};
     $updir =~ s/\/dump$//;

     my $res = `ssh $T{USER}\@$T{HOST} mount | grep $updir`;

     if($res eq '') {
       print "sshfs: \n";
       my $sshfs_out=`ssh $T{USER}\@$T{HOST} /usr/bin/sshfs -o uid=0,gid=0,nonempty $B{USER_FOR_PVE}\@$B{HOST}:$updir /var/backup`;
       if ($sshfs_out ne '' or not(defined($sshfs_out)) ) {
         die("Problems with sshfs: $sshfs_out\n");
       };
     } else {
       print "Looks like $updir from $B{HOST} already mounted: $res\nmount not required\n";
     };
     
  } else {
    die("Can not login to virtual proxmox");
  };
};

sub urlize {
  my ($rv) = @_;
  $rv =~ s/([^A-Za-z0-9])/sprintf("%%%2.2X", ord($1))/ge;
  return $rv;
}

sub get_node_by_vmid($) {
  my $p=$_[0];
  my $nodes = $p->get('/nodes');
  my $href;
  for my $node (@{$nodes}) {
    my $qemu_vms=$p->get('/nodes/'.$node->{node}.'/qemu');
    for my $vm (@{$qemu_vms}) {
      $href->{$vm->{vmid}}=$node->{node};
    };
  };
  return $href;
};

=head2 test

  Operation test - tries to recover specified (in --vm parameter) vm in virtual proxmox

=cut

sub do_test {
  if(not($proxmox_tester->login())) {
    die("Can not login to virtual proxmox");
  };
  my @vmids;  
  if(defined($vmid)) {
    push @vmids, $vmid
  } else {
    my $list_pve=`./pve-list-backuped-hosts "--proxmox_host=$PG{HOST}" "--proxmox_user=$PG{USER}" "--proxmox_pass=$PG{PASS}"`;
    foreach my $line (split("\n",$list_pve)) {
      my @cols=split("\t",$line);
      push @vmids, $cols[1];
    };
  };
  print "vmids:\n  ".join("\n  ",@vmids);
  my $node_by_vmid = get_node_by_vmid($proxmox_global);
  my $configs;
  my $bridges;
  for $vmid (@vmids) {
    my $current_config = $proxmox_global->get('/nodes/'.$node_by_vmid->{$vmid}.'/qemu/'.$vmid.'/config');
#    print Dumper($current_config);
    my %h=%{$current_config};
    my $cdrom=undef;
    for my $key (keys ( %h ) ) {
       my $value=$h{$key};
       if($key=~/^net.*/) {
         if($value=~/bridge=([a-z0-9A-Z\.:_]+)/) {
           $bridges->{$1} = 1;
         };
       };
       if($value=~/media=cdrom/) {
           print "delete cdrom\n";
           $cdrom=$key;
       };
       if(defined($h{$key})) {
          $h{$key} = urlize($h{$key});
       };
    };
    if(defined($cdrom)) {
       $h{_cdrom} = $cdrom;
    };
    if(defined($T{MAXMEMORY}) and $h{memory} > $T{MAXMEMORY}) {
       $h{memory} = $T{MAXMEMORY};
    };
    $h{kvm}=0;
    
    $configs->{$vmid} = \%h;
  };

  my $apinode = '/nodes/'.$T{INTERNAL_NODE};

  my $devs = $proxmox_tester->get($apinode.'/network');
  print Dumper($devs);
  for my $dev ( @{$devs}) {
    if(defined($bridges->{$dev->{iface}})) {
      delete $bridges->{$dev->{iface}};
    };
  };
  my $count=0;
  for my $br (keys(%{$bridges})) { # create remaining bridges
    print "Adding bridge $br\n";
    $count++;
    my $br_result = $proxmox_tester->post($apinode.'/network',
                          {
                          iface => $br,
                          type => 'bridge',
                          autostart => 1,
                          bridge_ports => 'none'
                          
                          }
                         );
    
    print "Result: ".Dumper($br_result);
  };
  if($count > 0) {
    print "Reboot required. Rebooting.\n";
    my $reboot_res = $proxmox_tester->post($apinode.'/status',{ command => 'reboot'} );
    sleep(10);
    print "Checking...\n";
    do_check();
    print "Mounting...\n";
    do_mount();
  };

# backup storage

### TBD - it's better to check beforehand.

  my $del_res = $proxmox_tester->delete('/storage/backup');
  my $storages = $proxmox_tester->post('/storage', {
          'type' => 'dir',
          'path' => '/var/backup', 
          'storage' => 'backup',
          'content' => 'backup'
         });

  my $storage_content=$proxmox_tester->get($apinode.'/storage/backup/content');
  
#  print Dumper($storage_content);

#   'content' => 'backup',
#   'format' => 'vma.gz',
#   'size' => 472,
#   'volid' => 'backup:backup/vzdump-qemu-144-2018_04_13-03_26_24.vma.gz'
  my $backups;
  foreach my $file (@{$storage_content}) {
    foreach my $vmid (keys(%{$configs})) { 
      if ($file->{volid} =~ /vzdump-qemu-$vmid-/ and $file->{content} eq 'backup') {
        $backups->{$vmid}->{$file->{volid}} = 1;
      };
    };
  };




  my $oldqemu = $proxmox_tester->get($apinode.'/qemu');

  for my $vmid (keys(%{$configs})) {
     if(not(defined($backups->{$vmid}))) {
        print "ERROR: no backups for vm $vmid found!\n";
     } else {
       foreach my $file (keys(%{$backups->{$vmid}})) {

          system("ssh $T{USER}\@$T{HOST} qmrestore --storage ".$T{STORAGE}." --force 1 ".$file." ".$vmid );

          print "Changing required vm settings for $vmid:\n";
          $configs->{$vmid}->{vmid}=$vmid;

          my %newconfig = (
               kvm => 0,
               memory => $configs->{$vmid}->{memory}
          ); 
          if(defined($configs->{$vmid}->{_cdrom})) {
            $newconfig{$configs->{$vmid}->{_cdrom}} = urlize( "none,media=cdrom" ); 
          };
          my $change_result = $proxmox_tester->put($apinode.'/qemu/'.$vmid.'/config', \%newconfig );

          print "change_result: ".Dumper($change_result)."\n";
          print "restore job: \n";

          print "You may go to https://".$T{HOST}.":8006/#v1:0:=qemu%2F$vmid , open the console and check for running jobs, run vm and test remaining thing manually\n";
          
          ### Here we can time-out, so login again.
          $proxmox_tester->login();
          my $run_result = $proxmox_tester->post($apinode.'/qemu/'.$vmid.'/status/start');
          print "run_result: ".Dumper($run_result)."\n";
          print "--Press any key to continue--\n";
          my $line = <STDIN>;
          ### Here we can time-out, so login again.
          $proxmox_tester->login();
          print "Stoping vm:\n";
          my $stop_result = $proxmox_tester->post($apinode.'/qemu/'.$vmid.'/status/stop');
          print "stop_result: ".Dumper($stop_result)."\n";
          print "Removing old vm : ".$vmid."\n";
          my $del_result = $proxmox_tester->delete($apinode.'/qemu/'.$vmid);
          print "result: ".Dumper($del_result);
         
          
       };
     };
     
  };

  
};


sub do_all {
  do_run();
  do_check();
  do_mount();
  do_test();
  do_shutdown();
};

sub do_shutdown {
  if($proxmox_tester->login()) {
    my $post_res = $proxmox_tester->post('/nodes/'.$T{INTERNAL_NODE}.'/status',{ command => 'shutdown'} );
    print Dumper($post_res);
  };
};

my %ops = ( 
   'all'   => \&do_all,
   'run'   => \&do_run,
   'check' => \&do_check,
   'mount' => \&do_mount,
   'test'  => \&do_test,
   'shutdown' => \&do_shutdown
);



if (defined($ops{$op})) {
    $proxmox_global->login() or die ('Couldnt connect to proxmox host');

    for my $key ( 'NODE', 'VM', 'HOST', 'USER', 'PASS' ) {
      if(not(defined($T{$key}))) {
        die('Please, configure TESTER->'.$key);
      };
    };

    $ops{$op}();
} else {
    print "Nothing to do (op=$op).\n";
};

exit(1);


my $list_pve=`./pve-list-backuped-hosts "--proxmox_host=$C{PROXMOX_HOST}" "--proxmox_user=$C{PROXMOX_USER}" "--proxmox_pass=$C{PROXMOX_PASS}"`;
my $list_bak=`ssh $C{BACKUP_USER}\@$C{BACKUP_HOST} ls -la  --time-style=+%s  $C{BACKUP_DIR}`;
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

__END__


=head1 REQUIRED CONFIGURATION
    
    B<pve-run-tester.pl> relies on ~/.pve-zabbix.yml

    This file should contain at least the following:

 %YAML 1.2
 ---
 PROXMOX:
   HOST: some.proxmox.host
   USER: username
   PASS: "SOMEPASSWORD"
   REALM: pam
 BACKUP:
   HOST: host_to_ssh
   USER: ssh_username
   USER_FOR_PVE: ssh_username_for_proxmox_to_login
   DIR: /var/vmbackup/dump
 TESTER:
   NODE: vm3
   VM: 123
   HOST: tester.proxmox.host
   USER: username
   REALM: pam
   PASS: "ONEMOREPASS"
   INTERNAL_NODE: test-deb9-vm
   MAXMEMORY: 3000
   STORAGE: vmpool

=head1 DESCRIPTION

    pve-run-tester.pl will connect to proxmox API of running cluster and do 
    some backup-testing operations.

    It expects that you have (in advance!) set up and configured one "testing" vm,
    which has proxmox installed inside.

    It also expects that you have ~/.pve-zabbix.yml with three parts:

=head2 PROXMOX
    
    This part describes original proxmox host. It will be touched in almost  read-only mode - 
    we have to find out, which vm's are backed up

=head2 BACKUP
  
    This part describes backup server. We expect that it is ssh-available host, which we can
    ssh to without having to enter password (use ssh-keygen and ssh-copy-id to achive this).
    
    We also expect that "testing" vm is already configured to do the same with backup host,
    and USER_FOR_PVE field contains it's username on backup host.

=head2 TESTER
   
    This part describes testing vm itself.

    NODE - is where this vm is situated

    VM - is it's VMID on host proxmox
  
    HOST - is it's hostname (after it will boot)
 
    USER/PASS/REALM - is it's internal proxmox's authentication settings.
 
    INTERNAL_NODE - is it's hostname as it is seen from inside virtual proxmox

    MAXMEMORY - maximum amount of memory allowed for guest vms to allocate.
 
    STORAGE - name of storage (inside virtual proxmox) to use for restoring vms

    N.B. We also expect that we can use ssh USER@HOST to log in to tester node and execute qmrestore, for example.


=head1 OPEARTIONS

   all - Perform all the following operations, in order.

   run - Run testing vm
 
   check - Wait for guest API is available.

   mount - mount backup storage on guest.

   test - do actual testing. It will try to configure vm's, call qmrestore through ssh to restore backups and will pause (expecting you to hit "Enter") when vm is ready for (manual? automated?) checking of it's internal health.
   
   shutdown - shutdown testing vm

=head1 NOTICES

   All network bridges are created as empty bridges - I expect that if you require some specific network virtualisation, you will tune it yourself in advance.

   If bridges are created, testing vm is rebooted afterwards.

   This tester tests VMs sequentially, assuming that they are independent. You need more complicated scenarios (and better - dedicated hardware) to test collective actions.

=cut 
