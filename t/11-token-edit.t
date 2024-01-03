#! /usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use CSS::Parser::TokenSequence;

my $tokens= CSS::Parser::TokenSequence->new(buffer => <<END);
p {
	background-color: black;
	color: white;
}
END
is( $tokens->[0], object {
	call index      => 0;
	call type       => 'ident';
	call value      => 'p';
	call source_pos => 0;
	call source     => 'p';
}, 'tokens[0] before' );

splice(@$tokens, 0, 0, ".prefix ");

is( $tokens->[0], object {
	call index      => 0;
	call type       => 'delim';
	call value      => '.';
	call source_pos => 0;
	call source     => '.';
}, 'tokens[0] after' );
is( $tokens->[1], object {
	call index      => 1;
	call type       => 'ident';
	call value      => 'prefix';
	call source_pos => 1;
	call source     => 'prefix';
}, 'tokens[1] after' );
is( $tokens->[3], object {
	call index      => 3;
	call type       => 'ident';
	call value      => 'p';
	call source_pos => 8;
	call source     => 'p';
}, 'tokens[2] after' );

done_testing;
