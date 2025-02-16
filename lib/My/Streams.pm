package My::Streams;
use v5.20;
use warnings;

use Carp                      qw( confess );
use Exporter                  qw( import );
use My::Streams::ActionStream qw( action );
use My::Streams::ConcatStream qw( concat );
use My::Streams::EmptyStream  qw( empty item_mapper );
use My::Streams::FingerprintSet;
use My::Streams::FlatmapEndStream;
use My::Streams::InterleaveStream qw( interleave );
use My::Streams::MemoStream       qw( memoize );
use My::Streams::SingletonStream  qw( singleton );
use Scalar::Util                  qw( blessed );

=head1 NAME

My::Streams - Concurrently constructed streams.

=head1 DESCRIPTION

The My::Streams library provides a model for concurrently constructed streams.

A stream is an object that produces a (potentially infinite) sequence of data elements,
and may block between elements and before termination.

Note that streams do not necessarily need to be long just because they can.
The response to a request could be modeled by a stream with a single element that gets
produced when the response is received, and a timeout could be modeled by the stream
terminating without producing an element.

At the core of My::Streams is a small but powerful set of predefined stream types, each
with its own production and termination logic.
Constructors are available for trivial streams, transforming streams, merging multiple
streams, memoizing streams, and importing streams from external sources.
Complex streams can be composed from these primitives, forming a DAG of streams that
consume each other to collectively produce the desired stream of data elements.

Streams are transformed using "mapper" functions.
A mapper function is one that transforms an element into a stream.
This mechanism allows a stream to construct itself while it is being evaluated.

Streams from external sources are imported with the help of "effect handlers".
An effect handler receives requests from streams of the "action" stream type.
The effect handler responds by producing elements for the stream and triggering its
termination.

One notable use case is the compilation of advanced reports of DNS data queried from
authoritative servers.

=head2 CONCURRENCY

Concurrency refers to multiple tasks being in progress at the same time.
This can be achieved by putting one task to the side while working on another.
Parallelism is concurrency with the added requirement that tasks are actually being
executed at the same time.
My::Streams evaluates streams concurrently but not in parallel.

As far as My::Streams is concerned, mappers functions do not need to be thread-safe.
But they do need to return quickly, or they interfere with the concurrent nature of
My::Streams.
Any operation that cannot be performed quickly should be offloaded to an effect handler to
be handled asynchronously.

When defining mapper functions nothing technically prevents you from binding lexical
variables outside of the function itself, but such practice is discouraged because memory
sharing behavior is difficult to test and debug.

Asynchronous requests should be sent out as soon as possible and intermediate results
should be produced as soon as possible.
This way processing can go on with minimal blocking as soon as new data comes available.

=head2 STREAMS

A stream is an object that produces a (potentially infinite) sequence of data elements,
and may block between elements and before termination.
An element is a list of Perl values that are opaque to My::Streams.

Streams do nothing unless you call their traverse method, either directly or indirectly.

Some streams produce elements by transforming or merging other streams.
The consuming stream is called the "downstream", and the consumed streams are called
"upstreams".
Also, when an stream is explicitly traversed, it is considered to be used an "upstream".

If a mapper function throws an exception, the ongoing traversal is aborted and cannot be
resumed.
To avoid aborting traversal in face of errors, mapper functions are recommended to produce
an element that represents the error.

Because how My::Streams is implemented, a stream can only produce elements for a single
downstream.
To avoid surprizing behaviors when a stream is accidentally used as an upstream more than
once, a simple ownership system has been implemented.
If a stream is used as an upstream more than once, an exception is thrown.
This limitation can be worked around using the L</memoize> and L</tee> constructors.

When a stream terminates, an event is triggered on its downstream.
Each type of stream has its own rules for what happens when an upstream is terminated.

=head3 traverse CONSUMER, STREAM

Traverse a stream.

The CONSUMER argument is a callback that takes an element as its arguments, and whose
return value is ignored.
Is called for each element as soon as it is produced.

Blocks until the given stream terminates.

Exceptions thrown by the mapper function are not caught by traverse.

=head3 empty

Construct a new empty stream.

    my $stream = empty;

Formal specification:

=over 2

=item

The output stream contains no elements.

=item

The output stream terminates immediately.

=back

=head3 singleton ELEMENT

Construct a new singleton stream.

    my $stream = singleton( 'shoesize', 46 );

Formal specification:

=over 2

=item

The output stream contains exactly one element.

=item

The first element must consists of the same values as the arguments to the constructor.

=item

The output stream terminates immediately after producing the element.

=back

=head3 concat STREAM...

Construct a new concat stream with zero or more upstreams.

    my $stream = concat(
        $upstream1,
        $upstream2,
    );

C<concat()> is equivalent to C<empty()>.

C<concat($stream)> is equivalent to C<$stream>.

Formal properties:

=over 2

=item

The output stream contains all elements of all input streams, and no additional elements.

=item

Elements from a given input stream appear in the output stream in the same relative order
as they were in the input stream.

=item

Elements from earlier upstreams in the list appear before elements from later upstreams.

=back

=head3 interleave STREAM...

