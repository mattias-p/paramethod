
=head1 NAME

My::DnsRequest::ForegroundHandler - Executes commands sequentially.

=cut

package My::DnsRequest::ForegroundHandler;
use 5.016;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp              qw( croak );
use My::DnsRequest    qw( $NO_RESPONSE new_packet );
use My::Streams::Util qw( $END );
use Net::DNS;
use Scalar::Util qw( looks_like_number );

=head1 DESCRIPTION

A simple implementation of My::Streams::HandlerRole that executes commands sequentially in
the foreground.

=head1 CONSTRUCTORS

=head2 new()

Construct a new instance.

    my $handler = My::DnsRequest::ForegroundHandler->new;

=cut

sub new {
    my ( $class, %args ) = @_;

    $args{dns_port} //= 53;

    if ( defined $args{timeout} && ( !looks_like_number( $args{timeout} ) || $args{timeout} <= 0 ) ) {
        croak "invalid argument: timeout";
    }

    my $obj = {
        _dns_port => delete $args{dns_port},
        _timeout  => delete $args{timeout},
        _tasks    => [],
        _next_id  => 1,
    };

    return bless $obj, $class;
}

=head1 METHODS

=cut

sub action_kind {
    return 'dns-request';
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_next_id}++;
}

=head2 submit()

Enqueue a command.

=cut

use Data::Dumper;

sub submit {
    my ( $self, @args ) = @_;

    my $id = $self->new_id;
    push $self->{_tasks}->@*, [ $id, @args ];

    return $id;
}

=head2 poll()

Execute the next command and return its result.

=cut

sub poll {
    my ( $self ) = @_;

    if ( !@{ $self->{_tasks} } ) {
        croak "no commands to await";
    }

    my ( $id, $server_ip, $qname, $qtype, $rd ) = shift( $self->{_tasks}->@* )->@*;

    my $client = Net::DNS::Resolver->new(
        nameserver => $server_ip,
        port       => $self->{_dns_port},
        recurse    => 0,
    );
    if ( defined $self->{_timeout} ) {
        $client->tcp_timeout( $self->{_timeout} );
        $client->udp_timeout( $self->{_timeout} );
    }

    my $result = $client->send( new_packet( $qname, $qtype, $rd ) );
    $result //= $NO_RESPONSE;

    return $id, [$result], $id, $END;
}

1;
