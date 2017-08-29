## @file ConsoleClient.pm
# A package of routines for connecting to a console stream server.
#
# $Id$
#
# @author Catherine Mitchell

## @class ConsoleClient
# Provides a programmatic interface to a remote consoled server.
package ConsoleClient;

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(checkServer
					 reqAvailableStreams reqCloseStream reqOpenStream
					 readAvailableStreams
					 availableStreams
					 );

our $ID = '$Id$';
my $VERSION = 'DEVELOPMENT';

use strict;
use warnings;
use JSON;
use Carp;
use Switch;
use IO::Pipe;
use IO::Handle;
use IO::Socket::UNIX;
use File::Temp;
use POSIX qw(strftime);
use Time::HiRes qw(ualarm usleep);

##############################################################################
# Constants
##############################################################################

use constant CONSOLED_PORT => 29168;  # consoled's listening port
use constant PROTO_VERSION_MAJ => 0;  # major protocol version
use constant PROTO_VERSION_MIN => 51; # minor protocol version
use constant EOL => "\015\012";		  # Internet EOL
# number of seconds after which status info is considered 'out-of-date'
use constant STATUS_LIFETIME => 120;
# amount of time we have to connect to remote, in milliseconds
use constant CONNECT_TIMEOUT => 5000;
# amount of time we'll wait for the router to process any request,
# in seconds
use constant ROUTER_REQUEST_TIMEOUT => 5;

##############################################################################
# Storage
##############################################################################
# available_streams is a hash of stream names to information about those streams;
# a stream which is listed in available_streams may not have any status information
# associated with it, since the list of streams and information about each stream
# arrive in separate messages
#my %available_streams;  ## moved to object-scoped storage: $self->{'available_streams'}
# subscribed_streams is a hash of stream names to the mode in which each stream
# was opened ('read'||'write'||'read write')
#my %subscribed_streams; ## moved to object-scoped storage: $self->{'subscribed_streams'}
# stream_data is a hash of stream name to a buffer of available data for that
# stream
#my %stream_data;## moved to object-scoped storage: $self->{'stream_data'}
# storage for errors
#my @errors; ## moved to object-scoped storage: $self->{'errors'}
# map of parent PID to object reference ($self)
my %PID_object;

##############################################################################
# Implementation
##############################################################################

## @cmethod ConsoleClient new()
# Returns a new ConsoleClient object.
#
# Configuration parameters are given in the form of a hash.	 Defaults are listed below in
# parenthesis.	 They include:
# @code
# server          IP address of server to connect to
# no_connect      (0) If set to 1, we won't connect to any servers on start-up
# TIMEOUT         (10) Number of seconds to wait for a response from the server on blocking
#                      calls
# quick_exit      (0) If set, allows disconnect to detach router thread instead of waiting for
#                     it to join.
# verbose         (0) If set, class will say what it's doing, writing to filehandle referenced
#                     in log_fh
# debug           (0) If set, router will dump all data recieved as raw JSON strings.
# log_fh          (STDOUT) file handle to which to write log messages
# timestamp_fmt   [%Y%m%d %H:%M:%S] strftime() format string for timestamp prefixing
#                     log lines
# timestamp_data  (1) If set to 1, prefixes each line of incoming data with the time
#                     at which it was recieved.  Assumes that linebreak sequence is \r\n.
#                     (\015\012)
# @endcode
sub new(;%)
{
	my $class = shift;
	my %params = @_;
	my $self = (%params) ? \%params : {};
		
	$self->{'server'} = '127.0.0.1' if (! exists($self->{'server'}));
	$self->{'TIMEOUT'} = ROUTER_REQUEST_TIMEOUT if (! exists($self->{'TIMEOUT'}));
	$self->{'error_str'} = "";
	$self->{'quick_exit'} = 0 unless exists($self->{'quick_exit'});
	$self->{'no_connect'} = 0 unless exists($self->{'no_connect'});
	$self->{'log_fh'} = \*STDOUT unless (exists($self->{'log_fh'}));
	$self->{'verbose'} = 0 unless (exists($self->{'verbose'}));
	$self->{'debug'} = 0 unless (exists($self->{'debug'}));
	$self->{'timestamp_fmt'} = '[%Y%m%d %H:%M:%S]'
		unless exists($self->{'timestamp_fmt'});
	$self->{'timestamp_data'} = 1 unless exists($self->{'timestamp_data'});
	
	bless($self, ref($class) || $class);
	
	# register our object handle to our PID so that asynchronous static methods
	# (like signal handlers) can update our internal state (get a reference
	# to $self)
	$PID_object{$$} = $self;
	# register a handler to de-register ourselves from the package-scoped
	# $PID_object mapping
	END { exists($PID_object{$$}) && delete($PID_object{$$}); };
	
	# don't log to given file handle unless it's good;
	# if it is good, open STDERR to log_fh
	if (! ($self->{'log_fh'}))
	{
		$self->{'log_fh'} = \*STDOUT;
		$self->printLog("Bad log handle given -- using standard-output");
	}
	else
	{
		my $filenum = fileno($self->{'log_fh'});
		
		open(STDERR, ">>&$filenum") or
		  $self->printErr("Unable to redirect stderr to logfile: $!");
	}
	
	# list the options we were called with
	$self->printLog("ConsoleClient library version $VERSION") if ($self->{'verbose'});
	$self->printLog("Connection debugging active") if ($self->{'debug'});
	$self->printLog("Library verbosity active") if ($self->{'verbose'});
	
	# set up storage to be per-object
	$self->{'available_streams'} = ();
	$self->{'subscribed_streams'} = ();
	$self->{'stream_data'} = ();
	$self->{'errors'} = [];
	
	if (! $self->{'no_connect'})
	{
		return(undef) unless ($self->connect());
		sleep(1);
	}
	
	return($self);
}

