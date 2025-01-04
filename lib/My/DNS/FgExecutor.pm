=head1 NAME

My::DNS::FgExecutor - Executes commands sequentially.

=cut

package My::DNS::FgExecutor;
use 5.016;
use warnings;

use parent 'My::Concurrent::Executor';

use Carp qw( croak );
use Net::DNS;
use Scalar::Util qw( looks_like_number );

=head1 DESCRIPTION

A simple implementation of My::Concurrent::Executor that executes commands sequentially in
the foreground.

=head1 CONSTRUCTORS

=head2 new()

Construct a new instance.

    my $executor = My::DNS::FgExecutor->new;

=cut

sub new {
    my ( $class, %args ) = @_;

    if ( defined $args{timeout} && ( !looks_like_number( $args{timeout} ) || $args{timeout} <= 0 ) ) {
        croak "invalid argument: timeout";
    }

    my $obj = {
        _timeout => delete $args{timeout},
        _tasks   => [],
    };

    return bless $obj, $class;
}

=head1 METHODS

=head2 submit()

Enqueue a command.

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::DNS::Query' ) ) {
        croak "command muts be a My::DNS::Query";
    }

    push @{ $self->{_tasks} }, [ $id, $command ];

    return;
}

=head2 await()

Execute the next command and return its result.

=cut

sub await {
    my ( $self ) = @_;

    if ( !@{ $self->{_tasks} } ) {
        croak "no commands to await";
    }

    my ( $id, $command ) = @{ shift @{ $self->{_tasks} } };

    my $client = Net::DNS::Resolver->new( nameserver => $command->server_ip, recurse => 0 );
    if ( defined $self->{_timeout} ) {
        $client->tcp_timeout( $self->{_timeout} );
        $client->udp_timeout( $self->{_timeout} );
    }

    my $result = $client->send( $command->new_packet );

    return 'return', $id, $command, $result;
}

1;
