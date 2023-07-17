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
sub _token       { $_[0]{tokens}[ $_[0]{token_pos} ] }
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
	my @rules;
	while (!$self->_eof) {
		push @rules, $self->_parse_rule;
	}
	return CSS::Parser::Stylesheet->new(
		location => undef,
		rules => \@rules,
		source => $self->{input},
		tokens => $self->{tokens},
	);
}

sub _parse_rule {
	my $self= shift;
	return $self->_token_type eq 'at'? $self->_parse_at_rule
		: $self->_parse_style_rule;
}

my %_rule_special_token= map +($_ => 1), qw| ; { } function EOF |;
sub _parse_at_rule {
	my $self= shift;
	return undef unless $self->_token_type eq 'at';
	my $type= $self->_consume_token->[3];
	my (@parts, @garbage);
	my $error;
	while (1) {
		if (!$_rule_special_token{$self->_token_type}) {
			push @parts, $self->_consume_token;
		} elsif ($self->_token_type eq 'function') {
			push @parts, $self->_parse_function;
		} elsif ($self->_token_type eq ';') {
			last;
		} elsif ($self->_token_type eq '{') {
			$self->_consume_token;
			my @block;
			while ($self->_token_type ne '}') {
				if (my $rule= $self->_parse_rule) {
					push @block, $rule;
				} else {
					$error= [ 'expected rule or "}"', $self->_token ];
					$self->_discard_token_until('}', \@garbage);
					last;
				}
			}
			push @parts, \@block;
			$self->_consume_token if $self->_token_type eq '}';
			last;
		} else { # } or EOF
			$error= [ 'expected "{" or ";" in at-rule', $self->_token ];
			last;
		}
	}
	return CSS::Parser::AtRule->new(type => $type, parts => \@parts,
		error => $error, garbage => \@garbage);
}

my %_selector_first_token= map +($_ => 1), qw| ident hash delimiter |;
my %_selector_next_token=  map +($_ => 1), qw| ident hash delimiter : [ string ] |;
my %_selector_abort_token= map +($_ => 1), ',', qw| ; { } EOF |;
sub _parse_selector {
	my $self= shift;
	if ($_selector_first_token{$self->_token_type}) {
		my @parts= ( $self->_consume_token );
		push @parts, $self->_consume_token
			while $_selector_next_token{$self->_token_type};
		return CSS::Parser::Selector->new(parts => @parts);
	}
	# this is a parse error.  Gobble up anything that isn't a selector_abort_token
	my $error= [ 'invalid start of selector', $self->_token ];
	my @garbage;
	push @garbage, $self->_consume_token while !$_selector_abort_token{$self->_token_type};
	return @garbage? CSS::Parser::Selector->new(error => $error, garbage => \@garbage)
		: undef;
}

sub _parse_style_rule {
	my $self= shift;
	my (@selectors, @properties, @garbage, $error);
	while (1) {
		my $sel= $self->_parse_selector;
		if ($sel) {
			push @selectors, $sel;
			next if $self->_token_type eq ',';
			last if $self->_token_type eq '{';
		}
		my $error= [ 'expected "," or "{"', $self->_token ];
		my @garbage;
		$self->_discard_token_until(\%_selector_abort_token, \@garbage);
	}
	if ($self->_token_type eq '{') {
		$self->_consume_token;
		while ($self->_token_type ne '}') {
			if (my $prop= $self->_parse_property) {
				push @properties, $prop;
			} else {
				$error= [ 'expected identifier', $self->_token ];
				$self->_discard_token_until({ ';' => 1, '}' => 1 }, \@garbage);
				push @garbage, $self->_consume_token
					if $self->_token_type eq ';';
				last if $self->_token_type eq 'EOF';
			}
		}
		$self->_consume_token if $self->_token_type eq '}';
	}
	return CSS::Parser::StyleRule->new(
		selectors => \@selectors, properties => \@properties,
		error => $error, garbage => \@garbage);
}

my %_value_special_token= %_rule_special_token;
sub _parse_property {
	my $self= shift;
	return undef unless $self->_token_type eq 'ident';
	my $name= $self->_consume_token->[3];
	my ($error, @garbage);
	if ($self->_token_type eq ':') {
		$self->_consume_token;
		my @value;
		while (1) {
			if (!$_value_special_token{$_->_token_type}) {
				push @value, $self->_consume_token;
			} elsif ($self->_token_type eq 'function') {
				push @value, $self->_parse_function;
			} elsif ($self->_token_type eq ';' || $self->_token_type eq '}') {
				return CSS::Parser::StyleProperty->new(name => $name, value => \@value)
					if @value;
				$error= [ 'expected property value before '.$self->_token_type, $self->_token ];
				last;
			} else {
				$error= [ 'expected property value', $self->_token ];
				$self->_discard_token_until({ ';' => 1, '}' => 1 }, \@garbage);
				last
			}
		}
	} else {
		$error= [ 'expected ":"', $self->_token ];
	}
	return CSS::Parser::StyleProperty->new(name => $name, error => $error, garbage => \@garbage);
}

sub _discard_token_until {
	my ($self, $set, $garbage)= @_;
	$set= { $set => 1 } unless ref $set eq 'HASH';
	while (!$set->{$self->_token_type} && !$self->_eof) {
		push @$garbage, $self->_consume_token;
	}
}

sub _parse2 {
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
