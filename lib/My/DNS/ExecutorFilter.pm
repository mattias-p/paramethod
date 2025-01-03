=head1 NAME

My::DNS::ExecutorFilter - Wraps an executor and filters commands.

=cut 

package My::DNS::ExecutorFilter;
use 5.016;
use warnings;

use Carp qw( croak );
use Data::Validate::IP qw( is_ipv4 is_ipv6 );
use Scalar::Util qw( blessed );

use parent 'My::Concurrent::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::DNS::ExecutorFilter->new( $inner_executor );

=cut

sub new {
    my ( $class, $executor, %config ) = @_;

    my $obj = {
        _inner => $executor,
        _ready => [],
        _config => {
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

=head2 submit()

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::Concurrent::Command' ) ) {
        croak "command argument to submit() must be a My::Concurrent::Command";
    }

    if ( ref $command eq 'My::DNS::Query' && !$self->check_ip( $command->server_ip ) ) {
        push @{ $self->{_ready} }, [ 'close', $id, $command ];
    }
    else {
        $self->{_inner}->submit( $id, $command );
    }

    return;
}

=head2 await()

=cut

sub await {
    my ( $self ) = @_;

    if ( @{ $self->{_ready} } ) {
        return @{ shift @{ $self->{_ready} } };
    }

    return $self->{_inner}->await;
}

sub check_ip {
    my ( $self, $addr ) = @_;

    return ( $self->{_config}{ipv4} && is_ipv4( $addr ) )
      || ( $self->{_config}{ipv6} && is_ipv6( $addr ) );
}

1;
