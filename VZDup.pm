package PVE::VZDup;

#    vzdup
#
#    Copyright (C) 2011 yoonique[.net]
#
#    Copyright: vzdup is under GNU GPL, the GNU General Public License.
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; version 2 dated June, 1991.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the
#    Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
#    MA 02110-1301, USA.
#
#    Based on proxmox's vzdump:
#      Copyright (C) 2007-2009 Proxmox Server Solutions GmbH
#      Author: Dietmar Maurer <dietmar@proxmox.com>

use strict;
use warnings;
use Data::Dumper;
use Fcntl ':flock';
use Sys::Hostname;
use Sys::Syslog;
use IO::File;
use IO::Select;
use IPC::Open3;
use POSIX qw(strftime);
use File::Path;
use PVE::VZDump::OpenVZ;
use Time::localtime;
use Time::Local;

my @posix_filesystems = qw(ext3 ext4 nfs nfs4 reiserfs xfs);

my $lockfile = '/var/run/vzdup.lock';

my $logdir = '/var/log/vzdup';

my @plugins = qw (PVE::VZDump::OpenVZ);


# helper functions

my $debugstattxt = {
    err =>  'ERROR:',
    info => 'INFO:',
    warn => 'WARN:',
};

sub debugmsg {
    my ($mtype, $msg, $logfd, $syslog) = @_;

    chomp $msg;

    return if !$msg;

    my $pre = $debugstattxt->{$mtype} || $debugstattxt->{'err'};

    my $timestr = strftime ("%b %d %H:%M:%S", CORE::localtime);

    syslog ($mtype eq 'info' ? 'info' : 'err', "$pre $msg") if $syslog;

    foreach my $line (split (/\n/, $msg)) {
	print STDERR "$pre $line\n";
	print $logfd "$timestr $pre $line\n" if $logfd;
    }
}

sub run_command {
    my ($logfd, $cmdstr, %param) = @_;

    my $timeout;
    my $input;
    my $output;

    foreach my $p (keys %param) {
	if ($p eq 'timeout') {
	    $timeout = $param{$p};
	} elsif ($p eq 'input') {
	    $input = $param{$p};
	} elsif ($p eq 'output') {
	    $output = $param{$p};
	} else {
	    die "got unknown parameter '$p' for run_command\n";
	}
    }

    my $reader = $output && $output =~ m/^>&/ ? $output : IO::File->new();
    my $writer = $input && $input =~ m/^<&/ ? $input : IO::File->new();
    my $error  = IO::File->new();

    my $orig_pid = $$;

    my $pid;
    eval {
	# suppress LVM warnings like: "File descriptor 3 left open";
	local $ENV{LVM_SUPPRESS_FD_WARNINGS} = "1";

	$pid = open3 ($writer, $reader, $error, ($cmdstr)) || die $!;
    };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	debugmsg ('err', "command '$cmdstr' failed - fork failed: $!", $logfd);
	POSIX::_exit (1); 
	kill ('KILL', $$); 
    }

    die $err if $err;

    if (ref($writer)) {
	print $writer $input if defined $input;
	close $writer;
    }

    my $select = new IO::Select;
    $select->add ($reader) if ref($reader);
    $select->add ($error);

    my ($ostream, $estream, $logout, $logerr) = ('', '', '', '');

    while ($select->count) {
	my @handles = $select->can_read ($timeout);

	if (defined ($timeout) && (scalar (@handles) == 0)) {
	    die "command '$cmdstr' failed: timeout\n";
	}

	foreach my $h (@handles) {
	    my $buf = '';
	    my $count = sysread ($h, $buf, 4096);
	    if (!defined ($count)) {
		waitpid ($pid, 0);
		die "command '$cmdstr' failed: $!\n";
	    }
	    $select->remove ($h) if !$count;

	    if ($h eq $reader) {
		$ostream .= $buf;
		$logout .= $buf;
		while ($logout =~ s/^([^\n]*\n)//s) {
		    my $line = $1;
		    debugmsg ('info', $line, $logfd);
		}
	    } elsif ($h eq $error) {
		$estream .= $buf;
		$logerr .= $buf;
		while ($logerr =~  s/^([^\n]*\n)//s) {
		    my $line = $1;
		    debugmsg ('info', $line, $logfd);
		}
	    }
	}
    }

    debugmsg ('info', $logout, $logfd);
    debugmsg ('info', $logerr, $logfd);

    waitpid ($pid, 0);
    my $ec = ($? >> 8);

    return $ostream if $ec == 24 && ($cmdstr =~ m|^(\S+/)?rsync\s|);

    die "command '$cmdstr' failed with exit code $ec\n" if $ec;

    return $ostream;
}

