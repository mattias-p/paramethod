package My::Streams::FmapStream;
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

    return My::Streams::StreamBase::_new( $class, 2, $mapper, $upstream );
}

sub _mapper {
    my ( $self ) = @_;
    return $self->[2];
}

sub _upstream {
    my ( $self ) = @_;
    return $self->[3];
}

sub upstreams {
    my ( $self ) = @_;

    if ( defined $self->_upstream ) {
        return $self->_upstream;
    }

    return;
}

sub stringify {
    return "fmap";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    $self->_upstream->flush(
        sub {
            my ( $element ) = @_;

            if ( $element eq $END ) {
                $callback->( $END );
                $self->_become_exhausted;
            }
            else {
                my @mapped = $self->_mapper->( @$element );
                $callback->( \@mapped );
            }
        },
        $dups,
        $binds,
    );

    return;
}

1;