## @cmethod boolean checkServer($server_ip)
# Checks to see whether there's a 'consoled' server alive at a given IP.
# If no IP is given, uses localhost (127.0.0.1).
#
# @arg $server_ip	 The IP address of the server to check.
#
# @return true if there is, false if there isn't.
sub checkServer(;$)
{
	my $remote = shift || '127.0.0.1';
	my $socket;
	
	$socket = IO::Socket::INET->new( Proto		 => 'tcp',
	                                 PeerAddr    => $remote,
	                                 PeerPort    => CONSOLED_PORT,
	                                 ReuseAddr   => 1 );
	
	sleep(1);
	
	if (($socket) && $socket->connected())
	{
		$socket->close();
		return(1);
	}
	
	return(0);
}

## @method boolean connected()
# Detects whether or not we're connected to a server.
# @return True if we're connected, false otherwise.
sub connected()
{
	my $self = shift || Carp::confess("Object method called as static method");
	
	return(exists($self->{'router_socket'}) &&
			 defined($self->{'router_socket'}) &&
			 $self->{'router_socket'}->connected());
}

## @method hash_ref makeMessage(%fields)
# Returns a reference to a hash containing the given fields and the appropriate
# header info for the protocol in use.
# @return A hash reference to a message.
sub makeMessage(;%)
{
	my $self = shift;
	my %message = @_;
	
	#$self->printLog("Creating message");
	$message{'version'} = (PROTO_VERSION_MAJ . '.' . PROTO_VERSION_MIN) + 0;
	return(\%message);
}

## @method void sendMessage(%fields)
# Sends the given message to the server.	Handles the JSON encoding of the message.
# Does nothing if we don't have an open connection.
sub sendMessage(\%)
{
	my $self = shift;
	my $msg_ref = shift;
	my $encoded;

	return() unless ($self->connected());
	
	my $outpipe = $self->{'router_socket'} || return;
	
	$encoded = encode_json($msg_ref);
	
	$self->printLog("Sending message $encoded");
	print($outpipe encode_json($msg_ref) . "\n");
}

## @method $msg_ref decodeMessage($raw_message)
# Decode the given JSON string into a message.
#
# @return If there's an error, the return will be undef.	 Otherwise,
# returns a reference to the decoded message structure (either a
# hash or a list).
sub decodeMessage($)
{
	my $self = shift || Carp::confess("Object method called as static");
	my $raw_message = shift || Carp::confess("No message supplied");
	my $msg_ref;
	
	eval
	{
		$msg_ref = decode_json($raw_message);
	};
	if (! (defined($msg_ref) && (ref($msg_ref) eq 'HASH')))
	{
		$self->printErr("Unable to decode message $raw_message");
		return(undef);
	}
	return($msg_ref);
}

## @method boolean msgIsDemonic($msg_ref)
# Checks to see whether or not a message conforms to the structure and
# version of the DeMonIC protocol that we know.
sub msgIsDEMONIC($)
{
	my $self = shift || Carp::confess("Object method called as static");
	my $msg_ref = shift || Carp::confess("No message object supplied");
	
	# check the message's structure
	if (ref($msg_ref) ne 'HASH')
	{
		$self->printErr("Message reference is not a hash");
		return(0);
	}
	# make sure that there's a version field
	if (! ( exists($msg_ref->{'version'}) ) )
	{
		$self->printErr("Message is non-conformant: no 'version' field");
		return(0);
	}
	# make sure that the version is one we can grok
	if (! ( $msg_ref->{'version'} =~ /^(\d+)\.\d+/) &&
			( $1 <= PROTO_VERSION_MAJ ) )
	{
		$self->printErr(sprintf(
		  'Message is non-conformant: major version mismatch (ours=%d theirs=%d)',
		  PROTO_VERSION_MAJ, $1));
		return(0);
	}
	# make sure that there's an identifier field
	if (! exists($msg_ref->{'identifier'}))
	{
		$self->printErr("Message is non-conformant: no 'identifier' field");
		return(0);
	}
	
	return(1);
}