sub storage_info {
    my $storage = shift;

    eval { require PVE::Storage; };
    die "unable to query storage info for '$storage' - $@\n" if $@;
    my $cfg = PVE::Storage::load_config();
    my $scfg = PVE::Storage::storage_config ($cfg, $storage);
    my $type = $scfg->{type};
 
    die "can't use storage type '$type' for backup\n" 
	if (!($type eq 'dir' || $type eq 'nfs'));
    die "can't use storage for backups - wrong content type\n" 
	if (!$scfg->{content}->{backup});

    PVE::Storage::activate_storage ($cfg, $storage);

    return {
	dumpdir => $scfg->{path},
    };
}

sub format_size {
    my $size = shift;

    my $kb = $size / 1024;

    if ($kb < 1024) {
	return int ($kb) . "KB";
    }

    my $mb = $size / (1024*1024);

    if ($mb < 1024) {
	return int ($mb) . "MB";
    } else {
	my $gb = $mb / 1024;
	return sprintf ("%.2fGB", $gb);
    } 
}

sub format_time {
    my $seconds = shift;

    my $hours = int ($seconds/3600);
    $seconds = $seconds - $hours*3600;
    my $min = int ($seconds/60);
    $seconds = $seconds - $min*60;

    return sprintf ("%02d:%02d:%02d", $hours, $min, $seconds);
}

sub encode8bit {
    my ($str) = @_;

    $str =~ s/^(.{990})/$1\n/mg; # reduce line length

    return $str;
}

sub escape_html {
    my ($str) = @_;

    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;

    return $str;
}

sub check_bin {
    my ($bin)  = @_;

    foreach my $p (split (/:/, $ENV{PATH})) {
	my $fn = "$p/$bin";
	if (-x $fn) {
	    return $fn;
	}
    }

    die "unable to find command '$bin'\n";
}

sub check_vmids {
    my (@vmids) = @_;

    my $res = [];
    foreach my $vmid (@vmids) {
	die "ERROR: strange VM ID '${vmid}'\n" if $vmid !~ m/^\d+$/;
	$vmid = int ($vmid); # remove leading zeros
	die "ERROR: got reserved VM ID '${vmid}'\n" if $vmid < 100;
	push @$res, $vmid;
    }

    return $res;
}


sub read_vzdup_defaults {

    my $fn = "/etc/vzdup.conf";

    my $res = {
#	bwlimit => 0,
	ionice => 7,
	size => 1024,
#	lockwait => 3*60, # 3 hours
	stopwait => 10, # 10 minutes
	mode => 'snapshot',
	volsize => 25,
	verbosity => 4,
	fullifolderthan => '1W',
	tmpdir => '/tmp',
#	maxfiles => 1, 
    };

    my $fh = IO::File->new ("<$fn");
    return $res if !$fh;
    
    my $line;
    while (defined ($line = <$fh>)) {
	next if $line =~ m/^\s*$/;
	next if $line =~ m/^\#/;

	if ($line =~ m/tmpdir:\s*(.*\S)\s*$/) {
	    $res->{tmpdir} = $1;
#	} elsif ($line =~ m/dumpdir:\s*(.*\S)\s*$/) {
#	    $res->{dumpdir} = $1;
	} elsif ($line =~ m/fullifolderthan:\s*(.*\S)\s*$/) {
	    $res->{fullifolderthan} = $1;
	} elsif ($line =~ m/volsize:\s*(\d+)\s*$/) {
	    $res->{volsize} = int($1);
	} elsif ($line =~ m/verbosity:\s*(\d+)\s*$/) {
	    $res->{verbosity} = int($1);
	} elsif ($line =~ m/destination:\s*(.*\S)\s*$/) {
	    $res->{destination} = $1;
	} elsif ($line =~ m/key:\s*(.*\S)\s*$/) {
	    $res->{key} = $1;
#	} elsif ($line =~ m/storage:\s*(\S+)\s*$/) {
#	    $res->{storage} = $1;
#	} elsif ($line =~ m/script:\s*(.*\S)\s*$/) {
#	    $res->{script} = $1;
#	} elsif ($line =~ m/bwlimit:\s*(\d+)\s*$/) {
#	    $res->{bwlimit} = int($1);
	} elsif ($line =~ m/ionice:\s*([0-8])\s*$/) {
	    $res->{ionice} = int($1);
#	} elsif ($line =~ m/lockwait:\s*(\d+)\s*$/) {
#	    $res->{lockwait} = int($1);
	} elsif ($line =~ m/stopwait:\s*(\d+)\s*$/) {
	    $res->{stopwait} = int($1);
	} elsif ($line =~ m/size:\s*(\d+)\s*$/) {
	    $res->{size} = int($1);
#	} elsif ($line =~ m/maxfiles:\s*(\d+)\s*$/) {
#	    $res->{maxfiles} = int($1);
#	} elsif ($line =~ m/mode:\s*(snapshot)\s*$/) {
#	    $res->{mode} = $1;
	} else {
	    debugmsg ('warn', "unable to parse configuration file '$fn' - error at line " . $., undef, 1);
	}

    }
    close ($fh);

    return $res;
}


