=head1 NAME

My::Concurrent::Executor - An interface that abstracts command execution.

=cut

package My::Concurrent::Executor;
use 5.016;
use warnings;

=head1 DESCRIPTION

The My::Concurrent::Executor interface allows callers to execute commands, and it allows
implementations to use different execution strategies.

The interface itself is not thread-safe, though it may abstract multi-threaded
implementations.

The interface does not include any constructors.
Implementations are expected to provide constructors adapted to their own needs.

=head1 ABSTRACT METHODS

=head2 submit()

Request the execution of a L<My::Concurrent::Command>.

    $executor->submit( $id, $command );

Should never block.
Does not need to be thread-safe.

=cut

sub submit {
    my ( $self ) = @_;

    die ref($self) . " must implement submit()";
}

=head2 await()

Get the result of the next completed command.

    my ( $id, $command, $result ) = $executor->await();

Should block until there is a completed command to report.
Does not need to be thread-safe.

=cut

sub await {
    my ( $self ) = @_;

    die ref($self) . " must implement await()";
}

=head1 SEE ALSO

=over 4

=item L<My::Concurrent::Command>

=back

=cut

1;
