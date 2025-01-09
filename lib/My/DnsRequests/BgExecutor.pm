package My::DnsRequests::BgExecutor;
use 5.016;
use warnings;

use parent 'My::Tasks::Executor';
use Carp qw(croak);
use Net::DNS;
use My::DnsRequests::Constants qw( $NO_RESPONSE );
use Scalar::Util               qw( looks_like_number );

sub new {
    my ( $class, %args ) = @_;

    if ( defined $args{timeout} && ( !looks_like_number( $args{timeout} ) || $args{timeout} <= 0 ) ) {
        croak "invalid argument: timeout";
    }

    my $self = {
        _clients     => {},
        _pending     => [],
        _index       => 0,
        _num_queries => 0,
        _timeout     => delete $args{timeout},
    };

    return bless $self, $class;
}

sub _mk_packet {
    my ( $self, $query ) = @_;

    my $packet = Net::DNS::Packet->new( $query->qname, $query->qtype );
}

sub submit {
    my ( $self, $id, $command ) = @_;

    croak "$command is not a My::DnsRequests::Command object" unless $command->isa( 'My::DnsRequests::Command' );

    my $server_ip = $command->{server_ip};

    $self->{_clients}{$server_ip} //= do {
        my $client = Net::DNS::Resolver->new( nameserver => $server_ip );

        if ( defined $self->{_timeout} ) {
            $client->tcp_timeout( $self->{_timeout} );
            $client->udp_timeout( $self->{_timeout} );
        }

        $client;
    };

    my $handle = $self->{_clients}{$server_ip}->bgsend( $command->new_packet );

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

        my ( $server_ip, $handle, $id, $command ) = @{ $self->{_pending}[ $self->{_index} ] };

        my $client = $self->{_clients}{$server_ip};

        if ( !$client->bgbusy( $handle ) ) {
            splice @{ $self->{_pending} }, $self->{_index}, 1;

            my $result = $client->bgread( $handle );
            $result //= $NO_RESPONSE;

            return $id, $command, [$result];
        }

        $self->{_index}++;
    }
}

1;

__END__

=head1 NAME

My::DnsRequests::BgExecutor - Execute My::DnsRequests::Command commands concurrently in the background.

=head1 DESCRIPTION

This implementation of L<My::Tasks::Executor> uses the bgsend/bgbusy/bgread API in Net::DNS to perform DNS queries specified by L<My::DnsRequests::Command> commands.

=head1 METHODS

=head2 new()

Creates a new instance of My::DnsRequests::BgExecutor.

=head2 submit($id, $command)

Submits a L<My::DnsRequests::Command> for execution. The DNS request is sent to the address specified in the command's server_ip attribute.

=head2 await()

Blocks until the next result is available. Returns a list containing the ID, the original command, and the DNS response.

=cut
