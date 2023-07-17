package CSS::Parser;
use utf8;
use v5.16;
use Moo;

has preserve_whitespace => ( is => 'rw', default => 1 );
has preserve_comment    => ( is => 'rw' );

sub parse {
	my $self= shift;
	($self->{input}, $self->{location})= @_;
	$self->{tokens}= $self->scan_tokens($self->{input});
	$self->{token_pos}= 0;
	$self->_skip_ws if $self->preserve_whitespace;
	return $self->_parse_stylesheet;
}
sub _token_type  { $_[0]{tokens}[ $_[0]{token_pos} ][0] }
sub _token_value { $_[0]{tokens}[ $_[0]{token_pos} ][3] }
sub _eof         { $_[0]{token_pos} < $#{ $_[0]{tokens} } }
sub _consume_token {
	my $self= shift;
	my $t= $self->{tokens}[ $self->{token_pos}++ ];
	$self->_skip_ws if $self->_preserve_whitespace;
	return $t;
}
sub _skip_ws {
	my $self= shift;
	while ($self->{tokens}[ $self->{token_pos} ][0] eq 'whitespace') {
		++$self->{token_pos};
	}
	$self;
}
sub _parse_stylesheet {
	my $self= shift;
	my $location= $self->{location};
	my ($error, $rules);
	unless (eval {
		$rules= $self->_parse;
		#push @rules, $self->_parse_rule([])
		#	while !$self->_eof;
		1
	}) { $error= $@ }
	return CSS::Parser::Stylesheet->new(
		location => $location,
		rules => $rules,
		source => $self->{input},
		tokens => $self->{tokens},
		token_pos => $self->{token_pos},
		error => $error,
	);
}

sub _parse {
	my $self= shift;
	my %token_code= (
		at          => 'a', '{' => '{', '}' => '}',
		ident       => 'i', '(' => '(', ')' => ')',
		string      => 's', '[' => '[', ']' => ']',
		bad_string  => 's', ';' => ';', ':' => ':',
		number      => 'n', ',' => ',',
		hash        => 'h',
		percentage  => 'p',
		dimension   => 'd',
		url         => 'u',
		bad_url     => 'u',
		function    => 'f',
		delimiter   => 'l',
	);
	local our $_self= $self;
	local our @tokens= grep $_->[0] ne 'comment' && $_->[0] ne 'whitespace' && $_->[0] ne 'EOF', @{ $self->{tokens} };
	local our @argstack;
	my @result;
	my $tok_seq= join '', map +($token_code{$_->[0]} // die "uncoded $_->[0]"), @tokens;
	while ($tok_seq =~ m{
		(?(DEFINE)
		  (?<VALUE>
		    [shnupdi]                               (?{ $tokens[-1+pos] })
		    | (?= f ) (?&FUNCTIONCALL)              # already sets $^R
		  )
		  (?<FUNCTIONCALL>
		    f \(
		    (?:                                     (?{ local $argstack[$#argstack+1]= [ function_call => $tokens[-2+pos] ]; })
		        (?= [shnupdif] ) (?&VALUE)          (?{ push @{$argstack[-1]}, $^R; })
		        (?: ,
		            (?= [shnupdif] ) (?&VALUE)      (?{ push @{$argstack[-1]}, $^R; })
		        )*
		    )
		    \)                                      (?{ pop @argstack; })
		  )
		  (?<PROPERTY>
		    i :                                     (?{ local $argstack[$#argstack+1]= [ style_property => $tokens[-2+pos] ]; })
		    (?:
		      (?= [shnupdif] ) (?&VALUE)            (?{ push @{$argstack[-1]}, $^R; })
		    )+                                      (?{ pop @argstack; })
		  )
		  (?<SELECTOR>
		    [il]                                    (?{ local $argstack[$#argstack+1]= [ selector => $tokens[-1+pos] ]; })
		    (?:
		      [il]                                  (?{ push @{$argstack[-1]}, $tokens[-1+pos]; })
		    )*                                      (?{ pop @argstack; })
		  )
		  (?<STYLERULE>                             (?{ local $argstack[$#argstack+1]= [ style_rule => [], [] ]; })
		    (?&SELECTOR)                            (?{ push @{$argstack[-1][1]}, $^R; })
		    ( , (?&SELECTOR)                        (?{ push @{$argstack[-1][1]}, $^R; })
		    )*
		    \{
		      (?&PROPERTY)                          (?{ push @{$argstack[-1][2]}, $^R; })
		      (?:
		        ; (?= i ) (?&PROPERTY)              (?{ push @{$argstack[-1][2]}, $^R; })
		      )*
		      ;?
		    \}                                      (?{ pop @argstack; })
		  )
		  (?<ATRULE>
		    a                                       (?{ local $argstack[$#argstack+1]= [ at_rule => $^R ]; })
		    (?:
		      (?= [shnupdif] )(?&VALUE)             (?{ push @{$argstack[-1]}, $^R; })
		    )*
		    (?:
		      \{                                    (?{ push @{$argstack[-1]}, []; })
		        (?:
		          (?&RULE)                          (?{ push @{$argstack[-1][-1]}, $^R; })
		        )*
		      \}
		      | ;
		    )                                       (?{ pop @argstack; })
		  )
		  (?<RULE> (?= a ) (?&ATRULE) | (?&STYLERULE) )
		)
		(?&RULE)
	}xsgc) {
		#use DDP; &p($^R);
		push @result, $^R;
	}
	return \@result;
}

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
		elsif ($token->[0] eq 'function' && lc($token->[3]) eq 'url'
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
		push @ret,
			[ garbage => pos($_[0]), length($_[0]) ],
			[ EOF => length($_[0]), length($_[0]) ];
	}
	return \@ret;
}

require CSS::Parser::Stylesheet;
1;
