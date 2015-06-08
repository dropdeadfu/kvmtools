#!/usr/bin/perl
#
# Written by Christoph Heuwieser 11.02.2015
#
# setup as /etc/libvirt/hooks/qemu and chmod +x
#
use strict;


my %domains =
(
  vmname01 =>
  {
    ip       => '192.168.122.20',
    forwards =>
    {
      33051  => '3389'
    }
  },
  vmname02 =>
  {
    ip       => '192.168.122.21',
    forwards =>
    {
      33052  => '3389',
      22442  => '80',
      22443  => '443'
    }
  }
);


my $logfile      = "/var/log/cv_domaincontrol.log";

my $debug        = "on";

my $iptables     = "/sbin/iptables";

my @external_ifs = ("xenbrext", "virbr0");

my $external_ip  = "10.1.1.1";

my $domain_name  = $ARGV[0];



if ($domains{$domain_name})
{

  if ($ARGV[1] eq "started")
  {

    &log("Domain ".$domain_name." started, adding portforwarding");

    &rules_update($domain_name," -I ");

  }
  elsif($ARGV[1] eq "stopped")
  {

    &log("Domain ".$domain_name." stopped, deleting portforwarding");

    &rules_update($domain_name," -D ");

  }
  elsif($ARGV[1] eq "reconnect")
  {

    &log("Domain ".$domain_name." stopped, deleting portforwarding");

    &rules_update($domain_name," -D ");

    &log("Domain ".$domain_name." started, adding portforwarding");

    &rules_update($domain_name," -I ");

  }
}

&log($ARGV[0]." ".$ARGV[1]);

exit();



sub rules_update
{

  my ($domain_name,$ipt_action) = @_;

  foreach my $forwardsourceport (keys %{$domains{$domain_name}{'forwards'}})
  {

    foreach my $externalif (@external_ifs)
    {
      # PREROUTING TCP
      my $preroutingcmd = $iptables." -t nat ".$ipt_action." PREROUTING -d ".$external_ip." -i ".$externalif." -p tcp -m tcp --dport ".$forwardsourceport." -j DNAT --to-destination ".$domains{$domain_name}{'ip'}.":".$domains{$domain_name}{'forwards'}{$forwardsourceport};

      system($preroutingcmd);

      # PREROUTING UDP
      my $preroutingcmd = $iptables." -t nat ".$ipt_action." PREROUTING -d ".$external_ip." -i ".$externalif." -p udp -m udp --dport ".$forwardsourceport." -j DNAT --to-destination ".$domains{$domain_name}{'ip'}.":".$domains{$domain_name}{'forwards'}{$forwardsourceport};

      system($preroutingcmd);

    }

    # FORWARD TCP
    my $forwardcmd = $iptables.$ipt_action." FORWARD -d ".$domains{$domain_name}{'ip'}." -p tcp -m state --state NEW -m tcp --dport ".$domains{$domain_name}{'forwards'}{$forwardsourceport}." -j ACCEPT";

    system($forwardcmd);

    # FORWARD UDP
    my $forwardcmd = $iptables.$ipt_action." FORWARD -d ".$domains{$domain_name}{'ip'}." -p udp -m state --state NEW -m udp --dport ".$domains{$domain_name}{'forwards'}{$forwardsourceport}." -j ACCEPT";

    system($forwardcmd);


  }



}


sub log
{
  my $message = shift;
  open(LOG,">>$logfile") or print "WARN: can not open logfile: $!\n";
  print LOG &timestamp().$message."\n";
  close(LOG);
  print &timestamp().$message."\n" if ($debug eq "on");
}

sub timestamp
{
  my @localtime = localtime;
  return(sprintf("\[%02d.%02d.%04d %02d:%02d:%02d\] ",
                                      $localtime[3],
                                      $localtime[4]+1,
                                      $localtime[5]+1900,
                                      $localtime[2],
                                      $localtime[1],
                                      $localtime[0]));
}