sub find_add_exclude {
    my ($self, $excltype, $value) = @_;

    if (($excltype eq '-regex') || ($excltype eq '-files')) {
	$value = "\.$value";
    }

    if ($excltype eq '-files') {
	push @{$self->{findexcl}}, "'('", '-not', '-type', 'd', '-regex' , "'$value'", "')'", '-o';
    } else {
	push @{$self->{findexcl}}, "'('", $excltype , "'$value'", '-prune', "')'", '-o';
    }
}

sub read_firstfile {
    my $archive = shift;
    
    die "ERROR: file '$archive' does not exist\n" if ! -f $archive;

    # try to detect archive type first
    my $pid = open (TMP, "tar tf '$archive'|") ||
	die "unable to open file '$archive'\n";
    my $firstfile = <TMP>;
    kill 15, $pid;
    close TMP;

    die "ERROR: archive contaions no data\n" if !$firstfile;
    chomp $firstfile;

    return $firstfile;
}

my $sendmail = sub {
    my ($self, $tasklist, $totaltime) = @_;

    my $opts = $self->{opts};

    my $mailto = $opts->{mailto};

    return if !$mailto;

    my $cmdline = $self->{cmdline};

    my $ecount = 0;
    foreach my $task (@$tasklist) {
	$ecount++ if $task->{state} ne 'ok';
	chomp $task->{msg} if $task->{msg};
	$task->{backuptime} = 0 if !$task->{backuptime};
	$task->{size} = 0 if !$task->{size};
	$task->{tarfile} = 'unknown' if !$task->{tarfile};
	$task->{hostname} = "VM $task->{vmid}" if !$task->{hostname};

	if ($task->{state} eq 'todo') {
	    $task->{msg} = 'aborted';
	}
    }

    my $stat = $ecount ? 'backup failed' : 'backup successful';

    my $hostname = `hostname -f` || hostname();
    chomp $hostname;


    my $boundary = "----_=_NextPart_001_".int(time).$$;

    my $rcvrarg = '';
    foreach my $r (@$mailto) {
	$rcvrarg .= " '$r'";
    }

    open (MAIL,"|sendmail -B 8BITMIME $rcvrarg") || 
	die "unable to open 'sendmail' - $!";

    my $rcvrtxt = join (', ', @$mailto);

    print MAIL "Content-Type: multipart/alternative;\n";
    print MAIL "\tboundary=\"$boundary\"\n";
    print MAIL "FROM: vzdup backup tool <root>\n";
    print MAIL "TO: $rcvrtxt\n";
    print MAIL "SUBJECT: vzdup backup status ($hostname) : $stat\n";
    print MAIL "\n";
    print MAIL "This is a multi-part message in MIME format.\n\n";
    print MAIL "--$boundary\n";

    print MAIL "Content-Type: text/plain;\n";
    print MAIL "\tcharset=\"UTF8\"\n";
    print MAIL "Content-Transfer-Encoding: 8bit\n";
    print MAIL "\n";

    # text part

    my $fill = '  '; # Avoid The Remove Extra Line Breaks Issue (MS Outlook)

    print MAIL sprintf ("${fill}%-10s %-6s %10s %10s  %s\n", qw(VMID STATUS TIME SIZE FILENAME));
    foreach my $task (@$tasklist) {
	my $vmid = $task->{vmid};
	if  ($task->{state} eq 'ok') {

	    print MAIL sprintf ("${fill}%-10s %-6s %10s %10s  %s\n", $vmid, 
				$task->{state}, 
				format_time($task->{backuptime}),
				format_size ($task->{size}),
				$task->{tarfile});
	} else {
	    print MAIL sprintf ("${fill}%-10s %-6s %10s %8.2fMB  %s\n", $vmid, 
				$task->{state}, 
				format_time($task->{backuptime}),
				0, '-');
	}
    }
    print MAIL "${fill}\n";
    print MAIL "${fill}Detailed backup logs:\n";
    print MAIL "${fill}\n";
    print MAIL "$fill$cmdline\n";
    print MAIL "${fill}\n";

    foreach my $task (@$tasklist) {
	my $vmid = $task->{vmid};
	my $log = $task->{tmplog};
	if (!$log) {
	    print MAIL "${fill}$vmid: no log available\n\n";
	    next;
	}
	open (TMP, "$log");
	while (my $line = <TMP>) { print MAIL encode8bit ("${fill}$vmid: $line"); }
	close (TMP);
	print MAIL "${fill}\n";
    }

    # end text part
    print MAIL "\n--$boundary\n";

    print MAIL "Content-Type: text/html;\n";
    print MAIL "\tcharset=\"UTF8\"\n";
    print MAIL "Content-Transfer-Encoding: 8bit\n";
    print MAIL "\n";

    # html part

    print MAIL "<html><body>\n";

    print MAIL "<table border=1 cellpadding=3>\n";

    print MAIL "<tr><td>VMID<td>NAME<td>STATUS<td>TIME<td>SIZE<td>FILENAME</tr>\n";

    my $ssize = 0;

    foreach my $task (@$tasklist) {
	my $vmid = $task->{vmid};
	my $name = $task->{hostname};

	if  ($task->{state} eq 'ok') {

	    $ssize += $task->{size};

	    print MAIL sprintf ("<tr><td>%s<td>%s<td>OK<td>%s<td align=right>%s<td>%s</tr>\n", 
				$vmid, $name,
				format_time($task->{backuptime}),
				format_size ($task->{size}),
				escape_html ($task->{tarfile}));
	} else {
	    print MAIL sprintf ("<tr><td>%s<td>%s<td><font color=red>FAILED<td>%s<td colspan=2>%s</tr>\n",
 
				$vmid, $name, format_time($task->{backuptime}), 
				escape_html ($task->{msg}));
	}
    }

    print MAIL sprintf ("<tr><td align=left colspan=3>TOTAL<td>%s<td>%s<td></tr>",
 format_time ($totaltime), format_size ($ssize));

    print MAIL "</table><br><br>\n";
    print MAIL "Detailed backup logs:<br>\n";
    print MAIL "<br>\n";
    print MAIL "<pre>\n";
    print MAIL escape_html($cmdline) . "\n";
    print MAIL "\n";

    foreach my $task (@$tasklist) {
	my $vmid = $task->{vmid};
	my $log = $task->{tmplog};
	if (!$log) {
	    print MAIL "$vmid: no log available\n\n";
	    next;
	}
	open (TMP, "$log");
	while (my $line = <TMP>) {
	    if ($line =~ m/^\S+\s\d+\s+\d+:\d+:\d+\s+(ERROR|WARN):/) {
		print MAIL encode8bit ("$vmid: <font color=red>". 
				       escape_html ($line) . "</font>"); 
	    } else {
		print MAIL encode8bit ("$vmid: " . escape_html ($line)); 
	    }
	}
	close (TMP);
	print MAIL "\n";
    }
    print MAIL "</pre>\n";

    print MAIL "</body></html>\n";

    # end html part
    print MAIL "\n--$boundary--\n";

};

