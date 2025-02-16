package My::DnsMethods::Zone;
use v5.20;
use warnings;

use Carp                 qw( croak );
use My::Streams          qw( concat empty interleave memoize singleton fingerprint_set );
use My::DnsMethods::Util qw( eq_domain get_addresses is_in_bailiwick is_referral_to is_valid_response ne_domain );
use My::DnsRequest       qw( $NO_RESPONSE dns_request );
use Readonly;

Readonly my %ROOT_NAME_SERVERS => (
    'a.root-servers.net' => [ '198.41.0.4',     '2001:503:ba3e::2:30' ],    # Verisign, Inc.
    'b.root-servers.net' => [ '170.247.170.2',  '2801:1b8:10::b' ],         # University of Southern California, Information Sciences Institute
    'c.root-servers.net' => [ '192.33.4.12',    '2001:500:2::c' ],          # Cogent Communications
    'd.root-servers.net' => [ '199.7.91.13',    '2001:500:2d::d' ],         # University of Maryland
    'e.root-servers.net' => [ '192.203.230.10', '2001:500:a8::e' ],         # NASA (Ames Research Center)
    'f.root-servers.net' => [ '192.5.5.241',    '2001:500:2f::f' ],         # Internet Systems Consortium, Inc.
    'g.root-servers.net' => [ '192.112.36.4',   '2001:500:12::d0d' ],       # US Department of Defense (NIC)
    'h.root-servers.net' => [ '198.97.190.53',  '2001:500:1::53' ],         # US Army (Research Lab)
    'i.root-servers.net' => [ '192.36.148.17',  '2001:7fe::53' ],           # Netnod
    'j.root-servers.net' => [ '192.58.128.30',  '2001:503:c27::2:30' ],     # Verisign, Inc.
    'k.root-servers.net' => [ '193.0.14.129',   '2001:7fd::1' ],            # RIPE NCC
    'l.root-servers.net' => [ '199.7.83.42',    '2001:500:9f::42' ],        # ICANN
    'm.root-servers.net' => [ '202.12.27.33',   '2001:dc3::35' ],           # WIDE Project
);

Readonly our %DNS_METHODS => (
    'get-parent-ns-ips'         => undef,
    'get-delegation'            => undef,
    'get-del-ns-names-and-ips'  => undef,
    'get-del-ns-names'          => undef,
    'get-del-ns-ips'            => undef,
    'get-zone-ns-names'         => undef,
    'get-ib-addr-in-zone'       => undef,
    'get-zone-ns-names-and-ips' => undef,
    'get-zone-ns-ips'           => undef,
);

Readonly our $ADDR_SET         => 'addr';
Readonly our $NS_SET           => 'ns';
Readonly our $NS_ADDR_SET      => 'nsaddr';
Readonly our $UNRESOLVABLE_SET => 'unresolvable';

sub new {
    my ( $class, %args ) = @_;

    $args{root_name_servers} //= \%ROOT_NAME_SERVERS;
    $args{undelegated_data}  //= {};

    my $child_zone        = delete $args{child_zone};
    my $root_name_servers = delete $args{root_name_servers};
    my $undelegated_data  = delete $args{undelegated_data};

    if ( ref $root_name_servers ne 'HASH' ) {
        croak "root_name_servers argument must be a hashref";
    }

    $child_zone =~ s/([^.])$/$1./;

    my $obj = [    #
        $child_zone,
        $root_name_servers,
        $undelegated_data,
        {%DNS_METHODS},
    ];

    return bless $obj, $class;
}

sub child_zone {
    my ( $self ) = @_;
    return $self->[0];
}

sub root_name_servers {
    my ( $self ) = @_;

    return $self->[1];
}

sub undelegated_data {
    my ( $self ) = @_;

    return $self->[2];
}

sub dns_method {
    my ( $self, $dns_method ) = @_;

    $self->[3]{$dns_method} //= do {
        my $method = '_' . ( $dns_method =~ s/-/_/gr );
        memoize( $self->$method() );
    };

    return $self->[3]{$dns_method}->tee;
}

