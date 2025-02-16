package My::Streams::FingerprintSet;
use v5.20;
use warnings;

sub new {
    my ( $class, $fingerprinter ) = @_;

    my $obj = {
        _fingerprints  => {},
        _fingerprinter => $fingerprinter,
    };

    return bless $obj, $class;
}

sub insert {
    my ( $self, @element ) = @_;

    my $fingerprint = $self->{_fingerprinter}->( @element );

    if ( exists $self->{_fingerprints}{$fingerprint} ) {
        return 0;
    }
    else {
        $self->{_fingerprints}{$fingerprint} = undef;
        return 1;
    }
}

1;