## @method $int processMessages()
# Process any messages the router has for us.
# Reads messages from the router until there are no more (i.e. the router
# a blank).
#
# @note This call will block while reading messages from the router.	 This
# means that this method will continue to process messages being held for
# the process calling it until there are no more queued messages on the
# router.
#
# @return the number of messages read
sub processMessages()
{
	my $self = shift || Carp::confess("Object method called as static");
	my $timeout = shift || $self->{'TIMEOUT'};
	my $utimeout;
	my $messages = 0;
	my $messages_left = 0;
	my $raw_message;
	my $from;
	
	# since we're using usleep() to time out reads from the router,
	# multiply our timeout value by 1000 to get the number of
	# microseconds to wait before sending ourselves the alarm signal
	$utimeout = int($timeout * 1000000);
	
	$from = $self->{'router_socket'};
	
	$self->printLog("Checking for incoming messages");
	
	do
	{
		my $msg_ref;
		my $payload;
		
		# do a blocking read on the recieving pipe so that the
		# router will see that we're ready to go whenever it's
		# done processing.
		eval
		{
			local $SIG{ALRM} = sub { die "rr_alarm\n" };
			ualarm($utimeout);
			$raw_message = <$from>;
			alarm(0);
		};
		# if we timed-out, we're done; if we recieved nothing, we're done.
		if (($@ eq "rr_alarm\n") || (! (($raw_message) && ($raw_message =~ /[\w\d]/))))
		{
			if ($messages_left > 0)
			{
				$self->printLog("Router lied to us.  messages_left: $messages_left and read timed-out.");
			}
			
			return($messages);
		}
		
		# router prefixes each transmission with the number of messages it's got
		# left for us and a pipe character; pull the transmission apart into
		# the message count and the message itself
		($messages_left, $payload) = ($raw_message =~ /^(\d+)\|(.*)/);
		
		# trim newlines off end of message
		chomp($payload);
		$self->printLog("Got message $payload") if ($self->{'debug'});
		$self->printLog("Messages remaining to process: $messages_left");
		
		# decode the message returned
		$msg_ref = $self->decodeMessage($payload);
		# if decoding failed, skip the message
		if (! defined($msg_ref))
		{
			$self->printErr("Unable to decode message $raw_message");
			next;
		}
		
		# process the message recieved from the i/o router and update our state
		# accordingly
		switch(lc($msg_ref->{'identifier'}))
		{
			case 'data'
			{
				# stream data
				my $stream = uc($msg_ref->{'stream'});
				
				# only process data messages for streams for which we've set up storage
				if (exists($self->{'stream_data'}->{$stream}))
				{
					$self->{'stream_data'}->{$stream} .= $msg_ref->{'data'};
					#					 print("Placed data into buffer for $stream\n");
				}
			}
			case 'ok'
			{
				switch (lc($msg_ref->{'command'}))
				{
					case 'open'
					{
						my $stream = uc($msg_ref->{'stream'});
						# add the stream for which this is the open confirmation to the
						# hash of subscribed streams
						$self->printLog("Stream $stream opened");
						$self->{'subscribed_streams'}->{$stream} =
						  (exists($msg_ref->{'mode'})) ? $msg_ref->{'mode'} : "";
						# set up storage for the newly-opened stream (unless it's not
						# newly-opened, in which case there may already be storage)
						$self->{'stream_data'}->{$stream} = "" unless exists($self->{'stream_data'}->{$stream});
					}
					case 'close'
					{
						my $stream = uc($msg_ref->{'stream'});
						# remove the stream from the set of subscribed streams
						$self->printLog("Stream $stream closed");
						delete($self->{'subscribed_streams'}->{$stream});
						# remove storage for the stream
						delete($self->{'stream_data'}->{$stream});
					}
					case 'status'
					{
						# see if this is general status or stream-specific status
						if (exists($msg_ref->{'stream'}))
						{
							# stream-specific status
							my $stream = uc($msg_ref->{'stream'});
							
							$self->printLog("Recieved status message for stream $stream");
							
							# set up storage for the stream's info as an anonymous hash
							if (! exists($$self->{'available_streams'}->{$stream}))
							{
								$self->{'available_streams'}->{$stream} = {};
							}								 
							$self->{'available_streams'}->{$stream}->{'last_update'} = time;
							$self->{'available_streams'}->{$stream}->{'listener_count'} =
							  $msg_ref->{'listener_count'};
							$self->{'available_streams'}->{$stream}->{'writer'} =
							  $msg_ref->{'writer'};
						}
						else
						{
							# general status
							my $stream;
							
							$self->printLog("Recieved general status message");
							
							# make note of time when this was recieved
							$self->{'last_general_status'} = time;
							
							$self->{'available_streams'}->{'last_update'} = time;
							$self->{'available_streams'}->{'uptime'} = $msg_ref->{'uptime'};
							$self->{'available_streams'}->{'client_count'} = $msg_ref->{'client_count'};
							
							# update the list of available streams using the list in this status message;
							# remove streams which no longer exist from available_streams, but don't
							# delete their stream_data since our client may still be processing stuff from it
							foreach $stream (keys(%{$self->{'available_streams'}}))
							{
								if (! grep { uc($_) eq $stream } @{$msg_ref->{'streams'}})
								{
									delete($self->{'available_streams'}->{$stream});
								}
							}
							# set up storage for, and cache info about, streams which didn't exist before
							foreach $stream (@{$msg_ref->{'streams'}})
							{
								if (! exists($self->{'available_streams'}->{uc($stream)}))
								{
									$self->{'available_streams'}->{uc($stream)} = {};
								}
							}
						}
					}
					case 'write'
					{
						## nothing to do on write acknowledgement
					}
					else
					{
						# unknown command
						$self->printLog("Unknown command recieved: " . $msg_ref->{'command'});
					}
				}
			}
			case 'fail'
			{
				# store error message associated with failure into errors
				if (exists($msg_ref->{'command'}))
				{
					my $msg = join(': ', $msg_ref->{'command'}, $msg_ref->{'error'});
					$self->printLog("Failure: $msg");
					push(@{$self->{'errors'}}, $msg);
				}
				else
				{
					$self->printLog("Failure: " . $msg_ref->{'error'});
					push(@{$self->{'errors'}}, $msg_ref->{'error'});
				}
			}
		}
		
		# track the number of messages we've processed
		$messages++;
	} while ($messages_left > 0);
	
	return($messages);
}
	

