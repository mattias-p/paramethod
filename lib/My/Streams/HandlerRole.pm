package My::Streams::HandlerRole;
use v5.20;
use warnings;

use Carp         qw( confess croak );
use Scalar::Util qw( blessed );

sub action_kind {
    my ( $self ) = @_;

    croak sprintf "My::Streams::HandlerRole::action_kind not implemented by %s", blessed $self;
}

# Returns
#  * id - a new unique id
sub new_id {
    my ( $self, @args ) = @_;

    croak sprintf "My::Streams::HandlerRole::new_id not implemented by %s", blessed $self;
}

# Returns
#  * id - the new action
sub submit {
    my ( $self, @args ) = @_;

    croak sprintf "My::Streams::HandlerRole::submit not implemented by %s", blessed $self;
}

# Returns
#  * () - no results are available at this time.
#  * (id, element) - a result is available.
sub poll {
    my ( $self ) = @_;

    croak sprintf "My::Streams::HandlerRole::poll not implemented by %s", blessed $self;
}

1;
