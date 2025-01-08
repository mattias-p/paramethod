=head1 NAME

My::DnsRequests::ExecutorDiagnostics - Wraps an executor and prints diagnostics to STDERR.

=cut 

package My::DnsRequests::ExecutorDiagnostics;
use 5.016;
use warnings;

use Carp qw( croak );
use Scalar::Util qw( blessed );

use parent 'My::Tasks::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::DnsRequests::ExecutorDiagnostics->new( $inner_executor );

=cut

sub new {
    my ( $class, $executor, $stats_ref ) = @_;

    $stats_ref //= \my $dummy;

    $$stats_ref = {
        requests  => 0,
        responses => 0,
    };

    my $obj = {
        _inner => $executor,
        _stats => $$stats_ref,
    };

    return bless $obj, $class;
}

=head1 METHODS

=head2 submit()

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::DnsRequests::Command' ) ) {
        croak "command argument must be a My::DnsRequests::Command";
    }

    $self->{_inner}->submit( $id, $command );
    $self->{_stats}{requests}++;

    return;
}

=head2 await()

=cut

sub await {
    my ( $self ) = @_;

    my ( $op, $id, $command, $response ) = $self->{_inner}->await;

    if ( defined $response ) {
        $self->{_stats}{responses}++;
    }
    else {
        printf STDERR "no response from %s on %s query\n", $command->server_ip, $command->qtype;
    }

    return ( $op, $id, $command, $response );
}

1;
