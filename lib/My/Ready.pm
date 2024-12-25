=head1 NAME

My::Ready - Represent a no-op pseudo-command.

=head1 DESCRIPTION

=cut

package My::Ready;
use 5.016;
use warnings;

use Carp qw( croak );
use Class::Accessor;
use Scalar::Util qw( blessed );

use Exporter 'import';
use base 'Class::Accessor';

our @EXPORT_OK = qw( ready );

=head1 CONSTRUCTORS

Constructs a new instance.

    use My::Ready qw( result => ready );

    my $ready = ready( 'foobar' );

=cut

sub ready {
    my ( %args ) = @_;

    if ( !defined $args{result} ) {
        croak "missing required argument: result";
    }

    my $obj = {
        result => delete $args{result},
    };

    if ( %args ) {
        croak "unrecognized arguments: " . join ' ', sort keys %args;
    }

    return bless $obj, 'My::Ready';
}

=head1 ATTRIBUTES

=head2 result

An scalar, required.

The result to provide to the handler.

=cut

My::Query->mk_accessors( qw( result ) );

1;
