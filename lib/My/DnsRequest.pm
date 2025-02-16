package My::DnsRequest;
use 5.016;
use warnings;

use Carp                      qw( confess );
use Exporter                  qw( import );
use My::Streams::ActionStream qw( action );
use Net::DNS;
use Readonly;

our @EXPORT_OK = qw(
  $NO_RESPONSE
  dns_request
  new_packet
);

Readonly our $NO_RESPONSE => 'NO_RESPONSE';

=head1 SUBROUTINES

Procedural helper to construct a new My::Streams::ActionStream instance.

    use My::DnsRequest qw( dns_request );

    my $command = dns_request( server_ip => '9.9.9.9', qname => 'iis.se', qtype => 'A' );

    my $command = dns_request( server_ip => '9.9.9.9', qname => 'iis.se', qtype => 'A', rd => 1 );

=cut

sub dns_request {
    my ( %args ) = @_;

    $args{rd} //= 0;

    my $server_ip = delete $args{server_ip} // confess 'missing argument: server_ip';
    my $qname     = delete $args{qname}     // confess 'missing argument: qname';
    my $qtype     = delete $args{qtype}     // confess 'missing argument: qtype';
    my $rd        = delete $args{rd};

    if ( %args ) {
        confess 'unrecognized attributes: ' . join( ', ', sort keys %args );
    }

    $qname = lc $qname =~ s/(.)\.$/$1/r;

    return action( 1, 'dns-request', $server_ip, $qname, $qtype, $rd );
}

sub new_packet {
    my ( $qname, $qtype, $rd ) = @_;

    my $packet = Net::DNS::Packet->new( $qname, $qtype );
    $packet->header->rd( $rd );

    return $packet;
}

1;
