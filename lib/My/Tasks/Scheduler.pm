
=head1 NAME

My::Tasks::Scheduler - Implements cooperative multi-tasking.

=cut

package My::Tasks::Scheduler;
use 5.016;
use warnings;

use Carp         qw( croak );
use Scalar::Util qw( blessed looks_like_number );

=head1 CONSTRUCTORS

=head2 new EXECUTOR

Construct an instance that delegates commands to EXECUTOR.

    my $scheduler = My::Tasks::Scheduler->new( $executor );

The EXECUTOR must implement My::Tasks::Executor.
Exclusive control over EXECUTOR is assumed.

=cut

sub new {
    my ( $class, $executor, $stats_ref ) = @_;

    $stats_ref //= \my $dummy;
    $$stats_ref = { tasks => 0 };

    if ( !blessed $executor || !$executor->isa( 'My::Tasks::Executor' ) ) {
        croak "executor argument must be a My::Tasks::Executor";
    }

    my $scheduler = {
        _executor     => $executor,
        _stats        => $$stats_ref,
        _num_tasks    => 0,
        _cur_task     => 0,
        _cur_consumer => 0,
        _tasks        => {},
        _pending      => [],
        _results      => [],
    };

    return bless $scheduler, $class;
}

=head1 METHODS

=head2 produce LIST

Produce a result.

    $scheduler->produce( @result );

=cut

sub produce {
    my ( $self, @result ) = @_;

    if ( $self->{_cur_consumer} == 0 ) {
        push @{ $self->{_results} }, \@result;
    }
    else {
        my $taskid = $self->{_cur_consumer};
        push @{ $self->{_tasks}{$taskid}{results} }, \@result;
        push @{ $self->{_pending} },                 $taskid;
    }

    return;
}

=head2 flatmap PRODUCER, CONSUMER

Schedule a consumer task with an attached producer.

    my $coderef = sub {
        my ( $scheduler ) = @_;
        ...
    };
    $scheduler->flatmap( $coderef, sub {
        my ( @result ) = @_;
        ...
    });

    $scheduler->flatmap( $command, sub {
        my ( @result ) = @_;
        ...
    });

The PRODUCER may be a coderef. The coderef is called with the My::Tasks::Scheduler instance as
its only argument.
The PRODUCER may be a My::Tasks::Command instance. The instance is submitted to the executor.
For each result produced by the PRODUCER, the CONSUMER is called with the result as its
arguments.

Returns a task id.

=cut

sub flatmap {
    my ( $self, $producer, $consumer ) = @_;

    if ( ref $consumer ne 'CODE' ) {
        croak "CONSUMER argument must be a coderef";
    }

    if ( blessed $producer && $producer->isa( 'My::Tasks::Command' ) ) {
        return $self->_task( [], $consumer, command => $producer );
    }

    if ( ref $producer eq 'CODE' ) {
        return $self->_task(
            [],
            $consumer,
            producer => $producer,
            results  => [],
        );
    }

    croak "PRODUCER argument must be either a My::Tasks::Command or a coderef";
}

=head2 after DEPENDENCIES, ACTION

Schedule an action task.

    $scheduler->after( \@dependencies, sub {
        ...
    });

DEPENDENCIES is an arrayref of task ids.
ACTION is a coderef. It is called without arguments once all DEPENDENCIES have completed.

Returns a task id.

=cut

sub after {
    my ( $self, $dependencies, $action ) = @_;

    if ( ref $dependencies ne 'ARRAY' ) {
        croak "dependencies argument must be an arrayref";
    }
    if ( ref $action ne 'CODE' ) {
        croak "action argument must be a coderef";
    }

    return $self->_task( $dependencies, $action );
}

=head2 run

Run the scheduled tasks until there are no more uncompleted tasks.

    my @results = $scheduler->run;

Returns a list of unconsumed results. Each result is returned as an arrayref.

=cut

