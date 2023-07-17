package CSS::Parser::Stylesheet;
use Moo;

has location => ( is => 'rw' );
has rules    => ( is => 'rw' );
has source   => ( is => 'rw' );
has tokens   => ( is => 'rw' );
has error    => ( is => 'rw' );

1;
