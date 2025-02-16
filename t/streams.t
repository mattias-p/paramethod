#!/usr/bin/env perl
use v5.20;
use warnings;
use Test::More;

use Carp              qw( confess );
use My::Streams       qw( empty singleton interleave flatmap tee action iterate );
use My::Streams::Util qw( $END );
use MyTest::Handler;
use Readonly;
use Scalar::Util      qw( blessed );
use Test::Differences qw( eq_or_diff );
use Test::Exception;
use Test::MockObject::Extends;
use Test::MockObject;

Readonly my $ONE => [];

sub left {
    my ( $left, undef ) = @_;

    return $left;
}

sub right {
    my ( undef, $right ) = @_;

    return $right;
}

sub both {
    my ( $left, $right ) = @_;

    return $left | $right;
}

sub left_copy {
    my ( $source ) = @_;
    return sub {
        ( $source, my $copy ) = tee( $source );
        return $copy;
    };
}

sub right_copy {
    my ( $source ) = @_;
    return sub {
        ( my $copy, $source ) = tee( $source );
        return $copy;
    };
}

sub zero {
    return empty();
}

sub one {
    return singleton();
}

sub two {
    return singleton() | singleton();
}

sub test_string {
    my ( $name, $expected_stringify, $expected_pretty, $stream ) = @_;

    my $actual_stringify = "$stream"       =~ s/\t[(][^)]*[)]$//r;
    my $actual_pretty    = $stream->pretty =~ s/\t[(][^)]*[)]//gr;

    eq_or_diff {
        stringify => $actual_stringify,
        pretty    => $actual_pretty,
      },
      {
        stringify => $expected_stringify,
        pretty    => $expected_pretty,
      }, $name;
}

sub test_flush_to_end {
    my ( $name, $expected, $stream ) = @_;
    lives_and {
        my @actual;
        $stream->flush( sub { push @actual, $_[0] } );
        eq_or_diff \@actual, $expected, "$name / result";
        is( blessed( $stream ), 'My::Streams::ExhaustedStream', "$name / class" )
          or diag $stream->pretty;
    }
    $name;
}

sub test_collect {
    my ( $name, $expected, $stream ) = @_;

    if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'invalid stream';
    }

    lives_and {
        my $orig_class = blessed( $stream );
        my @actual     = $stream->collect();
        eq_or_diff \@actual, $expected, "$name / result";
        is( blessed( $stream ), 'My::Streams::ExhaustedStream', "$name / class" )
          or diag $stream->pretty;
    }
    $name;
}

sub test_flush {
    my ( $name, $expected, $stream ) = @_;
    lives_and {
        my @actual;
        my $orig_class = blessed( $stream );
        $stream->flush( sub { push @actual, $_[0] } );
        eq_or_diff \@actual, $expected, "$name / result";
        is( blessed( $stream ), $orig_class, "$name / class" )
          or diag $stream->pretty;
    }
    $name;
}

sub test_tee {
    my ( $name, $source, $make_sink, $expected ) = @_;

    my $stream = $make_sink->( tee( $source ) );

    lives_and {
        my @actual;
        $stream->flush( sub { push @actual, $_[0] } );
        eq_or_diff \@actual, $expected, "$name / result";
        is( blessed( $stream ), 'My::Streams::ExhaustedStream', "$name / class" )
          or diag $stream->pretty;
    }
    $name;

}

sub test_traverse {
    my ( $name, $stream, $handlers, $expected ) = @_;

    my $class   = blessed $stream;
    my %methods = (
        flush   => \&{"${class}::flush"},
        refresh => "My::Streams::StreamBase::refresh",
        _sleep  => "My::Streams::StreamBase::_sleep",
    );

    my @sequence;
    my $mock = Test::MockObject::Extends->new( $stream );
    for my $method ( keys %methods ) {
        $mock->mock(
            $method,
            sub {
                push @sequence, $method;
                no strict 'refs';
                return $methods{$method}->( @_ );
            }
        );
    }

    $mock->traverse_end(
        sub {
            push @sequence, $_[0];
        },
        $handlers->@*,
    );

    eq_or_diff \@sequence, $expected, $name;
}

