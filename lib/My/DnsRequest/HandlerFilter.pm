package My::DnsRequest::HandlerFilter;
use v5.20;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp               qw( confess croak );
use Data::Validate::IP qw( is_ipv4 is_ipv6 );
use My::Streams::Util  qw( $END );
use Scalar::Util       qw( blessed looks_like_number );

=head1 CONSTRUCTORS

=head2 new()

    my $handler = My::DnsRequest::HandlerFilter->new( $inner_handler );

=cut

sub new {
    my ( $class, $handler, %config ) = @_;

    my $obj = {
        _inner   => $handler,
        _ready   => [],
        _pending => {},
        _config  => {
            ipv4 => delete $config{ipv4} // 1,
            ipv6 => delete $config{ipv6} // 1,
        },
    };

    if ( %config ) {
        croak "unrecognized config keys: " . join( ', ', sort keys %config );
    }

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
    my ( $server_ip ) = @args;

    if ( $self->check_ip( $server_ip ) ) {
        my $id = $self->{_inner}->submit( @args );
        if ( !looks_like_number( $id ) ) {
            croak sprintf "invalid id returned by %s::submit", blessed $self->{_inner};
        }

        $self->{_pending}{$id} = 1;

        return $id;
    }
    else {
        my $id = $self->new_id;
        push $self->{_ready}->@*, ( $id, $END );
        return $id;
    }
}

=head2 poll()

=cut

sub poll {
    my ( $self ) = @_;

    if ( !$self->{_pending}->%* ) {
        confess "no pending or ready actions";
    }

    my @results = splice $self->{_ready}->@*, 0, scalar $self->{_ready}->@*;

    if ( $self->{_pending}->%* ) {
        my @polled = $self->{_inner}->poll;

        my $i = 0;
        while ( $i < scalar( @polled ) ) {
            my ( $id, $element ) = ( $polled[$i], $polled[ $i + 1 ] );
            if ( $element eq $END ) {
                delete $self->{_pending}{$id};
            }
            $i += 2;
        }
        push @results, @polled;
    }

    return @results;
}

sub check_ip {
    my ( $self, $addr ) = @_;

    return ( $self->{_config}{ipv4} && is_ipv4( $addr ) )
      || ( $self->{_config}{ipv6} && is_ipv6( $addr ) );
}

1;
