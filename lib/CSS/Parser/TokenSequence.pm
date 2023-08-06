package CSS::Parser::TokenSequence;
use utf8;
use v5.16;
use Moo;
use Scalar::Util 'looks_like_number';

has buffer          => ( is => 'rwp', default => '' );

# token: [ $type, $value, $src_pos, $src_len, $tok_idx ]
use constant {
	TOKEN_TYPE => 0,
	TOKEN_VALUE => 1,
	TOKEN_SRC_POS => 2,
	TOKEN_SRC_LEN => 3,
	TOKEN_IDX => 4,
};
has tokens          => ( is => 'rwp', default => sub{[]} );
has with_whitespace => ( is => 'ro' );
has with_comments   => ( is => 'ro' );

sub BUILD {
	my ($self)= @_;
	push @{$self->tokens}, @{ $self->scan_tokens($self->{buffer}) }
		if length $self->buffer;
}

sub feed {
	my ($self, $chars)= @_;
	my $pos= pos($self->{buffer}) // 0;
	$self->_set_buffer($self->{buffer} . $chars);
	pos($self->{buffer})= $pos;
	push @{$self->tokens}, @{ $self->scan_tokens($self->{buffer}) };
	return $self;
}

sub token_at_src_pos {
	my ($self, $pos)= @_;
	# Binary search
	my $t= $self->tokens;
	my ($min, $max, $mid)= (0, $#$t);
	while ($min < $max) {
		$mid= ($min+$max+1) >> 1;
		if ($pos < $t->[$mid][TOKEN_SRC_POS]) {
			$max= $mid-1;
		} else {
			$min= $mid;
		}
	}
	return undef unless $min == $max;
	my $ofs= $pos - $t->[$min][TOKEN_SRC_POS];
	return $ofs >= 0 && $ofs < $t->[$min][TOKEN_SRC_LEN]? $t->[$min] : undef;
}

=head2 splice

  @removed= $tok_seq->splice($first_token, $last_token, @replacement);
  @removed= $tok_seq->splice($first_token, $count, @replacement);
  @removed= $tok_seq->splice($token_idx, $count, @replacement);

Just like Perl's splice() function, the C<$token_idx> can be negative to
refer to an offset from the end of the sequence, and C<$count> likewise.

Calling this splice function also edits the L</buffer> to match, removing
the entire span of characters from the beginning of C<$first_token> to the
end of C<last_token>.

C<@replacemnt> may be token objects (from the current sequence object) or
strings.  Each string will be parsed to generate tokens, but limited to the
string.  If a string contains a parse error that would spill over to break the
parse of the following token (such as an unterminated quoted string), this will
throw an exception.

=cut

sub splice {
	my ($self, $first, $last, @add)= @_;
	my $n_tok= scalar @{ $self->tokens };
	my ($prev, $next);
	defined $first
		or croak "Require \$first_token parameter to splice";
	if (looks_like_number($first)) {
		my $idx= $first < 0? $n_tok + $first : $first;
		croak "Index out of bounds: $first" if $idx < 0;
		carp "Index out of bounds: $first" if $idx > $n_tok && defined $last;
		$first= $idx >= $n_tok? undef : $self->tokens->[$idx];
	} else {
		$self->tokens->[$first->[TOKEN_IDX]] == $first
			or croak "\$first_token is not a member of this sequence";
	}
	if (!defined $first) {
		$last= undef;
	} elsif (!defined $last) {
		$last= $self->tokens->[-1];
	} elsif (looks_like_number($last)) {
		my $idx= $last < 0? $n_tok + $last : $first->[TOKEN_IDX] + $last;
		$last= $idx >= $n_tok? $self->tokens->[-1]
			: $idx < $first->[TOKEN_IDX]? $first
			: $self->tokens->[$idx];
	} else {
		$self->tokens->[$last->[TOKEN_IDX]] == $last
			or croak "\$last_token is not a member of this sequence";
		$last= $first if $last->[TOKEN_IDX] < $first->[TOKEN_IDX];
	}
	my $buf_add= '';
	my $token_span_from= undef;
	for (my $i= 0; $i < @add; $i++) {
		if (ref $add[$i]) {
			$token_span_from //= $i;
		} else {
			if (defined $oken_span_from) {
				$buff_add .= $self->get_token_source(@add[$token_span_from .. $i]);
				$token_span_from= undef;
			}
			$buff_add .= $add[$i];
			my @new_tok= $self->scan_tokens($add[$i]);
			splice(@add, $i, 1, @new_tok);
			$i += @new_tok - 1;
		}
	}
	if (defined $token_span_from) {
		$buff_add .= $self->get_token_source(@add[$token_span_from .. $#add]);
	}
	# Now verify that parsing the injected buffer will result in the same sequence of tokens.
	# Include one token before and after the insertion point.
	my $prev= !$first? $self->tokens->[-1]
		: $first->[TOKEN_IDX]? $self->tokens->[$first->[TOKEN_IDX]-1]
		: undef;
	if ($prev) {
		$buf_add= substr($self->buffer, $prev->[TOKEN_SRC_POS], $prev->[TOKEN_SRC_LEN]) . $buf_add;
		unshift @add, $prev;
	}
	my $next= !$last || $last->[TOKEN_IDX] == $n_tok-1? undef
		: $self->tokens->[$last->[TOKEN_IDX]+1];
	if ($next) {
		$buf_add .= substr($self->buffer, $next->[TOKEN_SRC_POS], $next->[TOKEN_SRC_LEN]);
		push @add, $next;
	}
	my @rep_tokens= $self->scan_tokens($buf_add);
	for (my ($i, $max)= (0, @add < @rep_tokens? $#add : $#rep_tokens); $i <= $max; $i++) {
		croak "After replacement, token $i (".$add[$i][TOKEN_TYPE].") would parse differently"
			if $add[$i][TOKEN_TYPE] ne $rep_tokens[$i][TOKEN_TYPE]
			or $add[$i][TOKEN_SRC_LEN] ne $rep_tokens[$i][TOKEN_SRC_LEN];
	}
	croak "After replacement, parse would return extra token ".$rep_token[$#add+1][TOKEN_TYPE]
		if @add < @rep_token;
	croak "After replacement, parse lacks token ".$add[$#rep_token+1][TOKEN_TYPE]
		if @add > @rep_token;
	# looks good, merge them
	my $reparse_from= $prev? $prev->[TOKEN_SRC_POS] : 0;
	my $reparse_until= $next? $next->[TOKEN_SRC_POS]+$next->[TOKEN_SRC_LEN] : length $self->buffer;
	substr($self->{buffer}, $reparse_from, $reparse_until-$reparse_from, $buf_add);
	CORE::splice(@{$self->tokens}, $prev->[TOKEN_IDX], $next->[TOKEN_IDX]-$prev->[TOKEN_IDX], @rep_tokens);
	for (@rep_tokens) {
		$_->[TOKEN_IDX] += $prev->[TOKEN_IDX];
		$_->[TOKEN_SRC_POS] += $prev->[TOKEN_SRC_POS];
	}
	for ($next->[TOKEN_IDX] .. $#{$self->tokens}) {
		$_->[TOKEN_IDX] += (@rep_tokens - ($next->[TOKEN_IDX] - $prev->[TOKEN_IDX]));
		$_->[TOKEN_SRC_POS] += ($rep_tokens[-1][TOKEN_SRC_POS] - $next->[TOKEN_SRC_POS]);
	}
}

sub scan_tokens {
	my $self= shift;
	# According to https://www.w3.org/TR/css-syntax-3
	# § 3.3
	$_[0] =~ s/( \r\n? | \f )/\n/xg;
	$_[0] =~ s/\0/\x{FFFD}/g;
	# § 4.1
	pos($_[0]) //= 0;
	my @ret;
	my $with_whitespace= $self->with_whitespace;
	local our $_with_comments= $self->with_commnts; # global, for compiled regex
	local $^R= undef;
	while($_[0] =~ m{\G
		# as an optimization, skip leading whitespace and generate the token later.
		[ \n\t]*
		  
		((?| # comment (non)token
		  /\* .*? \*/  (?{ $_with_comments [ 'comment' ] : undef })
		  
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
				if $with_whitespace;
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

1;
