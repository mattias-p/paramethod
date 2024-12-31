#!/usr/bin/env perl
use 5.016;
use warnings;
use Test::More;

use My::Scheduler qw( block_on );
use My::FifoExecutor;
use Test::Differences qw( eq_or_diff );
use Test::Exception;

my $executor = My::FifoExecutor->new;

subtest 'noop' => sub {
    lives_and {
        my @results = block_on( $executor, sub { } );
        eq_or_diff \@results, [];
    };
};

done_testing;
