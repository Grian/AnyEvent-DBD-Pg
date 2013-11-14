#!/usr/bin/env perl

use lib::abs '../lib';
use Test::More;
use AnyEvent::DBD::Pg;
use DBI;

my @args = ('dbi:Pg:dbname=test', user => '', {
	pg_enable_utf8 => 1,
	pg_server_prepare => 0,
	quote_char => '"',
	name_sep => ".",
});

eval {
	local $args[-1]{RaiseError} = 1;
	my $dbi = DBI->connect(@args);
	warn $dbi;
	$dbi->disconnect;
	1;
} or 
eval {
	local $args[-1]{RaiseError} = 1;
	$args[1]=''; # user
	my $dbi = DBI->connect(@args);
	warn $dbi;
	$dbi->disconnect;
	1;
} or plan skip_all => "No test DB";

plan tests => 2;
my $cv = AE::cv;

my $adb = AnyEvent::DBD::Pg->new( @args, debug => 0);

$adb->connect;
$adb->selectrow_arrayref( "select length(?::bytea)", {}, $adb->bytea( v65.0.65 ), sub {
	ok shift(), 'execute with bytea';
	my $res = shift;
	is( $res->[0], 3, 'bytea passed successfully' );
	$cv->send();
});


$cv->recv;

