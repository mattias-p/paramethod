
=head1 NAME

My::Streams::HandlerCache - Wraps a handler and caches its results.

=cut 

package My::Streams::HandlerCache;
use 5.020;
use warnings;
use parent qw( My::Streams::HandlerRole );

use Carp qw( croak );
use List::Util;
use My::Streams::Util qw( $END );
use Scalar::Util      qw( blessed looks_like_number );

=head1 CONSTRUCTORS

=head2 new()

    my $handler = My::Streams::HandlerCache->new( $inner_handler );

=cut

sub new {
    my ( $class, $handler, $cache ) = @_;

    $cache //= {};

    my $obj = {
        _inner   => $handler,
        _results => $cache,
        _pending => {},
        _keys    => {},
        _ready   => [],
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

Keeps track of which commands have been submitted.

The first time a command is seen it is propagated to the inner handler's submit() method.
When equivalent commands are seen, they're registered for immediate return from await().

=cut

sub submit {
    my ( $self, @args ) = @_;

    my $key = join '/', map s{/}{//}r, @args;

    if ( exists $self->{_results}{$key} ) {
        my $id = $self->new_id;

        $self->{_keys}{$id} = $key;

        push $self->{_ready}->@*, map { $id, $_ } $self->{_results}{$key}->@*;

        if ( exists $self->{_pending}{$key} ) {
            $self->{_pending}{$key}{$id} = undef;
        }

        return $id;
    }
    else {
        my $id = $self->{_inner}->submit( @args );
        if ( !defined $id || ref $id ne '' ) {
            croak sprintf "invalid id returned by %s::submit", blessed $self->{_inner};
        }

        $self->{_keys}{$id}     = $key;
        $self->{_pending}{$key} = { $id => undef };
        $self->{_results}{$key} = [];

        return $id;
    }
}

=head2 poll()

Caches results from commands that were propagated to the inner handler, and
reports cached results of commands that were merely registered.

=cut

sub poll {
    my ( $self ) = @_;

    if ( 0 == $self->{_keys}->%* ) {
        croak 'no pending actions';
    }

    my @results = splice $self->{_ready}->@*, 0, $self->{_ready}->@*;

    my @polled;
    if ( $self->{_pending}->%* ) {
        @polled = $self->{_inner}->poll;
    }
    my $i = 0;
    while ( $i < @polled ) {
        my ( $id, $element ) = @polled[ $i .. $i + 1 ];
        my $key = $self->{_keys}{$id};

        push $self->{_results}{$key}->@*, $element;

        if ( my $pending = $self->{_pending}{$key} ) {
            push @results, map { $_ => $element } sort keys %$pending;
        }

        if ( $element eq $END ) {
            delete $self->{_keys}{$id};
            delete $self->{_pending}{$key};
        }

        $i += 2;
    }

    return @results;
}

1;
