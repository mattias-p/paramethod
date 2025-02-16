package My::Streams::MemoStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Exporter qw( import );
use My::Streams::ExhaustedStream;
use My::Streams::Util qw( $END );

our @EXPORT_OK = qw( memoize );

sub memoize ($) {
    my ( $stream ) = @_;

    return __PACKAGE__->_new( $stream );
}

sub _new {
    my ( $class, $upstream ) = @_;

    if ( $upstream->isa( __PACKAGE__ ) ) {
        return $upstream;
    }

    $upstream->_attach();

    state $next_memo_id = 1;

    my $memo_id     = $next_memo_id++;
    my $buffer      = [];
    my $clone_count = 1;

    return My::Streams::StreamBase::_new(    #
        __PACKAGE__,
        2,
        $memo_id,
        1,
        \$clone_count,
        $buffer,
        0,
        $upstream,
    );
}

sub tee {
    my ( $self ) = @_;

    my $clone_count = $self->_clone_count;
    my $clone_id    = ++$clone_count->$*;

    return My::Streams::StreamBase::_new(    #
        __PACKAGE__,
        1,
        $self->memo_id,
        $clone_id,
        $clone_count,
        $self->_buffer,
        0,
        $self->_upstream,
    );
}

sub memo_id {
    my ( $self ) = @_;

    return $self->[2];
}

sub clone_id {
    my ( $self ) = @_;

    return $self->[3];
}

sub _clone_count {
    my ( $self ) = @_;

    return $self->[4];
}

sub _buffer {
    my ( $self ) = @_;

    return $self->[5];
}

sub _offset {
    my ( $self ) = @_;

    return $self->[6];
}

sub _set_offset {
    my ( $self, $value ) = @_;

    $self->[6] = $value;

    return;
}

sub _upstream {
    my ( $self ) = @_;

    return $self->[7];
}

sub upstreams {
    my ( $self ) = @_;

    return $self->_upstream;
}

sub stringify {
    my ( $self ) = @_;

    return sprintf "memo-%d#%d", $self->memo_id, $self->clone_id;
}

sub flush {
    my ( $self, $callback, $memos, $binds ) = @_;

    $memos //= {};
    $binds //= {};

    for my $element ( $self->_buffer->@[ $self->_offset .. $self->_buffer->$#* ] ) {
        $callback->( $element );
        if ( $element eq $END ) {
            $self->_become_exhausted();
            return;
        }
    }
    $self->_set_offset( scalar $self->_buffer->@* );

    if ( !exists $memos->{ $self->memo_id } ) {
        $memos->{ $self->memo_id } = undef;

        $self->_upstream->flush(
            sub {
                my ( $element ) = @_;

                push $self->_buffer->@*, $element;

                $callback->( $element );
                $self->_set_offset( scalar $self->_buffer->@* );

                if ( $element eq $END ) {
                    $self->_become_exhausted();
                }
            },
            $memos,
            $binds,
        );
    }

    return;
}

1;
