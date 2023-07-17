package CSS::Parser;
use utf8;
use Moo;
use v5.16;

has preserve_whitespace => ( is => 'rw', default => 1 );
has preserve_comment    => ( is => 'rw' );

# According to https://www.w3.org/TR/css-syntax-3
sub scan_tokens {
	my $self= shift;
	# § 3.3
	$_[0] =~ s/( \r\n? | \f )/\n/xg;
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
		  /\* .*? \*/  (?{ $_self->preserve_comment? [ 'comment' ] : undef })
		  
		  | # CDO token
		  <!--                                          (?{ [ 'CDO' ] })
		  | # CDC token
		  -->                                           (?{ [ 'CDC' ] })
		  
		  | # number token
		  ( [-+]?
		    (?: [0-9]+ (?: \. [0-9]+ )? | \. [0-9]+ )
		    (?: [eE] [-+]? [0-9]+ )?
		  ) (%?)                                        (?{ $3 eq '%'? [ percentage => $2/100 ] : [ number => 0+$2 ] })
		  
		  | # at-rule, identifier, or function
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
		  # Is it an at-rule?  (capture 2 not null?)
		  (?(2)                                         (?{ [ at => $^R ] })
		    |(?: # If followed by '(', it's a function
		      (?=[ \t\n]* \( )                          (?{ [ function => $^R ] })
		      | # No ")" following, it's an identifier
		                                                (?{ [ ident => $^R ] })
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
		  (?: "                                         (?{ [ string => $^R ] })
		    | (?= \Z | \n )                             (?{ [ bad_string => $^R ] })
		  )
		  | # singlequote string
		  '                                             (?{ '' })
		  (?| ([^'\n\\]+)                               (?{ $^R.$2 })
		      | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*          (?{ $^R.chr(hex($2)) })
		      | \\ ([^0-9A-Fa-f])                       (?{ $^R.$2 })
		  )*
		  (?: '                                         (?{ [ string => $^R ] })
		    | (?= \Z | \n )                             (?{ [ bad_string => $^R ] })
		  )
		
		  | # tokens which represent themselves
		  ( [[\]{}():;,] )                               (?{ [ $2 ] })
		
		  | # EOF
		  \Z                                            (?{ [ 'EOF' ] })
		  
		  | # anything else is a delim-token
		  (.)                                           (?{ [ delim => $2 ] })
		))
	}xsgc) {
		# If initial whitespace regex matched,
		if ($-[1] > $-[0]) {
			# Make a whitespace node if we're using those.
			push @ret, [ whitespace => $-[0], $-[1] ]
				if $self->preserve_whitespace;
		}
		next unless defined $^R;
		my $token= $^R;
		splice @$token, 1, 0, $-[1], $+[1]; # append string idx of start and end of token
		$^R= undef;
		# If an identifier followed a number with no whitespace inbetween,
		# it is a 'dimension' token.
		if ($token->[0] eq 'ident' && $-[1] == $-[0] && @ret && $ret[-1][0] eq 'number') {
			$ret[-1][0]= 'dimension';
			$ret[-1][2]= $token->[2];
			$ret[-1][4]= $token->[3];
			next;
		}
		# Special case for 'url(...)' function that doesn't require quotes around the argument
		# (yes, this can be wedged into the regex above, but it gets reeealy ugly)
		elsif ($token->[0] eq 'function' && fc($token->[3]) eq fc('url')
			&& $_[0] =~ /\G [ \t\n]* \( [ \t\n]* (?= [^'"] )/xsgc
		) {
			# § 4.3.6 Consume a URL token
			$^R= '';
			if ($_[0] =~ /\G
				(?|
				  ([^'"()\\ \t\n\0-\x08\x0B\x0E-\x1F\x7F]+)  (?{ $^R.$1 })
				  | \\ ([0-9A-Fa-f]{1,6}) [ \n\t]*           (?{ $^R.chr(hex($1)) })
				  | \\ ([^0-9A-Fa-f\n])                      (?{ $^R.$1 })
				)*
				[ \r\n]* \)
			/xsgc) {
				$token->[0]= 'url';
				$token->[2]= pos $_[0];
				$token->[3]= $^R;
			} else {
				# § 4.3.14 Consume the remnants of a bad url
				$^R= '';
				$_[0] =~ /\G
					(?| \\ ( [0-9A-Fa-f]{1,6} ) [ \n\t]*     (?{ $^R.chr(hex($1)) })
					  | \\ ( [^0-9A-Fa-f\n] )                (?{ $^R.$1 })
					  | ( [^)]+ )                            (?{ $^R.$1 })
					)*
		            \)?
				/xsgc or die "should always match: '".substr($_[0], pos($_[0]))."'";
				$token->[0]= 'bad_url';
				$token->[2]= pos $_[0];
				$token->[3]= $^R;
			}
		}
		push @ret, $token;
		last if $token->[0] eq 'EOF';
	}
	if (pos($_[0]) != length($_[0])) {
		push @ret, [ garbage => undef, pos($_[0]), length($_[0]) ];
	}
	return \@ret;
}

1;
