package My::DnsRequests;
use 5.016;
use warnings;

use Exporter 'import';
use My::DnsRequests::Command;
use Readonly;

our @EXPORT_OK = qw( dns_request );

Readonly our $NO_RESPONSE => 'NO_RESPONSE';

=head1 SUBROUTINES

Procedural helper to construct a new My::DnsRequests::Command instance.

    use My::DnsRequests qw( dns_request );

    my $command = dns_request( server_ip => '9.9.9.9', qname => 'iis.se', qtype => 'A' );

    my $command = dns_request( server_ip => '9.9.9.9', qname => 'iis.se', qtype => 'A', rd => 1 );

=cut

sub dns_request {
    my ( %args ) = @_;

    return My::DnsRequests::Command->new( %args );
}

1;
