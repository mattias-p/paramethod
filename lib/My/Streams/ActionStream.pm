package My::Streams::ActionStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp              qw( confess );
use Exporter          qw( import );
use My::Streams::Util qw( $END );

our @EXPORT_OK = qw(
  action
  is_action_kind
);

sub is_action_kind {
    my ( $kind ) = @_;

    return ref $kind eq '' && defined $kind && $kind =~ qr{^[a-z0-9-]+$};
}

sub action {
    my ( $origin_depth, $kind, @args ) = @_;

    if ( !is_action_kind( $kind ) ) {
        confess;
    }

    return My::Streams::ActionStream->_new( $origin_depth, $kind, @args );
}

sub _new {
    my ( $class, $origin_depth, $kind, @args ) = @_;

    return My::Streams::StreamBase::_new( $class, $origin_depth + 2, $kind, [@args], undef );
}

sub kind {
    my ( $self ) = @_;

    return $self->[2];
}

sub args {
    my ( $self ) = @_;

    return $self->[3]->@*;
}

sub _ready {
    my ( $self ) = @_;

    return $self->[4];
}

sub _init_ready {
    my ( $self ) = @_;

    $self->[4] = [];

    return;
}

sub upstreams {
    my ( $self ) = @_;

    return;
}

sub stringify {
    my ( $self ) = @_;

    return sprintf "action[%s]", $self->kind;
}

sub flush {
    my ( $self, $callback, undef, $perform ) = @_;

    if ( !defined $self->_ready ) {
        $self->_init_ready;
        $perform->( $self );
    }

    while ( my $element = shift $self->_ready->@* ) {
        $callback->( $element );
        if ( $element eq $END ) {
            $self->_become_exhausted;
            last;
        }
    }

    return;
}

1;
