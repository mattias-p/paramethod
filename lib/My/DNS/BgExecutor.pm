package My::DNS::BgExecutor;
use 5.016;
use warnings;

use parent 'My::Concurrent::Executor';
use Carp qw(croak);
use Net::DNS;

sub new {
    my ( $class ) = @_;

    my $self = {
        _clients  => {},
        _pending  => [],
        _index    => 0,
        _num_queries => 0,
    };

    return bless $self, $class;
}

sub _mk_packet {
    my ( $self, $query ) = @_;

    my $packet = Net::DNS::Packet->new( $query->qname, $query->qtype );
}

sub submit {
    my ( $self, $id, $command ) = @_;

    croak "$command is not a My::DNS::Query object" unless $command->isa( 'My::DNS::Query' );

    my $server_ip = $command->{server_ip};

    $self->{_clients}{$server_ip} //= Net::DNS::Resolver->new( nameserver => $server_ip );
    my $client = $self->{_clients}{$server_ip};

    my $packet = $self->_mk_packet( $command );

    my $handle = $client->bgsend( $packet );

    push @{ $self->{_pending} }, [ $server_ip, $handle, $id, $command ];

    return;
}

sub await {
    my ( $self ) = @_;

    if ( !@{ $self->{_pending} } ) {
        croak "no commands to await";
    }

    while ( 1 ) {
        if ( $self->{_index} > $#{ $self->{_pending} } ) {
            $self->{_index} = 0;
        }

        my ( $server_ip, $handle, $id, $command ) = @{ $self->{_pending}[$self->{_index}] };

        my $client = $self->{_clients}{$server_ip};

        if ( !$client->bgbusy( $handle ) ) {
            my $packet = $client->bgread( $handle );

            splice @{ $self->{_pending} }, $self->{_index}, 1;

            return 'return', $id, $command, $packet;
        }

        $self->{_index}++;
    }
}

1;

__END__

=head1 NAME

My::DNS::BgExecutor - Execute My::DNS::Query commands concurrently in the background.

=head1 DESCRIPTION

This implementation of L<My::Concurrent::Executor> uses the bgsend/bgbusy/bgread API in Net::DNS to perform DNS queries specified by L<My::DNS::Query> commands.

=head1 METHODS

=head2 new()

Creates a new instance of My::DNS::BgExecutor.

=head2 submit($id, $command)

Submits a L<My::DNS::Query> for execution. The DNS request is sent to the address specified in the command's server_ip attribute.

=head2 await()

Blocks until the next result is available. Returns a list containing the ID, the original command, and the DNS response.

=cut
