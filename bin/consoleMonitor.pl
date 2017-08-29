#! /usr/bin/env perl

use strict;
use warnings;
use ConsoleClient;
use IO::Handle;
use POSIX qw(strftime);
use Pod::Usage;
use Getopt::Long;
use Sys::Hostname;

# To see if we're meant to use a centralized consoled server and only read
# certain streams, we need to read our PCFG.
# Instead of writing our own PCFG-reading functions, we're guaranteed have
# the functions in TestManager::Lib or ../sbin/TestLib.pm available to us.
# In order to use one of those modules without failing, we use
# Module::Load::Conditional to do a conditional load at runtime instead of
# absolutely requiring the presence of either or both modules at compile
# time.
use lib '../sbin';
use TestManager::Lib;

my $ID = '$Id$';
my $VERSION = 'DEVELOPMENT';

my $consoled_host = 'localhost';
my $logfile_handle;
my @streams;
my %stream_logfile_handle;
my $stream;
my $finished = 0;
my $timestamp_format = "[%Y%m%d %H:%M:%S]";
my $timestamp_lines = 1;
my $concli;
my $seconds_elapsed = 1;
my %pcfg;

$SIG{USR1} = sub { $finished = 1; };
$SIG{TERM} = sub { $finished = 1; };

$logfile_handle = openLog('consoleMonitor.log');

printLog("Running consoleMonitor version $VERSION");
printLog("$ID");

# if we're using a PCFG, see if we've been configured to connect to a particular
# host running consoled (default is given above, in $consoled_host) and whether
# we should read specific streams, or all available streams
if (exists($ENV{'SYSTEM'}))
{
	%pcfg = getPcfg($ENV{'SYSTEM'});
}
else
{
	my ($uname) = (hostname() =~ /msa(.*)$/);
	printLog("SYSTEM environment variable not set; using $uname as hostname");
	%pcfg = getPcfg($uname);
}

if (exists($pcfg{'MULTIHOSTMASTER'}))
{
	$consoled_host = $pcfg{'MULTIHOSTMASTER'};
}

if (exists($pcfg{'MONITOR_STREAM'}))
{
	@streams = @{$pcfg{'MONITOR_STREAM'}};
}

printLog("Connecting to consoled on host $consoled_host");

# connect to the local consoled server
if (defined($logfile_handle))
{
	$concli = new ConsoleClient( 'verbose' => 1,
	                             'log_fh' => $logfile_handle,
	                             'server' => $consoled_host,
	                             'timestamp_data' => $timestamp_lines,
	                             'timestamp_fmt' => $timestamp_format);
}
else
{
	$concli = new ConsoleClient( 'verbose' => 1,
	                             'server' => $consoled_host,
	                             'timestamp_data' => $timestamp_lines,
	                             'timestamp_fmt' => $timestamp_format);
}

termError("Unable to connect to console stream server")
	unless (($concli) && $concli->connected());

# if we weren't given a list of streams to monitor in the PCFG, monitor all streams
if ($#streams < 0)
{
	# get a list of all streams
	@streams = $concli->availableStreams();
}

termError("No streams found") unless ((@streams) && ($#streams >= 0));

printLog("Opening the following streams: " . join(", ", @streams));

# open a log file for each stream, set it to unbuffered i/o, and store
# it in the hash of stream names to logfile handles;
# subscribe to each stream
foreach $stream (@streams)
{
	my $fh = undef;
	my $date = localtime;
	
	# set up logfile
	open($fh, ">$stream.log");
	$fh->autoflush(1);
	$fh->print(('*'x80) . "\n");
	$fh->printf("*** %72s ***\n", $date);
	$fh->printf("*** %72s ***\n", "consoleMonitor version $VERSION");
	$fh->printf("*** %72s ***\n", $ID);
	$fh->printf("*** %72s ***\n", "Listening to consoled server on [$consoled_host]");
	$fh->printf("*** %72s ***\n", "Monitoring output of [$stream]");
	$fh->print(('*'x80) . "\n");

	# subscribe
	if ($concli->subscribe($stream))
	{
		printLog("[$stream] subscribe ok");
	}
	else
	{
		printLog("[$stream] error subscribing: %s", $concli->getError());
	}
	
	$stream_logfile_handle{$stream} = $fh;
}

# get output and write it to the logfiles until we're done
do
{
	sleep(1);
	
	# print a log message every ten minutes
	if (($seconds_elapsed++ % 600) == 0)
	{
		printLog("** marker **");
	}
	
	foreach $stream (@streams)
	{
		my $data;		
		my $lfh;

		# get a simple copy of the filehandle so that we can use it in a print
		# statement (curly brace overloading in Perl can cause problems here)
		$lfh = $stream_logfile_handle{$stream};

		# read data
		$data = $concli->readStream($stream);

		# write data to the logfile if there's data available
		if ($data)
		{
			# print $data
			print($lfh $data);
			# reset our idle counter
			$seconds_elapsed = 1;
		}
	}
} while (! (($finished) || (-e 'autotest.halt') || (-e 'consoleMonitor.halt')));

if (-e 'autotest.halt')
{
	printLog();
	printLog("INFO:  Log file(s) closing due to 'autotest.halt' trigger\n");
}
elsif (-e 'consoleMonitor.halt')
{
	printLog();
	printLog("INFO:  Log file(s) closing due to 'consoleMonitor.halt' trigger\n");
}

# close logfile handles
foreach $stream (keys(%stream_logfile_handle))
{
	printLog("Closing log for $stream");
	close($stream_logfile_handle{$stream});
}

printLog("Console Monitor exiting.");

exit(0);