sub run {
    my ( $self ) = @_;

    while ( 1 ) {
        while ( my $taskid = shift @{ $self->{_pending} } ) {
            $self->_handle( $taskid );
        }

        last if !%{ $self->{_tasks} };

        my ( $taskid, undef, $result ) = $self->{_executor}->await;

        if ( !looks_like_number( $taskid ) ) {
            croak sprintf "taskid (from %s) must look like number", ref $self->{_executor};
        }

        if ( defined $result ) {
            $self->{_tasks}{$taskid}{result} = $result;
            push @{ $self->{_pending} }, $taskid;
        }
        else {
            $self->_finalize( $taskid );
        }
    }

    ( my $results, $self->{_results} ) = ( $self->{_results}, [] );
    return @$results;
}

sub _task {
    my ( $self, $dependencies, $handler, %properties ) = @_;

    my $taskid = ++$self->{_num_tasks};
    $self->{_stats}{tasks} = $self->{_num_tasks};

    my %dependencies = map { $_ => undef } @{$dependencies};
    my $parent       = $self->{_cur_task};

    $self->{_tasks}{$taskid} = {
        %properties,
        consumer         => $self->{_cur_consumer},
        handler          => $handler,
        num_dependencies => scalar @{$dependencies},
        num_children     => 0,
        parent           => $parent,
        dependents       => [],
    };

    if ( $parent ) {
        $self->{_tasks}{$parent}{num_children}++;
    }

    for my $dependency ( keys %dependencies ) {
        push @{ $self->{_tasks}{$dependency}{dependents} }, $taskid;
    }

    if ( !%dependencies ) {
        $self->_start( $taskid );
    }

    return $taskid;
}

sub _start {
    my ( $self, $taskid ) = @_;

    if ( !looks_like_number( $taskid ) ) {
        croak "taskid must look like number";
    }

    my $task = $self->{_tasks}{$taskid};

    if ( exists $task->{command} ) {
        $self->{_executor}->submit( $taskid, $task->{command} );
    }
    elsif ( exists $task->{producer} ) {
        local $self->{_cur_task}     = $taskid;
        local $self->{_cur_consumer} = $taskid;
        $task->{producer}( $self );
        $self->_finalize( $taskid );
    }
    else {
        push @{ $self->{_pending} }, $taskid;
    }

    return;
}

sub _handle {
    my ( $self, $taskid ) = @_;

    if ( !looks_like_number( $taskid ) ) {
        croak "taskid must look like number";
    }

    if ( !exists $self->{_tasks}{$taskid} ) {
        croak "attempting to handle unknown task ($taskid)";
    }

    my $task    = $self->{_tasks}{$taskid};
    my $handler = $task->{handler};
    local $self->{_cur_task}     = $taskid;
    local $self->{_cur_consumer} = $task->{consumer};

    if ( exists $task->{producer} ) {
        my $args = shift @{ $task->{results} };
        $handler->( @$args );
    }
    elsif ( exists $task->{result} ) {
        $handler->( @{ $task->{result} } );
    }
    else {
        $handler->();
    }

    $self->_finalize( $taskid );

    return;
}

sub _finalize {
    my ( $self, $taskid ) = @_;

    my @taskids;
    if ( !$self->_is_needed( $taskid ) ) {
        push @taskids, $taskid;
    }

    for my $taskid ( @taskids ) {
        my $parent     = $self->{_tasks}{$taskid}{parent};
        my @dependents = @{ $self->{_tasks}{$taskid}{dependents} };

        if ( $parent != 0 ) {
            $self->{_tasks}{$parent}{num_children}--;
            if ( !$self->_is_needed( $parent ) ) {
                push @taskids, $parent;
            }
        }

        for my $dependent ( @dependents ) {
            $self->{_tasks}{$dependent}{num_dependencies}--;
            if ( $self->{_tasks}{$dependent}{num_dependencies} == 0 ) {
                push @{ $self->{_pending} }, $dependent;
            }
        }

        delete $self->{_tasks}{$taskid};
    }

    return;
}

sub _is_needed {
    my ( $self, $taskid ) = @_;

    if ( $taskid == 0 ) {
        return 1;
    }

    my $task = $self->{_tasks}{$taskid};

    return $task->{num_children} > 0 || $task->{num_dependencies} > 0 || @{ $task->{results} // [] };
}

1;
