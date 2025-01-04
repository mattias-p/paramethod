=head1 NAME

My::Concurrent::ExecutorProgress - Wraps an executor and prints progress to STDERR.

=cut 

package My::Concurrent::ExecutorProgress;
use 5.016;
use warnings;

use Carp qw( croak );
use Scalar::Util qw( blessed );

use parent 'My::Concurrent::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::Concurrent::ExecutorProgress->new( $inner_executor );

=cut

sub new {
    my ( $class, $executor ) = @_;

    my $obj = {
        _inner     => $executor,
        _completed => 0,
        _total     => 0,
    };

    return bless $obj, $class;
}

=head1 METHODS

=head2 submit()

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::Concurrent::Command' ) ) {
        croak "command argument to submit() must be a My::Concurrent::Command";
    }

    $self->{_total}++;
    $self->{_inner}->submit( $id, $command );

    return;
}

=head2 await()

=cut

sub await {
    my ( $self ) = @_;

    printf STDERR "  %d/%d\r", $self->{_completed}, $self->{_total};

    $self->{_completed}++;

    return $self->{_inner}->await;
}

1;