subtest 'presentation' => sub {
    my $player = Test::MockObject->new();
    $player->set_always( 'action_kind', 'play' );

    test_string "empty"           => "empty",        "empty\n",                                         empty;
    test_string "singleton"       => "singleton",    "singleton\n",                                     singleton();
    test_string "interleave"      => "interleave",   "interleave\n  empty\n  singleton\n",              empty | singleton();
    test_string "flatmap"         => "flatmap",      "flatmap\n  empty\n",                              flatmap { singleton() } empty;
    test_string "tee[0]"          => "memo-1#1",     "memo-1#1\n  empty\n",                             [ tee( empty ) ]->[0];
    test_string "tee[0] again"    => "memo-2#1",     "memo-2#1\n  empty\n",                             [ tee( empty ) ]->[0];
    test_string "interleave(tee)" => "interleave",   "interleave\n  memo-3#1\n    empty\n  memo-3#2\n", interleave( tee( empty ) );
    test_string "action"          => "action[play]", "action[play]\n",                                  action( 0, 'play' );
    test_string "tee(tee[0])[0]"  => "memo-4#1",     "memo-4#1\n  empty\n",                             [ tee( [ tee( empty ) ]->[0] ) ]->[0];
    test_string "tee(tee[1])[0]"  => "memo-5#2",     "memo-5#2\n  empty\n",                             [ tee( [ tee( empty ) ]->[1] ) ]->[0];
    test_string "tee(tee[0])[1]"  => "memo-6#3",     "memo-6#3\n  empty\n",                             [ tee( [ tee( empty ) ]->[0] ) ]->[1];
    test_string "tee(tee[1])[1]"  => "memo-7#3",     "memo-7#3\n  empty\n",                             [ tee( [ tee( empty ) ]->[1] ) ]->[1];
};

subtest 'empty' => sub {
    test_flush_to_end 'zero' => [ ( $ONE ) x 0, $END ], empty;
};

subtest 'singleton' => sub {
    test_flush_to_end 'one' => [ ( $ONE ) x 1, $END ], singleton();
};

subtest 'interleave' => sub {
    test_flush_to_end 'zero + zero'       => [ ( $ONE ) x 0, $END ], empty | empty;
    test_flush_to_end 'zero + one'        => [ ( $ONE ) x 1, $END ], empty | singleton();
    test_flush_to_end 'one + zero'        => [ ( $ONE ) x 1, $END ], singleton() | empty;
    test_flush_to_end 'one + one'         => [ ( $ONE ) x 2, $END ], singleton() | singleton();
    test_flush_to_end '(one + one) + one' => [ ( $ONE ) x 3, $END ], ( singleton() | singleton() ) | singleton();
    test_flush_to_end 'one + (one + one)' => [ ( $ONE ) x 3, $END ], singleton() | ( singleton() | singleton() );

};

subtest 'flatmap' => sub {
    test_flush_to_end 'bottom * zero'     => [ ( $ONE ) x 0, $END ], flatmap { die } empty;
    test_flush_to_end 'zero * one'        => [ ( $ONE ) x 0, $END ], flatmap { empty } singleton();
    test_flush_to_end 'one * zero'        => [ ( $ONE ) x 0, $END ], flatmap { singleton() } empty;
    test_flush_to_end 'one * one'         => [ ( $ONE ) x 1, $END ], flatmap { singleton() } singleton();
    test_flush_to_end '(one + one) * one' => [ ( $ONE ) x 2, $END ], flatmap { singleton() | singleton() } singleton();
    test_flush_to_end 'one * (one + one)' => [ ( $ONE ) x 2, $END ], flatmap { singleton() } singleton() | singleton();
    test_flush_to_end 'one * (one * one)' => [ ( $ONE ) x 1, $END ], flatmap { singleton() } flatmap { singleton() } singleton();
    test_flush_to_end
      '(one * one) * one' => [ ( $ONE ) x 1, $END ],
      (
        flatmap {
            flatmap { singleton() } singleton()
        }
        singleton()
      );
};

subtest 'tee' => sub {
    test_tee 'left tee zero'  => zero(), \&left,  [ ( $ONE ) x 0, $END ];
    test_tee 'left tee one'   => one(),  \&left,  [ ( $ONE ) x 1, $END ];
    test_tee 'left tee two'   => two(),  \&left,  [ ( $ONE ) x 2, $END ];
    test_tee 'right tee zero' => zero(), \&right, [ ( $ONE ) x 0, $END ];
    test_tee 'right tee one'  => one(),  \&right, [ ( $ONE ) x 1, $END ];
    test_tee 'right tee two'  => two(),  \&right, [ ( $ONE ) x 2, $END ];
    test_tee 'both tee zero'  => zero(), \&both,  [ ( $ONE ) x 0, $END ];
    test_tee 'both tee one'   => one(),  \&both,  [ ( $ONE ) x 2, $END ];
    test_tee 'both tee two'   => two(),  \&both,  [ ( $ONE ) x 4, $END ];

    {
        my @actual = two()->flatmap( left_copy( two() ) )->collect;
        eq_or_diff \@actual, [ ( $ONE ) x 4 ], "flatmap left copy";
    }

    {
        my @actual = two()->flatmap( right_copy( two() ) )->collect;
        eq_or_diff \@actual, [ ( $ONE ) x 4 ], "flatmap right copy";
    }

    {
        my @actual = two()->flatmap( right_copy( two() ) )->collect;
        eq_or_diff \@actual, [ ( $ONE ) x 4 ], "flatmap right copy";
    }

    {
        my $a      = singleton();
        my @actual = singleton()->flatmap_end( sub { ( $a, my $b ) = tee $a; $b } )->collect();
        eq_or_diff \@actual, [ ( $ONE ) x 2 ], "tee in mapper"
    }
};

