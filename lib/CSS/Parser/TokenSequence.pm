package CSS::Parser::TokenSequence;
use utf8;
use v5.16;
use Moo;
use Scalar::Util 'looks_like_number';
use Carp;

=head1 DESCRIPTION

A TokenSequence takes a buffer of characters and parses the boundaries of tokens.
It allows you to iterate the tokens, but also alter and replace tokens while
preserving the whitespae in the original buffer.

=head1 ATTRIBUTES

=head2 buffer

The input buffer of characters.  Read-only accessor, but you can append to it
using L</feed> and perform token-level edits using L</splice>.

=head2 tokens

An arrayref of Token objects.  (this is actually instantiated on demand via
a tied array, so there is some overhead in using this property)

=head2 C<< ->[...] >>  (Array access)

You may access the tokens of the sequence using arrayref element notation.

=cut

use overload '@{}' => sub { $_[0]->tokens };

# token: [ $pos, $type, $value ]
use constant {
	TOKEN_POS   => 0,
	TOKEN_TYPE  => 1,
	TOKEN_VALUE => 2,
	TOKEN_UNIT  => 3,
};

has buffer          => ( is => 'rwp', default => '' );
has _tok            => ( is => 'ro',  default => sub {[]} );
has tokens          => ( is => 'lazy' );

sub _build_tokens {
	my $self= shift;
	tie my @tie, 'CSS::Parser::TokenSequence::_Tie', $self;
	return \@tie;
}
sub CSS::Parser::TokenSequence::_Tie::TIEARRAY  {
	my ($class, $self)= @_;
	Scalar::Util::weaken($self);
	bless \$self, $class;
}
sub CSS::Parser::TokenSequence::_Tie::FETCH     { ${$_[0]}->token($_[1]) }
sub CSS::Parser::TokenSequence::_Tie::STORE     { ${$_[0]}->splice($_[1], 1, $_[2]) }
sub CSS::Parser::TokenSequence::_Tie::FETCHSIZE { scalar @{ ${$_[0]}->_tok } }
sub CSS::Parser::TokenSequence::_Tie::STORESIZE {
	my $self= ${$_[0]};
	my $count= $_[1];
	my $cur= scalar @{$self->{_tok}};
	if ($count > $cur) {
		$self->splice($cur, 0, (undef)x($count-$cur));
	} else {
		$self->splice($count, $cur-$count);
	}
}
sub CSS::Parser::TokenSequence::_Tie::EXTEND    {}
sub CSS::Parser::TokenSequence::_Tie::EXISTS    { defined ${$_[0]}->_tok->[$_[1]] }
sub CSS::Parser::TokenSequence::_Tie::DELETE    { die "unimplemented" }
sub CSS::Parser::TokenSequence::_Tie::CLEAR     { @{ ${$_[0]}->_tok }= () }
sub CSS::Parser::TokenSequence::_Tie::PUSH {
	my $self= ${shift()};
	$self->splice( scalar @{$self->_tok}, 0, @_ );
}
sub CSS::Parser::TokenSequence::_Tie::POP       { ${$_[0]}->splice( -1, 1 ) }
sub CSS::Parser::TokenSequence::_Tie::SHIFT     { ${$_[0]}->splice( 0, 1 ) }
sub CSS::Parser::TokenSequence::_Tie::UNSHIFT   { ${shift()}->splice(0, 0, @_) }
sub CSS::Parser::TokenSequence::_Tie::SPLICE    { ${shift()}->splice(@_) }

sub CSS::Parser::TokenSequence::TokenProxy::sequence   { $_[0][0] }
sub CSS::Parser::TokenSequence::TokenProxy::index      { $_[0][1] }
sub CSS::Parser::TokenSequence::TokenProxy::type       { $_[0][0]{_tok}[$_[0][1]][TOKEN_TYPE] }
sub CSS::Parser::TokenSequence::TokenProxy::value      { $_[0][0]{_tok}[$_[0][1]][TOKEN_VALUE] }
sub CSS::Parser::TokenSequence::TokenProxy::source_pos { $_[0][0]{_tok}[$_[0][1]][TOKEN_POS] }
sub CSS::Parser::TokenSequence::TokenProxy::source     { $_[0][0]->_token_source($_[0][1]); }

