package My::Streams::ExhaustedStream;
use v5.20;
use warnings;

use Carp     qw( confess );
use Exporter qw( import );
use My::Streams::StreamBase;
use Readonly;

use parent qw( My::Streams::StreamBase );

our @EXPORT_OK = qw(
  $EXHAUSTED
  empty
);

Readonly our $EXHAUSTED => bless [], __PACKAGE__;

sub exhausted () {
    return $EXHAUSTED;
}

sub is_exhausted {
    return 1;
}

sub upstreams {
    my ( $self ) = @_;

    return;
}

sub stringify {
    return "exhausted";
}

sub flush {
    my ( $self, $callback ) = @_;

    confess 'already exhausted';

    return;
}

1;