## @method boolean connect($server_ip)
# Connects to a server.	 If no IP is given, will connect to whatever IP the
# client is configured with (defaults to localhost).	If already connected,
# closes the current connection before opening the new one.
#
# @note
# The connection is set up as blocking (that is, it blocks on i/o) by default.
#
# @arg $server_ip	 The IP of the server to connect to
#
# @return true on success, false on failure
sub connect(;$)
{
	my $self = shift || return(0);
	my $newip = shift;
	my $tempfifoh;
	my $tempfifoname;
	
	$self->{'server'} = $newip if (defined($newip));
	
	# don't re-connect if we're already connected
	return(1) if ($self->connected());
	
	# make a temporary fifo to use for this connection
	$tempfifoh = new File::Temp( 'UNLINK' => 0 );
	$tempfifoname = $tempfifoh->filename();
	$tempfifoh->close;
	unlink($tempfifoname);
	$self->{'router_fifo'} = $tempfifoname;
	$self->printLog("Selecting $tempfifoname as FIFO for router connection");

	# set up the signal handler for SIGCHLD so that we know when our
	# router process exits
	$SIG{'CHLD'} = \&handleDeadKid;
	
	# fork, and have the child be the router process
	$self->{'router_pid'} = fork;

	# if router_pid is undefined, it means that fork() failed
	Carp::confess("Couldn't create router process: $!")
		unless (defined($self->{'router_pid'}));
	
	# child is the router process
	if ($self->{'router_pid'} == 0)
	{
		$self->routeMessages();
		exit(0);
	}
	
	$self->printLog("Spawned router on PID " . $self->{'router_pid'});
	
	# open connection to router
	my $timeout = time + $self->{'TIMEOUT'};
	while (! (exists($self->{'router_socket'}) &&
				 defined($self->{'router_socket'})) &&
			 (time < $timeout))
	{
		$self->{'router_socket'} = new IO::Socket::UNIX('Type' => SOCK_STREAM,
														'Peer' => $self->{'router_fifo'});
	}
	# return an error if the open failed
	if (! $self->{'router_socket'})
	{
		$self->printErr("Couldn't connect to router");
		return(0);
	}
	# make the connection blocking
	$self->{'router_socket'}->blocking(1);
	$self->{'router_socket'}->autoflush(1);
	
	# wait for router to come up by printing a status-request message to
	# it; we will block until the router comes up and starts processing
	# messages, at which point we'll know that it's up because we
	# un-block
	$self->printLog("Requesting server status");
	$self->availableStreams();
	$self->printLog("Got status -- we're connected.");
	
	# set up END block to clean up if we abort
	END { no warnings 'closure'; ($self) && $self->disconnect(); }

	return($self->connected());
}

## @method void disconnect()
# Disconnects from a server if we're currently connected.
# Explicitly closes any streams we're connected to, shuts down router thread,
# and deletes data stores.
sub disconnect()
{
	my $self = shift;
	my $stream;
	my $wait_counter;
	
	# only disconnect if we're connected and we're not the router
	if ($self->connected() && ($self->{'router_pid'} > 0))
	{		 
		# go through each of our subscribed streams and close them
		foreach $stream (keys(%{$self->{'subscribed_streams'}}))
		{
			$self->printLog("Closing stream $stream");
			$self->reqCloseStream($stream);
		}
		
		# if the router is still running, send a TERM signal to the router so
		# that it will shut down gracefully.  Note that the router may already
		# have shut down if we were killed by an external signal (Perl may have
		# already propagated the signal to our children)
		if (exists($self->{'router_pid'}))
		{
			# shut down the router
			kill('TERM', $self->{'router_pid'});
			$self->printLog("Signalling router to shut down; giving it " . $self->{'TIMEOUT'} .
							" seconds to comply.");
	
			# give router process time to shut down
			$wait_counter = time + $self->{'TIMEOUT'};
			while (exists($self->{'router_pid'}) && (time < $wait_counter))
			{
				sleep(1);
			}
			# if router failed to exit, note the fact and kill it
			if (($wait_counter >= time) && exists($self->{'router_pid'}))
			{
				$self->printLog("Router process failed to shut down -- killing it forcefully");
				kill('KILL', $self->{'router_pid'});
			}
		}
	}

	# reset available streams data
	$self->{'available_streams'} = ();
	# reset subscribed stream data
	$self->{'subscribed_streams'} = ();
	# release stream data buffers
	$self->{'stream_data'} = ();
}

