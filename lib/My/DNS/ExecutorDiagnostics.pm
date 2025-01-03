=head1 NAME

My::DNS::ExecutorDiagnostics - Wraps an executor and prints diagnostics to STDERR.

=cut 

package My::DNS::ExecutorDiagnostics;
use 5.016;
use warnings;

use Carp qw( croak );
use Scalar::Util qw( blessed );

use parent 'My::Concurrent::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::DNS::ExecutorDiagnostics->new( $inner_executor );

=cut

sub new {
    my ( $class, $executor ) = @_;

    my $obj = { _inner => $executor, };

    return bless $obj, $class;
}

=head1 METHODS

=head2 submit()

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::DNS::Query' ) ) {
        croak "command argument must be a My::DNS::Query";
    }

    $self->{_inner}->submit( $id, $command );

    return;
}

=head2 await()

=cut

sub await {
    my ( $self ) = @_;

    my ( $op, $id, $command, $response ) = $self->{_inner}->await;

    if ( !defined $response ) {
        printf STDERR "no response from %s on %s query\n", $command->server_ip, $command->qtype;
    }

    return ( $op, $id, $command, $response );
}

1;
