package My::Streams::SingletonStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Exporter          qw( import );
use My::Streams::Util qw( $END );

our @EXPORT_OK = qw( singleton );

sub singleton {
    my ( @args ) = @_;

    return My::Streams::StreamBase::_new( __PACKAGE__, 2, @args );
}

sub args {
    my ( $self ) = @_;

    return $self->@[ 2 .. $self->$#* ];
}

sub upstreams {
    my ( $self ) = @_;

    return;
}

sub stringify {
    return "singleton";
}

sub flush {
    my ( $self, $callback, undef, undef ) = @_;

    $callback->( [ $self->args ] );
    $callback->( $END );
    $self->_become_exhausted();

    return;
}

1;
