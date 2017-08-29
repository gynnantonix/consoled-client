#!/usr/bin/env perl

my $ID = '$Id$';

use strict;
use warnings;
use ConsoleClient;
use Pod::Usage;
use Getopt::Long;
use TestManager::Lib;

my $server;
my $verbose = 0;
my $help;
my $cc;

GetOptions
(
   'server|host=s'   => \$server,
   'verbose!'        => \$verbose,
   'help!'           => \$help
);

if ($help)
{
   printf($ID . "\n");
   pod2usage(0);
   exit(0);
}

STDOUT->autoflush(1) if ($verbose);

$server = shift(@ARGV) if ($#ARGV == 0);

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
	}
	else
	{
		$server = 'localhost';
	}

	print("Using consoled service at host [$server]\n") if ($verbose);
}
# if we were given a server to connect to, make sure that the hostname's OK
#elsif ($server !~ /^[\w\d\-\.]+/)
#{
#   print(STDERR "Strange hostname given: $server\n");
#   pod2usage(0);
#   exit(1);
#}

#print("Making sure consoled server on $server is alive...\n") if ($verbose);
#
#if (! ConsoleClient::checkServer($server))
#{
#   print("** Server not responding.\n") if ($verbose);
#   print(STDERR "Unable to contact consoled daemon on $server.\n");
#   exit(-1);
#}
#print("Server is responsive.\n") if ($verbose);


# fire up a new connection, and set quick_exit since we won't be
# opening any streams
print("Opening connection to $server...\n") if ($verbose);
$cc = new ConsoleClient( 'server'  => $server,
                         'verbose' => $verbose );

if (! ($cc && $cc->connected()))
{
   print("** Failed to start consoled client.\n") if ($verbose);
   print(STDERR "Unable to open connection to consoled on $server: $!\n");
   exit(-2);
}
print("Connected.\n") if ($verbose);

print(join("\n", $cc->availableStreams()) . "\n");

$cc->disconnect();

print("Done.\n") if ($verbose);

exit(0);


__END__

=head1 NAME

lscon - print a list of streams being served by a consoled server

=head1 SYNOPSIS

lscon <--verbose> [server_name]

For more information, please type C<perldoc lscon>

=head1 DESCRIPTION

Prints a newline-separated list of names of streams being served by
a consoled server.  If no server is given, uses localhost as the server.
If no server is found, prints an error and exits.
 
If --verbose is given, prints information about what's happening
to STDOUT.

=head1 AUTHOR

Catherine Mitchell

=cut
