package CSS::Parser::StyleRule;
use Moo;

has selectors  => ( is => 'ro' );
has properties => ( is => 'ro' );

sub new_from_parse {
	my ($class, $parse)= @_;
	$class->new(selectors => $parse->[0], properties => $parse->[1]);
}

1;
