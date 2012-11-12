
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "File::Find" => 0,
    "File::Temp" => 0,
    "FindBin" => 0,
    "Module::Build" => "0.3601",
    "Scalar::Util" => 0,
    "Test::More" => "0.94",
    "perl" => "5.004"
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Git as versioned data store in Perl",
  "dist_author" => [
    "Fayland Lam <fayland\@gmail.com>",
    "Yanick Champoux <yanick\@cpan.org>"
  ],
  "dist_name" => "GitStore",
  "dist_version" => "0.13",
  "license" => "perl",
  "module_name" => "GitStore",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "Carp" => 0,
    "DateTime" => 0,
    "Git::PurePerl" => 0,
    "List::Util" => 0,
    "Moose" => 0,
    "Moose::Util::TypeConstraints" => 0,
    "Path::Class" => 0,
    "Storable" => 0,
    "strict" => 0,
    "warnings" => 0
  },
  "script_files" => []
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
