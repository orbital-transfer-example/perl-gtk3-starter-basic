use strict;
use warnings;

use ExtUtils::MakeMaker::CPANfile;

WriteMakefile(
  NAME => 'App::Example',
  VERSION_FROM => 'lib/App/Example.pm',
  AUTHOR => 'A.U.Thor <author@cpan.org>',
  EXE_FILES => [ qw(bin/app.pl) ],
);

sub MY::postamble {
  my $self = shift;
  my @ret = ();
  push @ret, <<'MAKE_FRAG';
config :: share/LocaleData
	$(NOECHO) $(ABSPERLRUN) -MExtUtils::Install -e 'install([ from_to => {@ARGV}, verbose => '\''$(VERBINST)'\'' ]);' -- \
	  'share/LocaleData' '$(INST_LIB)/auto/share/dist/$(DISTNAME)/LocaleData'

clean :: clean_locale

clean_locale:
	- $(RM_RF) \
	  share/LocaleData \
	  po/*.gmo

share/LocaleData: po/io.github.orbital-transfer-example.Perl-Gtk3-Starter-Basic.pot
	cd po && $(MAKE) install

MAKE_FRAG

  return join "\n", @ret;
}