sub new {
    my ($class, $cmdline, $opts) = @_;

    mkpath $logdir;

    check_bin ('cp');
    check_bin ('df');
    check_bin ('sendmail');
    check_bin ('rsync');
    check_bin ('tar');
    check_bin ('mount');
    check_bin ('umount');
    check_bin ('cstream');
    check_bin ('ionice');

    if ($opts->{snapshot}) {
	check_bin ('lvcreate');
	check_bin ('lvs');
	check_bin ('lvremove');
    }

    my $defaults = read_vzdup_defaults();

    foreach my $k (keys %$defaults) {
	if ($k eq 'dumpdir' || $k eq 'storage') {
	    $opts->{$k} = $defaults->{$k} if !defined ($opts->{dumpdir}) &&
		!defined ($opts->{storage});
	} else {
	    $opts->{$k} = $defaults->{$k} if !defined ($opts->{$k});
	}
    }

    $opts->{mode} = 'snapshot' if $opts->{snapshot};

#    $opts->{dumpdir} =~ s|/+$|| if ($opts->{dumpdir});
    $opts->{tmpdir} =~ s|/+$|| if ($opts->{tmpdir});

    my $self = bless { cmdline => $cmdline, opts => $opts };

    #always skip '.'
    push @{$self->{findexcl}}, "'('", '-regex' , "'^\\.\$'", "')'", '-o';

    $self->find_add_exclude ('-type', 's'); # skip sockets

    if ($opts->{'exclude-path'}) {
	foreach my $path (@{$opts->{'exclude-path'}}) {
	    $self->find_add_exclude ('-regex', $path);
	}
    }

    if ($opts->{stdexcludes}) {
	$self->find_add_exclude ('-files', '/var/log/.+');
	$self->find_add_exclude ('-regex', '/tmp/.+');
	$self->find_add_exclude ('-regex', '/var/tmp/.+');
	$self->find_add_exclude ('-regex', '/var/run/.+pid');
    }

    foreach my $p (@plugins) {

	my $pd = $p->new ($self);

	push @{$self->{plugins}}, $pd;

	if (!$opts->{dumpdir} && !$opts->{storage} && 
	    ($p eq 'PVE::VZDup::OpenVZ')) {
	    $opts->{dumpdir} = $pd->{dumpdir};
	}
    }

    if (!$opts->{dumpdir} && !$opts->{storage} && !$opts->{destination}) {
	die "no dumpdir/storage specified - use option '--dumpdir' or option '--storage'\n";
    }

    if (!$opts->{destination}) {
    if ($opts->{storage}) {
	my $info = storage_info ($opts->{storage});
	$opts->{dumpdir} = $info->{dumpdir};
    } elsif ($opts->{dumpdir}) {
	die "dumpdir '$opts->{dumpdir}' does not exist\n"
	    if ! -d $opts->{dumpdir};
    } else {
	die "internal error"; 
    }
    }

    if ($opts->{tmpdir} && ! -d $opts->{tmpdir}) {
	die "tmpdir '$opts->{tmpdir}' does not exist\n";
    }

    return $self;

}

