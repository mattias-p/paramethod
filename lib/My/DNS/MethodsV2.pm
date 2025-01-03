package My::DNS::MethodsV2;
use 5.016;
use warnings;

use Carp qw( croak );
use Data::Validate::IP qw( is_ip );
use Exporter 'import';
use My::DNS::Query qw( query );

our @EXPORT_OK = qw(
    eq_domain
    ne_domain
    lookup
    get_parent_ns_ip
    get_delegation
    get_del_ns_names_and_ips
    get_del_ns_names
    get_del_ns_ips
    get_zone_ns_names
    get_ib_addr_in_zone
    get_zone_ns_names_and_ips
    get_zone_ns_ips
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
    my ($domain, $bailiwick) = @_;

    $domain = lc $domain;
    $bailiwick = lc $bailiwick;

    # Remove trailing dots for uniformity
    $domain =~ s/\.$//;
    $bailiwick =~ s/\.$//;

    # Check if the domain ends with the bailiwick
    return ($domain eq $bailiwick || $domain =~ /\.\Q$bailiwick\E$/) ? 1 : 0;
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

sub lookup {
    my ( $origin, $origin_ns_ips, $qname ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        my $handle = sub {
            my ( $qtype, $packet ) = @_;

            $qname = lc $qname =~ s/([^.])$/$1./r;

            if ( defined $packet ) {
                for my $rr ( $packet->answer ) {
                    if ( eq_domain( $rr->owner, $qname ) && uc $rr->type eq $qtype ) {
                        $scheduler->produce( $rr->address );
                    }
                }
            }
        };

        $scheduler->consume( query( server_ip => '9.9.9.9', qname => $qname, qtype => 'A',    rd => 1 ), sub { $handle->( 'A',    shift ) } );
        $scheduler->consume( query( server_ip => '9.9.9.9', qname => $qname, qtype => 'AAAA', rd => 1 ), sub { $handle->( 'AAAA', shift ) } );

        return;
    };
}

sub get_parent_ns_ip {
    my ( $child_zone, $root_name_servers, $is_undelegated ) = @_;

    if ( ref $root_name_servers ne 'HASH' ) {
        croak "root_name_servers argument to get_parent_ns_ip() must be a hashref";
    }

    $child_zone =~ s/([^.])$/$1./;

    my @root_ns_ips = map { @{ $root_name_servers->{$_} } } sort keys %$root_name_servers;

    return sub {
        my ( $scheduler ) = @_;

        my $process_root_servers;
        my $handle_server;
        my $process_ns_response;
        my $process_ns_rrs;
        my $handle_intermediate;

        # Step 1
        if ( $child_zone eq '.' ) {
            return;
        }

        # Step 2
        if ( $is_undelegated ) {
            return;
        }

        # Step 3
        my %handled_servers; # "Handled Servers"
        # Instead of adding pairs to "Remaining Servers", they are submitted to the scheduler to be handled by $handle_server.
        # Instead of adding addresses to "Parent NS IP", they are produced from this task.

        # Step 4
        $process_root_servers = sub {
            for my $nsdname ( sort keys %$root_name_servers ) {
                for my $addr ( sort @{ $root_name_servers->{ $nsdname } } ) {
                    $handle_server->( $addr, '.' );
                }
            }
        };

        # Step 5 and 5.1
        $handle_server = sub {
            my ( $server_address, $zone_name ) = @_;

            if ( exists $handled_servers{$server_address}{$zone_name} ) {
                return;
            }

            # Step 5.2
            $handled_servers{$server_address} //= {};
            $handled_servers{$server_address}{$zone_name} = 1;

            # Step 5.3
            my $zone_name_soa_query = query( server_ip => $server_address, qname => $zone_name, qtype => 'SOA' );
            my $zone_name_ns_query  = query( server_ip => $server_address, qname => $zone_name, qtype => 'NS' );

            # Step 5.4
            $scheduler->consume(
                $zone_name_soa_query,
                sub {
                    my ( $soa_response ) = @_;

                    # Step 5.5 part 1/2
                    if ( !defined $soa_response || $soa_response->header->rcode ne 'NOERROR' || !$soa_response->header->aa ) {
                        return;
                    }

                    # Step 5.5 part 2/2
                    my @soa_rrs = grep { $_->type eq 'SOA' } $soa_response->answer;
                    if ( @soa_rrs != 1 || grep { ne_domain( $_->owner, $zone_name ) } @soa_rrs ) {
                        return;
                    }

                    # Step 5.6
                    $scheduler->consume(
                        $zone_name_ns_query,
                        sub {
                            my ( $ns_response ) = @_;

                            $process_ns_response->( $ns_response, $server_address, $zone_name );
                        }
                    );
                }
            );
        };

        # $process_ns_response implements a snippet of duplicated pseudo-code in Get-Parent-NS-IP.
        $process_ns_response = sub {
            my ( $ns_response, $server_address, $qname ) = @_;

            # Step 5.7 part 1/2
            # Step 5.11.5.2.3 part 1/2
            if ( !defined $ns_response || $ns_response->header->rcode ne 'NOERROR' || !$ns_response->header->aa ) {
                return;
            }

            # Step 5.8 part 1/2
            # Step 5.11.5.2.4 part 1/2
            my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->answer;

            # Step 5.7 part 2/2
            # Step 5.11.5.2.3 part 2/2
            if ( !@ns_rrs || grep { ne_domain( $_->owner, $qname ) } @ns_rrs ) {
                return;
            }

            $process_ns_rrs->( \@ns_rrs, [ $ns_response->additional ], $qname );

            # Step 5.10
            # Step 5.11.5.2.8
            $handle_intermediate->( $server_address, $qname );
        };

        # $process_ns_rrs implements a snipped of duplicated pseudo-code in Get-Parent-NS-IP.
        $process_ns_rrs = sub {
            my ( $ns_rrs, $additional_section, $zone_name ) = @_;

            $ns_rrs = [ sort { $a->nsdname cmp $b->nsdname } @$ns_rrs ];

            # Step 5.8 part 2/2
            # Step 5.11.5.2.4 part 2/2
            # Step 5.11.6.2.1 part 2/2
            my %glue = get_addresses( @$additional_section );

            for my $rr ( @$ns_rrs ) {
                if ( !exists $glue{ $rr->nsdname } ) {
                    # Step 5.9
                    # Step 5.11.5.2.5
                    # Step 5.11.6.2.2
                    $scheduler->consume(
                        lookup( '.', \@root_ns_ips, $rr->nsdname ),
                        sub {
                            my ( $addr ) = @_;

                            # Step 5.9.1 variant 1/2
                            # Step 5.11.5.2.6 variant 1/2
                            # Step 5.11.6.2.3 variant 1/2
                            $handle_server->( $addr, $zone_name );
                        }
                    );
                }
                else {
                    # Step 5.9.1 variant 2/2
                    # Step 5.11.5.2.6 variant 2/2
                    # Step 5.11.6.2.3 variant 2/2
                    for my $addr ( @{ $glue{ $rr->nsdname } } ) {
                        $handle_server->( $addr, $zone_name );
                    }
                }
            }
        };

        # $handle_intermediate implements the body of the inner loop of Get-Parent-NS-IP.
        $handle_intermediate = sub {
            my ( $server_address, $intermediate_query_name ) = @_;

            # Step 5.11.1
            {
                my $count = 1 + scalar split /[.]/, $intermediate_query_name;
                my @child_zone_labels = split /[.]/, $child_zone;
                $intermediate_query_name = join('.', @child_zone_labels[-$count..-1], '');
            }

            # Step 5.11.2
            my $intermediate_soa_query = query( server_ip => $server_address, qname => $intermediate_query_name, qtype => 'SOA' );

            # Step 5.11.3
            $scheduler->consume(
                $intermediate_soa_query,
                sub {
                    my ( $soa_response ) = @_;

                    # Step 5.11.4
                    if ( !defined $soa_response ) {
                        return;
                    }

                    # Step 5.11.5
                    my @soa_rrs = grep { $_->type eq 'SOA' && ne_domain( $_->owner, $intermediate_query_name ) } $soa_response->answer;
                    if ( @soa_rrs == 1 && $soa_response->header->aa && $soa_response->header->rcode eq 'NOERROR' ) {
                        # Step 5.11.5.1
                        if ( $intermediate_query_name eq $child_zone ) {

                            # Step 5.11.5.1.1 and 6
                            $scheduler->produce( $server_address );

                            # Step 5.11.5.1.2
                            return;
                        }

                        # Step 5.11.5.2.1
                        my $intermediate_ns_query = query( server_ip => $server_address, qname => $intermediate_query_name, qtype => 'NS' );

                        # Step 5.11.5.2.2
                        $scheduler->consume(
                            $intermediate_ns_query,
                            sub {
                                my ( $ns_response ) = @_;

                                $process_ns_response->( $ns_response, $server_address, $intermediate_query_name );
                            }
                        );
                        return;
                    }

                    # Step 5.11.6
                    elsif ( $soa_response->header->rcode eq 'NOERROR' && !$soa_response->header->aa && grep { $_->type eq 'NS' } $soa_response->authority ) {
                        # Step 5.11.6.1
                        if ( $intermediate_query_name eq $child_zone ) {

                            # Step 5.11.6.1.1 and 6
                            $scheduler->produce( $server_address );
                        }
                        else {

                            # Step 5.11.6.2.1 part 1/2
                            my @ns_rrs = grep { $_->type eq 'NS' } $soa_response->authority;
                            $process_ns_rrs->( \@ns_rrs, [ $soa_response->additional ], $intermediate_query_name );
                        }

                        # Step 5.11.6.3
                        return;
                    }

                    # Step 5.11.7
                    elsif ( $soa_response->header->rcode eq 'NOERROR' && $soa_response->header->aa ) {

                        # Step 5.11.7.1
                        if ( $intermediate_query_name ne $child_zone ) {
                            $handle_intermediate->( $server_address, $intermediate_query_name );
                        }

                        return;
                    }
                    else {
                        # Step 5.11.8
                        return;
                    }
                }
            );
        };

        $process_root_servers->();
    };
}

sub get_delegation {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        # Step 1
        if ( $is_undelegated ) {

            # Step 1.1-1.6
            for my $nsdname ( sort keys @{$undelegated_data} ) {
                $scheduler->produce( $nsdname );
                for my $addr ( @{ $undelegated_data->{$nsdname} } ) {
                    $scheduler->produce( $nsdname, $addr );
                }
            }

            # Step 1.7
            return;
        }

        # Step 2
        if ( eq_domain( $child_zone, '.' ) ) {
            for my $nsdname ( sort keys @{$root_name_servers} ) {
                $scheduler->produce( $nsdname );
                for my $addr ( @{ $root_name_servers->{$nsdname} } ) {
                    $scheduler->produce( $nsdname, $addr );
                }
            }

            return;
        }

        # Step 6
        my %delegation_name_servers;
        my %aa_name_servers;

        # Step 3 and 7
        my $actionid = $scheduler->consume(
            get_parent_ns_ip( $child_zone, $root_name_servers, $is_undelegated ),
            sub {
                my ( $parent_ns ) = @_;

                # Step 5
                my $ns_query = query( server_ip => $parent_ns, qname => $child_zone, qtype => 'NS' );

                # Step 7.1
                $scheduler->consume(
                    $ns_query,
                    sub {
                        my ( $ns_response ) = @_;

                        # Step 7.2
                        if ( !defined $ns_response || !is_valid_response( $ns_response ) || $ns_response->header->rcode ne 'NOERROR' ) {
                            return;
                        }

                        # Step 7.3
                        if ( is_referral_to( $ns_response, $child_zone ) ) {
                            # Step 7.3.1
                            my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->authority;

                            # Step 7.3.2 part 1/2
                            my %glue = get_addresses( $ns_response->additional );

                            for my $rr ( @ns_rrs ) {

                                # Step 7.3.3 part 1/2 and 7.3.3.1
                                if ( !exists $delegation_name_servers{ $rr->nsdname } ) {
                                    $delegation_name_servers{ $rr->nsdname } = {};
                                    $scheduler->produce( $rr->nsdname );
                                }

                                # Step 7.3.2 part 2/2
                                if ( is_in_bailiwick( $rr->nsdname, $child_zone ) ) {

                                    # Step 7.3.3 part 2/2 and 7.3.3.1
                                    for my $addr ( @{ $glue{ $rr->nsdname } // [] } ) {
                                        if ( !exists $delegation_name_servers{ $rr->nsdname }{$addr} ) {
                                            $delegation_name_servers{ $rr->nsdname }{$addr} = 1;
                                            $scheduler->produce( $rr->nsdname, $addr );
                                        }
                                    }
                                }
                            }
                        }

                        # Step 7.4 part 1
                        elsif ( $ns_response->header->aa ) {

                            # Step 7.4.1
                            my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->answer;

                            # Step 7.4 part 2
                            if ( grep { eq_domain( $_->owner, $child_zone ) } @ns_rrs ) {

                                # Step 7.4.2, 7.4.3 and 7.4.3.1
                                my %glue = get_addresses( $ns_response->additional );
                                for my $rr ( @ns_rrs ) {
                                    my @addrs;
                                    if ( is_in_bailiwick( $rr->nsdname, $child_zone ) ) {
                                        $aa_name_servers{ $rr->nsdname } //= {};
                                        my @addrs = @{ $glue{ $rr->nsdname } };
                                        for my $addr ( @addrs ) {
                                            $aa_name_servers{ $rr->nsdname }{$addr} = 1;
                                        }

                                        # Step 7.4.4
                                        if ( !@addrs ) {

                                            # Step 7.4.4.1, 7.4.4.2 nad 7.4.4.3
                                            $scheduler->consume(
                                                lookup( $child_zone, [$parent_ns], $rr->nsdname ),
                                                sub {
                                                    my ( $addr ) = @_;

                                                    # Step 7.4.4.4
                                                    $aa_name_servers{ $rr->nsdname }{$addr} = 1;
                                                }
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }
                );
            }
        );

        # Step 9
        $scheduler->defer(
            [$actionid],
            sub {
                if ( !%delegation_name_servers ) {
                    for my $nsdname ( sort keys %aa_name_servers ) {
                        $scheduler->produce( $nsdname );
                        for my $addr ( sort keys %{ $aa_name_servers{$nsdname} } ) {
                            $scheduler->produce( $nsdname, $addr );
                        }
                    }
                }
            }
        );
    };
}

sub get_oob_ips {
    my ( $nsdname, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        # Step 3.1
        if ( $is_undelegated ) {
            for my $addr ( @$undelegated_data ) {
                $scheduler->produce( $addr );
            }
        }
        else {
            $scheduler->consume(
                lookup( '.', $root_name_servers, $nsdname ),
                sub {
                    my ( $addr ) = @_;
                    $scheduler->produce( $addr );
                }
            );
        }
    };
}

sub get_del_ns_names_and_ips {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        # Step 1
        $scheduler->consume(
            get_delegation( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname, @addr ) = @_;

                if ( @addr ) {

                    # Step 6 variant 1/2 and 7
                    $scheduler->produce( $nsdname, @addr );
                }
                else {
                    $scheduler->produce( $nsdname );

                    if ( !is_in_bailiwick( $nsdname, $child_zone ) ) {

                        # Step 5
                        $scheduler->consume(
                            get_oob_ips( $nsdname, $root_name_servers, $undelegated_data, $is_undelegated ),
                            sub {
                                my ( $addr ) = @_;

                                # Step 6 variant 2/2 and 7
                                $scheduler->produce( $nsdname, $addr );
                            }
                        );
                    }
                }
            }
        );
    }
}

sub get_del_ns_names {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        $scheduler->consume(
            get_delegation( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname, @addr ) = @_;

                if ( !@addr ) {
                    $scheduler->produce( $nsdname );
                }
            }
        );
    }
}

sub get_del_ns_ips {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        $scheduler->consume(
            get_del_ns_names_and_ips( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname, @addr ) = @_;

                if ( @addr ) {
                    $scheduler->produce( @addr );
                }
            }
        );
    }
}

sub get_zone_ns_names {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        my %nsdnames;

        $scheduler->consume(
            get_del_ns_ips( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $addr ) = @_;

                $scheduler->consume(
                    query( server_ip => $addr, qname => $child_zone, qtype => 'NS' ),
                    sub {
                        my ( $ns_response ) = @_;

                        if ( !defined $ns_response || !$ns_response->header->aa ) {
                            return;
                        }

                        for my $rr ( $ns_response->answer ) {
                            if ( $rr->type eq 'NS' && eq_domain( $rr->owner, $child_zone ) ) {
                                if ( !exists $nsdnames{ $rr->nsdname } ) {
                                    $nsdnames{ $rr->nsdname } = 1;
                                    $scheduler->produce( $rr->nsdname );
                                }
                            }
                        }
                    }
                );
            }
        );
    }
}

