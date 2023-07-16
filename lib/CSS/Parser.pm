package CSS::Parser;
use utf8;
use Moo;
use v5.14;

sub preserve_whitespace { $_[0]{preserve_whitespace} //= 1 }
sub preserve_comment { $_[0]{preserve_comment} }

# According to https://www.w3.org/TR/css-syntax-3
sub scan_tokens {
	my $self= shift;
	# § 3.3
	$_[0] =~ s/( \r\n? | \f )/\n/g;
	$_[0] =~ s/\0/\x{FFFD}/g;
	# § 4.1
	pos($_[0])= 0;
	my @ret;
	local our $_self= $self;
	local $^R= undef;
	while($_[0] =~ m{\G
		# as an optimization, skip leading whitespace and generate the token later.
		[ \n\t]*
		  
		((?| # comment (non)token
		  /\* (.*?) \*/  (?{ $_self->preserve_comment? [ comment => $2 ] : undef })
		  
		  | # at-rule, identifier, function, or 'url(...'
		  ( \@ )?
		  (?|   # ident first char
		    --                                          (?{ '--' })
		    | (-?) (?| ( [a-zA-Z_\x80-] )               (?{ $3.$4 })
		           | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*     (?{ $3.chr(hex($4)) })
		           | \\ ([^0-9A-Fa-f\n])                (?{ $3.$4 })
		           )
		  )
		  (?|   # ident subsequent chars
		    ([-0-9A-Za-z_\x80-]+)                       (?{ $^R.$5 })
		    | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*            (?{ $^R.chr(hex($5)) })
		    | \\ ([^0-9A-Fa-f\n])                       (?{ $^R.$5 })
		  )*
		  # If it is not an at-rule, it may begin a function call with '('
		  (?(1)                                         (?{ [ at => $^R ] })
		    # If followed by '(', it's a function
		    | (?: \(
		  	    (?> # no backtracking after matching '('
		          # If the function is the literal string "url", continue parsing a URL
		          (?(?{ lc($^R) ne "url" })             (?{ [ function => $^R ] })
		            | [ \t\n]* (?|
		              (?{ '' })     # reset $^R to empty string
		              (?|
		                ([^'"()\\ \t\n\0-\x08\x0B\x0E-\x1F\x7F]+)  (?{ $^R.$6 })
		                | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*           (?{ $^R.chr(hex($6)) })
		                | \\ ([^0-9A-Fa-f\n])                      (?{ $^R.$6 })
		              )*
		            ) [ \r\n]* \)                       (?{ [ url => $^R ] })
		          )
		        )
		        # If it didn't start with (, then it's just a normal identifier
		      |                                         (?{ [ ident => $^R ] })
		      )
		  )
		  
		  | # hash-token
		  [#]                                           (?{ '' })
		  (?|
		    ([0-9A-Za-z_-\x80-]+)                       (?{ $^R.$2 })
		    | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*            (?{ $^R.chr(hex($2)) })
		    | \\ ([^0-9A-Fa-f\n])                       (?{ $^R.$2 })
		  )*                                            (?{ [ hash => $^R ] })
		  
		  | # doublequote string
		  "                                             (?{ '' })
		  (?| ([^"\n\\]+)                               (?{ $^R.$2 })
		      | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*          (?{ $^R.chr(hex($2)) })
		      | \\ ([^0-9A-Fa-f])                       (?{ $^R.$2 })
		  )*
		  "                                             (?{ [ string => $^R ] })
		  | # singlequote string
		  '                                             (?{ '' })
		  (?| ([^'\n\\]+)                               (?{ $^R.$2 })
		      | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*          (?{ $^R.chr(hex($2)) })
		      | \\ ([^0-9A-Fa-f])                       (?{ $^R.$2 })
		  )*
		  '                                             (?{ [ string => $^R ] })
		
		  | # EOF
		  \Z                                            (?{ 0 })
		))
	}xsgc) {
		if ($-[1] > $-[0]) {
			push @ret, [ whitespace => undef, $-[0], $-[1] ]
				if $self->preserve_whitespace;
		}
		next unless defined $^R;
		last unless $^R;
		push $^R->@*, $-[1], $+[1]; # append string idx of start and end of token
		push @ret, $^R;
		$^R= undef;
	}
	if (pos($_[0]) != length($_[0])) {
		push @ret, [ garbage => undef, pos($_[0]), length($_[0]) ];
	}
	return \@ret;
}

1;