sub BUILD {
	my ($self)= @_;
	@{$self->_tok}= $self->scan_tokens($self->{buffer})
		if length $self->buffer && !@{$self->_tok};
}

sub feed {
	my ($self, $chars)= @_;
	my $pos= pos($self->{buffer}) // 0;
	$self->_set_buffer($self->{buffer} . $chars);
	pos($self->{buffer})= $pos;
	push @{$self->_tok}, @{ $self->scan_tokens($self->{buffer}) };
	return $self;
}

sub token {
	my ($self, $idx)= @_;
	return undef unless $idx >= 0 && $idx < @{ $self->_tok };
	bless [ $self, $idx ], 'CSS::Parser::TokenSequence::TokenProxy';
}

sub _tok_at_pos {
	my ($self, $pos)= @_;
	# Binary search
	my $t= $self->_tok;
	my ($min, $max, $mid)= (0, $#$t);
	while ($min < $max) {
		$mid= ($min+$max+1) >> 1;
		if ($pos < $t->[$mid][TOKEN_POS]) {
			$max= $mid-1;
		} else {
			$min= $mid;
		}
	}
	return undef unless $min == $max;
	my $tok_lim= $min < $#$t? $t->[$min+1][TOKEN_POS] : length $self->buffer;
	return undef unless $pos >= $t->[$min][TOKEN_POS] && $pos < $tok_lim;
	return $min;
}

sub token_at_pos {
	my ($self, $pos)= @_;
	my $idx= $self->_tok_at_pos($pos);
	return defined $idx? $self->token($idx) : undef;
}

sub _token_source {
	my ($self, $idx)= @_;
	my $t= $self->_tok;
	my $tok_pos= $t->[$idx][TOKEN_POS];
	my $tok_lim= $idx == $#$t? length($self->buffer) : $t->[$idx+1][TOKEN_POS];
	substr $self->buffer, $tok_pos, $tok_lim-$tok_pos;
}

=head2 splice

  @removed= $tok_seq->splice($first_token, $until_token, @replacement);
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
	my ($self, $first, $count, @add)= @_;
	my $tok= $self->_tok;
	my $n_tok= scalar @$tok;
	defined $first
		or croak "Require \$first_token parameter to splice";
	if (looks_like_number($first)) {
		my $idx= $first < 0? $n_tok + $first : $first;
		croak "Index out of bounds: $first" if $idx < 0;
		carp "Index out of bounds: $first" if $idx > $n_tok && defined $count;
		$first= $idx > $n_tok? $n_tok : $idx;
	} else {
		croak "\$first_token is not a member of this sequence"
			unless $first->sequence == $self;
		$first= $first->index;
	}
	if (!defined $count) {
		$count= $n_tok-$first;
	} elsif (looks_like_number($count)) {
		# if negative, treat as offset from end, else treat it as a count
		$count= $n_tok - $first + $count if $count < 0;
	} else {
		croak "\$until_token is not a member of this sequence"
			unless $count->sequence == $self;
		$count= $count->index - $first;
	}
	$count= 0 if $count < 0;
	
	my $add_buf= '';
	for (@add) {
		if (ref and ref->can('source')) {
			$add_buf .= $_->source;
		} else {
			$add_buf .= $_;
		}
	}
	my @add_tok= length $add_buf? $self->scan_tokens($add_buf) : ();
	my $replace_pos= $tok->[$first][TOKEN_POS];
	my $replace_lim= $first+$count == $n_tok? length($self->buffer) : $tok->[$first+$count][TOKEN_POS];

	# Now verify that the buffer replacement didn't damage the token before or after the insertion point.
	if ($first > 0) {
		my $prev_pos= $tok->[$first-1][TOKEN_POS];
		my $prev_len= $replace_pos-$prev_pos;
		my $first_len= @add_tok > 1? $add_tok[1][TOKEN_POS] : length($add_buf);
		my $tmp_buf= substr($self->buffer, $prev_pos, $prev_len)
			. substr($add_buf, 0, $first_len);
		my @tmp_tok= $self->scan_tokens($tmp_buf);
		unless (@tmp_tok == 2
			&& $tmp_tok[0][TOKEN_TYPE]  eq $tok->[$first-1][TOKEN_TYPE]
			&& $tmp_tok[0][TOKEN_VALUE] eq $tok->[$first-1][TOKEN_VALUE]
			&& $tmp_tok[1][TOKEN_TYPE]  eq $add_tok[0][TOKEN_TYPE]
			&& $tmp_tok[1][TOKEN_VALUE] eq $add_tok[0][TOKEN_VALUE]
			&& $tmp_tok[1][TOKEN_POS]   == $prev_len
		) {
			croak "After replacement, previous token would parse differently"
				." (".$tok->[$first-1][TOKEN_TYPE].", '".$tok->[$first-1][TOKEN_VALUE]."')";
		}
	}
	if ($first+$count < $n_tok) {
		my $last_pos= $add_tok[-1][TOKEN_POS];
		my $last_len= length($add_buf) - $last_pos;
		my $next_lim= $first+$count+1 == $n_tok? length($self->buffer) : $tok->[$first+$count+1][TOKEN_POS];
		my $tmp_buf= substr($add_buf, $last_pos) . substr($self->buffer, $replace_lim, $next_lim-$replace_lim);
		my @tmp_tok= $self->scan_tokens($tmp_buf);
		unless (@tmp_tok == 2
			&& $tmp_tok[0][TOKEN_TYPE]  eq $add_tok[-1][TOKEN_TYPE]
			&& $tmp_tok[0][TOKEN_VALUE] eq $add_tok[-1][TOKEN_VALUE]
			&& $tmp_tok[1][TOKEN_TYPE]  eq $tok->[$first+$count][TOKEN_TYPE]
			&& $tmp_tok[1][TOKEN_VALUE] eq $tok->[$first+$count][TOKEN_VALUE]
			&& $tmp_tok[1][TOKEN_POS]   == $last_len
		) {
			croak "After replacement, next token would parse differently"
				." (".$tok->[$first+$count][TOKEN_TYPE].", '".$tok->[$first+$count][TOKEN_VALUE]."')";
		}
	}
	# looks good, merge them
	substr($self->{buffer}, $replace_pos, $replace_lim-$replace_pos, $add_buf);
	my @removed= CORE::splice(@$tok, $first, $count, @add_tok);
	$_->[TOKEN_POS] += $replace_pos
		for @add_tok;
	my $ofs= length($add_buf) - ($replace_lim-$replace_pos);
	$_->[TOKEN_POS] += $ofs
		for @add_tok;
	return @removed;
}

