#!/usr/bin/env perl
use 5.016;
use warnings;
use Test::More;

use My::Scheduler qw( block_on );
use My::FifoExecutor;
use Test::Differences qw( eq_or_diff );
use Test::Exception;

my $executor = My::FifoExecutor->new;

=pod

subtest 'noop' => sub {
    lives_and {
        my @results = block_on( $executor, sub { } );
        eq_or_diff \@results, [];
    };
};

subtest 'top level emit' => sub {
    lives_and {
        my @results = block_on(
            $executor,
            sub {
                my ( $scheduler ) = @_;

                $scheduler->emit( 123 );
                $scheduler->emit( 456 );
            }
        );

        eq_or_diff \@results, [ [123], [456] ];
    };
};

subtest 'task' => sub {
    lives_and {
        my @handled;
        my @returned = block_on(
            $executor,
            sub {
                my ( $scheduler ) = @_;

                my $bootstrap = sub {
                    $scheduler->emit( 123 );
                };

                my $handler = sub {
                    push @handled, \@_;
                    $scheduler->emit( 456 );
                };

                $scheduler->handle( $bootstrap, $handler );
            },
        );

        eq_or_diff                                              #
          { handled => \@handled, returned => \@returned, },    #
          { handled => [ [123] ], returned => [ [456] ], };
    };
};

subtest 'defer' => sub {
    lives_and {
        my @returned = block_on(
            $executor,
            sub {
                my ( $scheduler ) = @_;

                my $actionid = $scheduler->defer(
                    [],
                    sub {
                        $scheduler->emit( 123 );
                    }
                );
                $scheduler->defer(
                    [],
                    sub {
                        $scheduler->emit( 456 );
                    }
                );
            },
        );

        eq_or_diff                                                        #
          { returned => [ sort { $a->[0] <=> $b->[0] } @returned ], },    #
          { returned => [ [123], [456] ], };
    };
};

=cut

subtest 'dependency' => sub {
    lives_and {
        my @returned = block_on(
            $executor,
            sub {
                my ( $scheduler ) = @_;

                my $actionid = $scheduler->defer(
                    [],
                    sub {
                        $scheduler->emit( 123 );
                    }
                );
                $scheduler->defer(
                    [$actionid],
                    sub {
                        $scheduler->emit( 456 );
                    }
                );
            },
        );

        eq_or_diff                             #
          { returned => \@returned, },         #
          { returned => [ [123], [456] ], };
    };
};

done_testing;
