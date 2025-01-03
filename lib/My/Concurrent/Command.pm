=head1 NAME

My::Concurrent::Command - Base class for commands.

=cut

package My::Concurrent::Command;
use 5.016;
use warnings;

=head1 OPERATORS

=head2 string conversion

Stringification is overloaded to call stringify().

=cut

use overload q("") => \&stringify;

=head1 METHODS

=head2 stringify()

Returns a stringification of the command.

=cut

sub stringify {
    my ( $self ) = @_;

    return join( ' ', ref( $self ), $self->arg_strings );
}

=head1 ABSTRACT METHODS

=head2 arg_strings()

Should return all command attributes as a list of normalized strings.

The strings are used for string conversion and comparison.
They should be normalized and consist of printable characters.

=cut

sub arg_strings {
    my ( $self ) = @_;

    die ref($self) . " must implement arg_strings()";
}

1;
