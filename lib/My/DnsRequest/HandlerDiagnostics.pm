
=head1 NAME

My::DnsRequest::HandlerDiagnostics - Wraps a DNS handler and prints diagnostics to STDERR.

=cut 

package My::DnsRequest::HandlerDiagnostics;
use 5.020;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp              qw( croak );
use List::Util        qw( pairmap );
use My::DnsRequest    qw( $NO_RESPONSE );
use My::Streams::Util qw( $END );
use Scalar::Util      qw( blessed looks_like_number );

=head1 CONSTRUCTORS

=head2 new()

    my $handler = My::DnsRequest::HandlerDiagnostics->new( $inner_handler );

=cut

sub new {
    my ( $class, $handler, $stats_ref ) = @_;

    $stats_ref //= \my $dummy;

    $$stats_ref = {
        requests     => 0,
        responses    => 0,
        no_responses => 0,
        cancelled    => 0,
    };

    my $obj = {
        _inner  => $handler,
        _stats  => $$stats_ref,
        _params => {},
    };

    return bless $obj, $class;
}

=head1 METHODS

=cut

sub action_kind {
    my ( $self ) = @_;

    return $self->{_inner}->action_kind;
}

sub new_id {
    my ( $self ) = @_;

    return $self->{_inner}->new_id;
}

=head2 submit()

=cut

sub submit {
    my ( $self, @args ) = @_;

    my $id = $self->{_inner}->submit( @args );

    my ( $server_ip, undef, $qtype ) = @args;
    $self->{_stats}{requests}++;
    $self->{_params}{$id} = [ $server_ip, $qtype ];

    return $id;
}

=head2 poll()

=cut

sub poll {
    my ( $self ) = @_;

    my @results = $self->{_inner}->poll();

    pairmap {
        my ( $id, $result ) = ( $a, $b );

        if ( !looks_like_number( $id ) ) {
            croak sprintf "invalid id returned by %s::poll", blessed $self->{_inner};
        }

        my ( $server_ip, $qtype ) = $self->{_params}{$id}->@*;

        if ( $result eq $END ) {
            delete $self->{_params}{$id};
            $self->{_stats}{cancelled}++;
        }
        else {
            if ( $result->[0] eq $NO_RESPONSE ) {
                $self->{_stats}{no_responses}++;
                printf STDERR "no response from %s on %s query\n", $server_ip, $qtype;
            }
            else {
                $self->{_stats}{responses}++;
            }
        }
    }
    @results;

    return @results;
}

1;
