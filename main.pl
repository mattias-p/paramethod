use 5.016;

use My::CachingExecutor;
use My::SequentialExecutor;
use My::Query;

my $executor = My::CachingExecutor->new( My::SequentialExecutor->new );

my $query = My::Query->new( server_ip => '9.9.9.9', name => 'iis.se.', qtype => 'a' );
$executor->submit( $query );
$executor->submit( $query );

my ( $command, $result ) = $executor->await;
say $command;
say $result->string;

my ( $command, $result ) = $executor->await;
say $command;
say $result->string;
