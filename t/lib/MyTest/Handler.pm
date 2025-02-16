package MyTest::Handler;
use v5.20;
use warnings;

use parent qw( My::Streams::HandlerRole );

use Carp qw( confess );

sub new {
    my ( $class, $action_kind ) = @_;

    my $obj = {
        _action_kind => $action_kind,
        _next_id     => 1,
        _expected    => {},
        _started     => [],
        _delays      => [],
    };

    return bless $obj, $class;
}

sub _mk_action {
    my ( @args ) = @_;
    return join '-', map { $_ =~ s/-/--/r } @args;
}

sub expect {
    my ( $self, $args, @results ) = @_;

    my $action = _mk_action( $args->@* );
    $self->{_expected}{$action} //= [];
    push $self->{_expected}{$action}->@*, \@results;

    return $self;
}

sub action_kind {
    my ( $self ) = @_;

    return $self->{_action_kind};
}

sub submit {
    my ( $self, @args ) = @_;

    my $action  = _mk_action( @args );
    my @results = shift( $self->{_expected}{$action}->@* )->@*;

    my $id = $self->{_next_id}++;

    my $accum_delay = 0;
    while ( @results ) {
        my ( $delay, $element ) = splice @results, 0, 2;

        $accum_delay += $delay;
        push $self->{_delays}->@*,  $accum_delay;
        push $self->{_started}->@*, [ $id, $element ];
    }

    return $id;
}

use Data::Dumper;

sub poll {
    my ( $self, @ids ) = @_;

    my @results;
    for my $i ( reverse 0 .. $self->{_started}->$#* ) {
        if ( $self->{_delays}[$i] <= 0 ) {
            splice $self->{_delays}->@*, $i, 1;
            my ( $id, $element ) = splice( $self->{_started}->@*, $i, 1 )->@*;
            push @results, $element, $id;
        }
        else {
            $self->{_delays}[$i]--;
        }
    }

    return reverse @results;
}

1;
