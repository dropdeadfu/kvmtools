#!/usr/bin/perl
#
# Created by Crhistoph 'drodpead' Heuwieser
#

use strict;
use Sys::Virt;
use XML::Simple qw(:strict);
use File::Basename;


my $debug = "on"; # verbose logging
my $logfile = "/var/log/cv_backup.log"; # logfile
my $retention = "1"; # retentions kept - 1 means current + 1 are being kept 
my $backupdir = "/vmroot/temp/"; # mount to local temporary storage for current backup
my $remotedir = "/vmroot/backup/"; # mount to remote target
my $remotesync = "on"; # sync with remotedir
my $compression_cmd = "gzip -1 -c"; # syntax for compression pipe
my $compression_afix = "gz"; # the afix that gets appended to the filenames
my $disk_format = "lvm"; # lvm / file

my %vms =
(
  virtualhost01 => '1',
  virtualhost02 => '1',
);


### general initialization

my $starttime = time();

open(LOG,">>$logfile") or print "WARN: can not open logfile: $!\n";

### libvirt initialization

my $vmm = Sys::Virt->new();

my @domains = $vmm->list_domains();

&log("Starting Backup");

foreach my $dom (@domains) {
  my $vmname = $dom->get_name;
  &log($vmname.": Checking");

  if ($vms{$vmname})
  {
    if (!-e $backupdir."/config")
    {
      mkdir($backupdir."/config");
    }

    my $vmconfig = $dom->get_xml_description();
    open (CFG,">$backupdir/config/$vmname.xml");
    print CFG $vmconfig;
    close (CFG);

    my $xml_config_source = XMLin($dom->get_xml_description(), ForceArray=>['disk'], KeyAttr=>'');

    foreach my $storage_device (@{$xml_config_source->{'devices'}->{'disk'}})
    {
        if ($storage_device->{'device'} eq 'disk')
        {
          my $sourcetype;
          if (grep {/file/} keys %{$storage_device->{'source'}})
          {
            $sourcetype = "file";
          }
          elsif (grep {/dev/} keys %{$storage_device->{'source'}})
          {
            $sourcetype = "dev";
          }
          else
          {
            next;
          }
          if ($disk_format eq "file")
          {
              if ($dom->is_active())
              {
                 ### suspsend vm
                 &log($vmname.": Suspending");
                 $dom->suspend();

                 ### export savestate
                 &log($vmname.": Exporting Savestate");
                 $dom->save($backupdir.$vmname.".savestate");
                 &log($vmname.": copying diskimage ".$storage_device->{'source'}->{$sourcetype});
                 &rotate_basename(basename($storage_device->{'source'}->{$sourcetype}));
                 system("dd if=".$storage_device->{'source'}->{$sourcetype}." bs=64k | ".$compression_cmd." > ".$backupdir."/".basename($storage_device->{$sourcetype}->{'file'}).".img.".$compression_afix);
                 &log($vmname.": Resuming");
                 $vmm->restore_domain($backupdir.$vmname.".savestate");
                 $dom->resume();

              }
              else
              {
                 &log($vmname.": copying diskimage ".$storage_device->{'source'}->{$sourcetype});
                 &rotate_basename(basename($storage_device->{'source'}->{$sourcetype}));
                 system("dd if=".$storage_device->{'source'}->{$sourcetype}." bs=64k | ".$compression_cmd." > ".$backupdir."/".basename($storage_device->{'source'}->{$sourcetype}).".img.".$compression_afix);
              }

              if ($remotesync eq "on")
              {
                 &log($vmname.": Syncronizing to remote location ".$remotedir);
                 &sync_to_remote($vmname);
              }
          }
          elsif ($disk_format eq "lvm")
          {
              if ($dom->is_active())
              {
                 ### suspsend vm
                 &log($vmname.": Suspending");
                 $dom->suspend();

                 ### export savestate
                 &log($vmname.": Exporting Savestate");
                 $dom->save($backupdir.$vmname.".savestate");

                 &log($vmname.": Creating LVM-Snapshot ".$storage_device->{'source'}->{$sourcetype}."_snapshot");
                 system("lvcreate -L10G -s -n ".basename($storage_device->{'source'}->{$sourcetype})."_snapshot ".$storage_device->{'source'}->{$sourcetype});

                 &log($vmname.": Resuming");
                 $vmm->restore_domain($backupdir.$vmname.".savestate");
                 $dom->resume();

                 &log($vmname.": Exporting LVM-Snapshot ".$storage_device->{'source'}->{$sourcetype});
                 &rotate_basename(basename($storage_device->{'source'}->{$sourcetype}));
                 system("dd if=/dev/xenstore/".basename($storage_device->{'source'}->{$sourcetype})."_snapshot bs=64k | ".$compression_cmd." > ".$backupdir."/".basename($storage_device->{'source'}->{$sourcetype}).".img.".$compression_afix);

                 system("lvremove -f /dev/xenstore/".basename($storage_device->{'source'}->{$sourcetype})."_snapshot");
              }
              else
              {
                 &log($vmname.": Exporting LVM-Snapshot ".$storage_device->{'source'}->{$sourcetype});
                 &rotate_basename(basename($storage_device->{'source'}->{$sourcetype}));
                 system("dd if=".$storage_device->{'source'}->{$sourcetype}." bs=64k | ".$compression_cmd." > ".$backupdir."/".basename($storage_device->{'source'}->{$sourcetype}).".img.".$compression_afix);
              }

              if ($remotesync eq "on")
              {
                 &log($vmname.": Syncronizing to remote location ".$remotedir);
                 &sync_to_remote($vmname);
              }

          }
          else
          {
              next;
          }

        }
    }
    &log($vmname.": Snapshot-Backup finished.");
  }
}


