package My::Streams::DieHandler;
use 5.020;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp qw( confess );

sub new {
    my ( $class, $action_kind ) = @_;

    my $self = {
        _next_id     => 1,
        _action_kind => $action_kind,
    };

    return bless $self, $class;
}

sub action_kind {
    my ( $self ) = @_;

    return $self->{_action_kind};
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_next_id}++;
}

sub submit {
    my ( $self, $server_ip, $qname, $qtype, $rd ) = @_;

    confess;
}

sub poll {
    my ( $self ) = @_;

    confess;
}

1;