sub get_lvm_mapping {

    my $devmapper;

    my $cmd = "lvs --units m --separator ':' --noheadings -o vg_name,lv_name,lv_size";
    if (my $fd = IO::File->new ("$cmd 2>/dev/null|")) {
	while (my $line = <$fd>) {
	    if ($line =~ m|^\s*(\S+):(\S+):(\d+(\.\d+))[Mm]$|) {
		my $vg = $1;
		my $lv = $2;
		$devmapper->{"/dev/$vg/$lv"} = [$vg, $lv];
		my $qlv = $lv;
		$qlv =~ s/-/--/g;
		my $qvg = $vg;
		$qvg =~ s/-/--/g;
		$devmapper->{"/dev/mapper/$qvg-$qlv"} = [$vg, $lv];
	    }
	}
	close ($fd);
    }

    return $devmapper;
}

sub get_mount_info {
    my ($dir) = @_;

    my $out;
    if (my $fd = IO::File->new ("df -P -T '$dir' 2>/dev/null|")) {
	<$fd>; #skip first line
	$out = <$fd>;
	close ($fd);
    }

    return undef if !$out;
   
    my @res = split (/\s+/, $out);

    return undef if scalar (@res) != 7;

    return {
	device => $res[0],
	fstype => $res[1],
	mountpoint => $res[6]
    };
}

sub get_lvm_device {
    my ($dir, $mapping) = @_;
print "get_lvm_device";
print Dumper($dir);
print Dumper($mapping);

    my $info = get_mount_info ($dir);

    return undef if !$info;
   
    my $dev = $info->{device};

    my ($vg, $lv);

    ($vg, $lv) = @{$mapping->{$dev}} if defined $mapping->{$dev};

    return wantarray ? ($dev, $info->{mountpoint}, $vg, $lv, $info->{fstype}) : $dev;
}

