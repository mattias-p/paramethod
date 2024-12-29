#!/usr/bin/env perl
use 5.016;

use My::CachingExecutor;
use My::Query qw( query );
use My::Scheduler qw( block_on );
use My::FifoExecutor;

sub lookup {
    my ( $qname ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        my $handler = sub {
            my ( $query, $packet ) = @_;

            if ( defined $packet ) {
                my $qname = lc $query->qname =~ s/([^.])$/$1./r;
                my $qtype = uc $query->qtype;

                for my $rr ( $packet->answer ) {
                    if ( lc $rr->owner eq $qname && uc $rr->type eq $qtype ) {
                        $scheduler->emit( $rr->address );
                    }
                }
            }
        };

        $scheduler->command( [], query( server_ip => '127.0.0.53', qname => $qname, qtype => 'A' ),    $handler, );
        $scheduler->command( [], query( server_ip => '127.0.0.53', qname => $qname, qtype => 'AAAA' ), $handler, );
    };
}

block_on(
    My::CachingExecutor->new( My::FifoExecutor->new ),
    sub {
        my ( $scheduler ) = @_;

        $scheduler->task(
            [],
            lookup( 'paivarinta.se' ),
            sub {
                my ( $result ) = @_;
                say $result;
            }
        );

    }
);
