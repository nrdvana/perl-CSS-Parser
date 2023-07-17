package CSS::Parser::AtRule;
use Moo;

has name   => ( is => 'ro' );
has values => ( is => 'ro' );
has rules  => ( is => 'ro' );

1;
