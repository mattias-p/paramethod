#!/usr/bin/env perl
use 5.016;
use warnings;
use Test::More;

use My::Tasks::Scheduler qw( block_on );
use My::DnsRequests::FgExecutor;
use Test::Differences qw( eq_or_diff );
use Test::Exception;

my $executor = My::DnsRequests::FgExecutor->new;

lives_and {
    my @results = My::Tasks::Scheduler->new( $executor )->run;

    eq_or_diff \@results, [];
}
'noop';

subtest 'top level production' => sub {
    lives_and {
        my $scheduler = My::Tasks::Scheduler->new( $executor );
        $scheduler->produce( 123 );
        $scheduler->produce( 456 );

        my @results = $scheduler->run;

        eq_or_diff \@results, [ [123], [456] ];
    };
};

subtest 'task' => sub {
    lives_and {
        my $producer = sub {
            my ( $scheduler ) = @_;
            $scheduler->produce( 123 );
        };

        my @consumed;
        my $scheduler = My::Tasks::Scheduler->new( $executor );
        $scheduler->consume(
            $producer,
            sub {
                push @consumed, \@_;
                $scheduler->produce( 456 );
            }
        );

        my @returned = $scheduler->run;

        eq_or_diff                                                #
          { consumed => \@consumed, returned => \@returned, },    #
          { consumed => [ [123] ], returned => [ [456] ], };
    };
};

subtest 'defer' => sub {
    lives_and {
        my $scheduler = My::Tasks::Scheduler->new( $executor );
        $scheduler->defer(
            [],
            sub {
                $scheduler->produce( 123 );
            }
        );
        $scheduler->defer(
            [],
            sub {
                $scheduler->produce( 456 );
            }
        );

        my @returned = $scheduler->run;

        eq_or_diff                                                        #
          { returned => [ sort { $a->[0] <=> $b->[0] } @returned ], },    #
          { returned => [ [123], [456] ], };
    };
};

subtest 'dependency' => sub {
    lives_and {
        my $scheduler = My::Tasks::Scheduler->new( $executor );
        my $taskid    = $scheduler->defer(
            [],
            sub {
                $scheduler->produce( 123 );
            }
        );
        $scheduler->defer(
            [$taskid],
            sub {
                $scheduler->produce( 456 );
            }
        );

        my @returned = $scheduler->run;

        eq_or_diff                             #
          { returned => \@returned, },         #
          { returned => [ [123], [456] ], };
    };
};

done_testing;
