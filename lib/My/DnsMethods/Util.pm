package My::DnsMethods::Util;
use v5.20;
use warnings;

use Exporter qw( import );

our @EXPORT_OK = qw(
  eq_domain
  get_addresses
  is_in_bailiwick
  is_referral_to
  is_valid_response
  ne_domain
);

sub eq_domain {
    my ( $a, $b ) = @_;

    return lc( $a =~ s/[.]$//r ) eq lc( $b =~ s/[.]$//r );
}

sub ne_domain {
    my ( $a, $b ) = @_;

    return lc( $a =~ s/[.]$//r ) ne lc( $b =~ s/[.]$//r );
}

# TODO: What are we supposed to check here?
sub is_valid_response {
    my ( $response ) = @_;

    return 1;
}

sub is_referral_to {
    my ( $response, $zone_name ) = @_;

    return
         ( $response->header->rcode eq 'NOERROR' )
      && ( !$response->header->aa )
      && ( grep { $_->type eq 'NS' } $response->authority )
      && ( !grep { $_->type eq 'NS' && ne_domain( $_->owner, $zone_name ) } $response->authority )
      && ( !grep { $_->type ne 'CNAME' } $response->answer )
      && ( !$response->answer || !grep { $_ eq 'CNAME' } $response->question );
}

sub is_in_bailiwick {
    my ( $domain, $bailiwick ) = @_;

    $domain    = lc $domain;
    $bailiwick = lc $bailiwick;

    # Remove trailing dots for uniformity
    $domain    =~ s/\.$//;
    $bailiwick =~ s/\.$//;

    # Check if the domain ends with the bailiwick
    return ( $domain eq $bailiwick || $domain =~ /\.\Q$bailiwick\E$/ ) ? 1 : 0;
}

sub get_addresses {
    my ( @rrs ) = @_;

    @rrs =
      sort { $a->address cmp $b->address }
      grep { $_->type eq 'A' || $_->type eq 'AAAA' } @rrs;

    my %glue;    # Unnamed in specification
    for my $rr ( grep { $_->type eq 'A' } @rrs ) {
        $glue{ $rr->owner } //= [];
        push @{ $glue{ $rr->owner } }, $rr->address;
    }
    for my $rr ( grep { $_->type eq 'AAAA' } @rrs ) {
        $glue{ $rr->owner } //= [];
        push @{ $glue{ $rr->owner } }, $rr->address;
    }

    return %glue;
}

1;
