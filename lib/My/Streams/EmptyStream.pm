package My::Streams::EmptyStream;
use v5.20;
use warnings;
use parent qw( My::Streams::StreamBase );

use Carp              qw( confess );
use Exporter          qw( import );
use My::Streams::Util qw( $END );

our @EXPORT_OK = qw(
  empty
  item_mapper
);

sub empty () {
    return My::Streams::StreamBase::_new( __PACKAGE__, 2 );
}

sub item_mapper {
    my ( $mapper ) = @_;

    return sub {
        my ( $item ) = @_;

        if ( ref $item ne 'ARRAY' && $item ne $END ) {
            confess 'invalid element';
        }

        return $item eq $END
          ? empty
          : $mapper->( @$item );
    };
}

sub upstreams {
    my ( $self ) = @_;

    return;
}

sub stringify {
    return "empty";
}

sub flush {
    my ( $self, $callback ) = @_;

    $callback->( $END );
    $self->_become_exhausted();

    return;
}

1;
