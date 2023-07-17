#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use CSS::Parser;

my @tests= (
	# Comments do not return tokens by default, but they do break whitespace tokens
	[ comment_and_whitespace => 1, 1,
		"   /* foo \n*/ ",
		[[ whitespace => '   ' ],
		 [ comment => "/* foo \n*/" ],
		 [ whitespace => ' ' ],
		 [ EOF => '' ],
		]
	],
	[ identifiers_and_functions => 0, 0,
		q{html -background-color -- url(foo) url("/foo") url( foo ) foo( insane\\20 ide\\nt @media},
		[[ ident => 'html', 'html' ],
		 [ ident => '-background-color', '-background-color' ],
		 [ ident => '--', '--' ],
		 [ url => 'url(foo)', 'foo' ],
		 [ function => 'url', 'url' ], ['(','('], [ string => '"/foo"', '/foo' ], [')',')'],
		 [ url => 'url( foo )', 'foo' ],
		 [ function => 'foo', 'foo' ], ['(','('],
		 [ ident => "insane\\20 ide\\nt", 'insane ident' ],
		 [ at => '@media', 'media' ],
		 [ EOF => '' ],
		]
	],
	[ bad_url => 0, 0,
		qq{ url(/foo },
		[[ bad_url => 'url(/foo ', '/foo ' ],
		 [ EOF => '' ],
		]
	],
	[ strings => 0, 0,
		qq{'string' "string" "string's" 'string"s' "\\\nnewline" 'foo\\20 bar'},
		[[ string => q{'string'}, 'string' ],
		 [ string => q{"string"}, 'string' ],
		 [ string => q{"string's"}, q{string's} ],
		 [ string => q{'string"s'}, q{string"s} ],
		 [ string => qq{"\\\nnewline"}, qq{\nnewline} ],
		 [ string => qq{'foo\\20 bar'}, 'foo bar' ],
		 [ EOF => '' ],
		]
	],
	[ string_error => 0, 0,
		qq{'string\n"string},
		[[ bad_string => qq{'string}, 'string' ],
		 [ bad_string => qq{"string}, 'string' ],
		 [ EOF => '' ],
		]
	],
	[ numbers => 0, 0,
		qq{0 1.0 0200 2e2 px 2e+2/* */100e-2 2e2p\\20 x 50%},
		[[ number => q{0}, 0 ],
		 [ number => q{1.0}, 1 ],
		 [ number => q{0200}, 200 ],
		 [ number => q{2e2}, 200 ],
		 [ ident => q{px}, 'px' ],
		 [ number => q{2e+2}, 200 ],
		 [ number => q{100e-2}, 1 ],
		 [ dimension => q{2e2p\20 x}, 200, 'p x' ],
		 [ percentage => q{50%}, .5 ],
		 [ EOF => '' ],
		]
	],
	[ example1 => 1, 1, <<~CSS,
		\@media print {
		  html, table tr.foo th {
		    /* test */\r
		    background-image: url(/foo/bar);
		    content: url("/foo/bar");
		  }
		}
		CSS
		[[ at => '@media', 'media' ], [ whitespace => " " ],
		 [ ident => 'print', 'print' ], [ whitespace => " " ],
		 [ '{' => '{' ], [ whitespace => "\n  " ],
		 [ ident => 'html', 'html' ], [ ',' => ',' ], [ whitespace => ' ' ],
		 [ ident => 'table', 'table' ], [ whitespace => ' ' ], [ ident => 'tr', 'tr' ],
		 [ delim => '.', '.' ], [ ident => 'foo', 'foo' ], [ whitespace => ' ' ],
		 [ ident => 'th', 'th' ], [ whitespace => ' ' ], [ '{' => '{' ], [ whitespace => "\n    " ],
		 [ comment => '/* test */' ], [ whitespace => "\n    " ],
		 [ ident => 'background-image', 'background-image' ],
		 [ ':' => ':' ], [ whitespace => ' ' ],
		 [ url => 'url(/foo/bar)', '/foo/bar' ], [ ';' => ';' ], [ whitespace => "\n    " ],
		 [ ident => 'content', 'content' ], [ ':' => ':' ], [ whitespace => ' ' ],
		 [ function => 'url', 'url' ], [ '(' => '(' ], [ string => '"/foo/bar"', '/foo/bar' ],
		 [ ')' => ')' ], [ ';' => ';' ], [ whitespace => "\n  " ],
		 [ '}' => '}' ], [ whitespace => "\n" ],
		 [ '}' => '}' ], [ whitespace => "\n" ],
		 [ EOF => '' ],
		]
	],
);

for (@tests) {
	my ($name, $ws, $comment, $css, $tokens)= @$_;
	subtest $name => sub {
		note $css;
		my $parser= CSS::Parser->new(preserve_whitespace => $ws, preserve_comment => $comment);
		my @parsed= map +[ $_->[0], substr($css, $_->[1], $_->[2] - $_->[1]), @{$_}[3..$#$_] ],
			$parser->scan_tokens($css)->@*;
		for (0..$#$tokens) {
			is_deeply( $parsed[$_], $tokens->[$_], "$parsed[$_][0] = $tokens->[$_][0]" )
				or diag explain [ $parsed[$_], $tokens->[$_] ];
		}
		is( scalar @parsed, scalar @$tokens, 'no extra tokens' );
	};
}

done_testing;
