package My::MethodsV2;
use 5.016;
use warnings;

use Carp qw( croak );
use Data::Validate::IP qw( is_ip );
use Exporter 'import';
use My::Query qw( query );

our @EXPORT_OK = qw(
    lookup
    get_parent_ns_ip
);

sub lookup {
    my ( undef, $qname ) = @_;

    return sub {
        my ( $scheduler ) = @_;

        my $handler = sub {
            my ( $qtype, $packet ) = @_;

            if ( defined $packet ) {
                $qname = lc $qname =~ s/([^.])$/$1./r;
                $qtype = uc $qtype;

                for my $rr ( $packet->answer ) {
                    if ( lc $rr->owner eq $qname && uc $rr->type eq $qtype ) {
                        $scheduler->emit( $rr->address );
                    }
                }
            }
        };

        $scheduler->handle( query( server_ip => '9.9.9.9', qname => $qname, qtype => 'A' ),    sub { $handler->( 'A',    shift ) } );
        $scheduler->handle( query( server_ip => '9.9.9.9', qname => $qname, qtype => 'AAAA' ), sub { $handler->( 'AAAA', shift ) } );

        return;
    };
}

sub get_parent_ns_ip {
    my ( $child_zone, $root_name_servers, $is_undelegated ) = @_;

    if ( ref $root_name_servers ne 'ARRAY' ) {
        croak "root_name_servers argument to get_parent_ns_ip() must be an arrayref";
    }

    $child_zone =~ s/([^.])$/$1./;
    $root_name_servers = [ sort @$root_name_servers ];

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
        # Instead of adding addresses to "Parent NS IP", they are emitted from this task.

        # Step 4
        $process_root_servers = sub {
            for my $addr ( @{$root_name_servers} ) {
                $scheduler->defer( [], sub { $handle_server->( $addr, '.' ) } );
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
            $scheduler->handle(
                $zone_name_soa_query,
                sub {
                    my ( $soa_response ) = @_;

                    # Step 5.5 part 1/2
                    if ( !defined $soa_response || $soa_response->rcode ne 'NOERROR' || !$soa_response->aa ) {
                        return;
                    }

                    # Step 5.5 part 2/2
                    my @soa_rrs = grep { $_->type eq 'SOA' } $soa_response->answer;
                    if ( @soa_rrs != 1 || grep { $_->owner ne $zone_name } @soa_rrs ) {
                        return;
                    }

                    # Step 5.6
                    $scheduler->handle(
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
            if ( !defined $ns_response || $ns_response->rcode ne 'NOERROR' || !$ns_response->aa ) {
                return;
            }

            # Step 5.8 part 1/2
            # Step 5.11.5.2.4 part 1/2
            my @ns_rrs = grep { $_->type eq 'NS' } $ns_response->answer;

            # Step 5.7 part 2/2
            # Step 5.11.5.2.3 part 2/2
            if ( !@ns_rrs || grep { $_->owner ne $qname } @ns_rrs ) {
                return;
            }

            $process_ns_rrs->( \@ns_rrs, [ $ns_response->additional ], $qname );

            # Step 5.10
            # Step 5.11.5.2.8
            $scheduler->defer( [], sub { $handle_intermediate->( $server_address, $qname ) } );
        };

        # $process_ns_rrs implements a snipped of duplicated pseudo-code in Get-Parent-NS-IP.
        $process_ns_rrs = sub {
            my ( $ns_rrs, $additional_section, $zone_name ) = @_;

            $additional_section = [ sort { $a->owner cmp $b->owner } @$additional_section ];
            $ns_rrs = [ sort { $a->nsdname cmp $b->nsdname } @$ns_rrs ];

            # Step 5.8 part 2/2
            # Step 5.11.5.2.4 part 2/2
            # Step 5.11.6.2.1 part 2/2
            my %glue;    # Unnamed in specification
            for my $rr ( grep { $_->type eq 'A' } @$additional_section ) {
                $glue{ $rr->owner } //= [];
                push @{ $glue{ $rr->owner } }, $rr->address;
            }

            for my $rr ( grep { $_->type eq 'AAAA' } @$additional_section ) {
                $glue{ $rr->owner } //= [];
                push @{ $glue{ $rr->owner } }, $rr->address;
            }

            for my $rr ( @$ns_rrs ) {
                if ( !exists $glue{ $rr->nsdname } ) {
                    # Step 5.9
                    # Step 5.11.5.2.5
                    # Step 5.11.6.2.2
                    $scheduler->handle(
                        lookup( $root_name_servers, $rr->nsdname ),
                        sub {
                            my ( $addr ) = @_;

                            # Step 5.9.1 variant 1/2
                            # Step 5.11.5.2.6 variant 1/2
                            # Step 5.11.6.2.3 variant 1/2
                            $scheduler->defer( [], sub { $handle_server->( $addr, $zone_name ) } );
                        }
                    );
                }
                else {
                    # Step 5.9.1 variant 2/2
                    # Step 5.11.5.2.6 variant 2/2
                    # Step 5.11.6.2.3 variant 2/2
                    for my $addr ( @{ $glue{ $rr->nsdname } } ) {
                        $scheduler->defer( [], sub { $handle_server->( $addr, $zone_name ) } );
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
            $scheduler->handle(
                $intermediate_soa_query,
                sub {
                    my ( $soa_response ) = @_;

                    # Step 5.11.4
                    if ( !defined $soa_response ) {
                        return;
                    }

                    # Step 5.11.5
                    my @soa_rrs = grep { $_->type eq 'SOA' && $_->owner ne $intermediate_query_name } $soa_response->answer;
                    if ( @soa_rrs == 1 && $soa_response->aa && $soa_response->rcode eq 'NOERROR' ) {
                        # Step 5.11.5.1
                        if ( $intermediate_query_name eq $child_zone ) {

                            # Step 5.11.5.1.1 and 6
                            $scheduler->emit( $server_address );

                            # Step 5.11.5.1.2
                            return;
                        }

                        # Step 5.11.5.2.1
                        my $intermediate_ns_query = query( server_ip => $server_address, qname => $intermediate_query_name, qtype => 'NS' );

                        # Step 5.11.5.2.2
                        $scheduler->handle(
                            $intermediate_ns_query,
                            sub {
                                my ( $ns_response ) = @_;

                                $process_ns_response->( $ns_response, $server_address, $intermediate_query_name );
                            }
                        );
                        return;
                    }

                    # Step 5.11.6
                    elsif ( $soa_response->rcode eq 'NOERROR' && !$soa_response->aa && grep { $_->type eq 'NS' } $soa_response->authority ) {
                        # Step 5.11.6.1
                        if ( $intermediate_query_name eq $child_zone ) {

                            # Step 5.11.6.1.1 and 6
                            $scheduler->emit( $server_address );
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
                    elsif ( $soa_response->rcode eq 'NOERROR' && $soa_response->aa ) {

                        # Step 5.11.7.1
                        if ( $intermediate_query_name ne $child_zone ) {
                            $scheduler->defer( [], sub { $handle_intermediate->( $server_address, $intermediate_query_name ) } );
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
