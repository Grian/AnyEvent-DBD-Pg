package AnyEvent::DBD::Pg;

use 5.008008; # don't use old crap without utf8
use common::sense 3;m{
	use strict;
	use warnings;
}x;
use Scalar::Util 'weaken';
use Carp;
use DBI;
use DBD::Pg ':async', 'PG_BYTEA';
use AE 5;
use Time::HiRes 'time';
{ package AnyEvent::DBD::Pg::BYTEA; };

=head1 NAME

AnyEvent::DBD::Pg - AnyEvent interface to DBD::Pg's async interface

=cut

our $VERSION = '0.03_06'; $VERSION = eval($VERSION);

=head1 SYNOPSIS

	use AnyEvent::DBD::Pg;
	
	my $adb = AnyEvent::DBD::Pg->new('dbi:Pg:dbname=test', user => 'pass', {
		pg_enable_utf8 => 1,
		pg_server_prepare => 0,
		quote_char => '"',
		name_sep => ".",
	}, debug => 1);
	
	$adb->queue_size( 4 );
	$adb->debug( 1 );
	
	$adb->connect;
	
	$adb->selectcol_arrayref("select pg_sleep( 0.1 ), 1", { Columns => [ 1 ] }, sub {
		my $rc = shift or return warn;
		my $res = shift;
		warn "Got <$adb->{qd}> = $rc / @{$res}";
		$adb->selectrow_hashref("select data,* from tx limit 2", {}, sub {
			my $rc = shift or return warn;
			warn "Got $adb->{qd} = $rc [@_]";
		});
	});
	
	$adb->execute("update tx set data = data;",sub {
		my $rc = shift or return warn;
		warn "Got exec: $rc";
		#my $st = shift;
		#$st->finish;
	});
	
	$adb->execute("select from 1",sub {
		shift or return warn;
		warn "Got $adb->{qd} = @_";
	});
	
	$adb->execute("insert into table_with_bytea(col) values (?::bytea)",
		{}, 
		$adb->bytea( $binary_data ),
		sub {
		shift or return warn;
		say STDERR "insert was successfull";
	});

	$adb->selectrow_array("select pg_sleep( 0.1 ), 2", {}, sub {
		shift or return warn;
		warn "Got $adb->{qd} = [@_]";
		$adb->selectrow_hashref("select * from tx limit 1", {}, sub {
			warn "Got $adb->{qd} = [@_]";
			$adb->execute("select * from tx", sub {
				my $rc = shift or return warn;
				my $st = shift;
				while(my $row = $st->fetchrow_hashref) { warn "$row->{id}"; }
				$st->finish;
				exit;
			});
		});
	});
	AE::cv->recv;

=cut

sub new {
	my ($pkg,$dsn,$user,$pass,$args,@args) = @_;
	$args ||= {};
	my $self = bless {@args},$pkg;
	$self->{cnn} = [$dsn,$user,$pass,$args];
	$self->{id} = sprintf '%08x', int $self unless defined $self->{id};
	$self->{queue_size} = 2 unless defined $self->{queue_size};
	$self->{queue} = [];
	#$self->{current};
	#$self->connect;
	$self->{querynum}  = 0;
	$self->{queuetime} = 0;
	$self->{querytime} = 0;
	$self;
}

BEGIN {
	for my $method (qw( cnn queue_size debug )) {
		*$method = sub { @_ > 1 ? $_[0]->{$method} = $_[1] : $_[0]->{$method} }
	}
}

sub callcb($$@) {
	my ($cb,$err,@args) = @_;
	my $e;
	my $wa = wantarray;
	my ($rc,@rc);
	{
		local $@;
		eval {
			$@ = $err;
			$wa ? @rc = $cb->(@args) : $rc = $cb->(@args);
		1 } or $e = $@;
	}
	die $e if defined $e;
	$wa ? @rc : $rc;
}

sub _set_ka_timer {
	my $self = shift;
	$self->{ka} = AE::timer 30,30, sub {
		
	};
}