sub lookup {
    my ( $origin, $origin_ns_ips, $qname ) = @_;

    my $mapper = sub {
        my ( $qtype, $result ) = @_;

        $qname = lc $qname =~ s/([^.])$/$1./r;

        my @streams;
        if ( $result ne $NO_RESPONSE ) {
            for my $rr ( $result->answer ) {
                if ( eq_domain( $rr->owner, $qname ) && $rr->type eq $qtype ) {
                    push @streams, singleton( $rr->address );
                }
            }
        }

        return concat( @streams );
    };

    return interleave(    #
        dns_request( server_ip => '1.1.1.1', qname => $qname, qtype => 'A', rd => 1 )    #
          ->flatmap( sub { $mapper->( 'A', shift ) } ),
        dns_request( server_ip => '1.1.1.1', qname => $qname, qtype => 'AAAA', rd => 1 )    #
          ->flatmap( sub { $mapper->( 'AAAA', shift ) } ),
    );
}

sub is_undelegated {
    my ( $self ) = @_;

    return !!$self->undelegated_data->%*;
}

=head2 get_parent_ns_ips

Produces these sets:

=over 4

=item ip IPADDR

=item unresolvable

=back

=cut

sub _get_parent_ns_ips {
    my ( $self ) = @_;

    my @root_ns_ips = map { sort $self->root_name_servers->{$_}->@* } sort keys $self->root_name_servers->%*;

    # Step 1
    if ( $self->child_zone eq '.' ) {
        return empty;
    }

    # Step 2
    if ( $self->is_undelegated ) {
        return empty;
    }

    # Step 3
    # "Handled Servers"
    my $handled_servers = fingerprint_set {
        my ( undef, $addr, $zone ) = @_;
        return $addr . '/' . $zone;
    };

    # Instead of adding pairs to "Remaining Servers", they are submitted to the scheduler to be handled by $handle_server.
    # Instead of adding addresses to "Parent NS IP", they are produced from this task.

    # $process_ns_rrs implements a snipped of duplicated pseudo-code in Get-Parent-NS-IP.
    my $process_ns_rrs = sub {
        my ( $ns_rrs, $additional_section, $zone_name ) = @_;

        $ns_rrs = [ sort { $a->nsdname cmp $b->nsdname } @$ns_rrs ];

        # Step 5.8 part 2/2
        # Step 5.11.5.2.4 part 2/2
        # Step 5.11.6.2.1 part 2/2
        my %glue = get_addresses( @$additional_section );

        my @streams;
        for my $rr ( @$ns_rrs ) {
            if ( exists $glue{ $rr->nsdname } ) {

                # Step 5.9.1 variant 2/2
                # Step 5.11.5.2.6 variant 2/2
                # Step 5.11.6.2.3 variant 2/2
                push @streams, map { singleton( 'remaining', $_, $zone_name ) } $glue{ $rr->nsdname }->@*;
            }
            else {
                # Step 5.9
                # Step 5.11.5.2.5
                # Step 5.11.6.2.2
                push @streams, lookup( '.', \@root_ns_ips, $rr->nsdname )    #
                  ->fmap(
                    sub {
                        # Step 5.9.1 variant 1/2
                        # Step 5.11.5.2.6 variant 1/2
                        # Step 5.11.6.2.3 variant 1/2
                        'remaining', $_[0], $zone_name;
                    }
                  );
            }
        }

        return interleave( @streams )

          # Step 5.2 variant 2/2
          ->uniq( $handled_servers );
    };

    # Step 4
    return    #
      concat(
        map { singleton( 'remaining', $_, '.' ) }
        map { sort $self->root_name_servers->{$_}->@* }
        sort keys $self->root_name_servers->%*
      )

      # Step 5.2 variant 1/2
      ->uniq( $handled_servers )

      # Step 5
      # Step 6
      ->iterate(
        sub {
            my ( $set, @params ) = @_;

            # Step 5.1
            if ( $set ne 'remaining' ) {
                return empty;
            }
            my ( $server_address, $zone_name ) = @params;

            # Step 5.3 part 1/2
            # Step 5.4
            return dns_request( server_ip => $server_address, qname => $zone_name, qtype => 'SOA' )    #
              ->flatmap(
                sub {
                    my ( $soa_response ) = @_;

                    # Step 5.5 part 1/2
                    if ( $soa_response eq $NO_RESPONSE || $soa_response->header->rcode ne 'NOERROR' || !$soa_response->header->aa ) {
                        return empty;
                    }

                    # Step 5.5 part 2/2
                    my @soa_rrs = grep { $_->type eq 'SOA' } $soa_response->answer;
                    if ( @soa_rrs != 1 || grep { ne_domain( $_->owner, $zone_name ) } @soa_rrs ) {
                        return empty;
                    }

                    # Step 5.3 part 2/2
                    # Step 5.6
                    return dns_request( server_ip => $server_address, qname => $zone_name, qtype => 'NS' )    #
                      ->flatmap(
                        sub {
                            my ( $ns_response ) = @_;

                            singleton( 'ns_response', $ns_response, $server_address, $zone_name )    #
                              ->iterate(
                                sub {
                                    my ( $tag, $ns_response, $server_address, $qname ) = @_;

                                    if ( $tag ne 'ns_response' ) {
                                        return empty;
                                    }

                                    # Step 5.7 part 1/2
                                    # Step 5.11.5.2.3 part 1/2
                                    if ( $ns_response eq $NO_RESPONSE || $ns_response->header->rcode ne 'NOERROR' || !$ns_response->header->aa ) {
                                        return empty;
                                    }

                                    # Step 5.8 part 1/2
                                    # Step 5.11.5.2.4 part 1/2
                                    my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->answer;

                                    # Step 5.7 part 2/2
                                    # Step 5.11.5.2.3 part 2/2
                                    if ( !@ns_rrs || grep { ne_domain( $_->owner, $qname ) } @ns_rrs ) {
                                        return;
                                    }

                                    return interleave(
                                        $process_ns_rrs->( \@ns_rrs, [ $ns_response->additional ], $qname ),

                                        # Step 5.10
                                        # Step 5.11.5.2.8
                                        singleton( 'intermediate', $server_address, $qname )    #
                                          ->iterate(
                                            sub {
                                                my ( $tag, $server_address, $intermediate_query_name ) = @_;

                                                if ( $tag ne 'intermediate' ) {
                                                    return empty;
                                                }

                                                # Step 5.11.1
                                                {
                                                    my $count = 1 + scalar split /[.]/, $intermediate_query_name;
                                                    my @child_zone_labels = split /[.]/, $self->child_zone;
                                                    $intermediate_query_name = join( '.', @child_zone_labels[ -$count .. -1 ], '' );
                                                }

                                                # Step 5.11.2
                                                # Step 5.11.3
                                                return dns_request( server_ip => $server_address, qname => $intermediate_query_name, qtype => 'SOA' )    #
                                                  ->flatmap(
                                                    sub {
                                                        my ( $soa_response ) = @_;

                                                        # Step 5.11.4
                                                        if ( $soa_response eq $NO_RESPONSE ) {
                                                            return empty;
                                                        }

                                                        # Step 5.11.5
                                                        my @soa_rrs = grep { $_->type eq 'SOA' && eq_domain( $_->owner, $intermediate_query_name ) } $soa_response->answer;
                                                        if ( @soa_rrs == 1 && $soa_response->header->aa && $soa_response->header->rcode eq 'NOERROR' ) {

                                                            # Step 5.11.5.1
                                                            if ( $intermediate_query_name eq $self->child_zone ) {

                                                                # Step 5.11.5.1.1, 5.11.5.1.2 and 6
                                                                return singleton( 'parent', $ADDR_SET, $server_address );
                                                            }
                                                            else {
                                                                # Step 5.11.5.2.1
                                                                # Step 5.11.5.2.2
                                                                return dns_request( server_ip => $server_address, qname => $intermediate_query_name, qtype => 'NS' )    #
                                                                  ->fmap( sub { 'ns_response', $_[0], $server_address, $intermediate_query_name } );
                                                            }
                                                        }

                                                        # Step 5.11.6
                                                        elsif ( $soa_response->header->rcode eq 'NOERROR' && !$soa_response->header->aa && grep { $_->type eq 'NS' } $soa_response->authority ) {

                                                            # Step 5.11.6.1
                                                            if ( $intermediate_query_name eq $self->child_zone ) {

                                                                # Step 5.11.6.1.1, 5.11.6.3 variant 1/2, and 6
                                                                return singleton( 'parent', $ADDR_SET, $server_address );
                                                            }
                                                            else {

                                                                # Step 5.11.6.2.1 part 1/2, and 5.11.6.3 variant 2/2
                                                                my @ns_rrs = grep { $_->type eq 'NS' } $soa_response->authority;
                                                                return $process_ns_rrs->( \@ns_rrs, [ $soa_response->additional ], $intermediate_query_name );
                                                            }
                                                        }

                                                        # Step 5.11.7
                                                        elsif ( $soa_response->header->rcode eq 'NOERROR' && $soa_response->header->aa ) {

                                                            # Step 5.11.7.1
                                                            if ( $intermediate_query_name ne $self->child_zone ) {
                                                                return singleton( 'intermediate', $server_address, $intermediate_query_name );
                                                            }

                                                            return empty;
                                                        }
                                                        else {
                                                            # Step 5.11.8
                                                            return empty;
                                                        }
                                                    }
                                                  );
                                            }
                                          ),
                                    );
                                }
                              )    #
                              ->flatmap( sub { ( $_[0] eq 'ns_response' ) ? empty : singleton( @_ ) } );
                        }
                      );
                }
              );
        }
      )    #
      ->select_discriminants( 'parent' )    #
      ->fmap( sub { splice @_, 1 } )

      # Step 7
      ->concat( singleton( $UNRESOLVABLE_SET ) )    #
      ->prefer_discriminants( $ADDR_SET );
}

