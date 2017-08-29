#! /usr/bin/perl -w

## consoleUtil
#
# An interactive, readline-based client for consoled servers.
#
# TAB SETTING: 4 spaces per tab; tabs only for full indent from start-of-line
#
# Copyright (C) 2008, Hewlett-Packard Development Company

use strict;
use warnings;
use ConsoleClient;
use Term::ReadLine;
use Pod::Usage;
use Getopt::Long;
use POSIX qw(strftime);
use Cwd;
use threads;
use threads::shared;
use TestManager::Lib;

my $ID = '$Id$';
my $VERSION = 'DEVELOPMENT';

# format for timestamps
my $timestamp_format = "[%Y%m%d %H:%M:%S]";
# reference to filehandle for logging
my $log_handle;
# shared reference to output filehandle
my $OUT;
# Term::Readline object
my $term;
# ConsoleClient object
my $concli;
# shared storage for user input
my $user_input : shared;
## shared storage for output to user
#my $output_buffer : shared;
# shared flag indicating whether or not we're shutting down
my $done : shared;
# name of the stream we're working with
my $stream;
# whether or not router should generate debug information
my $debug = 0;
# whether or not we should be verbose about what we're doing
my $verbose = 0;


MAIN:
{
	my $server;
	my $writeLog = 0;
	my $help = 0;
	my $logfileName;
	my $line;
	my $userThread;
	
	# default stream is CLIA
	$stream = 'CLIA';

	GetOptions
	(
		'h|help!'          => \$help,
		's|server=s'       => \$server,
		'l|log!'           => \$writeLog,
		'd|debug!'         => \$debug,
		'v|verbose!'       => \$verbose,
		'f|logfile=s'      => \$logfileName
	);
	
	# if there are any arguments left on the command line after option processing,
	# the first one should be the name of the consoled stream to connect to
	if ($#ARGV > -1)
	{
		$stream = shift(@ARGV);
	}
	
	# if we're running from a "run" directory, automatically log
	# to consoleUtil.log, ignoring the log flag
	if (cwd() =~ /run$/)
	{
		$writeLog = 1;
		$logfileName = 'consoleUtil.log';
	}
	
	# if we're meant to write a log, open it now and write our ID into it
	if ($writeLog)
	{
		open($log_handle, ">$logfileName")
		  or die("Error opening log file: $!");
		printlog("consoleUtil version $VERSION");
		printlog("$ID");
		printlog("");
	}
	
	# If we weren't explicitly given a sever to connect to, see if we're part of a test
	# cell with a master host.  If not, use localhost.
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
	
	# make a new Term::Readline object
	$term = new Term::ReadLine 'consoleUtil';
	die("Unable to create readline interface: $!") unless (defined($term));
	
	# make the terminal pretty
	$term->ornaments(1);
	
	# get a reference to the output filehandle to use
	$OUT = $term->OUT || \*STDOUT;

	# open the requested consoled stream
	printlog("Connecting to $server... ");
	if ($writeLog)
	{
		$concli = new ConsoleClient( 'verbose' => $verbose,
		                             'debug'   => $debug,
									 'log_fh'  => $log_handle,
									 'server'  => $server );
	}
	else
	{
		$concli = new ConsoleClient( 'verbose' => $verbose,
		                             'debug'   => $debug,
		                             'server'  => $server );
	}
	
	# make sure we got the connection
	if ($concli && $concli->connected())
	{
		printlog("Connected.");
	}
	else
	{
		printlog("Failed to connect to $server.");
		exit(1);
	}
	
	# subscribe to indicated stream
	if (! $concli->subscribe($stream, 'read-write'))
	{
		printlog("Error subscribing to stream $stream: " . $concli->getError());
		exit(2);
	}
	
	printlog("Subscribed to $stream.");

	# set up to go into our input-handler loop
	$done = 0;
	
	
	## do the readline in a separate thread; this thread will put
	## user input into a FIFO which the main thread will read and react
	## to by printing stuff to OUT
	$userThread = threads->create("waitForInput");
	
	# give user i/f thread time to come up
	sleep(1);
	
	while (! $done)
	{
		my $from_stream;
		
		# get any incoming data and write it to both terminal and log
		$from_stream = $concli->readStream($stream);
		if ($from_stream)
		{
#			lock($output_buffer);
#			$output_buffer .= $from_stream;
			print($OUT $from_stream);
			print($log_handle $from_stream);
		}
		
		# process user input
		processUserInput();
		
		if (! $concli->connected())
		{
			print($OUT "Lost connection to router -- shutting down.\n");
			lock($done);
			$done = 1;
		}
	}
	
	printlog("Joining user i/f thread...\n");
	$userThread->join();
	
	printlog("Bye.\n");
	# close the log file
	close($log_handle);
}

## @method void processUserInput($input)
# Processes input from a user.
# Things which aren't recognized as local commands are sent on to
# the stream to which the user is connected.
sub processUserInput
{
	my @lines;
	my $input;

	# nothing to do unless we have some input to process
	return unless ($user_input);
	
	{
		lock($user_input);
		
		# grab any input from the user i/f thread and reset the $user_input buffer
		@lines = split(/[\r\n]+/, $user_input);
		$user_input = "";
	}
	
	foreach $input (@lines)
	{
		# send anything that gets here to the stream
		$concli->writeStream($stream, $input)
		  or printlog("Error writing to stream $stream\n");
	}
}

## @method void waitForInput()
# Waits for input from the user using Term::Readline.readline().
# Adds input from user to whatever's in $user_input shared storage
# (if anything).
sub waitForInput
{
	my $line;
	
	while (! $done)
	{
		# use an alarm block to break us out of waiting for input
		# from the user so that we can handle any text that's waiting
		# for us
		eval
		{
			local $SIG{ALRM} = sub { die "alarum!\n" };
			alarm(1);
			$line = $term->readline("$stream> ");
			alarm(0);
		};
		if ($@ eq "alarum!\n")
		{
			alarm(0);
		}
		
		if (defined($line))
		{
			
			# report (and add to the history buffer) any input which has at least one
			# non-whitespace character
			if ($line =~ /\S/)
			{
				lock($user_input);
				$user_input .= $line;
				$term->addhistory($line);
			}
			
			# handle special words
			if ($line =~ /^\s*(\w+)\s*$/i)
			{
				my $command = $1;
				
				if ($command eq 'help')
				{
					print($OUT "Commands:\n");
					print($OUT "  help     Get help with commands\n");
					print($OUT "  quit     End the consoleUtil session\n");
					print($OUT "  exit     Synonym for quit\n");
					print($OUT "\n");
					print($OUT "Anything else will be sent to $stream.\n");
				}
				elsif (($command eq 'quit') || ($command eq 'exit'))
				{
					lock($done);
					$done = 1;
				}
			}
		}
		
#		if ($output_buffer)
#		{
#			lock($output_buffer);
#			print($OUT $output_buffer);
#			$output_buffer = '';
#		}
	}
}


## @method printlog(...)
# Prints a sprintf-style string to $log_handle, prefixing it with a timestamp
# in local-time and adding a newline to the end.
sub printlog
{
	my $fmt_str = shift | "";
	
	chomp($fmt_str);
	
	if ($log_handle)
	{   
		$log_handle->print(sprintf("%s $fmt_str\n", strftime($timestamp_format, localtime), @_));
	}
	
	if ($OUT)
	{
		printf($OUT "$fmt_str\n", @_);
	}
}


__END__

=head1 NAME
 
consoleUtil -- interact with a stream being served by a consoled server

=head1 SYNOPSIS
 
consoleUtil <options> <stream-name>
 
Options:
 
	--server <hostname>	 supply the hostname of a server to connect to

For more information, please type C<perldoc usecon> 
 
=head1 DESCRIPTION
 
consoleUtil allows an interactive session with a console stream being served
by a consoled server.  It provides a command line with Readline support and
history tracking.
 
To quit, enter "quit".

=head1 AUTHOR

Catherine Mitchell
