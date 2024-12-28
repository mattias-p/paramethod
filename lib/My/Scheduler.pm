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

    my $scheduler = {
        _executor     => $executor,
        _cur_actionid => 0,
        _num_actions  => 0,
        _actions      => {},
        _actionids    => {},
        _ready        => [],
    };

    bless $scheduler, 'My::Scheduler';

    $bootstrap->( $scheduler );

    while ( %{ $scheduler->{_actions} } ) {
        while ( my $ready = shift @{ $scheduler->{_ready} } ) {
            my ( $actionid, $result ) = @{ $ready };

            $scheduler->_handle( $actionid, $result );
        }

        my ( $command, $result ) = $scheduler->{_executor}->await;

        for my $actionid ( @{ delete $scheduler->{_actionids}{$command} } ) {
            $scheduler->_handle( $actionid, $result );
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
    my ( $self, $deps, $command, $handler ) = @_;

    my $actionid = $self->{_num_tasks}++;
    $self->{_actionids}{$command} //= [];
    push @{ $self->{_actionids}{$command} }, $actionid;

    $self->{_actions}{$actionid} = {
        liveness => 1,
        rdeps    => [],
        deps     => [@{ $deps }],
        command  => $command,
        handler  => $handler,
        parent   => $self->{_cur_handler},
    };

    if ( @{ $deps } ) {
        for my $dep ( @{ $deps } ) {
            push @{ $self->{_actions}{$dep}{rdeps} }, $actionid;
        }

        return;
    }

    if ( $command->isa( 'My::Ready' ) ) {
        push @{ $self->{_ready} }, $actionid;

        return;
    }

    $self->{_executor}->submit( $command );

    return;
}

sub _handle {
    my ( $self, $actionid, $result ) = @_;

    $self->{_cur_actionid} = $actionid;

    {
        my $handler = $self->{_actions}{$actionid}{handler};
        my $command = $self->{_actions}{$actionid}{command};
        $handler->( $command, $result );
    }

    while ( $actionid ) {
        my $action = $self->{_actions}{$actionid};

        $action->{liveness}--;

        if ( !$action->{liveness} ) {
            for my $rdep_actionid ( @{ $action->{rdeps} } ) {
                my $rdep_action = $self->{_actions}{$rdep_actionid};

                delete $rdep_action->{deps}{$actionid};

                if ( !%{ $rdep_action->{deps} } ) {
                    push @{ $self->{_ready} }, $actionid;
                }
            }

            delete $self->{_actions}{$actionid};
        }

        $actionid = $action->{parent};
    }

    return;
}

1;
