package CSS::Selector;
use Moo;

has name  => ( is => 'ro' );
has value => ( is => 'ro' );

sub new_from_parse {
	my ($class, $parse)= @_;
	$class->new(name => $parse->[0], value => $parse->[1]);
}

1;
