
=head1 NAME

My::Scheduler - TODO

=cut

package My::Scheduler;
use 5.016;
use warnings;

use Carp qw( croak );
use Exporter 'import';
use Scalar::Util qw( blessed looks_like_number );

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

    my @results;

    $scheduler->handle( $bootstrap, sub {
        my ( @result ) = @_;

        push @results, \@result;
    });

    $scheduler->_run();

    return @results;
}

=head1 METHODS

executor->await returns:
'close', actionid
'return', actionid, results
'yield', actionid, results

=head2 submit()

    $scheduler->submit( [], $action, sub {
        my ( @result ) = @_;

        ...
    });

=cut

sub defer {
    my ( $self, $dependencies, $callback ) = @_;

    if ( ref $dependencies ne 'ARRAY' ) {
        croak "dependencies argument to defer() must be an arrayref";
    }
    if ( ref $callback ne 'CODE' ) {
        croak "callback argument to defer() must be a coderef";
    }

    return $self->_action( $dependencies, $callback );
}

sub handle {
    my ( $self, $action, $handler ) = @_;

    if ( ref $handler ne 'CODE' ) {
        croak "handler argument to handle() must be a coderef";
    }

    if ( blessed $action && $action->isa( 'My::Command' ) ) {
        return $self->_action( [], $handler, command => $action );
    }

    if ( ref $action eq 'CODE' ) {
        return $self->_action(
            [],
            $handler,
            bootstrap => $action,
            emissions => [],
        );
    }

    croak "action argument to handle() must be either a My::Command or a coderef";
}

sub emit {
    my ( $self, @args ) = @_;

    if ( $self->{_cur_task} == 0 ) {
        croak "no active task";
    }

    my $task = $self->{_cur_task};
    push @{ $self->{_actions}{$task}{emissions} }, \@args;
    push @{ $self->{_pending} },                   $task;

    return;
}

sub _run {
    my ( $self ) = @_;

    while ( 1 ) {
        while ( my $actionid = shift @{ $self->{_pending} } ) {
            $self->_handle( $actionid );
        }

        last if !%{ $self->{_actions} };

        my ( $op, $actionid, undef, @result ) = $self->{_executor}->await;

        if ( !looks_like_number($actionid) ) {
            croak "actionid must look like number";
        }

        if ( $op eq 'close' ) {
            $self->_finalize( $actionid );
        }
        else {
            $self->{_actions}{$actionid}{result} = \@result;
            push @{ $self->{_pending} }, $actionid;
        }
    }

    return;
}

sub _action {
    my ( $self, $dependencies, $handler, %properties ) = @_;

    my $actionid = ++$self->{_num_actions};

    my %dependencies = map { $_ => undef } @{$dependencies};
    my $parent       = $self->{_cur_action};

    $self->{_actions}{$actionid} = {
        %properties,
        task             => $self->{_cur_task},
        handler          => $handler,
        num_dependencies => scalar @{$dependencies},
        num_children     => 0,
        parent           => $parent,
        dependents       => [],
    };

    if ( $parent ) {
        $self->{_actions}{$parent}{num_children}++;
    }

    for my $dependency ( keys %dependencies ) {
        push @{ $self->{_actions}{$dependency}{dependents} }, $actionid;
    }

    if ( !%dependencies ) {
        $self->_start( $actionid );
    }

    return $actionid;
}

sub _start {
    my ( $self, $actionid ) = @_;

    if ( !looks_like_number($actionid) ) {
        croak "actionid must look like number";
    }

    my $action = $self->{_actions}{$actionid};

    if ( exists $action->{command} ) {
        $self->{_executor}->submit( $actionid, $action->{command} );
    }
    elsif ( exists $action->{bootstrap} ) {
        local $self->{_cur_action} = $actionid;
        local $self->{_cur_task}   = $actionid;
        $action->{bootstrap}( $self );
        $self->_finalize( $actionid );
    }
    else {
        push @{ $self->{_pending} }, $actionid;
    }

    return;
}

sub _handle {
    my ( $self, $actionid ) = @_;

    if ( !looks_like_number($actionid) ) {
        croak "actionid must look like number";
    }

    if ( !exists $self->{_actions}{$actionid} ) {
        croak "attempting to handle unknown action ($actionid)";
    }

    my $action  = $self->{_actions}{$actionid};
    my $handler = $action->{handler};
    local $self->{_cur_action} = $actionid;
    local $self->{_cur_task}   = $action->{task};

    if ( exists $action->{bootstrap} ) {
        my $args = shift @{ $action->{emissions} };
        $handler->( @$args );
    }
    elsif ( exists $action->{result} ) {
        $handler->( @{ $action->{result} } );
    }
    else {
        $handler->();
    }

    $self->_finalize( $actionid );

    return;
}

sub _finalize {
    my ( $self, $actionid ) = @_;

    my @actionids;
    if ( !$self->_is_needed( $actionid ) ) {
        push @actionids, $actionid;
    }

    for my $actionid ( @actionids ) {
        my $parent       = $self->{_actions}{$actionid}{parent};
        my @dependents = @{ $self->{_actions}{$actionid}{dependents} };

        if ( $parent != 0 ) {
            $self->{_actions}{$parent}{num_children}--;
            if ( !$self->_is_needed( $parent ) ) {
                push @actionids, $parent;
            }
        }

        for my $dependent ( @dependents ) {
            $self->{_actions}{$dependent}{num_dependencies}--;
            if ( $self->{_actions}{$dependent}{num_dependencies} == 0 ) {
                push @{ $self->{_pending} }, $dependent;
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

    return $action->{num_children} > 0 || $action->{num_dependencies} > 0 || @{ $action->{emissions} // [] };
}

1;
