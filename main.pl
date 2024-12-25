#!/usr/bin/env perl
use 5.016;

use My::CachingExecutor;
use My::Query qw( query );
use My::Scheduler qw( block_on );
use My::SequentialExecutor;

block_on(
    My::CachingExecutor->new( My::SequentialExecutor->new ),
    sub {
        my ( $scheduler ) = @_;

        my $query = query( server_ip => '9.9.9.9', qname => 'iis.se.', qtype => 'a' );

        $scheduler->submit(
            $query,
            sub {
                my ( $command, $result ) = @_;
                say $command;
                say $result->string;
            }
        );

        $scheduler->submit(
            $query,
            sub {
                my ( $command, $result ) = @_;
                say $command;
                say $result->string;
            }
        );
    }
);
