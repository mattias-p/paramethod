#!/usr/bin/env perl
use 5.016;

use My::ExecutorCache;
use My::ExecutorFilter;
use My::MethodsV2 qw( get_parent_ns_ip );
use My::ParExecutor;
use My::Scheduler qw( block_on );
use Time::HiRes qw( time );

my %config = (    #
    ipv6 => 0,
);

my $executor = My::ExecutorFilter->new( My::ExecutorCache->new( My::ParExecutor->new ), %config );

my $begin_time = time();

block_on(
    $executor,
    sub {
        my ( $scheduler ) = @_;

        $scheduler->handle(
            get_parent_ns_ip(
                'jprs.co.jp',
                [    #
                    '170.247.170.2',
                    '192.112.36.4',
                    '192.203.230.10',
                    '192.33.4.12',
                    '192.36.148.17',
                    '192.5.5.241',
                    '192.58.128.30',
                    '193.0.14.129',
                    '198.41.0.4',
                    '198.97.190.53',
                    '199.7.83.42',
                    '199.7.91.13',
                    '202.12.27.33',
                ],
            ),
            sub {
                my ( $result ) = @_;
                printf( "%8.2fs  %s\n", time() - $begin_time, $result );
            }
        );
    }
);
