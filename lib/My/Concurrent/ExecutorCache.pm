=head1 NAME

My::Concurrent::ExecutorCache - Wraps an executor and caches its results.

=cut 

package My::Concurrent::ExecutorCache;
use 5.016;
use warnings;

use Carp qw( croak );
use Scalar::Util qw( blessed );

use parent 'My::Concurrent::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::Concurrent::ExecutorCache->new( $inner_executor );

=cut

sub new {
    my ( $class, $executor ) = @_;

    my $obj = {
        _inner => $executor,
        _cache => {},
        _pending => {},
        _ready => [],
    };

    return bless $obj, $class;
}

=head1 METHODS

=head2 submit()

Keeps track of which commands have been submitted.

The first time a command is seen it is propagated to the inner executor's submit() method.
When equivalent commands are seen, they're registered for immediate return from await().

=cut

sub submit {
    my ( $self, $id, $command ) = @_;

    if ( !blessed $command || !$command->isa( 'My::Concurrent::Command' ) ) {
        croak "command argument to submit() must be a My::Concurrent::Command";
    }

    if ( my $item = $self->{_cache}{$command} ) {
        my ( $op, @result ) = @$item;
        push @{ $self->{_ready} }, [ $op, $id, $command, @result ];
    }
    elsif ( exists $self->{_pending}{$command} ) {
        push @{ $self->{_pending}{$command} }, $id;
    }
    else {
        $self->{_pending}{$command} = [ $id ];
        $self->{_inner}->submit( $id, $command );
    }

    return;
}

=head2 await()

Caches results from commands that were propagated to the inner executor, and
reports cached results of commands that were merely registered.

=cut

sub await {
    my ( $self ) = @_;

    if ( !@{ $self->{_ready} } ) {
        my ( $op, undef, $command, @result ) = $self->{_inner}->await;

        $self->{_cache}{$command} = [$op, @result];

        for my $id ( @{ delete $self->{_pending}{$command} } ) {
            push @{ $self->{_ready} }, [ $op, $id, $command, @result ];
        }
    }

    return @{ shift @{ $self->{_ready} } };
}

1;
