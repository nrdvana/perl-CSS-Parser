#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use CSS::Parser;

my @tests= (
	# Comments do not return tokens by default, but they do break whitespace tokens
	[ comment_and_whitespace => "   /* foo \n*/ ",
		[[ whitespace => '   ' ],
		 [ whitespace => ' ' ],
		]
	],
	[ identifiers_and_functions => "html -background-color -- url(foo) foo( insane\\20 ide\\nt",
		[[ ident => 'html', 'html' ], [ whitespace => ' ' ],
		 [ ident => '-background-color', '-background-color' ], [ whitespace => ' ' ],
		 [ ident => '--', '--' ], [ whitespace => ' ' ],
		 [ url => 'url(foo)', 'foo' ], [ whitespace => ' ' ],
		 [ function => 'foo(', 'foo' ], [ whitespace => ' ' ],
		 [ ident => "insane\\20 ide\\nt", 'insane ident' ]
		]
	],
	[ strings => qq{'string' "string" "string's" 'string"s' "\\\nnewline" 'foo\\20 bar'},
		[[ string => q{'string'}, 'string' ], [ whitespace => ' ' ],
		 [ string => q{"string"}, 'string' ], [ whitespace => ' ' ],
		 [ string => q{"string's"}, q{string's} ], [ whitespace => ' ' ],
		 [ string => q{'string"s'}, q{string"s} ], [ whitespace => ' ' ],
		 [ string => qq{"\\\nnewline"}, qq{\nnewline} ], [ whitespace => ' ' ],
		 [ string => qq{'foo\\20 bar'}, 'foo bar' ],
		]
	],
	#[ simple => 'html{color:black;}',
	#	[[ ident => 'html' ],
	#	 [ block => '{' ],
	#	 [ ident => 'color' ],
	#	 [ value => ':' ],
	#	 [ ident => 'black' ],
	#	 [ st_end   => ';' ],
	#	 [ bl_end   => '}' ],
	#	]
	#],
	#[ complex => <<~CSS,
	#	\@media print {
	#	  html, table tr.foo th {
	#	    /* test */\r
	#	    background-image: url("/foo/bar");
	#	  }
	#	}
	#	CSS
	#	[[ at_keyword => '@media' ], [ whitespace => " " ],
	#	 [ ident => 'print' ], [ whitespace => " " ],
	#	 [ '{' => '{' ], [ whitespace => "\n    \n    " ],
	#	 [ ident => 'background-image' ],
	#	 [ colon => ':' ], [ whitespace => ' ' ],
	#	 [ function => 'url(' ],
	#	 [ string => '"/foo/bar"' ],
	#	 [ ')' => ')' ],
	#	 [ semicolon => ';' ], [ whitespace => "\n  " ],
	#	 [ '}' => '}' ], [ whitespace => "\n" ],
	#	 [ '}' => '}' ],
	#	]
	#],
);

for (@tests) {
	my ($name, $css, $tokens)= @$_;
	note $css;
	my $parser= CSS::Parser->new(preserve_whitespace => 1, preserve_comment => 1);
	my @parsed= map +[ $_->[0], substr($css, $_->[2], $_->[3] - $_->[2]), (defined $_->[1]? ($_->[1]):()) ],
		$parser->scan_tokens($css)->@*;
	is_deeply( \@parsed, $tokens, $name )
		or diag explain \@parsed;
}

done_testing;