Construct a new interleave stream with zero or more upstreams.

    my $stream = interleave(
        $upstream1,
        $upstream2,
    );

C<interleave()> is equivalent to C<empty()>.

C<interleave($stream)> is equivalent to C<$stream>.

Formal specification:

=over 2

=item

The output stream contains all elements of all input streams, and no additional elements.

=item

Elements from a given input stream appear in the output stream in the same relative order
as they were in the input stream.

=item

If at least one stream is not blocked at a given moment, the output stream must make
progress by emitting an element.

=back

=head3 flatmap MAPPER, STREAM

Construct a new flatmap stream.

    my $stream = $integer_stream->flatmap( sub {
        my ( $integer ) = @_;

        if ( $integer % 2 != 0 ) {
            return empty;
        }

        return singleton( $integer );
    });

C<flatmap( \&singleton, $stream )> is equivalent to C<$stream>.

Formal specification:

=over 2

=item

For every element in the upstream, the output stream includes all elements in the stream
returned by the mapper for that element (a.k.a. the mapped stream for that element), and
no others.

=item

Elements from a mapped stream appear in the output stream in the same relative order
as they were in the mapped stream.

=item

The output stream terminates when both the upstream and all the mapped streams have
terminated.

=back

=head3 iterate MAPPER, STREAM

Construct a new iterate stream.

    my $collatz_stream = $initial_stream->iterate(
        sub {
            my ( $integer ) = @_;

            return empty
              if $integer == 1;

            return singleton( $integer / 2 )
              if $integer % 2 == 0;

            return singleton( 3 * $integer + 1 );
        }
    );

C<iterate( \&empty, $stream )> is equivalent to C<$stream>.

Formal specification:

=over 2

=item

The output stream includes all elements from the upstream, as well as all elements from
the mapped stream for each element in the output stream, and no other elements.

=item

Elements from the upstream appear in the output stream in the same relative order as they
were in the upstream.

=item

Elements from the mapped streams appear in the output stream in the same relative order as
they were in the mapped stream.

=item

The output stream terminates when both the upstream and all the mapped streams have
terminated.

=back

=head3 memoize STREAM

Construct a new memoization object.

A memoization object buffers the elements of its upstream and allows traversing the same
sequence of elements multiple times.
While a memoization object is itself not a stream, multiple identical streams can be
created based on it.

    my $memo  = $upstream->memoize;
    my $copy1 = $memo->tee;
    my $copy2 = $memo->tee;

From the perspective of the ownership system, The stream argument is considered an
upstream of the memoization object, but the the memoization object is not considered to be
an upstream of its associated tee streams.
This allows us to work around the limitation that a stream can only be traversed once.

Keep in mind that the buffer of a memoization object may consume a lot of memory if the
upstream produces may or large elements.

See also L<tee MEMOIZATION>.

=head3 tee MEMOIZATION

Construct a new tee stream.

C<tee( memoize( $stream ) )> is equivalent to C<$stream>, except that the elements get
buffered, so there is an extra memory cost.

The output stream contains all elements of the memoized stream, and no additional
elements.
Elements from the memoized stream appear in the output stream in the same relative order
as they were in the memoized stream.

See also L<memoize STREAM>.

=head3 action EFFECT, SCALAR_LIST

Construct a new action stream.

    my $stream = action( 'dns_request', '192.0.2.1', 'example.com', 'AAAA' );

The output streams include all elements produced by the effect handler that matches the
given EFFECT, and no other elements.
Elements in the output stream appear in the same relative order as they were produced by
the effect handler.

=head2 EFFECT HANDLERS

Streams from external sources are imported with the help of "effect handlers".
Allows streams to produce elements using asynchronous APIs.

The effect handler interface allows decoupling communication with external sources from
the requesting and processing of data from them.

An effect handler receives requests from streams of the "action" stream type.
It responds by producing elements for the stream and triggering its termination.

What effect handler implementation should handle a given effect is specified when starting
a stream traversal.

Allows customizing handlers at runtime to add selections of features implemented in a
modular way.

=cut

our @EXPORT_OK = qw(
  action
  concat
  drain
  empty
  fingerprint_set
  flatmap
  interleave
  iterate
  memoize
  singleton
  tee
);

sub each_element (&$) {
    my ( $callback, $stream ) = @_;

    $stream->traverse( $callback );

    return;
}

sub flatmap_end (&$) {
    my ( $mapper, $upstream ) = @_;

    return My::Streams::FlatmapEndStream->_new( $mapper, $upstream );
}

sub flatmap (&$) {
    my ( $mapper, $upstream ) = @_;

    return My::Streams::FlatmapEndStream->_new( item_mapper( $mapper ), $upstream );
}

sub iterate (&$) {
    my ( $mapper, $upstream ) = @_;

    return My::Streams::IterateStream->_new( $mapper, $upstream );
}

sub tee {
    my ( $self ) = @_;

    my $clone_1 = $self->memoize();
    my $clone_2 = $clone_1->tee();
    return ( $clone_1, $clone_2 );
}

sub fingerprint_set (&) {
    my ( $keyer ) = @_;

    return My::Streams::FingerprintSet->new( $keyer );
}

1;