## @method void routeMessages()
# Worker routine which manages our i/o.
#
# This routine communicates with its caller on a pair of pipes.  Messages to be
# sent to the server are encoded by the sender and sent to this routine, which
# will then forward them to the server.  Responses from the server are buffered
# and sent to the main process when it is ready to read from the return pipe.
#
# Pings from the server are handled here, instead of being sent up to the main
# (application) process.  Ping requests to the server are also handled here, if
# they're enabled.
#
# @note This routine is designed to be called on its own thread.	It loops until
# it recieves a TERM signal, at which point it shuts down gracefully.
sub routeMessages($)
{
	use IO::Socket;
	use IO::Select;
	
	my $self = shift;
	my $remote = shift || $self->{'server'} || die("No remote host given");
	my $shutting_down = 0;
	my $connection;  # connection to remote server
	my $unixsocket;  # listener socket to which main proc will connect
	my $mainproc;	  # connection to main process
	my $raw_data;
	my $connect_timeout;
	my $read_vec;
	my $write_vec;
	my @messages_for_parent;
	
	# if we were asked to log protocol-layer transactions, write raw.log
	if ($self->{'debug'})
	{
		my $fh;
		
		# set 'verbose' within this process so that printLog works
		$self->{'verbose'} = 1;
		
		open($fh, '>raw.log') or die("Couldn't open raw.log: $!");
		$fh->autoflush(1);
		$self->{'log_fh'} = $fh;
		print($fh "Router process $$ opened raw.log\n");
		$self->printLog("Writing raw.log");
	}
	else
	{
		# otherwise, log nothing
		$self->{'log_fh'} = undef;
	}
	
	# open connection
	$connection = IO::Socket::INET->new( Proto      => 'tcp',
	                                     PeerAddr   => $remote,
	                                     PeerPort   => CONSOLED_PORT,
	                                     ReuseAddr  => 1,
	                                     Blocking   => 0 );
	
	if (! $connection)
	{
		my $err = "Couldn't open socket: $!";
		
		$self->printLog($err);
		Carp::confess($err);
	}
	
	$connection->autoflush(1);
	
	# open a UNIX-domain socket to which the main process can connect using the
	# temporary socket created at startup (only allow one listener)
	$unixsocket = new IO::Socket::UNIX('Type' => SOCK_STREAM,
	                                   'Local' => $self->{'router_fifo'},
	                                   'Listen' => 1);
	if (! defined($unixsocket))
	{
		my $errmsg = "Unable to open socket for main process: $!";
		$self->printErr($errmsg);
		Carp::confess($errmsg);
	}
	
	$unixsocket->autoflush(1);
	
	# immediately loop until we get the connection from the main process
	$self->printLog("Waiting for connection from main process");
	while (! defined($mainproc))
	{
		$mainproc = $unixsocket->accept();
	}
	$self->printLog("Got connection from main process");
		
	# set up a vector of handles which we'd like to read from whenever they're
	# ready to be read from
	$read_vec = new IO::Select();
	$read_vec->add($connection);
	$read_vec->add($mainproc);
	# do likewise for handles we'd like to write to
	$write_vec = new IO::Select;
	$write_vec->add($mainproc);
	
	# give connection time to come up
	$self->printLog("Waiting for server connection to come up");
	$connect_timeout = time + CONNECT_TIMEOUT;
	while ((! $connection->connected()) && (time < $connect_timeout))
	{
		usleep(200);
	}
	
	# if we couldn't connect to the server, say why and dump out
	if (time >= $connect_timeout)
	{
		my $err = "Connection timed out";
		$self->printErr($err);
		exit(-1);
	}
	elsif (! $connection->connected())
	{
		my $err = "Couldn't connect to $remote: $!";
		$self->printErr($err);
		exit(-1);
	}
	$self->printLog("Connected to $remote");

	# set up a signal handler for the TERM signal which will set the shutting-down
	# flag, causing our main loop to terminate on the next go-around
	$SIG{TERM} = sub { $shutting_down = 1; };

	# process messages until we recieve the shut-down signal
	$self->printLog("Entering main loop");
	while (! $shutting_down)
	{
		my $read_ready_ref;	# reference to a list of handles ready to be read
		my $write_ready_ref; # reference to a list of handles ready to be written
		my $handle;

		# select on our i/o handles with a timout so we can also respond to
		# shut-down event
		($read_ready_ref, $write_ready_ref) = IO::Select::select($read_vec,
		                                                         $write_vec,
		                                                         undef,
		                                                         500);
		
		# process the handles which are ready to be read
		foreach $handle (@$read_ready_ref)
		{
			Carp::confess("Undefined handle") unless defined($handle);
			# send any outgoing messages
			if ($handle == $mainproc)
			{
				my $msg;

				# process one message at a time
				$msg = <$handle>;
				next unless ($msg && ($msg =~ /[\w\d]/));
				
				$self->printLog("Sending outgoing message");
				print($connection $msg . EOL);

				next;
			}

			my $raw_message;	# single JSON message		 
			my $msg_ref;  # reference to de-serialzed message;
			
			# we only have two filehandles we're selecting on; if we got here, it
			# means that the socket has data waiting for us, and a read on it won't
			# block
			$raw_data .= <$connection>;
			# see if we've got a whole line -- if so, cut the line into $raw_message leaving
			# the left-overs in $raw_data.
			next unless ( $raw_data =~ s/^([^\r]+)\r\n// );
			
			$raw_message = $1;
			
			$self->printLog("Got message $raw_message")
			  if ($self->{'debug'});
			
			# If this message contains the string "ping-request", decode it, make sure that
			# it is a ping request, and respond if it is.
			if ($raw_message =~ /ping-request/i)
			{
				my $msg_ref;

				# decode the message
				$msg_ref = $self->decodeMessage($raw_message);
				
				# make sure that we were able to decode it and that it's valid
				if (! (defined($msg_ref) && $self->msgIsDEMONIC($msg_ref)))
				{
					$self->printErr("Unable to decode message that looks like a ping request");
					next;
				}
				
				if (lc($msg_ref->{'identifier'}) eq 'ping-request')
				{
					$self->printLog("Responding to ping from server");
					# can't use sendMessage here because router_socket isn't defined in this process
					print($connection
					      encode_json($self->makeMessage( 'identifier' => 'ping-response' ) )
					      . EOL );
					next;
				}
			}

			# Otherwise, just buffer it for forwarding to the main process
			$self->printLog("Buffering incoming message for application layer (" .
			                ($#messages_for_parent + 2) . " queued)");
			push(@messages_for_parent, $raw_message);
			
			# set up socket to parent to be tested for write-readyness, now that
			# we have something to write to it (if it isn't already in the write
			# vector, of course)
			$write_vec->add($mainproc);
		}
				
		# process handles which are ready to be written
		foreach $handle (@$write_ready_ref)
		{
			# if parent process is ready for a message and we've got at least one
			# for it, send it one
			if ($handle == $mainproc)
			{
				if ($#messages_for_parent >= 0)
				{
					$self->printLog("Forwarding message to application layer (" .
					                $#messages_for_parent . " remaining in queue)");
#					$self->printLog("Message: $messages_for_parent[0]");
					print($handle $#messages_for_parent . "|" . shift(@messages_for_parent) . "\n");
				}
				else
				{
					# de-register socket to main process from list of handles
					# which will un-block us when they're ready to read
					$write_vec->remove($mainproc);
				}
			}
		}
	}
	
	# close up shop
	$self->printLog("Shutting down");
	delete($self->{'router_pid'});
	$connection->close();
	$mainproc->close();
	$unixsocket->close();
	unlink($self->{'router_fifo'});
}

## @method void reqAvailableStreams()
# Queries the connected server for a fresh list of available streams.
# Does not wait for a response (non-blocking).
sub reqAvailableStreams()
{
	my $self = shift || Carp::confes("Object method called as static");
	
	return if (! $self->connected());
	
	$self->printLog("Requesting available streams");
	
	$self->sendMessage($self->makeMessage( 'identifier' => 'status' ));
}

## @method @streams readAvailableStreams()
# Returns the cached list of available streams.	 Doesn't request a status update,
# so the returned list may be out-of-date.
#
# @return In list context, a ist of available streams; in scalar context, the
# number of available streams.
sub readAvailableStreams()
{
	my $self = shift;

	$self->printLog("Reading available streams");
	
	# keys() checks wantarray for us, so we don't have to in order to return
	# a contextual answer (list or number)
	return ( keys(%{$self->{'available_streams'}}) > 0) ? keys(%{$self->{'available_streams'}}) : ();
}
	
## @method @streams availableStreams()
# Returns a list of streams which are available from the server to which we
# are connected.	This call may block if available stream data has not yet
# arrived or is deemed out-of-date.	 Use reqAvailableStreams() and readAvailableStreams()
# to request and read the list of available streams in a non-blocking manner.
#
# @return In list context, list of available streams.	 In scalar context, the number
# of available streams.	 If there was an error, undef.
sub availableStreams()
{
	my $self = shift;
	my $spins = 0;
	
	# make sure our message queue is clear (only wait one second before timing out)
	$self->processMessages(0.1);
	
	# if our status info is out of date, request an update and wait
	if ((! exists($self->{'last_general_status'})) ||
		 ( $self->{'last_general_status'} < (time - STATUS_LIFETIME) ))
	{
		$self->printLog("Refreshing status information");
		$self->reqAvailableStreams();

		while ( ($spins < 2) &&
				  ( ( ! exists($self->{'last_general_status'}) ) ||
					 ( $self->{'last_general_status'} < (time - STATUS_LIFETIME) ) ) )
		{
			if (! $self->processMessages())
			{
				$self->printLog("Waiting for status update");
				sleep(1);
				$spins++;
			}
		}
		
		if ($spins == 2)
		{
			$self->printErr("Timed-out while waiting for status update");
		}
	}
	
	return($self->readAvailableStreams());
}

## @method void reqOpenStream($stream_name, $perms)
# Requests that the indicated stream be opened with the indicated permissions.
# If no permissions are specified, the stream will be requested opened read-only.
# Does not wait for a reply.
#
# @arg stream_name The name of the stream to open
# @arg perms A string containing any combination of "read" and "write"
sub reqOpenStream($;$)
{
	my $self = shift;
	my $streamname = uc(shift);
	my $perms = shift || 'read';
	
	# don't try to open without a connection
	return() unless ($self->connected());
	# don't try to open streams that aren't available
	return() unless exists($self->{'available_streams'}->{$streamname});
	
	$self->printLog("Requesting open on stream $streamname with permissions [$perms]");
	
	$self->sendMessage( $self->makeMessage( 'identifier' => 'open',
														 'stream'	  => $streamname,
														 'mode'		  => $perms ) );
}

## @method void reqCloseStream($stream_name)
# Requests that a given stream be closed.	 Does not wait for a response (non-blocking).
sub reqCloseStream($)
{
	my $self = shift;
	my $stream = shift;
	
	return() unless ($self->connected());
	
	$self->printLog("Requesting close on stream $stream");
	
	$self->sendMessage( $self->makeMessage( 'identifier' => 'close',
														 'stream' => $stream ) );
}

## @method boolean subscribe($stream_name, $mode)
# Subscribe to a given stream.
# Given the name of a stream, attempts to subscribe to that stream using whatever
# permissions are supplied.  If no permissions are supplied, the stream will be
# opened read-only.	This call will block until either RESPONSE_TIMEOUT seconds
# have passed, or until the server returns some response to the subscription
# request.
#
# @par Permissions
# Permissions are any combination of 'read' and 'write'.	 If a stream is opened
# write-only, no data will be recieved from that stream but writing will be possible.
# Attempts to read a write-only stream will not cause an error; there will simply not
# be any data to read.	However, an attempt to write to a read-only stream will result
# in an error.
#
# @arg stream_name the name of the stream to open
# @arg mode the mode in which to open the stream (read|write|read-write)
#
# @return true if the stream was subscribed-to, false if the subscription action
# failed.
sub subscribe($;$)
{
	my $self = shift || Carp::confess("Object method called as static");
	my $stream = shift || Carp::confess("No stream name supplied");
	my $mode = shift || 'read';
	my $spintime;
	my @modelist;
	my $retval = 0;
	
	$self->printLog("Subscribing to stream $stream using mode \"$mode\"");
	
	# make sure stream info is up to date
	$self->availableStreams(1);
	
	if (! (defined($stream) && exists($self->{'available_streams'}->{$stream})))
	{
		$self->{'error_str'} = "Stream $stream doesn't exist";
		return(0);
	}
	
	$self->reqOpenStream($stream, $mode);
	# process messages until either we time out or we get a message back
	$spintime = time + $self->{'TIMEOUT'};
	while ((time <= $spintime) && (! $self->processMessages())) { sleep(1); };
	
	if (! exists($self->{'subscribed_streams'}->{$stream}))
	{
		$self->printLog("Failed to subscribe to stream $stream");
		return(0);
	}
	
	my @missing_perms;
	$retval = 1;
	
	@modelist = split(/[-,\s]+/, $mode);
	# look through the permission list and make sure that what we requested
	# is there
	foreach $mode (@modelist)
	{
		if (! (grep { uc($_) eq uc($mode) } split(/\s+/, $self->{'subscribed_streams'}->{$stream})))
		{
			push(@missing_perms, $mode);
		}
	}
	if ($#missing_perms >= 0)
	{
		my $sayso = "Failed to open stream $stream with permissions " .
						join(', ', @missing_perms);
		$retval = 0;
		$self->{'error_str'} = $sayso;
		$self->printLog($sayso);
	}

	return($retval);
}

## @method $data readStream($stream_name)
# Reads the indicated stream.	 If there's nothing to be read, returns undef.
# Blocks for one second.
sub readStream($)
{
	my $self = shift;
	my $stream = shift || Carp::confess("No stream name given");
	my $data;
	
	$self->processMessages(0.3);
	
	# grab any data for the requested stream
	$data = $self->{'stream_data'}->{$stream};
	
	# if there wasn't any, we have nothing to do
	return(undef) unless ($data);
	
	# reset the stream's output buffer
	$self->{'stream_data'}->{$stream} = "";

	# if we've been asked to timestamp lines, do so.
	if ($self->{'timestamp_data'})
	{
		my $timestamped = "";
		my @now;
		
		# if the data's timestamped, use the timestamp on the data
		# to generate our log timestamp. otherwise, use the current time.
# 		if (exists($data->{'time'}))
# 		{
# 			@now = localtime($data->{'time'});
# 		}
# 		else
# 		{
 			@now = localtime();
# 		}

      # if we get any carriage return in the data replace
      # with blank and for any new line character replace it 
      # with new line and timestamp. Since we need to print
      # timestamp in newline everytime
      
      $data =~ s/\r//g;
      $timestamped = strftime($self->{'timestamp_fmt'}, @now);
      $data =~ s/\n/\n$timestamped/g;
	}
	
	return($data);
}

## @method boolean writeStream($stream_name, $data)
# Writes the given data to the indicated stream.
# Doesn't wait for confirmation of the write from the server.
#
# If the indicated stream isn't open with write permissions, call will
# fail without doing anything.
#
# @return true if the given data was successfully sent to the stream, and
# false otherwise.
sub writeStream($$)
{
	my $self = shift;
	my $stream_name = shift || Carp::croak("No stream name provided");
	my $data = shift || Carp::croak("No data provided");
	
	return(0) unless (exists($self->{'subscribed_streams'}->{$stream_name}) &&
	                  $self->{'subscribed_streams'}->{$stream_name} =~ /write/);
		
	$self->sendMessage($self->makeMessage( 'stream'     => $stream_name,
	                                       'identifier' => 'write',
	                                       'data'       => $data . EOL) );
	
	return(1);
}

## @method static private void handleDeadKid(signame)
# This method is supposed to be called as the handler for the CHLD signal.
# It waits for the child to return and cleans up our state to indicate that
# the router is no longer running.
#
# Closes pipes to router and deletes router PID record
sub handleDeadKid
{
	my $self = $PID_object{$$};
	my $kidpid;

	$self->printLog("Called on signal " . shift);
	
	# only run in contexts where we've got a mapping from PID to the object
	# on which we should operate
	if (! defined($self))
	{
		Carp::cluck("Unable to find object ID for caller");
		return;
	}
	
	# wait() in a loop, in case the router happens to spawn any external
	# processes for which we get signalled on their completion
	while (1)
	{
		# do our wait() inside of an eval so that we can time it out with an
		# alarm signal if it blocks
		eval
		{
			local $SIG{ALRM} = sub { die "alarm\n" };
			alarm(1);
			$kidpid = wait();
			alarm(0);
		};
		# return if wait blocked
		if ($@ eq "alarm\n")
		{
			Carp::cluck("Failed to collect completed child process");
			return;
		}
		return if ((! defined($kidpid)) || ($kidpid == -1));
		# loop if the PID of the completed process isn't that of the router
		next unless ($kidpid == $self->{'router_pid'});
		
		# clean up reference to defunct router PID
		delete($self->{'router_pid'});
		# close our connection to the (now-defunct) router and clean up
		# any references to the backing FIFO
		$self->{'router_socket'}->close() if ($self->{'router_socket'});
		delete($self->{'router_socket'});
		unlink($self->{'router_fifo'}) if (-e $self->{'router_fifo'});
		delete($self->{'router_fifo'});
		
		$self->printLog("Cleaned up after child PID $kidpid");
	}
}

## @method $error getError()
# Returns a description of the latest error to have occurred.
sub getError()
{
	my $self = shift;
	my $error_string = "";
	
	if ($self->{'error_str'})
	{
		$error_string .= $self->{'error_str'};
		$self->{'error_str'} = "";
	}

	{
		lock(@{$self->{'errors'}});
		$error_string .= '[ ' . join('; ', @{$self->{'errors'}}) . ' ]' if ($#{$self->{'errors'}} >= 0);
		@{$self->{'errors'}} = ();
	}
	
	return($error_string);
}

## @method private void printLog($)
# Prints the given message to whatever log filehandle we're using (if any).
# If no filehandle is set up, returns without doing anything.
sub printLog($)
{
	my $self = shift;
	my $fh = $self->{'log_fh'} || return;
	my $calledme = (caller(1))[3];
	
	return() unless (($self->{'verbose'} || $self->{'debug'}) && ($fh) && $fh->opened());
	
	# don't report printErr as our caller if it's calling us; report whoever
	# called it
	$calledme = (caller(2))[3] if ($calledme =~ /printErr/);

	# print our package name plus the name of the routine which called us
	printf($fh "%s (%05d) %s: %s\n",
	       strftime($self->{'timestamp_fmt'}, localtime()),
	       $$,
	       $calledme,
	       shift(@_));
}

## @method private void printErr($)
# Prints the given string to STDERR and then passes it to printLog().
sub printErr($)
{
	my $self = shift;
	my $msg = shift;
	
	print(STDERR Carp::longmess($msg));
	$self->printLog($msg);
}

1;

__END__

=head1 NAME

Consoled Client Library

=head1 SYNOPSIS

Provides an object-oriented, asynchronous interface to a consoled server.

use ConsoleClient;

my $cc = new ConsoleClient();

=head1 DESCRIPTION

This module provides an asynchronous interface to a consoled server.
Connnection with the server is maintained in a child process, and communication
with the parent process is done via pipes.

Actual message-processing is done within the parent process, within the name-
space of the client library.

=head1 AUTHOR

Catherine Mitchell

=cut
