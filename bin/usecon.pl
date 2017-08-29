#!/usr/bin/env perl

my $ID = '$Id$';

use strict;
use warnings;
use ConsoleClient;
use Getopt::Long;
use Pod::Usage;
use IO::Handle;
use POSIX qw(strftime);
use TestManager::Lib;

my $server;
my $open_read = 1;
my $open_write = 0;
my $timestamp_lines = 1;
my $timestamp_format = "[%Y%m%d %H:%M:%S]";
my $help;
my $verbose = 0;
my $debug = 0;
my $finished = 0;
my $user_input;
my $cc;
my $logfile_handle;


sub usage(;$);
sub clean_exit();


MAIN:
{
	my $stream_name;
	my $perms = "";
	# for tracking whether or not a carriage-return was the last
	# character in the last message
	my $saw_carriage_return = 0;			
	my $logfile_name;

	GetOptions
	(
	  'h|help!'          => \$help,
	  'v|verbose!'       => \$verbose,
	  'd|debug!'         => \$debug,
	  'server|host=s'    => \$server,
	  'r|read!'          => \$open_read,
	  'w|write!'         => \$open_write,
	  'timestamp-lines!' => \$timestamp_lines,
	  'logfile=s'        => \$logfile_name,
	);

	usage() if defined($help);

	# if no stream name is supplied, error out.
	if (! $ARGV[0])
	{
		print(STDERR "No stream name supplied.\n");
		usage(1);
	}

	# try to grab user input early (otherwise we might lose it if we
	# were opened on a pipe)
	eval
	{
		local $SIG{ALRM} = sub { die("whamo!\n"); };
		alarm(1);
		sysread(STDIN, $user_input, 512);
		alarm(0);
	};

	# stream name should be the first non-option argument
	$stream_name = shift(@ARGV);

	# If we weren't explicitly given a sever to connect to, see if we're part of a test
	# cell with a master host.	 If not, use localhost.
	if (! defined($server))
	{
		my %pcfg;
		
		%pcfg = getPcfg($ENV{'SYSTEM'});
		
		die("Error reading PCFG for [$ENV{'SYSTEM'}]") if (keys(%pcfg) <= 0);
		
		if (exists($pcfg{'MULTIHOSTMASTER'}))
		{
			$server = $pcfg{'MULTIHOSTMASTER'};
			printlog("Using consoled service at host [$server]");
		}
		else
		{
			$server = 'localhost';
		}
	}
	
	# error out if we can't contact the server
	if (! ConsoleClient::checkServer($server))
	{
		print(STDERR "Can't connect to consoled server on $server.\n");
		exit(1);
	}

	# if we were given the name of a logfile to write, set us up to
	# write all background info to the logfile
	if (defined($logfile_name))
	{
		open($logfile_handle, ">$logfile_name")
			or die("Error opening log file $logfile_name: $!");

		$cc = new ConsoleClient( 'server'         => $server,
                                 'verbose'        => $verbose,
                                 'debug'          => $debug,
                                 'log_fh'         => $logfile_handle,
                                 'timestamp_data' => $timestamp_lines );
	}
	else
	{
		$cc = new ConsoleClient( 'server'         => $server,
                                 'verbose'        => $verbose,
                                 'debug'          => $debug,
                                 'timestamp_data' => $timestamp_lines );
	}

	# error out if we couldn't build a new ConsoleClient session
	if (! defined($cc))
	{
		print(STDERR "Error starting consoled session.\n");
		exit(1);
	}

	# register a signal handler for control-c and such
	$SIG{INT} = "clean_exit"; 
	$SIG{TERM} = "clean_exit";

	# error out if we don't have any streams
	my @stream_list = $cc->availableStreams();
	if ($#stream_list < 0)
	{
		print(STDERR "No streams available on $server.\n");
		exit(1);
	}
	# error out with list of available streams if the requested stream doesn't exist
	if (! grep { uc($_) eq uc($stream_name) } @stream_list)
	{
		print(STDERR "Stream $stream_name doesn't exist.\n" .
		             "Available streams are:\n" .
		             join("\n", @stream_list) . "\n");
		exit(1);
	}

	# take the first stream of the matching list and subscribe to it
	($stream_name) = grep { uc($_) eq uc($stream_name) } @stream_list;

	# put together a string of permissions
	$perms .= 'read' if ($open_read);
	$perms .= ' write' if ($open_write);
	# attempt to subscribe to stream
	if (! $cc->subscribe($stream_name, $perms))
	{
		print(STDERR "Unable to subscribe to stream $stream_name: " . $cc->getError() . "\n");
		exit(1);
	}

	# set STDIN to non-blocking via IO::Handle if we're writing to the stream
	if ($open_write)
	{
		my $ioh = IO::Handle->new_from_fd(0, '<');
		$ioh->blocking(0);
	}

	# set STDOUT to be un-buffered
	$| = 1;

	# poll for user input & stream output; send user input to stream if
	# we've opened the stream for writing
	while (! $finished)
	{
		my $stream_output;

		# get any output we might have from the stream
		$stream_output = $cc->readStream($stream_name);

		# write user input to the stream if we've opened it for writing and the
		# user has typed something
		if ($open_write &&
				($user_input || sysread(STDIN, $user_input, 255)))
		{
			$cc->writeStream($stream_name, $user_input);
			$user_input = "";
		}

		# if STDIN is closed and we're not reading, we're done.
		last if (eof(STDIN) && (! $open_read));

		# write anything recieved from the stream to STDOUT
		if ($stream_output)
		{
			print($stream_output);
		}
	}

	clean_exit();

}

sub clean_exit()
{
	if ( defined($cc) )
	{
		$cc->disconnect();
		close($logfile_handle) if ($logfile_handle);
	}
	exit(0);
}

sub usage(;$)
{
	my $retval = shift || 0;

	print($ID . "\n\n");
	pod2usage(0);
	exit($retval);
}

__END__

=head1 NAME

usecon - interact with streams from a consoled server

=head1 SYNOPSIS

usecon <options> stream

Options:

--server <server name>	sets the server to which we should connect
--(no-)read					requests (or declines) output from stream
--(no-)write				requests (or declines) input permission
--(no-)timestamp-lines	sets (or un-sets) time-stamping of lines
--verbose					requests a bunch of runtime information
--debug						requests dumping of raw data from server
--logfile <name>			specify the logfile to write

For more information, please type C<perldoc usecon>

=head1 DESCRIPTION

usecon provides an interactive interface to a single stream provided by
a consoled server.  If a stream name isn't given, an error will be printed
and usecon will exit.

By default, the server will be assumed to be running on the local system,
	and streams are opened read-only.

	If an error occurs when opening the stream, an error message will be printed
	and usecon will exit with a non-zero value.

	=head1 OPTIONS

	=over 5

	=item --server

	Allows the name of the server to which to connect to be specified.

	=item --(no-)read or -r

	Requests that the stream be opened with read permission.	 If --no-read is
	given, requests that the stream be opened without read permission (in which
			case no data will be recieved from the stream).	 Does not override other
	permissions; will be combined with them.

	=item --(no-)write or -w

	Requests that the stream be opened with write permissions.	If --no-write
	is given, explicitly requests that the stream be opened without write
	permissions.  The default is to open a stream without write permission.
	Can be combined with other permissions.

	=item --(no-)timestamp-lines

	Sets (or un-sets) the option of prefixing each line with a time-stamp.
	Time stamps are in the form [YYYY.MM.DD HH:MM:SS].	 Lines are sequences of
	zero or more characters followed by any number of \n and \r, in any sequence.

	=item --verbose or -v

	Causes lots of information on what the underlying library code is doing to
	show up in this utility's log file.

	=item --debug or -d

	Causes the underlying library code to write a log file (raw.log) which
	the raw JSON data recieved from the consoled server.

	=item --logfile <file_name>

	If given, causes all ancillary output (such as that generated by --debug
			and --verbose) to be written to the given file.	 The file will be truncated
	before writing.

	=back


	=head1 AUTHOR

	Catherine Mitchell

	=cut