### finish

my $endtime = time();

&log("Finished in ".sprintf("%02d:%02d:%02d",(($endtime - $starttime)/3600),((($endtime - $starttime)/60) % 60),(($endtime - $starttime) % 60)));

close(LOG);

exit 0;

###############

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

sub log
{
  my $message = shift;
  print LOG &timestamp().$message."\n";
  print &timestamp().$message."\n" if ($debug eq "on");
}


sub rotatebackup
{
  my $basename = shift;
  for (my $i = $retention; $i > 0; $i--)
  {
    if ($i > 1)
    {
      rename $backupdir.$basename.".img.".$compression_afix.".".($i - 1), $backupdir.$basename.".img.".$compression_afix.".".$i;
      rename $backupdir.$basename.".savestate.".($i - 1), $backupdir.$basename.".savestate.".$i;
    }
    else
    {
      rename $backupdir.$basename.".img.".$compression_afix, $backupdir.$basename.".img.".$compression_afix.".".$i;
      rename $backupdir.$basename.".savestate", $backupdir.$basename.".savestate.".$i;
    }
  }
}

sub rotate_basename
{
  my $basename = shift;
  for (my $i = $retention; $i > 0; $i--)
  {
    if ($i > 1)
    {
      rename $backupdir.$basename.".img.".$compression_afix.".".($i - 1), $backupdir.$basename.".img.".$compression_afix.".".$i;
    }
    else
    {
      rename $backupdir.$basename.".img.".$compression_afix, $backupdir.$basename.".img.".$compression_afix.".".$i;
    }
  }
}

sub rotate_savestate
{
  my $basename = shift;
  for (my $i = $retention; $i > 0; $i--)
  {
    if ($i > 1)
    {
      rename $backupdir.$basename.".savestate.".($i - 1), $backupdir.$basename.".savestate.".$i;
    }
    else
    {
      rename $backupdir.$basename.".savestate", $backupdir.$basename.".savestate.".$i;
    }
  }
}


sub sync_to_remote
{
  my $basename = shift;
  for (my $i = $retention; $i > 0; $i--)
  {
    if ($i > 1)
    {
      rename $remotedir.$basename.".img.".$compression_afix.".".($i - 1), $remotedir.$basename.".img.".$compression_afix.".".$i;
      #system("cp", $backupdir.$basename.".img.".$archive_affix.".".$i, $remotedir);
    }
    else
    {
      rename $remotedir.$basename.".img.".$compression_afix, $remotedir.$basename.".img.".$compression_afix.".".$i;
      #system("cp", $backupdir.$basename.".img.".$archive_affix, $remotedir);
    }
  }
  system("cp", $backupdir.$basename.".img.".$compression_afix, $remotedir);
}
