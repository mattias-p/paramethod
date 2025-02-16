package My::Streams::SelectDiscriminantsStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp              qw( confess );
use My::Streams::Util qw( $END );
use Scalar::Util      qw( blessed );

sub _new {
    my ( $class, $stream, @discriminants ) = @_;

    if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'invalid stream';
    }

    my %discriminants_hash;
    for my $discriminant ( @discriminants ) {
        if ( !defined $discriminant || ref $discriminant ne '' ) {
            confess 'all discriminants must be defined scalars';
        }
        $discriminants_hash{$discriminant} = undef;
    }

    $stream->_attach();

    return My::Streams::StreamBase::_new( $class, 1, \%discriminants_hash, $stream );
}

sub _discriminants {
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
    return "select_discriminants";
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
            elsif ( @$element && exists $self->_discriminants->{ $element->[0] } ) {
                $callback->( $element );
            }
        },
        $dups,
        $binds,
    );

    return;
}

1;