sub getlock {
    my ($self) = @_;

    my $maxwait = $self->{opts}->{lockwait} || $self->{lockwait};
 
    if (!open (SERVER_FLCK, ">>$lockfile")) {
	debugmsg ('err', "can't open lock on file '$lockfile' - $!", undef, 1);
	exit (-1);
    }

    if (flock (SERVER_FLCK, LOCK_EX|LOCK_NB)) {
	return;
    }

    if (!$maxwait) {
	debugmsg ('err', "can't aquire lock '$lockfile' (wait = 0)", undef, 1);
	exit (-1);
    }

    debugmsg('info', "trying to get global lock - waiting...", undef, 1);

    eval {
	alarm ($maxwait * 60);
	
	local $SIG{ALRM} = sub { alarm (0); die "got timeout\n"; };

	if (!flock (SERVER_FLCK, LOCK_EX)) {
	    my $err = $!;
	    close (SERVER_FLCK);
	    alarm (0);
	    die "$err\n";
	}
	alarm (0);
    };
    alarm (0);
    
    my $err = $@;

    if ($err) {
	debugmsg ('err', "can't aquire lock '$lockfile' - $err", undef, 1);
	exit (-1);
    }

    debugmsg('info', "got global lock", undef, 1);
}

sub run_hook_script {
    my ($self, $phase, $task, $logfd) = @_;

    my $opts = $self->{opts};

    my $script = $opts->{script};

    return if !$script;

    my $cmd = "$script $phase";

    $cmd .= " $task->{mode} $task->{vmid}" if ($task);

    local %ENV;

    foreach my $ek (qw(vmtype dumpdir hostname tarfile logfile)) {
	$ENV{uc($ek)} = $task->{$ek} if $task->{$ek};
    }

    run_command ($logfd, $cmd);
}

