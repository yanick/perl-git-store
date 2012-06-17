use strict;
use warnings;

use Test::More;

use Git::PurePerl;
use Path::Class;
use GitStore;

plan skip_all => 'Test needs Git::Repository'
    unless eval "use Git::Repository; 1";

plan tests => 7;

# init the test
my $directory = 't/test';
dir($directory)->rmtree;
my $gitobj = Git::PurePerl->init( directory => $directory );

my $gs = GitStore->new($directory);

my @bad_files = (
    '/oops', 
    '///naughty',
);

$gs->set( $_ => $_ ) for @bad_files;

$gs->commit;

is $gs->get( $_ ) => $_, "can retrieve '$_'" for @bad_files;

my $clone_dir = dir( './t/test-clone' );
$clone_dir->rmtree;

ok Git::Repository->run( clone => dir($directory)->absolute->stringify,
        $clone_dir->stringify ), "cloning";

for my $file ( @bad_files ) {
    ok -f file( $clone_dir, $file )->stringify, "'$file' exists";
}

$gs->delete($_) for @bad_files;
$gs->commit;

is $gs->get($_) => undef, "'$_' not there anymore" for @bad_files;

