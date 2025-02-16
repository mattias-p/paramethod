package My::Streams::StreamBase;
use v5.20;
use warnings;

use Carp qw( croak confess );
use My::Streams::ConcatStream;
use My::Streams::EmptyStream      qw( item_mapper );
use My::Streams::FmapStream       qw( item_mapper );
use My::Streams::InterleaveStream qw( interleave );
use My::Streams::IterateStream;
use My::Streams::MemoStream;
use My::Streams::PreferDiscriminantsStream;
use My::Streams::SelectDiscriminantsStream;
use My::Streams::UniqStream;
use My::Streams::Util qw( $END );
use Scalar::Util      qw( blessed refaddr );
use Time::HiRes       qw( usleep );

use overload (
    '""' => 'stringify',
    '|'  => sub {
        my ( $lhs, $rhs, $swap ) = @_;
        if ( $swap ) {
            ( $rhs, $lhs ) = ( $lhs, $rhs );
        }
        interleave $lhs, $rhs;
    },
    '+' => sub {
        my ( $lhs, $rhs, $swap ) = @_;

        if ( $swap ) {
            ( $rhs, $lhs ) = ( $lhs, $rhs );
        }

        if ( !blessed $lhs || !$lhs->isa( 'My::Streams::StreamBase' ) ) {
            confess 'lhs: invalid stream';
        }

        if ( !blessed $rhs || !$rhs->isa( 'My::Streams::StreamBase' ) ) {
            confess 'rhs: invalid stream';
        }

        concat( $lhs, $rhs );
    },
);

sub _new {
    my ( $class, $origin_depth, @fields ) = @_;

    if ( "" . $origin_depth eq "defer" ) {
        confess;
    }
    my ( undef, $filename, $line ) = caller( $origin_depth );

    return bless [ 0, "$filename:$line", @fields ], $class;
}

sub _is_attached {
    my ( $self ) = @_;

    return $self->[0];
}

sub _attach {
    my ( $self ) = @_;

    if ( $self->[0] ) {
        confess sprintf '%s (%s) is already attached', $self, $self->origin;
    }

    $self->[0] = 1;

    return;
}

sub origin {
    my ( $self ) = @_;

    return $self->[1];
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    croak sprintf "not implemented by %s", blessed $self;
}

sub stringify {
    my ( $self ) = @_;

    croak sprintf "not implemented by %s", blessed $self;
}

sub upstreams {
    my ( $self ) = @_;

    croak sprintf "not implemented by %s", blessed $self;
}

sub _become_exhausted {
    my ( $self ) = @_;

    $self->@* = ();
    bless $self, 'My::Streams::ExhaustedStream';

    return;
}

sub flatmap_end {
    my ( $self, $mapper ) = @_;

    return My::Streams::FlatmapEndStream->_new( $mapper, $self );
}

sub flatmap {
    my ( $self, $mapper ) = @_;

    return My::Streams::FlatmapEndStream->_new( item_mapper( $mapper ), $self );
}

sub fmap {
    my ( $self, $mapper ) = @_;

    return My::Streams::FmapStream->_new( $mapper, $self );
}

sub concat {
    my ( $self, $stream ) = @_;

    if ( !blessed $stream || !$stream->isa( 'My::Streams::StreamBase' ) ) {
        confess 'invalid stream';
    }

    return My::Streams::ConcatStream::concat( $self, $stream );
}

sub iterate {
    my ( $self, $mapper ) = @_;

    return My::Streams::IterateStream->_new( $mapper, $self );
}

sub extras {
    return;
}

sub preorder (&$) {
    my ( $callback, $root ) = @_;

    my %seen;
    my @queue = ( 0, $root, undef );
    while ( @queue ) {
        my ( $depth, $stream, $downstream ) = splice @queue, -3;

        $callback->( $depth, $stream, $downstream );
        for my $upstream ( reverse $stream->upstreams ) {
            if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
                confess sprintf 'invalid stream returned from %s::upstreams', $stream;
            }
            next if exists $seen{ refaddr $upstream};
            $seen{ refaddr $upstream} = undef;

            push @queue, $depth + 1, $upstream, $stream;
        }
    }

    return;
}