sub get_ib_addr_in_zone {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        my $lookup_nsdname = sub {
            my ( $server_ip, $nsdname ) = @_;

            state %seen;

            $scheduler->consume( lookup( $child_zone, [$server_ip], $nsdname ), sub {
                my ( $addr ) = @_;

                if ( !exists $seen{$addr} ) {
                    $seen{$addr} = 1;

                    $scheduler->produce( $nsdname, $addr );
                }
            });
        };

        # Call $query_addresses for the cross product of Get-Del-NS-IPs and the in-bailiwick names from Get-Zone-NS-Names
        my @zone_ns_names;
        my @del_ns_ips;
        $scheduler->consume(
            get_zone_ns_names( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname ) = @_;

                if ( is_in_bailiwick( $nsdname, $child_zone ) ) {
                    push @zone_ns_names, $nsdname;

                    $scheduler->produce( $nsdname );

                    for my $server_ip ( @del_ns_ips ) {
                        $lookup_nsdname->( $server_ip, $nsdname );
                    }
                }
            }
        );
        $scheduler->consume(
            get_del_ns_ips( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $server_ip ) = @_;

                push @del_ns_ips, $server_ip;

                for my $nsdname ( @zone_ns_names ) {
                    $lookup_nsdname->( $server_ip, $nsdname );
                }
            }
        );
    }
}

sub get_zone_ns_names_and_ips {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        $scheduler->consume(
            get_ib_addr_in_zone( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname, @addr ) = @_;

                $scheduler->produce( $nsdname, @addr );
            }
        );

        $scheduler->consume(
            get_zone_ns_names( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname ) = @_;

                if ( !is_in_bailiwick( $nsdname, $child_zone ) ) {
                    $scheduler->produce( $nsdname );

                    $scheduler->consume(
                        get_oob_ips( $nsdname, $root_name_servers, $undelegated_data, $is_undelegated ),
                        sub {
                            my ( $addr ) = @_;

                            $scheduler->produce( $nsdname, $addr );
                        }
                    );

                }
            }
        );
    };
}

sub get_zone_ns_ips {
    my ( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        $scheduler->consume(
            get_zone_ns_names_and_ips( $child_zone, $root_name_servers, $undelegated_data, $is_undelegated ),
            sub {
                my ( $nsdname, @addr ) = @_;

                if ( @addr ) {
                    $scheduler->produce( @addr );
                }
            }
        );
    };
}

1;
