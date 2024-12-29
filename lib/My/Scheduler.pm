=head1 NAME

My::Scheduler - TODO

=cut

package My::Scheduler;
use 5.016;
use warnings;

use Carp qw( croak );
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
        _executor    => $executor,
        _num_actions => 0,
        _cur_action  => 0,
        _cur_task    => 0,
        _actions     => {},
        _pending     => [],
    };

    bless $scheduler, 'My::Scheduler';

    $bootstrap->( $scheduler );

    $scheduler->_run();

    return;
}

=head1 METHODS

=head2 submit()

    $scheduler->submit( $command, sub {
        my ( $command, $result ) = @_;

        ...
    });

=cut

sub command {
    my ( $self, $deps, $command, $handler ) = @_;

    if ( ref $deps ne 'ARRAY' ) {
        croak "deps argument to command() must be an arrayref";
    }
    if ( !blessed $command || !$command->isa( 'My::Command' ) ) {
        croak "command argument to command() must be a My::Command";
    }
    if ( ref $handler ne 'CODE' ) {
        croak "handler argument to command() must be a coderef";
    }

    return $self->_action(
        $deps,
        $handler,
        task    => $self->{_cur_task},
        command => $command,
    );
}

sub result {
    my ( $self, $deps, $result, $handler ) = @_;

    if ( ref $deps ne 'ARRAY' ) {
        croak "deps argument to result() must be an arrayref";
    }
    if ( ref $handler ne 'CODE' ) {
        croak "handler argument to result() must be a coderef";
    }

    return $self->_action(
        $deps,
        $handler,
        task   => $self->{_cur_task},
        result => $result,
    );
}

sub task {
    my ( $self, $deps, $bootstrap, $handler ) = @_;

    if ( ref $deps ne 'ARRAY' ) {
        croak "deps argument to task() must be an arrayref";
    }
    if ( ref $bootstrap ne 'CODE' ) {
        croak "bootstrap argument to task() must be a coderef";
    }
    if ( ref $handler ne 'CODE' ) {
        croak "handler argument to task() must be a coderef";
    }

    return $self->_action(
        $deps,
        $handler,
        bootstrap  => $bootstrap,
        results    => [],
    );
}

sub emit {
    my ( $self, $result ) = @_;

    if ( $self->{_cur_task} == 0 ) {
        croak "no active task";
    }

    my $task = $self->{_cur_task};
    push @{ $self->{_actions}{$task}{results} }, $result;
    push @{ $self->{_pending} },                 $task;

    return;
}

sub _run {
    my ( $self ) = @_;

    while ( 1 ) {
        while ( my $actionid = shift @{ $self->{_pending} } ) {
            $self->_handle( $actionid );
        }

        last if !%{ $self->{_actions} };

        my ( $actionid, undef, $result ) = $self->{_executor}->await;
        $self->{_actions}{$actionid}{result} = $result;
        push @{ $self->{_pending} }, $actionid;
    }

    return;
}

sub _action {
    my ( $self, $deps, $handler, %properties ) = @_;

    my $actionid = ++$self->{_num_actions};

    my %deps   = map { $_ => undef } @{$deps};
    my $parent = $self->{_cur_action};

    $self->{_actions}{$actionid} = {
        task => $actionid,
        %properties,
        handler        => $handler,
        num_dependents => 0,
        num_children   => 0,
        parent         => $parent,
        dependencies   => [ sort keys %deps ],
    };

    if ( $parent ) {
        $self->{_actions}{$parent}{num_children}++;
    }

    for my $dependent ( keys %deps ) {
        $self->{_actions}{$dependent}{num_dependents}++;
    }

    if ( !%deps ) {
        $self->_start( $actionid );
    }

    return $actionid;
}

sub _start {
    my ( $self, $actionid ) = @_;

    my $action = $self->{_actions}{$actionid};

    if ( exists $action->{result} ) {
        push @{ $self->{_pending} }, $actionid;
    }
    elsif ( exists $action->{command} ) {
        $self->{_executor}->submit( $actionid, $action->{command} );
    }
    elsif ( exists $action->{bootstrap} ) {
        local $self->{_cur_action} = $actionid;
        local $self->{_cur_task}   = $actionid;
        $action->{bootstrap}( $self );
    }
    else {
        croak "unreachable";
    }

    return;
}

sub _handle {
    my ( $self, $actionid ) = @_;

    if ( !exists $self->{_actions}{$actionid} ) {
        croak "attempting to handle unknown action ($actionid)";
    }

    my $action  = $self->{_actions}{$actionid};
    my $handler = $action->{handler};
    local $self->{_cur_task}   = $action->{task};
    local $self->{_cur_action} = $actionid;

    if ( exists $action->{command} ) {
        $handler->( $action->{command}, $action->{result} );
    }
    elsif ( exists $action->{bootstrap} ) {
        while ( my $result = shift @{ $action->{results} } ) {
            $handler->( $result );
        }
    }
    else {
        $handler->( $action->{result} );
    }

    $self->_finalize( $actionid );

    return;
}

sub _finalize {
    my ( $self, $actionid ) = @_;

    my @actionids;
    if ( !$self->_is_needed( $actionid) ) {
        push @actionids, $actionid;
    }

    for my $actionid ( @actionids ) {
        my $parent     = $self->{_actions}{$actionid}{parent};
        my $dependents = $self->{_actions}{$actionid}{dependents};

        if ( $parent != 0 ) {
            $self->{_actions}{$parent}{num_children}--;
            if ( !$self->_is_needed( $parent ) ) {
                push @actionids, $parent;
            }
        }

        for my $dependent ( @{$dependents} ) {
            $self->{_actions}{$dependent}{num_dependents}--;
            if ( !$self->_is_needed( $dependent ) ) {
                push @actionids, $dependent;
            }
        }

        delete $self->{_actions}{$actionid};
    }

    return;
}

sub _is_needed {
    my ( $self, $actionid ) = @_;

    if ( $actionid == 0 ) {
        return 1;
    }

    my $action = $self->{_actions}{$actionid};

    return $action->{num_children} > 0 || $action->{num_dependents} > 0 || @{ $action->{results} // [] }
}

1;