sub preorder_with_extras (&$) {
    my ( $callback, $root ) = @_;

    my %seen;
    my @queue = ( 0, $root, undef, 0 );
    while ( @queue ) {
        my ( $depth, $stream, $downstream, $is_extra ) = splice @queue, -4;

        $callback->( $depth, $stream, $downstream, $is_extra );
        for my $upstream ( reverse $stream->upstreams ) {
            if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
                confess sprintf 'invalid stream returned from %s::upstreams', $stream;
            }
            next if exists $seen{ refaddr $upstream};
            $seen{ refaddr $upstream} = undef;

            push @queue, $depth + 1, $upstream, $stream, 0;
        }

        for my $upstream ( reverse $stream->extras ) {
            if ( !blessed $upstream || !$upstream->isa( 'My::Streams::StreamBase' ) ) {
                confess sprintf 'invalid stream returned from %s::upstreams', $stream;
            }
            next if exists $seen{ refaddr $upstream};
            $seen{ refaddr $upstream} = undef;

            push @queue, $depth + 1, $upstream, $stream, 1;
        }
    }

    return;
}

sub pretty {
    my ( $self ) = @_;

    my @parts;
    preorder_with_extras {
        my ( $depth, $stream, undef, $is_extra ) = @_;
        my $prefix = $is_extra ? '*' : '';
        push @parts, '  ' x $depth, $prefix, $stream->stringify, "\t(", $stream->origin, ")\n";
    }
    $self;

    return join( '', @parts );
}

sub refresh {
    my ( $self, $handlers, $actions ) = @_;

    my $produced = 0;

    for my $kind ( sort keys $handlers->%* ) {
        my $handler = $handlers->{$kind};
        my @results = $handler->poll();

        my $i = 0;
        while ( $i < @results ) {
            my ( $id, $element ) = @results[ $i, $i + 1 ];

            if ( !defined $id || ref $id ne '' ) {
                croak sprintf "invalid id returned by %s::poll", blessed $handler;
            }

            push $actions->{ refaddr $handler}{$id}->_ready->@*, $element;

            if ( $element eq $END ) {
                delete $actions->{ refaddr $handler}{$id};
            }

            $i += 2;
        }

        $produced ||= !!@results;
    }

    return $produced;
}

sub _sleep {
    usleep( 100 );
}

sub memoize {
    my ( $self ) = @_;

    return My::Streams::MemoStream->_new( $self );
}

sub select_discriminants {
    my ( $self, @discriminants ) = @_;

    if ( @discriminants ) {
        return My::Streams::SelectDiscriminantsStream->_new( $self, @discriminants );
    }
    else {
        return $self;
    }
}

sub prefer_discriminants {
    my ( $self, @discriminants ) = @_;

    if ( @discriminants ) {
        return My::Streams::PreferDiscriminantsStream->_new( $self, @discriminants );
    }
    else {
        return $self;
    }
}

sub uniq {
    my ( $self, $uniqueness ) = @_;

    return My::Streams::UniqStream->new( $uniqueness, $self );
}

sub traverse {
    my ( $self, $callback, @handlers ) = @_;

    $self->traverse_end( item_mapper( $callback ), @handlers );

    return;
}

sub traverse_end {
    my ( $self, $callback, @handlers ) = @_;

    my %actions;

    my %handlers;
    for my $handler ( @handlers ) {
        if ( !blessed $handler || !$handler->isa( 'My::Streams::HandlerRole' ) ) {
            confess 'invalid handler';
        }
        $handlers{ $handler->action_kind } = $handler;
    }

    my $perform = sub {
        my ( $action ) = @_;

        my $handler = $handlers{ $action->kind }
          or confess sprintf 'no bind for action kind %s', $self->kind;

        my $id = $handler->submit( $action->args );
        if ( !defined $id || ref $id ne '' ) {
            croak sprintf "invalid id returned by %s::submit", blessed $self->_handler;
        }

        $actions{ refaddr $handler}{$id} = $action;
    };

    $self->_attach();

    $self->flush( $callback, {}, $perform );

    while ( !$self->is_exhausted ) {
        while ( !$self->refresh( \%handlers, \%actions ) ) {
            $self->_sleep;
        }

        $self->flush( $callback, {}, $perform );
    }

    return;
}

sub collect {
    my ( $self, @handlers ) = @_;

    my @elements;
    $self->traverse_end( sub { push @elements, $_[0] }, @handlers );
    pop @elements;

    return @elements;
}

sub is_exhausted {
    return 0;
}

1;