sub exec_backup_task {
    my ($self, $task) = @_;
	 
    my $opts = $self->{opts};

    my $vmid = $task->{vmid};
    my $plugin = $task->{plugin};

    my $vmstarttime = time ();
    
    my $logfd;

    my $cleanup = {};

    my $vmstoptime = 0;

    eval {
	die "unable to find VM '$vmid'\n" if !$plugin;

	my $vmtype = $plugin->type();

	my $tmplog = "$logdir/$vmtype-$vmid.log";

	my $lt = localtime();

	my $bkname = "vzdup-$vmtype-$vmid";
	my $basename = sprintf "${bkname}-%04d_%02d_%02d-%02d_%02d_%02d", 
	$lt->year + 1900, $lt->mon + 1, $lt->mday, 
	$lt->hour, $lt->min, $lt->sec;

#	my $logfile = $task->{logfile} = "$opts->{dumpdir}/$basename.log";
#	my $logfile = $task->{logfile} = "$opts->{tmpdir}/$basename.log";

	my $ext = $opts->{compress} ? '.tgz' : '.tar';

#	if ($opts->{stdout}) {
#	    $task->{tarfile} = '-';
#	} else {
#	    my $tarfile = $task->{tarfile} = "$opts->{dumpdir}/$basename$ext";
#	    $task->{tmptar} = $task->{tarfile};
#	    $task->{tmptar} =~ s/\.[^\.]+$/\.dat/;
#	    unlink $task->{tmptar};
#	}

	$task->{vmtype} = $vmtype;

#	if ($opts->{tmpdir}) {
#	    $task->{tmpdir} = "$opts->{tmpdir}/vzduptmp$$"; 
#	} else {
#	    # dumpdir is posix? then use it as temporary dir
#	    my $info = get_mount_info ($opts->{dumpdir});
		$task->{tmpdir} = "/var/tmp/vzduptmp$$";
		my $logfile = $task->{logfile} = "$task->{tmpdir}/$basename.log";
#		debugmsg ('info', "filesystem type on dumpdir is '$info->{fstype}' -" .
		debugmsg ('info', "using $task->{tmpdir} for temporary files", $logfd);
#	}

	rmtree $task->{tmpdir};
	mkdir $task->{tmpdir};
	-d $task->{tmpdir} ||
	    die "unable to create temporary directory '$task->{tmpdir}'";

	$logfd = IO::File->new (">$tmplog") ||
	    die "unable to create log file '$tmplog'";

#	$task->{dumpdir} = $opts->{dumpdir};
	$task->{dumpdir} = $task->{tmpdir};

	$task->{tmplog} = $tmplog;

	unlink $logfile;

	debugmsg ('info',  "Starting Backup of VM $vmid ($vmtype)", $logfd, 1);

	$plugin->set_logfd ($logfd);

	# test is VM is running
	my ($running, $status_text) = $plugin->vm_status ($vmid);

	debugmsg ('info', "status = ${status_text}", $logfd);

	# prepare

#	my $mode = $running ? $opts->{mode} : 'snapshot';
	my $mode = 'snapshot';

	if ($mode eq 'snapshot') {
	    my %saved_task = %$task;
	    eval { $plugin->prepare ($task, $vmid, $mode); };
	}

	$task->{mode} = $mode;

   	debugmsg ('info', "backup mode: $mode", $logfd);

	debugmsg ('info', "bandwidth limit: $opts->{bwlimit} KB/s", $logfd)
	    if $opts->{bwlimit};

	debugmsg ('info', "ionice priority: $opts->{ionice}", $logfd);

	if ($mode eq 'snapshot') {

	    my $snapshot_count = $task->{snapshot_count} || 0;

	    $self->run_hook_script ('pre-stop', $task, $logfd);

	    if ($opts->{stop} && $running) {
	    	debugmsg ('info', "stop vm to make snapshot", $logfd);
	    	$vmstoptime = time ();
	    	$plugin->stop_vm ($task, $vmid);
	    	$cleanup->{restart} = 1;
	    }

	    $plugin->snapshot ($task, $vmid);

	    $self->run_hook_script ('pre-restart', $task, $logfd);

	    my ($running, $status_text) = $plugin->vm_status ($vmid);
	    if ($opts->{start} && !$running) {
		debugmsg ('info', "start vm", $logfd);
		$cleanup->{restart} = 0;
		$plugin->start_vm ($task, $vmid);
		my $delay = time () - $vmstoptime;
		debugmsg ('info', "vm is online again after $delay seconds", $logfd);
	    }

	} else {
	    die "internal error - unknown mode '$mode'\n";
	}

	# assemble archive image
	$plugin->assemble ($task, $vmid);
	
	# produce archive 

#	if ($opts->{stdout}) {
#	    debugmsg ('info', "sending archive to stdout", $logfd);
#	    $plugin->archive ($task, $vmid, $task->{tmptar});
#	    $self->run_hook_script ('backup-end', $task, $logfd);
#	    return;
#	}

#	debugmsg ('info', "creating archive '$task->{tarfile}'", $logfd);
	duplicity ($task, $vmid);

#	rename ($task->{tmptar}, $task->{tarfile}) ||
#	    die "unable to rename '$task->{tmptar}' to '$task->{tarfile}'\n";

	# determine size
#	$task->{size} = (-s $task->{tarfile}) || 0;
#	my $cs = format_size ($task->{size}); 
#	debugmsg ('info', "archive file size: $cs", $logfd);
#
#	# purge older backup
#
#	my $maxfiles = $opts->{maxfiles};
#
#	if ($maxfiles) {
#	    my @bklist = ();
#	    my $dir = $opts->{dumpdir};
#	    foreach my $fn (<$dir/${bkname}-*>) {
#		next if $fn eq $task->{tarfile};
#		if ($fn =~ m!/${bkname}-(\d{4})_(\d{2})_(\d{2})-(\d{2})_(\d{2})_(\d{2})\.(tgz|tar)$!) {
#		    my $t = timelocal ($6, $5, $4, $3, $2 - 1, $1 - 1900);
#		    push @bklist, [$fn, $t];
#		}
#	    }
#	
#	    @bklist = sort { $b->[1] <=> $a->[1] } @bklist;
#
#	    my $ind = scalar (@bklist);
#
#	    while (scalar (@bklist) >= $maxfiles) {
#		my $d = pop @bklist;
#		debugmsg ('info', "delete old backup '$d->[0]'", $logfd);
#		unlink $d->[0];
#		my $logfn = $d->[0];
#		$logfn =~ s/\.(tgz|tar)$/\.log/;
#		unlink $logfn;
#	    }
#	}
#
	$self->run_hook_script ('backup-end', $task, $logfd);
    };
    my $err = $@;

    if ($plugin) {
	# clean-up

	eval { $plugin->cleanup ($task, $vmid) };
	warn $@ if $@;

	eval { $plugin->set_logfd (undef); };
	warn $@ if $@;

    }

    eval { unlink $task->{tmptar} if $task->{tmptar} && -f $task->{tmptar}; };
    warn $@ if $@;

    eval { rmtree $task->{tmpdir} if $task->{tmpdir} && -d $task->{tmpdir}; };
    warn $@ if $@;

    my $delay = $task->{backuptime} = time () - $vmstarttime;

    if ($err) {
	$task->{state} = 'err';
	$task->{msg} = $err;
	debugmsg ('err', "Backup of VM $vmid failed - $err", $logfd, 1);

	eval { $self->run_hook_script ('backup-abort', $task, $logfd); };

    } else {
	$task->{state} = 'ok';
	my $tstr = format_time ($delay);
	debugmsg ('info', "Finished Backup of VM $vmid ($tstr)", $logfd, 1);
    }

    close ($logfd) if $logfd;
    
#    if ($task->{tmplog} && $task->{logfile}) {
#	system ("cp '$task->{tmplog}' '$task->{logfile}'");
#    }

    eval { $self->run_hook_script ('log-end', $task); };

    die $err if $err && $err =~ m/^interrupted by signal$/;
}

