package My::Query;
use 5.016;
use warnings;

use Scalar::Util qw( blessed );

use Class::Accessor;
use base 'Class::Accessor';
My::Query->mk_accessors( qw( server_ip name qtype ) );

use overload q("") => \&str;
use overload q(eq) => \&equals;

sub new {
    my ( $class, %args ) = @_;

    return bless {
        server_ip => $args{server_ip},
        name      => $args{name},
        qtype     => $args{qtype},
    }, $class;
}

sub equals {
    my ( $self, $other ) = @_;

    return
         blessed( $other )
      && $other->isa( 'Query' )
      && $self->server_ip eq $other->server_ip
      && $self->name eq $other->name
      && $self->qtype eq $self->qtype;
}

sub str {
    my ( $self ) = @_;

    return sprintf "%s %s %s %s", $self->command_type, $self->server_ip, $self->name, $self->qtype;
}

sub command_type {
    return "query";
}

sub args {
    my ( $self ) = @_;

    return $self->server_ip, $self->name, $self->qtype;
}

1;
