package My::Streams::UniqStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp              qw( confess );
use My::Streams::Util qw( $END );
use Scalar::Util      qw( blessed );

sub new {
    my ( $class, $fingerprint_set, $stream ) = @_;

    if ( !blessed $fingerprint_set || !$fingerprint_set->isa( 'My::Streams::FingerprintSet' ) ) {
        confess 'invalid fingerprint_set';
    }

    if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'invalid stream';
    }

    $stream->_attach();

    return My::Streams::StreamBase::_new( $class, 1, $fingerprint_set, $stream );
}

sub _fingerprint_set {
    my ( $self ) = @_;

    return $self->[2];
}

sub _upstream {
    my ( $self ) = @_;

    return $self->[3];
}

sub upstreams {
    my ( $self ) = @_;

    return ( $self->[3] );
}

sub stringify {
    return "uniq";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    $self->_upstream->flush(
        sub {
            my ( $element ) = @_;

            if ( $element eq $END ) {
                $callback->( $element );
                $self->_become_exhausted();
            }
            elsif ( $self->_fingerprint_set->insert( @$element ) ) {
                $callback->( $element );
            }
        },
        $dups,
        $binds,
    );

    return;
}

1;