sub bytea{
    @_ == 1 ? ( bless \$_[0], "AnyEvent::DBD::Pg::BYTEA" ) : bless \$_[1], "AnyEvent::DBD::Pg::BYTEA";
}

sub connect {
	my $self = shift;
	my ($dsn,$user,$pass,$args) = @{ $self->{cnn} };
	local $args->{RaiseError} = 0;
	local $args->{PrintError} = 0;
	
	if( $self->{db} = DBI->connect($dsn,$user,$pass,$args) ) {
		#warn "connect $dsn $user {@{[ %$args  ]}} successful ";
		$self->{fh} = $self->{db}->{pg_socket} + 0;
		warn "Connection to $dsn established for pid $$\n" if $self->{debug} > 2;
		$self->{pid} = $$;
		$self->{lasttry} = undef;
		$self->{gone} = undef;
		return $self->{db}->ping;
	} else {
		#warn "connect $dsn $user {@{[ %$args  ]}} failed ";
		$self->{error} = DBI->errstr;
		$self->{gone} = time unless defined $self->{gone};
		$self->{lasttry} = time;
		warn "Connection to $dsn failed: ".DBI->errstr;
		return 0;
	}
}

our %METHOD = (
	selectrow_array    => 'fetchrow_array',
	selectrow_arrayref => 'fetchrow_arrayref',
	selectrow_hashref  => 'fetchrow_hashref',
	selectall_arrayref => sub {
		my ($st,$args) = @_;
		$st->fetchall_arrayref($args->{Slice});
	}, #'fetchall_arrayref',
	selectall_hashref  => 'fetchall_hashref',
	selectcol_arrayref => sub {
		my ($st,$args) = @_;
		$st->fetchall_arrayref($args->{Columns});
	},
	execute            => sub { $_[0]; }, # just pass the $st
);

sub DESTROY {}

sub _dequeue {
	my $self = shift;
	if ($self->{db}->{pg_async_status} == 1 ) {	
		warn "Can't dequeue (), while processing query ($self->{current}[0]) by @{[ (caller)[1,2] ]}";
		if ( @{ $self->{queue} } ) {
			warn "\tHave queue $self->{queue}[0][1]  $self->{queue}[0][2]";
		}
		return;
	}
	#warn "Run dequeue with status=$self->{db}->{pg_async_status}";
	return $self->{current} = undef unless @{ $self->{queue} };
	my $next = shift @{ $self->{queue} };
	my $at = shift @$next;
	$self->{queuetime} += time - $at;
	my $method = shift @$next;
	local $self->{queuing} = 0;
	$self->$method(@$next);
}

sub ping { my $self = shift; $self->{db} && $self->{db}->ping }

sub begin_work {
	my $self = shift;
	my $cb = pop;
	$self->execute("begin",$cb);
}

sub commit {
	my $self = shift;
	my $cb = pop || sub {};
	$self->execute("commit",$cb);
}

sub rollback {
	my $self = shift;
	my $cb = pop || sub {};
	$self->execute("rollback",$cb);
}

