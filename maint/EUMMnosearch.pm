use strict;
use warnings;
package EUMMnosearch;
# ABSTRACT: Hack ExtUtils::MakeMaker library searching on MSWin32

package # hide from PAUSE
	main;
# only run when we call the Makefile.PL script
if( $0 eq "Makefile.PL" || $0 eq "./Makefile.PL"  ) {
	$0 = "./Makefile.PL"; # normalise for no '.' in @INC
	require ExtUtils::MakeMaker;
	require ExtUtils::Liblist::Kid;

	open(my $f, '<', $0) or die "OPENING $0 $!\n";
	my $makefile_contents = do { local($/); <$f> };
	close($f);

	my $eumm_targ = "main";
	if( $makefile_contents =~ /^use XS::Install/m ) {
		$eumm_targ = 'XS::Install';
	}

	my $i = ExtUtils::MakeMaker->can("import");
	no warnings "redefine";
	no warnings "once";
	*ExtUtils::MakeMaker::import = sub {
		&$i;
		#my $targ = caller;
		my $targ = $eumm_targ;
		#my $wm = $targ->can("WriteMakefile");
		my $wm = ExtUtils::MakeMaker->can("WriteMakefile");
		print "$targ\n";
		no strict "refs"; ## no critic: 'RequireUseStrict'
		*{"${targ}::WriteMakefile"} = sub {
			my %args = @_;

			if( $args{LIBS} && ref $args{LIBS} eq 'ARRAY' ) {
				$args{LIBS} = join " ", @{ $args{LIBS} };
			}

			# Only apply :nosearch after lib linker directory
			# for entire mingw64 system. This way XS modules
			# that depend on other XS modules can compile
			# statically using .a files.
			#
			# The pattern needs to be case-insensitive because
			# Windows is case-insensitive.
			my $mingw64_lib_unix_path = '/mingw64/lib';

			$args{LIBS} = '' unless $args{LIBS};
			my @L_paths = $args{LIBS} =~ m/-L(\S+)/g;
			my @paths_to_replace = grep {
				my $path = $_;
				chomp(my $unix_path = `cygpath -u $path`);
				# look for match in case $path is specified as
				# relative directory
				$unix_path eq $mingw64_lib_unix_path;
			} @L_paths;

			for my $lib_path (@paths_to_replace) {
				$args{LIBS} =~ s,^(.*?)(\Q-L$lib_path\E\s),$1 :nosearch $2,i;
			}

			# Special case for expat (XML::Parser::Expat) because
			# it does not use either of
			#
			#   - -L<libpath>
			#   - pkg-config --libs expat
			$args{LIBS} =~ s,(\Q-lexpat\E),:nosearch $1,;

			# Special case for XS::libpanda
			if( $args{NAME} eq 'XS::libpanda' ) {
				$args{LIBS} =~ s,^(.*)$,:nosearch $1 :search,;
				$args{LIBS} =~ s/-lexecinfo//g;
			}
			print "LIBS: $args{LIBS}\n";
			$wm->(%args);
		};
	};

	*ExtUtils::Liblist::Kid::_win32_search_file = sub {
		my ( $thislib, $libext, $paths, $verbose, $GC ) = @_;

		my @file_list = ExtUtils::Liblist::Kid::_win32_build_file_list( $thislib, $GC, $libext );

		for my $path ( @{$paths} ) {
			for my $lib_file ( @file_list ) {
				my $fullname = $lib_file;
				$fullname = "$path\\$fullname" if $path;
				print $fullname, "\n";
				print `ls $fullname`, "\n";

				return ( $fullname, $path ) if -f $fullname;

				ExtUtils::Liblist::Kid::_debug( "'$thislib' not found as '$fullname'\n", $verbose );
			}
		}

		return;
	};


	if( $makefile_contents =~ /\QExtUtils::Depends\E/ ) {
	# Add back hack that was in `ExtUtils::Depends@0.8000` which is needed
	# for MINGW builds where one XS module depends on another XS module.
	#
	# See <https://rt.cpan.org/Ticket/Display.html?id=45224#txn-2006401>,
	# <https://gitlab.gnome.org/GNOME/perl-extutils-depends/-/merge_requests/2>.

# Hook into ExtUtils::MakeMaker to create an import library on MSWin32 when gcc
# is used.  FIXME: Ideally, this should be done in EU::MM itself.
package # wrap to fool the CPAN indexer
	ExtUtils::MM;
use Config;
sub static_lib {
	my $base = shift->SUPER::static_lib(@_);

	return $base unless $^O =~ /MSWin32/ && $Config{cc} =~ /\bgcc\b/i;

	my $DLLTOOL = $Config{'dlltool'} || 'dlltool';

	return <<"__EOM__"
# This isn't actually a static lib, it just has the same name on Win32.
\$(INST_DYNAMIC_LIB): \$(INST_DYNAMIC)
	$DLLTOOL --def \$(EXPORT_LIST) --output-lib \$\@ --dllname \$(DLBASE).\$(DLEXT) \$(INST_DYNAMIC)

dynamic:: \$(INST_DYNAMIC_LIB)
__EOM__
}
	}

	my $exit = eval { do $0 };
	warn "Hack failed: (exit: $exit) $@" if $@ || $exit;

	# we can exit now that we are done
	exit 0;
}

1;
