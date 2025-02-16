#!/usr/bin/env perl
use v5.20;
use warnings;
use Test::More;

use My::DnsRequest qw( dns_request );
use My::DnsRequest::BackgroundHandler;
use My::DnsRequest::ForegroundHandler;
use My::DnsRequest::HandlerFilter;
use My::Streams qw( empty singleton interleave );
use My::Streams::HandlerCache;
use Net::DNS::Nameserver;
use Test::Differences qw( eq_or_diff );

my $SERVER_IP = '127.0.0.1';

sub new_server {
    my ( $server_port, $responder ) = @_;

    return Net::DNS::Nameserver->new(
        LocalAddr    => $SERVER_IP,
        LocalPort    => $server_port,
        Verbose      => 0,
        ReplyHandler => $responder,
    ) || BAIL_OUT "couldn't create nameserver object";
}

sub test_dns {
    my ( $name, $server, $stream, $handlers, $expected ) = @_;

    $server->start_server( 10 );

    subtest $name => sub {
        my @items = $stream->collect( $handlers->@* );
        eq_or_diff \@items, $expected;
    };

    $server->stop_server();

    return;
}

sub responder {
    my ( $qname, $qclass, $qtype, $peerhost, $query, $conn ) = @_;

    note "Received query from $peerhost to " . $conn->{sockhost} . "\n" . $query->string;

    my ( $rcode, @ans, @auth, @add );
    if ( $qtype eq "A" && $qname eq "foo.example.com" ) {
        my ( $ttl, $rdata ) = ( 3600, "10.1.2.3" );
        my $rr = Net::DNS::RR->new( "$qname $ttl $qclass $qtype $rdata" );
        push @ans, $rr;
        $rcode = "NOERROR";
    }
    elsif ( $qname eq "foo.example.com" ) {
        $rcode = "NOERROR";
    }
    else {
        $rcode = "NXDOMAIN";
    }

    # mark the answer as authoritative (by setting the 'aa' flag)
    my $headermask = { aa => 1 };

    # specify EDNS options  { option => value }
    my $optionmask = {};

    return ( $rcode, \@ans, \@auth, \@add, $headermask, $optionmask );
}

test_dns background => (
    new_server( 15353, \&responder ),                                                   #
    dns_request( server_ip => $SERVER_IP, qname => 'foo.example.com', qtype => 'A' )    #
      ->flatmap(
        sub {
            my ( $item ) = @_;

            if ( ref( $item ) ne 'Net::DNS::Packet' ) {
                return singleton( 'no-response' );
            }

            my ( $rr ) = $item->answer;
            if ( !defined $rr ) {
                return singleton( 'no-answer' );
            }

            if ( $rr->type ne 'A' ) {
                return singleton( 'no-address' );
            }

            return singleton( 'got-address' );
        }
      ),
    [ My::DnsRequest::BackgroundHandler->new( dns_port => 15353 ) ],
    [ ['got-address'] ]
);

test_dns foreground => (
    new_server( 15354, \&responder ),                                                   #
    dns_request( server_ip => $SERVER_IP, qname => 'foo.example.com', qtype => 'A' )    #
      ->flatmap(
        sub {
            my ( $item ) = @_;

            if ( ref( $item ) ne 'Net::DNS::Packet' ) {
                return singleton( 'no-response' );
            }

            my ( $rr ) = $item->answer;
            if ( !defined $rr ) {
                return singleton( 'no-answer' );
            }

            if ( $rr->type ne 'A' ) {
                return singleton( 'no-address' );
            }

            return singleton( 'got-address' );
        }
      ),
    [ My::DnsRequest::ForegroundHandler->new( dns_port => 15354 ) ],
    [ ['got-address'] ]
);

test_dns filter => (
    new_server( 15355, \&responder ),
    interleave(    #
        dns_request( server_ip => $SERVER_IP, qname => 'foo.example.com', qtype => 'A' ),
        dns_request( server_ip => "::1",      qname => 'foo.example.com', qtype => 'A' ),
      )            #
      ->flatmap(
        sub {
            my ( $item ) = @_;

            if ( ref( $item ) ne 'Net::DNS::Packet' ) {
                return singleton( 'no-response' );
            }

            my ( $rr ) = $item->answer;
            if ( !defined $rr ) {
                return singleton( 'no-answer' );
            }

            if ( $rr->type ne 'A' ) {
                return singleton( 'no-address' );
            }

            return singleton( 'got-address' );
        }
      ),
    [ My::DnsRequest::HandlerFilter->new( My::DnsRequest::ForegroundHandler->new( dns_port => 15355 ), ipv6 => 0 ) ],
    [ ['got-address'] ]
);

my $id;
test_dns cache => (
    new_server( 15356, \&responder ),
    interleave(    #
        dns_request( server_ip => $SERVER_IP, qname => 'foo.example.com', qtype => 'A' ),
        dns_request( server_ip => $SERVER_IP, qname => 'foo.example.com', qtype => 'A' ),
      )            #
      ->flatmap(
        sub {
            my ( $item ) = @_;

            if ( ref( $item ) ne 'Net::DNS::Packet' ) {
                return singleton( 'no-response' );
            }

            $id //= $item->header->id;

            if ( $id != $item->header->id ) {
                return singleton( 'id-mismatch' );
            }

            my ( $rr ) = $item->answer;
            if ( !defined $rr ) {
                return singleton( 'no-answer' );
            }

            if ( $rr->type ne 'A' ) {
                return singleton( 'no-address' );
            }

            return singleton( 'got-address' );
        }
      ),
    [ My::Streams::HandlerCache->new( My::DnsRequest::ForegroundHandler->new( dns_port => 15356 ) ) ],
    [ ['got-address'], ['got-address'] ]
);

done_testing;
