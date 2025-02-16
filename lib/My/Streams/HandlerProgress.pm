
=head1 NAME

My::Streams::HandlerProgress - Wraps a handler and prints progress to STDERR.

=cut 

package My::Streams::HandlerProgress;
use 5.020;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp         qw( croak );
use Scalar::Util qw( blessed );

=head1 CONSTRUCTORS

=head2 new()

    my $handler = My::Streams::HandlerProgress->new( $inner_handler );

=cut

sub new {
    my ( $class, $handler ) = @_;

    my $obj = {
        _inner     => $handler,
        _completed => 0,
        _total     => 0,
    };

    return bless $obj, $class;
}

=head1 METHODS

=cut

sub action_kind {
    my ( $self ) = @_;

    return $self->{_inner}->action_kind;
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_inner}->new_id;
}

=head2 submit()

=cut

sub submit {
    my ( $self, @args ) = @_;

    $self->{_total}++;
    return $self->{_inner}->submit( @args );
}

=head2 poll()

=cut

sub poll {
    my ( $self ) = @_;

    printf STDERR "  %d/%d\r", $self->{_completed}, $self->{_total};
    $self->{_completed}++;

    return $self->{_inner}->poll;
}

1;
