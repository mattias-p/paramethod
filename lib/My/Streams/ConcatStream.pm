package My::Streams::ConcatStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp                     qw( confess );
use Exporter                 qw( import );
use My::Streams::EmptyStream qw( empty );
use My::Streams::Util        qw( $END );
use Scalar::Util             qw( blessed );

our @EXPORT_OK = qw( concat );

sub concat {
    my ( @streams ) = @_;

    if ( @streams == 0 ) {
        return empty;
    }

    if ( @streams == 1 ) {
        return $streams[0];
    }

    @streams = map {
        if ( !blessed $_ || !$_->isa( 'My::Streams::StreamBase' ) ) {
            confess 'invalid stream';
        }

        $_->_attach();

        $_->isa( 'My::Stream::ConcatStream' )
          ? $_->upstreams
          : ( $_ );
    } @streams;

    return My::Streams::StreamBase::_new( __PACKAGE__, 1, @streams );
}

sub upstreams {
    my ( $self ) = @_;

    return grep { defined $_ } $self->@[ 2 .. $self->$#* ];
}

sub stringify {
    return "concat";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    while ( $self->upstreams ) {
        $self->[2]->flush(
            sub {
                my ( $element ) = @_;

                if ( $element ne $END ) {
                    $callback->( $element );
                }
            },
            $dups,
            $binds,
        );

        if ( $self->[2]->is_exhausted ) {
            splice $self->@*, 2, 1;
        }
        else {
            return;
        }
    }

    $self->_become_exhausted();
    $callback->( $END );

    return;
}

1;
