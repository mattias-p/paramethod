package My::Executor;
use 5.016;
use warnings;

use My::Query;
use Readonly;
use Zonemaster::LDNS;

Readonly my %command_types => (
    query => sub {
        my ( $server_addr, $name, $rrtype ) = @_;

        return Zonemaster::LDNS->new( $server_addr )->query( $name, $rrtype );
    },
);

sub new {
    my ( $class ) = @_;

    my $obj = {
        _commands => [],
        _cache => {},
    };

    bless $obj, $class;

    return $obj;
}

sub submit {
    my ( $self, $command ) = @_;

    push @{ $self->{_commands} }, $command;

    return;
}

sub await {
    my ( $self ) = @_;

    my $command = shift @{ $self->{_commands} };

    if ( my $result = $self->{_cache}{$command} ) {
        return $command, $result;
    }

    my $result = $command_types{$command->command_type}->( $command->args );

    $self->{_cache}{$command} = $result;

    return $command, $result;
}

1;
