#!/usr/bin/env perl

use 5.010;
use strict;
use warnings;
use lib "$ENV{HOME}/ndn";

use IO::Socket::INET;
use Ndn::Common::Db;
use Ndn::Common::DateTime;

my $COLLECTD_HOST   = 'alc-stash-v100.dreamhost.com';
my $COLLECTD_PORT   = 2003;
my $COLLECTD_BUCKET = 'marketing.google.adwords';
# my $COLLECTD_BUCKET = 'test.joshua.google.adwords';
my $LAST_IMPORT     = '2014-07-22'; # date of last AdWords import
my $VERBOSE         = 0;

my $collectd  = get_collectd()       or die "Can't get collectd";
my $used      = get_used()           or die "Can't get used";
my $available = get_available($used) or die "Can't get available";
send_updates("$COLLECTD_BUCKET.used", $used);
send_updates("$COLLECTD_BUCKET.avail", $available);

exit;

# Returns: connected IO::Socket
#
sub get_collectd {
	my $collectd = IO::Socket::INET->new(
	    PeerAddr => $COLLECTD_HOST,
	    PeerPort => $COLLECTD_PORT,
	    Proto    => 'tcp',
	    Timeout  => 5,
	);
	return "Unable to connect: $!" unless $collectd->connected;
	return $collectd;
}

# Returns: [ [<date>, <int>], ... ]
#
sub get_used {
	my $db = Ndn::Common::Db->new('marketing') or die "Can't connect to db";
	my $sth = $db->prepare("select timestamp,count(*) as per_day from adwords group by timestamp");
	return $sth->fetchall_arrayref();
}

# Returns: [ [<date>, <int>], ... ]
#
sub get_available {
	my ($used) = @_;

	my $available;
	my $db = Ndn::Common::Db->new('marketing') or die "Can't connect to db";
	my $total_avail = $db->getvalue("select count(*) from adwords where timestamp>'$LAST_IMPORT' and expiry>now()");
	my $date = Ndn::Common::DateTime::Today();

	# Walk backward through time until the date of the last import,
	# storing each day's available adword count.
	#
	while ($date gt Ndn::Common::DateTime::AddDays($LAST_IMPORT, 1)) {
		$date = Ndn::Common::DateTime::AddDays($date, -1);

		my $avail = $db->getvalue("select count(*) from adwords where timestamp='$date' and expiry>now()");
		$total_avail += $avail if $avail;

		push @$available, [$date, $total_avail];
	}

	# return in sorted order.
	#
	return [ reverse @$available ];
}

sub send_updates {
	my ($bucket, $rows) = @_;

	for my $row (@$rows) {
		my ($date, $count) = @$row;
		next unless $date;
		$date = Ndn::Common::DateTime::ToUnix($date) if $date !~ /^\d{9,}$/;
		$count //= 0;
		my $update = "$bucket $count $date\n";
		print $update if $VERBOSE;
		$collectd->send($update)
			or warn "couldn't send '$update' to collectd";
	}
}

END {
	$collectd->shutdown(SHUT_RDWR)
		if $collectd && $collectd->connected;
}