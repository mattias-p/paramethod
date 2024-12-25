=head1 NAME

My::SequentialExecutor - Executes commands sequentially.

=cut

package My::SequentialExecutor;
use 5.016;
use warnings;

use My::Query;
use Readonly;
use Zonemaster::LDNS;

Readonly my %command_types => (
    'My::Query' => sub {
        my ( $query ) = @_;

        return Zonemaster::LDNS->new( $query->server_ip )->query( $query->name, $query->qtype );
    },
);

=head1 DESCRIPTION

A simple implementation of My::Executor that executes commands sequentially in
the foreground.

=head1 CONSTRUCTORS

=head2 new()

Construct a new instance.

    my $executor = My::SequentialExecutor->new;

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
    my ( $self, $command ) = @_;

    push @{ $self }, $command;

    return;
}

=head2 await()

Execute the next command and return its result.

=cut

sub await {
    my ( $self ) = @_;

    my $command = shift @{ $self };

    my $result = $command_types{ ref( $command ) }->( $command );

    return $command, $result;
}

1;
