=head1 NAME

My::DNS::Query - Represents a DNS query command.

=head1 DESCRIPTION

=cut

package My::DNS::Query;
use 5.016;
use warnings;

use Carp qw( croak );
use Class::Accessor;
use Scalar::Util qw( blessed );
use Data::Validate::IP qw( is_ip );

use Exporter 'import';
use base 'Class::Accessor';
use parent 'My::Concurrent::Command';

our @EXPORT_OK = qw( query );

=head1 CONSTRUCTORS

Constructs a new instance.

    use My::DNS::Query qw( query );

    my $query = query( server_ip => '9.9.9.9', qname => 'iis.se', qtype => 'A' );

=cut

sub query {
    my ( %args ) = @_;

    if ( !defined $args{server_ip} || !is_ip( $args{server_ip} ) ) {
        croak "argument must be an IP address: server_ip";
    }

    if ( !defined $args{qname} || ref $args{qname} ne '' || $args{qname} eq '' ) {
        croak "argument must be a non-empty scalar: qname";
    }

    if ( !defined $args{qtype} ) {
        croak "missing required argument: qtype";
    }

    my $obj = {
        server_ip => delete $args{server_ip},
        qname     => delete $args{qname},
        qtype     => delete $args{qtype},
    };

    if ( %args ) {
        croak "unrecognized arguments: " . join ' ', sort keys %args;
    }

    return bless $obj, 'My::DNS::Query';
}

=head1 ATTRIBUTES

=head2 server_ip

An IP address, required.

The name server IP to send the query to.

=head2 qname

A domain name, required.

The qname to use in the query.

=head2 qtype

An RRtype, required.

The qtype to use in the query.

=cut

My::DNS::Query->mk_accessors( qw( server_ip qname qtype ) );

=head1 METHODS

=head2 arg_strings()

=cut

sub arg_strings {
    my ( $self ) = @_;

    return $self->server_ip, lc $self->qname =~ s/(.)\.$/$1/r, uc $self->qtype;
}

1;
