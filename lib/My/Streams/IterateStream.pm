package My::Streams::IterateStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp                     qw( confess );
use My::Streams::EmptyStream qw( empty );
use My::Streams::Util        qw( $END );
use Scalar::Util             qw( blessed );

sub _new {
    my ( $class, $mapper, $upstream ) = @_;

    if ( ref $mapper ne 'CODE' ) {
        confess 'mapper must be a coderef';
    }

    if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'upstream must be a stream';
    }

    $upstream->_attach();

    return My::Streams::StreamBase::_new( $class, 2, [$upstream], $mapper );
}

sub upstreams_ref {
    my ( $self ) = @_;

    return $self->[2];
}

sub upstreams {
    my ( $self ) = @_;

    return $self->[2]->@*;
}

sub _mapper {
    my ( $self ) = @_;
    return $self->[3];
}

sub stringify {
    return "iterate";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    # Note: We keep flushing newly added upstreams here to fulfull the expectation of
    # traverse() to not having any more elements to produce without a refresh().
    # Consequently, an infinite stream here will starve other streams from producing.
    my $i = 0;
    while ( $i < $self->upstreams ) {
        $self->upstreams_ref->[$i]->flush(
            sub {
                my ( $element ) = @_;

                if ( $element eq $END ) {
                    return;
                }

                $callback->( $element );

                my $stream = $self->_mapper->( @$element );
                if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
                    confess sprintf 'mapper (%s) must return a stream', $self->origin;
                }
                push $self->upstreams_ref->@*, $stream;
            },
            $dups,
            $binds
        );

        if ( $self->upstreams_ref->[$i]->is_exhausted ) {
            splice $self->upstreams_ref->@*, $i, 1;
        }
        else {
            $i++;
        }
    }

    if ( !$self->upstreams ) {
        $callback->( $END );
        $self->_become_exhausted();
    }

    return;
}

1;
