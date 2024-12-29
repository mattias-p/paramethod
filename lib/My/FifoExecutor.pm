=head1 NAME

My::FifoExecutor - Executes commands sequentially.

=cut

package My::FifoExecutor;
use 5.016;
use warnings;

use Carp qw( croak );
use My::Query;
use Readonly;
use Zonemaster::LDNS;

Readonly my %command_types => (
    'My::Query' => sub {
        my ( $query ) = @_;

        my $response = Zonemaster::LDNS->new( $query->server_ip )->query( $query->qname, $query->qtype );
        return $response;
    },
);

=head1 DESCRIPTION

A simple implementation of My::Executor that executes commands sequentially in
the foreground.

=head1 CONSTRUCTORS

=head2 new()

Construct a new instance.

    my $executor = My::FifoExecutor->new;

=cut

sub new {
    my ( $class ) = @_;

    return bless [], $class;
}

=head1 METHODS

=head2 submit()

Enqueue a command.

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !exists $command_types{ ref $command } ) {
        croak "unrecognized command type (" . ref( $command ) . ")";
    }

    push @{ $self }, [ $id, $command ];

    return;
}

=head2 await()

Execute the next command and return its result.

=cut

sub await {
    my ( $self ) = @_;

    if ( !@{$self} ) {
        croak "no commands to await";
    }

    my ( $id, $command ) = @{ shift @{$self} };

    my $result = $command_types{ ref $command }->( $command );

    return $id, $command, $result;
}

1;