subtest 'effects' => sub {
    test_traverse 'empty' => (    #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, $END ) ],
        [ 'flush', 'refresh', 'flush', $END ],
    );

    test_traverse 'delayed empty' => (    #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 1, $END ) ],
        [ 'flush', 'refresh', '_sleep', 'refresh', 'flush', $END ],
    );

    test_traverse 'singleton' => (        #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, [], 0, $END ) ],
        [ 'flush', 'refresh', 'flush', $ONE, $END ],
    );

    test_traverse 'delayed singleton 1' => (    #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 1, [], 0, $END ) ],
        [ 'flush', 'refresh', '_sleep', 'refresh', 'flush', $ONE, $END ],
    );

    test_traverse 'delayed singleton 2' => (    #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, [], 1, $END ) ],
        [ 'flush', 'refresh', 'flush', $ONE, 'refresh', 'flush', $END ],
    );

    test_traverse 'delayed singleton 3' => (    #
        action( 0, 'testing' ), [ MyTest::Handler->new( 'testing' )->expect( [] => 1, [], 1, $END ) ],
        [ 'flush', 'refresh', '_sleep', 'refresh', 'flush', $ONE, 'refresh', 'flush', $END ],
    );

    test_traverse 'interleave' => (             #
        ( action( 0, 'testing' ) | action( 0, 'testing' ) ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, [], 0, $END )->expect( [] => 0, [], 0, $END ) ],
        [ 'flush', 'refresh', 'flush', $ONE, $ONE, $END ],
    );

    test_traverse 'flatmap 1' => (              #
        empty()->flatmap_end( sub { action( 0, 'testing' ) } ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, $END ) ],
        [ 'flush', 'refresh', 'flush', $END ],
    );

    test_traverse 'flatmap 2' => (              #
        action( 0, 'testing' )->flatmap_end( sub { singleton() } ), [ MyTest::Handler->new( 'testing' )->expect( [] => 0, $END ) ],
        [ 'flush', 'refresh', 'flush', [], $END ],
    );

    test_traverse 'flatmap 3' => (
        action( 0, 'testing' )                    #
          ->flatmap_end( sub { singleton() } )    #
        ,
        [
            MyTest::Handler->new( 'testing' )     #
              ->expect( [] => 0, [], 0, $END )
        ],
        [ 'flush', 'refresh', 'flush', [], [], $END ],
    );

    test_traverse 'flatmap 4' => (
        action( 0, 'testing', 1 )                               #
          ->flatmap_end( sub { action( 0, 'testing', 2 ) } )    #
        ,
        [
            MyTest::Handler->new( 'testing' )                   #
              ->expect( [1] => 0, $END )                        #
              ->expect( [2] => 0, $END )
        ],
        [ 'flush', 'refresh', 'flush', 'refresh', 'flush', $END ],
    );

    test_traverse 'flatmap 5' => (
        action( 0, 'testing', 1 )                               #
          ->flatmap_end( sub { action( 0, 'testing', 2 ) } )    #
        ,
        [
            MyTest::Handler->new( 'testing' )                   #
              ->expect( [1] => 0, [],  0, $END )                #
              ->expect( [2] => 2, [1], 0, $END )                #
              ->expect( [2] => 1, [2], 0, $END )
        ],
        [ 'flush', 'refresh', 'flush', 'refresh', '_sleep', 'refresh', 'flush', [2], 'refresh', 'flush', [1], $END ],
    );
};

subtest 'iterate' => sub {
    test_collect 'identity' => (    #
        [ [1], [2], [3] ],
        iterate( sub { empty }, singleton( 1 ) + singleton( 2 ) + singleton( 3 ) ),
    );
};

# TODO: Add tests for exceptions when trying to consume the same stream multiple times.
# The empty stream stream is exempted from this requirement since it doesn't cause
# confusing behaviors, and the exception allows for an optimization of the implementation.

done_testing;
