package My::Streams::PreferDiscriminantsStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp              qw( confess );
use My::Streams::Util qw( $END );

sub _new {
    my ( $class, $upstream, @discriminants ) = @_;

    if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'invalid stream';
    }

    my %discriminants_hash;
    for my $discriminant ( @discriminants ) {
        if ( !defined $discriminant || ref $discriminant ne '' ) {
            confess 'all discriminants must be defined scalars';
        }
        $discriminants_hash{$discriminant} = undef;
    }

    $upstream->_attach();

    return My::Streams::StreamBase::_new(    #
        __PACKAGE__,
        2,
        \%discriminants_hash,
        $upstream,
        [],
    );
}

sub _discriminants {
    my ( $self ) = @_;

    return $self->[2];
}

sub _upstream {
    my ( $self ) = @_;

    return $self->[3];
}

sub _buffer {
    my ( $self ) = @_;

    return $self->[4];
}

sub _drop_buffer {
    my ( $self ) = @_;

    $self->@* = $self->@[ 0 .. 3 ];

    return;
}

sub upstreams {
    my ( $self ) = @_;

    return $self->_upstream;
}

sub stringify {
    my ( $self ) = @_;

    return "prefer_discriminants";
}

sub flush {
    my ( $self, $callback, $memos, $binds ) = @_;

    $self->_upstream->flush(
        sub {
            my ( $element ) = @_;

            if ( $element eq $END ) {
                return;
            }

            if ( exists $self->_discriminants->{ $element->[0] } ) {
                $callback->( $element );
                $self->_drop_buffer;
            }
            elsif ( my $buffer = $self->_buffer ) {
                push $buffer->@*, $element;
            }
        },
        $memos,
        $binds,
    );

    if ( $self->_upstream->is_exhausted ) {
        if ( my $buffer = $self->_buffer ) {
            for my $element ( $buffer->@* ) {
                $callback->( $element );
            }
        }

        $callback->( $END );
        $self->_become_exhausted;
    }

    return;
}

1;
