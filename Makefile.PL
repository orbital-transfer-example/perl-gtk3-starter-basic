use strict;
use warnings;

use ExtUtils::MakeMaker::CPANfile;

WriteMakefile(
  NAME => 'App::Example',
  VERSION_FROM => 'lib/App/Example.pm',
  AUTHOR => 'A.U.Thor <author@cpan.org>',
  EXE_FILES => [ qw(bin/app.pl) ],
  META_MERGE  => {
    x_static_install => 1,
  },
);
