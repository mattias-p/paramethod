package My::Streams::InterleaveStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp                     qw( confess );
use Exporter                 qw( import );
use My::Streams::EmptyStream qw( empty );
use My::Streams::Util        qw( $END );
use Scalar::Util             qw( blessed );

our @EXPORT_OK = qw( interleave );

sub interleave {
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

        $_->isa( __PACKAGE__ )
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
    return "interleave";
}

sub flush {
    my ( $self, $callback, $dups, $binds ) = @_;

    $dups  //= {};
    $binds //= {};

    my @exhausted;

    for my $i ( 2 .. $self->$#* ) {
        my $upstream = $self->[$i];

        $upstream->flush(
            sub {
                my ( $element ) = @_;

                if ( $element eq $END ) {
                    push @exhausted, $i;
                }
                else {
                    $callback->( $element );
                }
            },
            $dups,
            $binds,
        );
    }

    for my $i ( reverse @exhausted ) {
        splice $self->@*, $i, 1;
    }

    if ( !$self->upstreams ) {
        $self->_become_exhausted();
        $callback->( $END );
    }

    return;
}

1;
