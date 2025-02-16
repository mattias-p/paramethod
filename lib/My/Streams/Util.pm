package My::Streams::Util;
use v5.20;
use warnings;

use Exporter qw( import );
use Readonly;

our @EXPORT_OK = qw(
  $END
);

Readonly our $END => '$END';

1;
