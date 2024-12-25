=head1 NAME

My::Scheduler - TODO

=cut

package My::Scheduler;
use 5.016;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw( block_on );

=head1 SUBROUTINES

=head2 block_on()

    use My::Scheduler qw( block_on );

    block_on( $executor, sub {
        my ( $scheduler ) = @_;

        ...
    });

=cut

sub block_on {
    my ( $executor, $bootstrap ) = @_;

    my %handlers;
    my @ready;

    my $scheduler = {
        _executor => $executor,
        _handlers => \%handlers,
        _ready    => \@ready,
    };

    bless $scheduler, 'My::Scheduler';

    $bootstrap->( $scheduler );

    while ( %handlers ) {
        while ( my $action = shift @ready ) {
            my ( $command, $handler ) = @{ $item };
            $handler->( $command, $command->result );
        }

        my ( $command, $result ) = $executor->await;

        for my $handler ( @{ delete $handlers{$command} } ) {
            $handler->( $command, $result );
        }
    }

    return;
}

=head1 METHODS

=head2 submit()

    $scheduler->submit( $command, sub {
        my ( $command, $result ) = @_;

        ...
    });

=cut

sub submit {
    my ( $self, $command, $handler ) = @_;

    if ( $command->isa( 'My::Ready' ) ) {
        push @{ $self->{_ready} }, $command, $ready;

        return;
    }

    $self->{_handlers}{$command} //= [];
    push @{ $self->{_handlers}{$command} }, $handler;

    $self->{_executor}->submit( $command );

    return;
}

1;
