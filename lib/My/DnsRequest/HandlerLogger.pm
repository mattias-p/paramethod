package My::DnsRequest::HandlerLogger;
use v5.20;
use warnings;
use parent qw( My::Streams::HandlerRole );

use List::Util        qw( any max );
use My::Streams::Util qw( $END );
use My::DnsRequest    qw( $NO_RESPONSE );

sub new {
    my ( $class, $inner ) = @_;

    my $obj = {
        _inner   => $inner,
        _pending => {},
    };

    return bless $obj, $class;
}

sub action_kind {
    my ( $self ) = @_;

    return $self->{_inner}->action_kind;
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_inner}->new_id;
}

sub _log_response {
    my ( $server_ip, $qname, $qtype, $rd, $response ) = @_;

    state $server_ip_width = 15;
    state $qname_width     = 18;
    state $qtype_width     = 4;
    state $flags_width     = 9;

    my @flags;
    if ( !$rd ) {
        push @flags, '+nordflag';
    }

    my $flags_string = join( '  ', '', @flags );

    $server_ip_width = max $server_ip_width, length $server_ip;
    $qname_width     = max $qname_width,     length $qname;
    $qtype_width     = max $qtype_width,     length $qtype;
    $flags_width     = max $flags_width,     length $flags_string;

    printf STDERR "Request  @%-*s  %-*s  %-*s  %-*s -> %s\n", $server_ip_width, $server_ip, $qname_width, $qname, $qtype_width, $qtype, $flags_width, $flags_string, $response;
}

sub _follow_redirects {
    my ( $packet, $qname ) = @_;

    my %cnames;
    for my $rr ( grep { $_->type eq 'CNAME' } $packet->answer ) {
        if ( exists $cnames{ $rr->owner } ) {
            return;
        }
        $cnames{ $rr->owner } = $rr->cname;
    }

    my %reverse_cnames = reverse %cnames;
    if ( exists $reverse_cnames{$qname} ) {
        return;
    }

    if ( scalar %cnames != scalar keys %reverse_cnames ) {
        return;
    }

    my $name = $qname;
    while ( exists $cnames{$name} ) {
        $name = delete $cnames{$name};
    }

    if ( %cnames ) {
        return;
    }

    return $name;
}

sub _is_subdomain {
    my ( $child, $parent ) = @_;

    my $child_len     = split( /[.]/, $child );
    my @parent_labels = split /[.]/, $parent;
    if ( @parent_labels < $child_len ) {
        return !!0;
    }
    my @truncated_parent_labels = @parent_labels[ -$child_len .. -1 ];
    return $child =~ s/[.]$//r eq join( '.', @truncated_parent_labels );
}

sub _is_referral {
    my ( $packet, $qname ) = @_;

    if ( $packet->header->rcode ne 'NOERROR' ) {
        return;
    }
    if ( $packet->header->aa ) {
        return;
    }
    if ( any { $_->type ne 'CNAME' } $packet->answer ) {
        return;
    }

    my $name = _follow_redirects( $packet, $qname );
    if ( !defined $name ) {
        return;
    }

    my %children =
      map { $_->owner => undef }
      grep { _is_subdomain( $name, $_->owner ) && $_->type eq 'NS' } $packet->authority;

    if ( keys %children != 1 ) {
        warn join ' ', sort keys %children;
        return;
    }

    return [ keys %children ]->[0];
}

sub submit {
    my ( $self, @args ) = @_;

    my $id = $self->{_inner}->submit( @args );

    $self->{_pending}{$id} = \@args;

    return $id;
}

sub poll {
    my ( $self ) = @_;

    my @results = $self->{_inner}->poll;

    my $i = 0;
    while ( $i < @results ) {
        my ( $id, $element ) = @results[ $i .. $i + 1 ];

        my @args = $self->{_pending}{$id}->@*;
        my ( undef, $qname, $qtype, undef ) = @args;

        my $response;
        if ( $element eq $END ) {
            delete $self->{_pending}{$id};
        }
        else {
            my ( $response ) = @$element;
            if ( $response eq $NO_RESPONSE ) {
                $response = 'No Response';
            }
            elsif ( my $child = _is_referral( $response, $qname ) ) {
                $response = "Referral to $child";
            }
            else {
                my $rcode      = $response->header->rcode;
                my $aa         = $response->header->aa;
                my $has_answer = any { $_->owner eq $qname && $_->type eq $qtype } $response->answer;

                my $name = _follow_redirects( $response, $qname );

                if ( defined $name ) {
                    if ( $name ne $qname ) {
                        if ( $rcode eq 'NOERROR' && !$has_answer ) {
                            $response = "CName $name";
                        }
                    }
                    else {
                        if ( $rcode eq 'NXDOMAIN' && !$has_answer ) {
                            $response = 'Non-Existent Domain';
                        }
                        elsif ( $rcode eq 'NOERROR' && !$has_answer ) {
                            $response = 'No Data';
                        }
                        elsif ( $rcode eq 'NOERROR' && $has_answer ) {
                            $response = 'Answer';
                        }
                    }
                }

                if ( defined $response ) {
                    $response = $aa ? "Auth $response" : "Non-Auth $response";
                }
                elsif ( $rcode ne 'NOERROR' ) {
                    $response = $rcode;
                }
                else {
                    $response = 'Uncategorized';
                }
            }

            _log_response( @args, $response );
        }

        $i += 2;
    }

    return @results;
}

1;