our $AUTOLOAD;
sub  AUTOLOAD {
	my ($method) = $AUTOLOAD =~ /([^:]+)$/;
	my $self = shift;
	die sprintf qq{Can't locate autoloaded object method "%s" (%s) via package "%s" at %s line %s.\n}, $method, $AUTOLOAD, ref $self, (caller)[1,2] # '
		unless exists $METHOD{$method};
	my $fetchmethod = $METHOD{$method};
	defined $fetchmethod or croak "Method $method not implemented yet";
	ref (my $cb = pop) eq 'CODE' or croak "need callback";
	
	$self->{pid} == $$ or warn("reestablish connection to database because of pid change from $self->{pid} to $$"), $self->connect;
	$self->{db} or $self->connect or return callcb( $cb,$self->{error} );
	
	if ($self->{db}->{pg_async_status} == 1 or $self->{current} ) {
		if ( $self->{queue_size} > 0 and @{ $self->{queue} } > $self->{queue_size} - 1 ) {
			my $c = 1;
			my $counter = ++$self->{querynum};
			printf STDERR "\e[036;1m$self->{id}/Q$counter\e[0m. [\e[03${c};1m%0.4fs\e[0m] < \e[03${c};1m%s\e[0m > ".("\e[031;1mQuery run out of queue size $self->{queue_size}\e[0m")."\n", 0 , $_[0];
			return callcb( $cb, "Query $_[0] run out of queue size $self->{queue_size}" );
		} else {
			warn "Query $_[0] pushed to queue because of ".( $self->{db}->{pg_async_status} == 1 ? 'async_status' : "current=$self->{current}" )."\n" if $self->{debug} > 1;
			push @{ $self->{queue} }, [time(), $method, @_,$cb];
			return;
		}
	}
	my $query = shift;
	my $args = shift || {};
	$args->{pg_async} = PG_ASYNC;
	my $counter = ++$self->{querynum};
	warn "prepare call <$query>( @_ ), async status = ".$self->{db}->{pg_async_status} if $self->{debug} > 2;
	$self->{current} = [$query,@_];
	$self->{current_start} = time();
	
	#weaken $self;
	$self or warn("self was destroyed"),return;
	my ($st,$w,$t,$check);
	my @watchers;
	push @watchers, sub {
		$self and $st or warn("no self"), @watchers = (), return 1;
		#warn time()." Callback $self->{db}->{pg_async_status} / ".$st->pg_ready();
		my $rs;
		{
			local $SIG{__WARN__} = sub {
				warn "$self->{id}: $query.pg_ready : @_";
			};
			$rs = $self->{db}->{pg_async_status} && $st->pg_ready();
		}
		
		if ($rs) {
			undef $w;
			my $res;
			{
				local $SIG{__WARN__} = sub {
					warn "$self->{id}: $query.pg_result : @_";
				};
				$res = $st->pg_result;
			}
			my $run = time - $self->{current_start};
			$self->{querytime} += $run;
			my ($diag,$DIE);
			if ($self->{debug}) {
				$diag = $self->{current}[0];
				my @bind = @{ $self->{current} };
				shift @bind;
				$diag =~ s{\?}{ "'".shift(@bind)."'" }sge;
			} else {
				$diag = $self->{current}[0];
			}
			if (!$res) {
				$DIE = $self->{db}->errstr;
			}
			local $self->{qd} = $diag;
			if ($self->{debug}) {
				my $c = $run < 0.01 ? '2' : $run < 0.1 ? '3' : '1';
				my $x = $DIE ? '1' : '6';
				printf STDERR "\e[036;1m$self->{id}/Q$counter\e[0m. [\e[03${c};1m%0.4fs\e[0m] < \e[03${x};1m%s\e[0m > ".($DIE ? "\e[031;1m$DIE\e[0m" : '')."\n", $run , $diag;
			}
			local $self->{queuing} = @{ $self->{queue} };
			if ($res) {
				undef $@;
				#local $@;eval {
				if (ref $fetchmethod) {
					$cb->($res, $st->$fetchmethod($args));
				} else {
					$cb->($res, $st->$fetchmethod);
					
					# my @res = $st->$fetchmethod;
					# undef $st;
					# $self->_dequeue();
					# $cb->($res, @res);
				}
				#1} or do { warn "call callback failed: $@"; die $@; };
				undef $st;
				undef $self->{current};
				$self->_dequeue();
				@watchers = ();
			} else {
				#local $@ = $DIE;
				#warn "st failed: $DIE";
				$st->finish;
				callcb($cb,$DIE);
				undef $st;
				undef $self->{current};
				@watchers = ();
				$self->_dequeue();
			}
			return 1;
		}
		return 0;
		#undef $w;
	};
	if (0 and $query =~ /^\s*begin(?:_work|)\s*$/i) {
		my $rc = eval { $self->{db}->begin_work;1 };
		$rc or warn;
		
			my ($diag,$DIE);
			if (!$rc) {
				$DIE = $@;
			}
			if ($self->{debug}) {
				$diag = $self->{current}[0];
				my @bind = @{ $self->{current} };
				shift @bind;
				$diag =~ s{\?}{ "'".shift(@bind)."'" }sge;
			} else {
				$diag = $self->{current}[0];
			}
			local $self->{qd} = $diag;
			if ($self->{debug}) {
				my $c = 2;
				my $x = $DIE ? '1' : '6';
				printf STDERR "\e[036;1m$self->{id}/Q$counter\e[0m. [\e[03${c};1m%0.4fs\e[0m] < \e[03${x};1m%s\e[0m > ".($DIE ? "\e[031;1m$DIE\e[0m" : '')."\n", 0 , $diag;
			}
		
		undef $self->{current};
		if($rc) {
			$cb->( '0E0' );
		} else {
			$cb->();
		}
		$self->_dequeue if @{ $self->{queue} };
		return;
	}
	
	use Time::HiRes 'time';
	#warn time()." call query $query";
	undef $@;
	$st = eval { $self->{db}->prepare($query,$args) }; # this could die with 'server closed the connection unexpectedly'
	my $return_err_cb = sub {
	    undef $st;
	    @watchers = ();
	    my $err = defined $@ && $@ ? "$@" : $self->{db}->errstr;
	    warn "prepare/execute failed: $@/" . $self->{db}->errstr . " = $err ";
	    callcb( $cb, $err );

	    $self->_dequeue;
	};
	if ( $st ){
	    for my $i ( 0..$#_ ){
                if ( UNIVERSAL::isa($_[ $i ], 'AnyEvent::DBD::Pg::BYTEA' )){
                    splice @_, $i, 1, ${$_[$i]};
                    $st->bind_param( $i + 1, undef, { pg_type => PG_BYTEA } );
                }
            };
            $st->execute( @_ ) or return $return_err_cb->();
	}
	else {
	    return $return_err_cb->();
	}
	#warn time()." call query $query done";
	# At all we don't need timers for the work, but if we have some bugs, it will help us to find them
	push @watchers, AE::timer 1,1, $watchers[0];
	push @watchers, AE::io $self->{fh}, 0, $watchers[0];
	$watchers[0]() and return;
	return;
}

=head1 METHODS

=over 4

=item connect()

Establish connection to database

=item selectrow_array( $query, [\%args], $cb->( $rc, ... ))

Execute PG_ASYNC prepare, than push result of C<fetchrow_array> into callback

=item selectrow_arrayref( $query, [\%args], $cb->( $rc, \@row ))

Execute PG_ASYNC prepare, than push result of C<fetchrow_arrayref> into callback

=item selectrow_hashref( $query, [\%args], $cb->( $rc, \%row ))

Execute PG_ASYNC prepare, than push result of C<fetchrow_hashref> into callback

=item selectall_arrayref( $query, [\%args], $cb->( $rc, \@rows ))

Execute PG_ASYNC prepare, than push result of C<fetchall_arrayref> into callback

=item selectall_hashref( $query, [\%args], $cb->( $rc, \@rows ))

Execute PG_ASYNC prepare, than push result of C<fetchall_hashref> into callback

=item selectcol_arrayref( $query, { Columns => [...], ... }, $cb->( $rc, \@rows ))

Execute PG_ASYNC prepare, than push result of C<fetchall_hashref($args{Columns})> into callback

=item execute( $query, [\%args], $cb->( $rc, $sth ))

Execute PG_ASYNC prepare, than invoke callback, pushing resulting sth to it.

=item bytea( $binary_data )

Bless binary data into form usefull for passing into Postgres

B<Please, note>: result already passed as first argument

=back

=head1 THANKS

=over 4

=item * Thanks to Ruslan Zakirov C<< <ruz@bestpractical.com> >> for hint about pg_socket option

=back

=head1 AUTHOR

Mons Anderson, C<< <mons@cpan.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Mons Anderson.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

=cut

1;