=head2 get_delegation

Produces these sets:

=over 4

=item name DOMAIN

=item ip DOMAIN IPADDR

=item unresolvable

=back

=cut

sub _get_delegation {
    my ( $self, $undelegated_data ) = @_;

    # Step 1
    if ( $self->is_undelegated ) {

        # Step 1.1-1.6
        # Step 1.7
        my @streams;
        for my $hostname ( sort keys $self->undelegated_data->%* ) {
            my @addrs = $self->undelegated_data->{$hostname}->@*;

            push @streams, singleton( $NS_SET, $hostname );
            push @streams, map { singleton( $NS_ADDR_SET, $hostname, $_ ) } @addrs;
        }

        return concat( @streams );
    }

    # Step 2
    if ( eq_domain( $self->child_zone, '.' ) ) {
        my @streams;
        for my $hostname ( sort keys $self->root_name_servers->%* ) {
            my @addrs = $self->root_name_servers->{$_}->@*;

            push @streams, singleton( $NS_SET, $hostname );
            push @streams, map { singleton( $NS_ADDR_SET, $hostname, $_ ) } @addrs;
        }

        return concat( @streams );
    }

    # Step 6
    my $delegation_name_servers = fingerprint_set {
        my ( undef, @args ) = @_;
        join '/', @args
    };

    # Step 3 and 7
    return $self->dns_method( 'get-parent-ns-ips' )    #
      ->flatmap(
        sub {
            my ( $set, @params ) = @_;

            # Step 4
            if ( $set eq $UNRESOLVABLE_SET ) {
                return singleton( 'delegation', $UNRESOLVABLE_SET );
            }

            my ( $parent_ns ) = @params;

            # Step 5
            # Step 7.1
            return dns_request( server_ip => $parent_ns, qname => $self->child_zone, qtype => 'NS' )    #
              ->flatmap(
                sub {
                    my ( $ns_response ) = @_;

                    # Step 7.2
                    if ( $ns_response eq $NO_RESPONSE || !is_valid_response( $ns_response ) || $ns_response->header->rcode ne 'NOERROR' ) {
                        return empty;
                    }

                    # Step 7.3
                    if ( is_referral_to( $ns_response, $self->child_zone ) ) {

                        # Step 7.3.1
                        my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->authority;

                        # Step 7.3.2 part 1/2
                        my %glue = get_addresses( $ns_response->additional );

                        my @streams;
                        for my $rr ( @ns_rrs ) {

                            # Step 7.3.3 part 1/2
                            # Step 7.3.3.1
                            push @streams, singleton( 'delegation', $NS_SET, $rr->nsdname );

                            # Step 7.3.2 part 2/2
                            if ( is_in_bailiwick( $rr->nsdname, $self->child_zone ) ) {

                                # Step 7.3.3 part 2/2
                                # Step 7.3.3.1
                                for my $addr ( @{ $glue{ $rr->nsdname } // [] } ) {
                                    push @streams, singleton( 'delegation', $NS_ADDR_SET, $rr->nsdname, $addr );
                                }
                            }
                        }

                        return interleave( @streams )    #
                          ->uniq( $delegation_name_servers );
                    }

                    # Step 7.4 part 1
                    elsif ( $ns_response->header->aa ) {

                        # Step 7.4.1
                        my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->answer;

                        # Step 7.4 part 2
                        my @streams;
                        if ( grep { eq_domain( $_->owner, $self->child_zone ) } @ns_rrs ) {

                            # Step 7.4.2, 7.4.3 and 7.4.3.1
                            my %glue = get_addresses( $ns_response->additional );
                            for my $rr ( @ns_rrs ) {
                                if ( is_in_bailiwick( $rr->nsdname, $self->child_zone ) ) {
                                    push @streams, singleton( 'aa', $NS_SET, $rr->nsdname );

                                    my @addrs = $glue{ $rr->nsdname }->@*;
                                    for my $addr ( @addrs ) {
                                        push @streams, singleton( 'aa', $NS_ADDR_SET, $rr->nsdname, $addr );
                                    }

                                    # Step 7.4.4
                                    if ( !@addrs ) {

                                        # Step 7.4.4.1, 7.4.4.2 nad 7.4.4.3
                                        push @streams, lookup( $self->child_zone, [$parent_ns], $rr->nsdname )

                                          # Step 7.4.4.4
                                          ->fmap( sub { 'aa', $NS_ADDR_SET, $rr->nsdname, $_[0] } );
                                    }
                                }
                            }
                        }

                        return interleave( @streams );
                    }
                }
              );
        }
      )

      # Step 9
      ->prefer_discriminants( 'delegation', $UNRESOLVABLE_SET )    #
      ->fmap( sub { splice @_, 1 } );
}

sub get_oob_ips {
    my ( $self, $nsdname ) = @_;

    # Step 2
    my @streams;

    push @streams, singleton( $NS_SET, $nsdname );

    # Step 3.1
    if ( my $ips = $self->undelegated_data->{$nsdname} ) {
        for my $ip ( @$ips ) {
            push @streams, singleton( $NS_ADDR_SET, $nsdname, $ip );
        }

        next;
    }

    # Step 3.2
    # Step 3.3
    # Step 3.4 part 1/2
    push @streams, lookup( $self->child_zone, $self->root_name_servers, $nsdname )

      # Step 3.4 part 2/2
      # Step 3.5
      ->fmap( sub { $NS_ADDR_SET, $nsdname, $_[0] } );

    # Step 4
    return interleave( @streams );
}

=head2 get_del_ns_names_and_ips

Produces these sets:

=over 4

=item name DOMAIN

=item ip DOMAIN IPADDR

=item unresolvable

=back

=cut

sub _get_del_ns_names_and_ips {
    my ( $self ) = @_;

    # Step 1
    # Step 3
    return $self->dns_method( 'get-delegation' )    #
      ->flatmap(
        sub {
            my ( $set, @params ) = @_;

            # Step 2
            if ( $set eq $UNRESOLVABLE_SET ) {
                return singleton( $UNRESOLVABLE_SET );
            }

            my @streams;
            if ( $set eq $NS_SET ) {
                my ( $name ) = @params;

                # Step 4
                if ( is_in_bailiwick( $name, $self->child_zone ) ) {

                    # Step 6 part 1/3
                    push @streams, singleton( $NS_SET, $name );
                }
                else {

                    # Step 5
                    # Step 6 part 2/3
                    push @streams, $self->get_oob_ips( $name );
                }
            }
            else {
                my ( $name, $ip ) = @params;

                # Step 6 part 3/3
                push @streams, singleton( $NS_ADDR_SET, $name, $ip );
            }

            return interleave( @streams );
        }
      );
}

=head2 get_del_ns_names

Produces these sets:

=over 4

=item name DOMAIN

=item unresolvable

=back

=cut

sub _get_del_ns_names {
    my ( $self ) = @_;

    return $self->dns_method( 'get-del-ns-names-and-ips' )    #
      ->select_discriminants( $UNRESOLVABLE_SET, $NS_SET );
}

=head2 get_del_ns_ips

Produces these sets:

=over 4

=item ip IPADDR

=item unresolvable

=back

=cut

sub _get_del_ns_ips {
    my ( $self ) = @_;

    return $self->dns_method( 'get-del-ns-names-and-ips' )         #
      ->select_discriminants( $UNRESOLVABLE_SET, $NS_ADDR_SET )    #
      ->fmap( sub { ( $_[0] eq $NS_ADDR_SET ) ? ( $ADDR_SET, $_[2] ) : @_ } );
}

=head2 get_zone_ns_names

Produces these sets:

=over 4

=item name DOMAIN

=item unresolvable

=back

=cut

sub _get_zone_ns_names {
    my ( $self ) = @_;

    my $nsdnames = fingerprint_set {
        my ( undef, $nsdname ) = @_;
        $nsdname
    };

    return $self->dns_method( 'get-del-ns-ips' )    #
      ->flatmap(
        sub {
            my ( $set, @params ) = @_;

            if ( $set eq $UNRESOLVABLE_SET ) {
                return singleton( $UNRESOLVABLE_SET );
            }

            my ( $addr ) = @params;

            return dns_request( server_ip => $addr, qname => $self->child_zone, qtype => 'NS' )    #
              ->flatmap(
                sub {
                    my ( $ns_response ) = @_;

                    if ( $ns_response eq $NO_RESPONSE || !$ns_response->header->aa ) {
                        return empty;
                    }

                    my @streams;
                    for my $rr ( $ns_response->answer ) {
                        if ( $rr->type eq 'NS' && eq_domain( $rr->owner, $self->child_zone ) ) {
                            push @streams, singleton( $NS_SET, $rr->nsdname );
                        }
                    }

                    return interleave( @streams )    #
                      ->uniq( $nsdnames );
                }
              );
        }
      );
}

=head2 get_ib_addr_in_zone

Produces these sets:

=over 4

=item name DOMAIN

=item ip DOMAIN IPADDR

=back

=cut

sub _get_ib_addr_in_zone {
    my ( $self ) = @_;

    my $seen = fingerprint_set {
        my ( undef, $nsdname, $addr ) = @_;
        $nsdname . '/' . $addr
    };

    my $lookup_nsdname = sub {
        my ( $server_ip, $nsdname ) = @_;

        # TODO: Fix this is cheating
        return lookup( $self->child_zone, [$server_ip], $nsdname )    #
          ->fmap(
            sub {
                my ( $addr ) = @_;

                $NS_ADDR_SET, $nsdname, $addr;
            }
          )                                                           #
          ->uniq( $seen );
    };

    # Step 1
    my $name_server_ips = memoize( $self->dns_method( 'get-del-ns-ips' ) );

    # Step 2
    return $self->dns_method( 'get-zone-ns-names' )    #
      ->flatmap(
        sub {
            my ( $set, @params ) = @_;

            # Step 3
            # Either both get-del-ns-ips and get-zone-ns-names emit unresolvable or
            # neihter does, so no need to check both.
            if ( $set eq $UNRESOLVABLE_SET ) {
                return empty;
            }

            my ( $nsdname ) = @params;

            # Step 4
            if ( !is_in_bailiwick( $nsdname, $self->child_zone ) ) {
                return empty;
            }

            # Step 6.2
            return concat(    #
                singleton( $NS_SET, $nsdname ),
                $name_server_ips                         #
                  ->tee                                  #
                  ->select_discriminants( $ADDR_SET )    #
                  ->flatmap(
                    sub {
                        my ( $set, $addr ) = @_;

                        # Step 6.1
                        return $lookup_nsdname->( $addr, $nsdname );
                    }
                  )
            );
        }
      );
}

=head2 get_zone_ns_names_and_ips

Produces these sets:

=over 4

=item name DOMAIN

=item ip DOMAIN IPADDR

=item unresolvable

=back

=cut

sub _get_zone_ns_names_and_ips {
    my ( $self ) = @_;

    # Step 1
    # Step 3
    my $names = $self->dns_method( 'get-zone-ns-names' );

    # Step 4
    # Step 5
    # Step 6
    my $name_servers = $self->dns_method( 'get-ib-addr-in-zone' );

    # Step 7
    my $oob_names = $names    #
      ->flatmap(
        sub {
            my ( $set, @params ) = @_;

            # Step 2
            if ( $set eq $UNRESOLVABLE_SET ) {
                return singleton( $UNRESOLVABLE_SET );
            }

            my ( $nsdname ) = @params;

            # Step 8
            if ( is_in_bailiwick( $nsdname, $self->child_zone ) ) {
                return empty;
            }

            return $self->get_oob_ips( $nsdname );
        }
      );

    # Step 9
    # Step 10
    return interleave( $name_servers, $oob_names );
}

=head2 get_zone_ns_ips

Produces these sets:

=over 4

=item ip IPADDR

=item unresolvable

=back

=cut

sub _get_zone_ns_ips {
    my ( $self ) = @_;

    return $self->dns_method( 'get-zone-ns-names-and-ips' )        #
      ->select_discriminants( $NS_ADDR_SET, $UNRESOLVABLE_SET )    #
      ->fmap( sub { $ADDR_SET, splice @_, 2 } );
}

1;
