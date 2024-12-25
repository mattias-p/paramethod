=head1 NAME

My::CachingExecutor - Wraps an executor and caches its results.

=cut 

package My::CachingExecutor;
use 5.016;
use warnings;

use parent 'My::Executor';

=head1 CONSTRUCTORS

=head2 new()

    my $executor = My::CachingExecutor->new( $inner_executor );

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
    my ( $self, $command ) = @_;

    if ( exists $self->{_cache}{$command} ) {
        push @{ $self->{_ready} }, $command;

        return;
    }

    if ( exists $self->{_pending}{$command} ) {
        $self->{_pending}{$command}++;

        return;
    }

    $self->{_inner}->submit( $command );
    $self->{_pending}{$command} = 0;

    return;
}

=head2 await()

Caches results from commands that were propagated to the inner executor, and
reports cached results of commands that were merely registered.

=cut

sub await {
    my ( $self ) = @_;

    if ( my $command = shift @{ $self->{_ready} } ) {
        return $command, $self->{_cache}{$command};
    }

    my ( $command, $result ) = $self->{_inner}->await();

    $self->{_cache}{$command} = $result;

    my $pending = delete $self->{_pending}{$command};
    while ( $pending-- ) {
        push @{ $self->{_ready} }, $command;
    }

    return $command, $result;
}

1;
