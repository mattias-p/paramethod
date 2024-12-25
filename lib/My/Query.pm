package My::Query;
use 5.016;
use warnings;

use parent 'My::Command';

use Class::Accessor;
use base 'Class::Accessor';
My::Query->mk_accessors( qw( server_ip name qtype ) );

use Scalar::Util qw( blessed );

sub new {
    my ( $class, %args ) = @_;

    return bless {
        server_ip => $args{server_ip},
        name      => $args{name},
        qtype     => $args{qtype},
    }, $class;
}

sub arg_strings {
    my ( $self ) = @_;

    return $self->server_ip, lc $self->name =~ s/(.)\.$/\1/r, uc $self->qtype;
}

1;
