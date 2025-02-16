package My::Streams::FlatmapEndStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp                     qw( confess );
use My::Streams::EmptyStream qw( empty item_mapper );
use My::Streams::Util        qw( $END );
use Scalar::Util             qw( blessed );

sub _new {
    my ( $class, $mapper, $upstream ) = @_;

    if ( ref $mapper ne 'CODE' ) {
        confess 'mapper must be a coderef';
    }

    if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'mapper must be a stream';
    }

    $upstream->_attach();

    return My::Streams::StreamBase::_new( $class, 2, [], $mapper, $upstream );
}

sub _producers {
    my ( $self ) = @_;
    return $self->[2];
}

sub _mapper {
    my ( $self ) = @_;
    return $self->[3];
}

sub _upstream {
    my ( $self ) = @_;
    return $self->[4];
}

sub upstreams {
    my ( $self ) = @_;

    if ( defined $self->_upstream ) {
        return $self->_upstream;
    }

    return;
}

sub extras {
    my ( $self ) = @_;

    return $self->_producers->@*;
}

sub stringify {
    return "flatmap";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    $dups  //= {};
    $binds //= {};

    if ( my $upstream = $self->_upstream ) {
        $upstream->flush(
            sub {
                my ( $element ) = @_;

                my $stream = $self->_mapper->( $element );
                if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
                    confess sprintf 'mapper (%s) must return a stream', $self->origin;
                }

                $stream->_attach();
                push $self->_producers->@*, $stream;

                if ( $element eq $END ) {
                    $self->@* = $self->@[ 0 .. 2 ];
                }
            },
            $dups,
            $binds,
        );
    }

    my @done;
    for my $i ( 0 .. $self->_producers->$#* ) {
        $self->_producers->[$i]->flush(
            sub {
                my ( $element ) = @_;

                if ( $element eq $END ) {
                    push @done, $i;
                }
                else {
                    $callback->( $element );
                }
            },
            $dups,
            $binds,
        );
    }

    for my $i ( reverse sort { $a <=> $b } @done ) {
        splice $self->_producers->@*, $i, 1;
    }

    if ( !defined $self->_upstream && $self->_producers->@* == 0 ) {
        $callback->( $END );
        $self->_become_exhausted();
    }

    return;
}

1;