sub exec_backup {
    my ($self) = @_;

    my $opts = $self->{opts};

    debugmsg ('info', "starting new backup job: $self->{cmdline}", undef, 1);

    my $tasklist = [];

    if ($opts->{all}) {
	foreach my $plugin (@{$self->{plugins}}) {
	    my $vmlist = $plugin->vmlist();
	    foreach my $vmid (sort @$vmlist) {
		next if grep { $_ eq  $vmid } @{$opts->{exclude}};
	        push @$tasklist, { vmid => $vmid,  state => 'todo', plugin => $plugin };
	    }
	}
    } else {
	foreach my $vmid (sort @{$opts->{vmids}}) {
	    my $plugin;
	    foreach my $pg (@{$self->{plugins}}) {
		my $vmlist = $pg->vmlist();
		if (grep { $_ eq  $vmid } @$vmlist) {
		    $plugin = $pg;
		    last;
		}
	    }
	    push @$tasklist, { vmid => $vmid,  state => 'todo', plugin => $plugin };
	}
    }

    my $starttime = time();
    my $errcount = 0;
    eval {

	$self->run_hook_script ('job-start');

	foreach my $task (@$tasklist) {
	    $self->exec_backup_task ($task);
	    $errcount += 1 if $task->{state} ne 'ok';
	}

	$self->run_hook_script ('job-end');    
    };
    my $err = $@;

    $self->run_hook_script ('job-abort') if $err;    

    if ($err) {
	debugmsg ('err', "Backup job failed - $err", undef, 1);
    } else {
	if ($errcount) {
	    debugmsg ('info', "Backup job finished with errors", undef, 1);
	} else {
	    debugmsg ('info', "Backup job finished successfuly", undef, 1);
	}
    }

    my $totaltime = time() - $starttime;

    eval { $self->$sendmail ($tasklist, $totaltime); };
    debugmsg ('err', $@) if $@;
}

sub duplicity {
    my ($self, $vmid) = @_;
#print "self " . Dumper ($self);
#print "vmid " . Dumper ($vmid);
    
    my $findexcl = $self->{plugin}->{vzdump}->{findexcl};
    my $findargs = join (' ', @$findexcl) . ' -print0';
    my $opts = $self->{plugin}->{vzdump}->{opts};

    my $srcdir = $self->{plugin}->{vmlist}->{$vmid}->{dir};
    my $snapdir = $self->{snapdir};

    my $dupopts  = "";
if($opts->{verbosity}) {
    $dupopts .= "--verbosity $opts->{verbosity} ";
}
if($opts->{volsize}) {
    $dupopts .= "--volsize $opts->{volsize} ";
}
if($opts->{fullifolderthan}) {
    $dupopts .= "--full-if-older-than $opts->{fullifolderthan} ";
}
if($opts->{gpgkey}) {
	$dupopts .= "--encrypt-key $opts->{gpgkey} --sign-key $opts->{gpgkey} ";
}
else {
	$dupopts .= "--no-encryption "
}

    my $cmd = "(";
#    $cmd .= "duplicity cleanup $dupopts $opts->{destination};";
#    $cmd .= "duplicity $dupopts --encrypt-key $opts->{key} $snapdir $opts->{destination}";
    $cmd .= "duplicity --num-retries 20 --allow-source-mismatch --archive-dir=$opts->{tmpdir} $dupopts $snapdir $opts->{destination}/$vmid";

    $cmd .= ")";
    
    debugmsg('info', "executing $cmd", undef, 1);

#print Dumper ($cmd);

#    if ($opts->{stdout}) {
#	$self->{plugin}->cmd ($cmd, output => ">&=" . fileno($opts->{stdout}));
#    } else {
	$self->{plugin}->cmd ("$cmd ");
#    }
}



1;
