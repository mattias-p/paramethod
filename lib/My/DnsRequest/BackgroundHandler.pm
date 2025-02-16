package My::DnsRequest::BackgroundHandler;
use 5.020;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp              qw( confess croak );
use My::Streams::Util qw( $END );
use My::DnsRequest    qw( $NO_RESPONSE new_packet );
use Net::DNS;
use Scalar::Util qw( looks_like_number );

sub new {
    my ( $class, %args ) = @_;

    $args{dns_port} //= 53;

    if ( defined $args{timeout} && ( !looks_like_number( $args{timeout} ) || $args{timeout} <= 0 ) ) {
        croak "invalid argument: timeout";
    }

    my $self = {
        _clients  => {},
        _pending  => [],
        _index    => 0,
        _timeout  => delete $args{timeout},
        _dns_port => delete $args{dns_port},
        _next_id  => 0,
    };

    return bless $self, $class;
}

sub action_kind {
    my ( $self ) = @_;

    return 'dns-request';
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_next_id}++;
}

sub submit {
    my ( $self, $server_ip, $qname, $qtype, $rd ) = @_;

    my $id = $self->new_id;

    $self->{_clients}{$server_ip} //= do {
        my $client = Net::DNS::Resolver->new(
            nameserver => $server_ip,
            port       => $self->{_dns_port},
            recurse    => 0,
        );

        if ( defined $self->{_timeout} ) {
            $client->tcp_timeout( $self->{_timeout} );
            $client->udp_timeout( $self->{_timeout} );
        }

        $client;
    };

    my $handle = $self->{_clients}{$server_ip}->bgsend( new_packet( $qname, $qtype, $rd ) );

    push $self->{_pending}->@*, [ $server_ip, $handle, $id ];

    return $id;
}

sub poll {
    my ( $self ) = @_;

    if ( !$self->{_pending}->@* ) {
        confess "no pending actions";
    }

    while ( 1 ) {
        if ( $self->{_index} > $self->{_pending}->$#* ) {
            $self->{_index} = 0;
        }

        my ( $server_ip, $handle, $id ) = $self->{_pending}[ $self->{_index} ]->@*;

        my $client = $self->{_clients}{$server_ip};

        if ( !$client->bgbusy( $handle ) ) {
            splice $self->{_pending}->@*, $self->{_index}, 1;

            my $result = $client->bgread( $handle );
            $result //= $NO_RESPONSE;

            return $id, [$result], $id, $END;
        }

        $self->{_index}++;
    }
}

1;

__END__

=head1 NAME

My::DnsRequests::BackgroundHandler - Execute My::DnsRequests::Command commands concurrently in the background.

=head1 DESCRIPTION

This implementation of L<My::Tasks::Executor> uses the bgsend/bgbusy/bgread API in Net::DNS to perform DNS queries specified by L<My::DnsRequests::Command> commands.

=head1 METHODS

=head2 new()

Creates a new instance of My::DnsRequests::BackgroundHandler.

=head2 submit($id, $command)

Submits a L<My::DnsRequests::Command> for execution. The DNS request is sent to the address specified in the command's server_ip attribute.

=head2 await()

Blocks until the next result is available. Returns a list containing the ID, the original command, and the DNS response.

=cut
