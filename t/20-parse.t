#! /usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use CSS::Parser;

sub tok {
	my $type= shift;
	my $value= shift;
	return array {
		item 0 => $type;
		item 1 => D;
		item 2 => D;
		item 3 => $value if defined $value;
		etc;
	};
}

my @tests= (
	# Comments do not return tokens by default, but they do break whitespace tokens
	[ basic_style_rule => 1, 1, <<~CSS,
		html {
		  color: black;
		  background-color: white;
		}
		CSS
		[[ style_rule =>
			[ 
				[ selector => tok(ident => 'html') ],
			],
			[
				[ style_property => tok(ident => 'color'), tok(ident => 'black') ],
				[ style_property => tok(ident => 'background-color'), tok(ident => 'white') ],
			]
		]]
	],
);

for (@tests) {
	my ($name, $ws, $comment, $css, $tree)= @$_;
	note $css;
	my $parser= CSS::Parser->new(preserve_whitespace => $ws, preserve_comment => $comment);
	my $parsed= $parser->parse($css);
	is( $parsed->rules, $tree, $name );
}

done_testing;