sub scan_tokens {
	my $class= shift;
	# According to https://www.w3.org/TR/css-syntax-3
	# § 3.3
	$_[0] =~ s/( \r\n? | \f )/\n/xg;
	$_[0] =~ s/\0/\x{FFFD}/g;
	# § 4.1
	pos($_[0]) //= 0;
	my @ret;
	local $^R= undef;
	while($_[0] =~ m{\G
		# as an optimization, skip leading whitespace and generate the token later.
		[ \n\t]*
		  
		((?| # comment (non)token
		  /\* .*? \*/                                   (?{ [ 'comment' ] })
		  
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
			push @ret, [ $-[0] => 'whitespace' ]
		}
		next unless defined $^R;
		my $token= $^R;
		unshift @$token, $-[1];
		$^R= undef;
		# If an identifier followed a number with no whitespace inbetween,
		# it is a 'dimension' token.
		if ($token->[TOKEN_TYPE] eq 'ident' && $-[1] == $-[0] && @ret && $ret[-1][TOKEN_TYPE] eq 'number') {
			$ret[-1][TOKEN_TYPE]= 'dimension';
			$ret[-1][TOKEN_UNIT]= $token->[TOKEN_VALUE];
			next;
		}
		# Special case for 'url(...)' function that doesn't require quotes around the argument
		# (yes, this can be wedged into the regex above, but it gets reeealy ugly)
		elsif ($token->[TOKEN_TYPE] eq 'function' && lc($token->[TOKEN_VALUE]) eq 'url'
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
				$token->[TOKEN_TYPE]= 'url';
				$token->[TOKEN_VALUE]= $^R;
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
				$token->[TOKEN_TYPE]= 'bad_url';
				$token->[TOKEN_VALUE]= $^R;
			}
		}
		push @ret, $token;
		last if $token->[TOKEN_TYPE] eq 'EOF';
	}
	if (pos($_[0]) != length($_[0])) {
		push @ret,
			[ pos($_[0]) => 'garbage' ],
			[ length($_[0]) => 'EOF' ];
	}
	return \@ret;
}

1;
