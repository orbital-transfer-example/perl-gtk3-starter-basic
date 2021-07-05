#!/usr/bin/env perl
# PODNAME: helper
# ABSTRACT: helper for build

use strict;
use warnings;

use CPAN::Meta::YAML; # only using for devops.yml
use Data::Dumper ();
use IPC::Cmd ();
use JSON::PP ();
use IO::File;
use File::Spec;
use File::Path ();
use File::Copy ();
use File::Basename ();
use File::Temp ();
use File::Find ();
use List::Util qw(first);
use Config ();
use Env qw(
	@PATH
	@PERL5LIB
	$PERL_LOCAL_LIB_ROOT
	$PERL_MB_OPT $PERL_MM_OPT
	$PERL5OPT
);
use Cwd ();

use constant {
	PLATFORM_LINUX_DEBIAN => 'debian',
	PLATFORM_MACOS_HOMEBREW => 'macos-homebrew',
	PLATFORM_MACOS_MACPORTS => 'macos-macports',
	PLATFORM_MSYS2_MINGW64 => 'msys2-mingw64',
};

my $command_dispatch = {
	'exec' => \&cmd_exec,
	'check-devops-yaml' => \&cmd_check_devops_yaml,
	'get-packages' => \&cmd_get_packages,
	'setup-cpan-client' => \&cmd_setup_cpan_client,
	'install-native-packages' => \&cmd_install_native_packages,
	'install-via-cpanfile' => \&cmd_install_via_cpanfile,
	'gha-get-cache-output' => \&cmd_gha_get_cache_output,
	'run-tests' => \&cmd_run_tests,
	'create-dist-tarball' => \&cmd_create_dist_tarball,
	'build-msi' => \&cmd_build_msi,
	'setup-macports-ci' => \&cmd_setup_macports_ci,
	'install-macports' => \&cmd_install_macports,
	'setup-for-dmg' => \&cmd_setup_for_dmg,
	'build-dmg' => \&cmd_build_dmg,
};

sub main {
	my $command = shift @ARGV;

	die "Need command: @{[ sort keys %$command_dispatch ]}"
		unless $command;
	die "Unknown command: $command"
		unless exists $command_dispatch->{$command};

	_setup_perl_install();
	$IPC::Cmd::VERBOSE = 1;
	$command_dispatch->{$command}->();
}

#### Utilities
sub _log {
	print STDERR @_;
}

sub _read_file {
	my ($file) = @_;
	open my $fh, "<:encoding(UTF-8)", $file;
	my $contents = do { local $/; <$fh> };
}

sub _is_debian { $^O eq 'linux' && -f '/etc/debian_version' }
sub _is_macos  { $^O eq 'darwin' }
sub _is_msys2_mingw { $^O eq 'MSWin32' && exists $ENV{MSYSTEM} }

sub _is_github_action { exists $ENV{GITHUB_ACTIONS} }

my $_PLATFORM_TYPE_CACHE;
sub _get_platform_type {
	return $_PLATFORM_TYPE_CACHE if $_PLATFORM_TYPE_CACHE;

	if ( _is_debian() ) {
		$_PLATFORM_TYPE_CACHE = PLATFORM_LINUX_DEBIAN;
	} elsif( _is_macos() ) {
		$_PLATFORM_TYPE_CACHE = PLATFORM_MACOS_HOMEBREW;
	} elsif( _is_msys2_mingw() ) {
		$_PLATFORM_TYPE_CACHE = PLATFORM_MSYS2_MINGW64;
	} else {
		die "Unknown platform";
	}

	return $_PLATFORM_TYPE_CACHE;
}

sub read_devops_file {
	my $yaml = CPAN::Meta::YAML->read_string(_read_file('maint/devops.yml'))
		or die CPAN::Meta::YAML->errstr;
	my $data = $yaml->[0];
	return $data;
}

sub get_package_list {
	my $data = read_devops_file();
	return $data->{native}{ _get_platform_type() }{packages} || [];
}

my $PLATFORM_PREFIX_GHA = {
	PLATFORM_LINUX_DEBIAN ,=> '/home/runner/build',
	PLATFORM_MACOS_HOMEBREW ,=> '/Users/runner/build',
	PLATFORM_MSYS2_MINGW64 ,=> 'c:/cx',
};
sub get_gha_prefix {
	return $PLATFORM_PREFIX_GHA->{ _get_platform_type() };
}

# Directory under which build work is done.
sub get_prefix {
	if( _is_github_action() ) {
		return get_gha_prefix();
	}

	File::Spec->catfile( Cwd::getcwd(), 'build' );
}

# Directory under which components are installed.
#
# By default, the same as get_prefix()
our $INSTALL_PREFIX;
sub get_install_prefix() {
	if( ! $INSTALL_PREFIX ) {
		return get_prefix();
	}

	return $INSTALL_PREFIX;
}

sub get_perl_install_prefix {
	File::Spec->catfile(get_install_prefix(), 'perl5');
}

sub get_tool_prefix {
	File::Spec->catfile( Cwd::getcwd(), '_tool' );
}

sub get_app_install_prefix {
	File::Spec->catfile(get_install_prefix(), 'app');
}

sub get_msys2_install_prefix {
	# /mingw64 gets installed under $PREFIX/mingw64
	get_install_prefix();
}

sub get_msys2_base {
	chomp( my $msys2_base = `cygpath -w /` );
	$msys2_base;
}

sub _setup_perl_install {
	my $perl5_dir = get_perl_install_prefix();
	my $tool_dir = get_tool_prefix();

	for my $dir ( $perl5_dir, $tool_dir ) {
		my $lib_dir  = File::Spec->catfile( $dir, qw(lib perl5));
		my $arch_dir = File::Spec->catfile( $dir, qw(lib perl5), $Config::Config{archname} );
		my $bin_dir =  File::Spec->catfile( $dir, 'bin');
		unshift @PATH, $bin_dir;
		unshift @PERL5LIB, $lib_dir, $arch_dir;
		unshift @INC, $lib_dir, $arch_dir;
	}

	$PERL_LOCAL_LIB_ROOT = $perl5_dir;
	$PERL_MB_OPT = "--install_base $perl5_dir";
	$PERL_MM_OPT = "INSTALL_BASE=$perl5_dir";

	if( _is_msys2_mingw() ) {
		$PERL5OPT="-I@{[ Cwd::getcwd() ]}/maint -MEUMMnosearch";
	}
}

#### Commands

sub cmd_exec {
	# replace 'perl' with running perl
	$ARGV[0] = $^X if $ARGV[0] eq 'perl';

	IPC::Cmd::run( command => \@ARGV ) or die;
}

sub cmd_check_devops_yaml {
	my $data = read_devops_file();
	require YAML;
	require Test::Deep;
	require Test::More;
	my $data_compare = YAML::LoadFile('maint/devops.yml');
	Test::Deep::cmp_deeply( $data, $data_compare );
	Test::More::done_testing();
}

sub cmd_get_packages {
	my $packages = get_package_list();
	print join(' ', @$packages), "\n";
}

our @CPAN_CLIENT_MODULES = qw(App::cpanminus App::cpm local::lib);
use constant {
	# NOTE using shell
	RUN_INST_CPANM_V_CPAN => "yes | cpan -T @CPAN_CLIENT_MODULES || true",
};
sub cmd_setup_cpan_client {
	if( IPC::Cmd::can_run('curl' ) ) {
		my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
		my $cpanm_down = File::Spec->catfile(
			$tmpdir, 'cpanm'
		);
		IPC::Cmd::run( command => [
			qw(curl https://cpanmin.us),
				qw(-o), $cpanm_down
		]) or die;

		IPC::Cmd::run( command => [
			qw(perl), $cpanm_down,
			@CPAN_CLIENT_MODULES,
			qw(-L), get_perl_install_prefix(),
			qw(-n --no-man-pages),
		] ) or die;
	} else {
		IPC::Cmd::run( command => RUN_INST_CPANM_V_CPAN ) or die;
	}
}

my $RUN_INSTALL_CMD = {
	PLATFORM_LINUX_DEBIAN ,=> [ qw( sudo apt-get install -y --no-install-recommends ) ],
	PLATFORM_MACOS_HOMEBREW ,=> [ qw( brew install ) ],
	PLATFORM_MSYS2_MINGW64 ,=> [ qw( pacman -S --needed --noconfirm ) ],
};

sub _install_native_packages {
	my ($packages) = @_;
	return unless @$packages;

	IPC::Cmd::run(
		command => [
			@{ $RUN_INSTALL_CMD->{ _get_platform_type() } },
			@$packages,
		]
	) or die;
}

sub cmd_install_native_packages {
	my $packages = get_package_list();
	if( _is_debian() ) {
		push @$packages, qw(xvfb);
	}
	_install_native_packages($packages);
}

sub cmd_install_via_cpanfile {
	# Use shorter path particularly on Windows to avoid Win32 MAX_PATH
	# issues.
	my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
	my $cpm_home_dir = File::Spec->catfile( $tmpdir, qw(.perl-cpm) );
	my $cpanm_home_dir = File::Spec->catfile( $tmpdir, qw(.cpanm) );
	$ENV{PERL_CPANM_HOME} = $cpanm_home_dir;

	my $cpm_success = IPC::Cmd::run( command => [
		qw(cpm install --cpanfile=./cpanfile --show-build-log-on-failure),
		qw(-L), get_perl_install_prefix(),
		qw(--home), $cpm_home_dir,
	]);
	return if $cpm_success;

	my $cpanm_success = IPC::Cmd::run( command => [
		qw(cpanm --installdeps .),
		qw(-L), get_perl_install_prefix(),
	]);
	return if $cpanm_success;

	print "cpanm failed. Dumping build log:\n";
	print _read_file( File::Spec->catfile($cpanm_home_dir, qw(build.log)) ), "\n";
	die;
}

sub cmd_gha_get_cache_output {
	my @paths = ( get_perl_install_prefix() );
	my $json = JSON::PP->new->allow_nonref;
	my $paths_json = $json->encode(join "\n", @paths);
	print '::set-output name=paths::', $paths_json,  "\n";
	print '::set-output name=prefix::', get_gha_prefix(),  "\n";
}

sub cmd_run_tests {
	my @dirs = qw(t xt);

	my @dirs_exist = grep { -d } @dirs;
	return unless @dirs_exist;

	my @prove_command = ( $^X, qw(-S prove -lvr ), @dirs_exist );

	if( _is_debian() ) {
		unshift @prove_command, qw(xvfb-run -a);
	}

	IPC::Cmd::run( command => [
		@prove_command
	]) or die;
}

sub cmd_create_dist_tarball {
	my ($basename, $dirname) = File::Basename::fileparse( get_install_prefix() );
	my $tarball_name = "$basename.tbz2";
	IPC::Cmd::run( command => [
		qw( tar cjvf ), $tarball_name,
		qw(-C), $dirname,
		$basename,
	]) or die;

	if( _is_github_action() ) {
		print '::set-output name=dist-tarball-file::', $tarball_name,  "\n";
	}
}

sub _pacman_package_dependencies {
	my ($package, @opts) = @_;

	my %package_set = ();
	my @linear_package_list = do {
		my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
			command => [ qw(pactree -l), @opts, $package  ],
			verbose => 0,
		) or die;

		split /\n/, join "", @$stdout_buff;
	};
	# NOTE the output of linear package list contains the direct
	# package
	$package_set{$_} = 1 for @linear_package_list;
	return [ keys %package_set ];
}

sub _pacman_package_direct_children {
	my ($package) = @_;
	return [ grep { $_ ne $package } @{ _pacman_package_dependencies( $package, qw(--depth 1) ) } ];
}

sub _pacman_package_files_pacman {
	my ($package) = @_;
	my @package_files = do {
		my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
			command => [ qw(pacman -Ql), $package ],
			verbose => 0,
		) or die;

		map { (/^[\w-]+\s+(.*)$/)[0]  }
			split /\n/, join "", @$stdout_buff;
	};
	\@package_files;
}

my $pkgfile_setup_state = 0;
sub _pacman_package_files_pkgfile {
	my ($package) = @_;

	if( !$pkgfile_setup_state ) {
		_install_native_packages([ 'pkgfile' ]);
		IPC::Cmd::run( command => [
			qw(pkgfile --update),
		]) or die;
		$pkgfile_setup_state = 1;
	}

	my @package_files = do {
		my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
			command => [ qw(pkgfile -l), $package ],
			verbose => 0,
		) or die;

		map { (/^[^\t]+\t(.*)$/)[0]  }
			split /\n/, join "", @$stdout_buff;
	};
	\@package_files;
}

sub _pacman_package_files {
	my ($package) = @_;
	# pkgfile is faster than pacman
	_pacman_package_files_pkgfile($package);
}

sub _pacman_apply_filters_to_package {
	my ($package) = @_;

	my $data = read_devops_file();
	my $filters = $data->{dist}{ PLATFORM_MSYS2_MINGW64() }{pacman}{filter};

	_log "Retrieving files for $package\n";
	my $package_files = _pacman_package_files( $package );

	my %package_files_copy = map { $_ => 1 } @$package_files;
	for my $filter (@$filters) {
		my $package_re = qr/$filter->{package}/;
		if( $package =~ $package_re ) {
			my $file_filter_re = qr/@{[ join "|", @{ $filter->{files} } ]}/x;
			FILE: for my $file (keys %package_files_copy) {
				$package_files_copy{$file} = 0 if $file =~ $file_filter_re;
			}
		}
	}
	my @package_files_filtered = grep $package_files_copy{$_}, keys %package_files_copy;

	_log "$package: @{[ scalar @package_files_filtered ]} files to copy / @{[ scalar @$package_files ]} total files\n";

	\@package_files_filtered;
}

sub _build_msi_install_app {
	IPC::Cmd::run( command => [
		qw(cpanm .),
		qw(--verbose -n --no-man-pages),
		qw(-l), get_app_install_prefix(),
	]) or die;
}

sub _build_msi_get_app_exec_info {
	my $data = read_devops_file();
	my $script_name = $data->{dist}{app}{script};
	my $basename = File::Basename::basename( $script_name, qw(.pl) );
	return +{
		script_path => $script_name,
		basename => $basename,
		par_output_name => "$basename@{[ $Config::Config{_exe} ]}",
	}
}

sub _build_msi_par_packer {
	IPC::Cmd::run( command => [
		qw(cpanm -n --no-man-pages),
		qw(-L), get_tool_prefix(),
		qw( Template Data::UUID PAR::Packer ),
	]) or die;

	IPC::Cmd::run( command => [
		qw(cpanm -n --no-man-pages),
		qw(-L), get_perl_install_prefix(),
		qw( Win32::HideConsole ),
	]) or die;

	my $exec_info = _build_msi_get_app_exec_info();

	my ($fh, $filename) = File::Temp::tempfile();
	my $app_rel_prefix = [ File::Spec->splitdir(
		File::Spec->abs2rel( get_app_install_prefix(), get_install_prefix() )
	) ];

	print $fh <<'EOF';
use strict;
use warnings;

my $app_rel_prefix;
EOF
	print $fh <<EOF;
BEGIN {
	@{[ Data::Dumper->Dump( [$app_rel_prefix], [qw( app_rel_prefix )] ) ]}
}

EOF

	print $fh <<'EOF';
use Env qw(@PATH);

BEGIN {
	if( exists $ENV{PAR_PROGNAME} ) {
		# running under PAR::Packer
		require File::Basename;
		require File::Spec;
		my $prefix = File::Basename::dirname( $ENV{PAR_PROGNAME} );
		unshift @PATH, map {
			File::Spec->catfile( $prefix, @$_ )
		} (
			[qw(mingw64 bin)],
		);

		# to load Perl core modules
		unshift @INC, File::Spec->catfile( $prefix,
			qw(mingw64 lib perl5 core_perl) );

		# load app deps
		require local::lib;
		local::lib->import(
			'--no-create',
			File::Spec->catfile( $prefix, qw(perl5) ),
			File::Spec->catfile( $prefix, qw(app) ),
		);

		if( ! $ENV{PAR_MSWIN32_NOHIDE} && $^O eq 'MSWin32' ) {
			# Removes the persistent console window when compiled
			# with /SUBSYSTEM:CONSOLE
			print "Reticulating splines...\n";
			require Win32::HideConsole;
			Win32::HideConsole::hide_console();

			# Removes the console windows for subprocesses that run under
			# the cmd.exe shell when compiled with /SUBSYSTEM:WINDOWS
			require Win32;
			Win32::SetChildShowWindow(0);
		}
	}
}

EOF

	# Add original script
	print $fh _read_file( $exec_info->{script_path} );

	IPC::Cmd::run( command => [
		$^X, qw(-c),
		qq{-Mlocal::lib=--no-create,@{[ get_app_install_prefix() ]}},
		$filename,
	]) or die;

	# Using the /SUBSYSTEM:CONSOLE (no --gui option)
	IPC::Cmd::run( command => [
		$^X,
		qw(-S pp),
		# Modules to bundle
		( map { qw(-M), $_ } qw(Env Tie::Array local::lib) ),
		qw( -vvv -n -B ),
		qw(-o), File::Spec->catfile( get_install_prefix(), $exec_info->{par_output_name} ),
		$filename,
	]) or die;
}

sub _build_msi_copy_msys2_deps {
	my @packages_to_process = (
		'mingw-w64-x86_64-perl',
		@{ get_package_list() }
	);

	my @files_to_copy;
	my %packages_processed;
	while(  @packages_to_process ) {
		my $package = shift @packages_to_process;
		next if exists $packages_processed{ $package };
		my $files = _pacman_apply_filters_to_package( $package );
		if( @$files ) {
			push @files_to_copy, @$files;
			push @packages_to_process,
				grep { ! exists $packages_processed{$_} }
				@{ _pacman_package_direct_children( $package ) };
		} else {
			_log "No files for $package. Skipping children\n";
		}
		$packages_processed{ $package } = 1;
	}

	my $msys2_base = get_msys2_base();
	my $prefix = get_msys2_install_prefix();
	for my $file (@files_to_copy) {
		my $source_path = File::Spec->catfile( $msys2_base, $file );
		my $target_path = File::Spec->catfile( $prefix, $file );

		if( -f $source_path && ! -r $target_path ) {
			my $parent_dir = File::Basename::dirname($target_path);
			File::Path::make_path( $parent_dir ) if ! -d $parent_dir;
			File::Copy::copy($source_path, $target_path )
				or die "Could not copy: $source_path -> $target_path";
			_log "Copied $source_path -> $target_path\n";
		}
	}

	# Post-install
	my $old_cwd = Cwd::getcwd();

	unshift @PATH, File::Spec->catfile( $prefix,
		qw(mingw64 bin),
	);

	chdir $prefix;

	# NOTE might not need to copy these into prefix.
	#
	# For example, use $ENV{GDK_PIXBUF_MODULE_FILE} for
	# gdk-pixbuf-query-loaders.
	IPC::Cmd::run( command => [
		qw(gdk-pixbuf-query-loaders --update-cache)
	]) or die;

	IPC::Cmd::run( command => [
		qw(glib-compile-schemas),
			File::Spec->catfile( qw(mingw64 share glib-2.0 schemas) )
	]) or die;

	chdir $old_cwd;
}

sub _build_msi_get_paraffin {
	my $paraffin_tool_dir = File::Spec->catfile( get_tool_prefix(), 'Paraffin');
	my $paraffin_download_url = 'https://github.com/Wintellect/Paraffin/releases/download/3.7.1/Paraffin.zip';
	my $paraffin_zip_path = File::Spec->catfile( $paraffin_tool_dir, 'Paraffin.zip' );
	my $paraffin_top_dir = File::Spec->catfile( $paraffin_tool_dir, 'extract' );
	my $paraffin_exe = File::Spec->catfile($paraffin_top_dir, 'Paraffin.exe');
	if( !-d $paraffin_tool_dir ) {
		File::Path::make_path( $paraffin_tool_dir );
		IPC::Cmd::run( command => [
			qw(wget),
			qw(-P), $paraffin_tool_dir,
			$paraffin_download_url,
		]) or die;
		File::Path::make_path $paraffin_top_dir;
		IPC::Cmd::run( command => [
			qw(C:/Windows/System32/tar),
			qw(-C), $paraffin_top_dir,
			qw(-xf), $paraffin_zip_path,
		]) or die;
	}

	return $paraffin_exe;
}

sub _git_version_from_tags {
	chomp( my $git_version = `git describe --exact-match --tags` );
	$git_version;
}

sub _build_msi_build_wix {
	my $old_cwd = Cwd::getcwd();
	my $prefix = get_install_prefix();

	require Data::UUID;
	require Template;

	my $paraffin_exe = _build_msi_get_paraffin();
	my $tt = Template->new;

	my $main_wxs = 'app.wxs';
	my $main_wixobj = 'app.wixobj';
	my @wxs_files;
	my @wixobj_files;

	my @dirs = qw(app mingw64 perl5);

	my $data = read_devops_file();
	my $wix_data = $data->{dist}{ PLATFORM_MSYS2_MINGW64() }{wix};
	$wix_data->{exec} = _build_msi_get_app_exec_info();
	$wix_data->{uuid} = Data::UUID->new;
	$wix_data->{dirs} = \@dirs;

	_install_native_packages([ qw(git) ]); # should have git
	my $git_version = _git_version_from_tags();
	$wix_data->{package_version} = $git_version || '0.0.0.0';

	chdir $prefix;
	$tt->process( \<<TEMPLATE, $wix_data, $main_wxs ) or die $tt->error, "\n";
<?xml version='1.0' encoding='windows-1252'?>
<Wix xmlns='http://schemas.microsoft.com/wix/2006/wi'>
  <Product Name='[% product_name %]' Id='[% product_uuid %]' UpgradeCode='[% uuid.create_str() %]'
    Language='1033' Codepage='1252'
    Version='[% package_version %]'
    Manufacturer='[% manufacturer %]'>

    <Package Id='*' Keywords='Installer' Description="[% package_description %]"
      Comments='[% package_comments %]' Manufacturer='[% manufacturer %]'
      InstallerVersion='100' Languages='1033' Compressed='yes' SummaryCodepage='1252' />

    <Media Id='1' Cabinet='Sample.cab' EmbedCab='yes' DiskPrompt="CD-ROM #1" />
    <Property Id='DiskPrompt' Value="[% package_description %] Installation [1]" />

    <Directory Id='TARGETDIR' Name='SourceDir'>
      <Directory Id='ProgramFilesFolder' Name='PFiles'>
        <Directory Id='INSTALLDIR' Name='[% INSTALLDIR %]'>

          <Component Id='MainExecutable' Guid='[% uuid.create_str() %]'>
            <File Id='[% exec.basename %]EXE' Name='[% exec.par_output_name %]' DiskId='1' Source='[% exec.par_output_name %]' KeyPath='yes'>
              <Shortcut Id="startmenuPR" Directory="ProgramMenuDir" Name="[% product_name %]" WorkingDirectory='INSTALLDIR' Icon="[% exec.basename %].exe" IconIndex="0" Advertise="yes" />
              <Shortcut Id="desktopPR" Directory="DesktopFolder" Name="[% product_name %]" WorkingDirectory='INSTALLDIR' Icon="[% exec.basename %].exe" IconIndex="0" Advertise="yes" />
            </File>
          </Component>
        </Directory>
      </Directory>

      <Directory Id="ProgramMenuFolder" Name="Programs">
        <Directory Id="ProgramMenuDir" Name="[% ProgramMenuDir %]">
          <Component Id="ProgramMenuDir" Guid="[% uuid.create_str() %]">
            <RemoveFolder Id='ProgramMenuDir' On='uninstall' />
            <RegistryValue Root='HKCU' Key='Software\[Manufacturer]\[ProductName]' Type='string' Value='' KeyPath='yes' />
          </Component>
        </Directory>
      </Directory>

      <Directory Id="DesktopFolder" Name="Desktop" />
    </Directory>

    <Feature Id='Complete' Level='1'>
      <ComponentRef Id='MainExecutable' />
      <ComponentRef Id='ProgramMenuDir' />
      [% FOREACH d IN dirs %]
      <ComponentGroupRef Id='app_[% d %]' />
      [% END %]
    </Feature>

    <Icon Id="[% exec.basename %].exe" SourceFile="[% exec.par_output_name %]" />

  </Product>
</Wix>

TEMPLATE

	for my $dir (@dirs) {
		my $group_name = "app_$dir"; # same name as ComponentGroupRef
		my $wxs = "$group_name.wxs";
		my $wixobj = "$group_name.wixobj";
		IPC::Cmd::run( command => [
			$paraffin_exe,
			qw(-d), $dir,
			qw(-gn), $group_name,
			$wxs,
		]) or die;
		push @wxs_files, $wxs;
		push @wixobj_files, $wixobj;
	}

	push @PATH, "C:/Program Files (x86)/WiX Toolset v3.11/bin";
	IPC::Cmd::run( command => [
		qw(candle), @wxs_files, $main_wxs
	]) or die;

	my $output_path = File::Spec->catfile(
		$prefix,
		"@{[ $wix_data->{app_shortname} ]}-mingw64-@{[ $git_version || 'noversion' ]}.msi"
	);
	IPC::Cmd::run( command => [
		qw(light -v),
		@wixobj_files, $main_wixobj,
		qw(-o), $output_path,
	]) or die;

	if( _is_github_action() ) {
		print '::set-output name=asset::', $output_path,  "\n";
	}

	chdir $old_cwd;
}

sub cmd_build_msi {
	die "Can only build .msi on @{[ PLATFORM_MSYS2_MINGW64 ]}"
		unless _is_msys2_mingw();

	_build_msi_install_app;
	_build_msi_par_packer;
	_build_msi_copy_msys2_deps;
	_build_msi_build_wix;
}

use constant MACPORTS_PREFIX => '/opt/orb';

our $MACPORTS_CACHED_BUILD_DIR = "@{[ MACPORTS_PREFIX ]}/var/macports/incoming/_cached";

sub cmd_setup_macports_ci {
	# Use <https://github.com/GiovanniBussi/macports-ci> to install MacPorts in CI
	IPC::Cmd::run( command => [
		qw(curl -LO https://raw.githubusercontent.com/GiovanniBussi/macports-ci/master/macports-ci)
	]) or die;

	IPC::Cmd::run( command => [
		qw(bash -c), "source ./macports-ci install --prefix=@{[ MACPORTS_PREFIX ]}"
	]) or die;

	_log "Using sudo to edit MacPorts configuration\n";
	system( qw(sudo), $^X, qw(-e), 'do shift @ARGV; _macports_edit_conf_runner()', '--', File::Spec->rel2abs($0) );
}

sub _macports_edit_conf_runner {
	my $macports_etc_path  = File::Spec->catfile( MACPORTS_PREFIX, qw(etc macports) );
	my $macports_conf_path = File::Spec->catfile( $macports_etc_path, qw(macports.conf) );
	my $variants_conf_path = File::Spec->catfile( $macports_etc_path, qw(variants.conf) );
	my $archives_conf_path = File::Spec->catfile( $macports_etc_path, qw(archive_sites.conf) );
	my $pubkeys_conf_path  = File::Spec->catfile( $macports_etc_path, qw(pubkeys.conf) );

	my $data = read_devops_file();
	my $macports_pkg_data = $data->{native}{ PLATFORM_MACOS_MACPORTS() };
	my $macports_dist_data = $data->{dist}{ PLATFORM_MACOS_MACPORTS() };

	my $mp_conf_fh = IO::File->new;
	$mp_conf_fh->open( $macports_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $macports_conf_path";
	my $mp_vari_fh = IO::File->new;
	$mp_vari_fh->open( $variants_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $variants_conf_path";
	my $mp_site_fh = IO::File->new;
	$mp_site_fh->open( $archives_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $archives_conf_path";
	my $mp_pk_fh = IO::File->new;
	$mp_pk_fh->open( $pubkeys_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $pubkeys_conf_path";
	if( exists $macports_dist_data->{macosx_deployment_target} ) {
		die "macosx_deployment_target invalid"
			unless $macports_dist_data->{macosx_deployment_target} =~ /^(10|11).[0-9]+$/;
		print $mp_conf_fh <<EOF
buildfromsource ifneeded
macosx_deployment_target @{[ $macports_dist_data->{macosx_deployment_target} ]}
EOF
	}

	if( exists $macports_dist_data->{macosx_sdk_version} ) {
		die "macosx_sdk_version invalid"
			unless $macports_dist_data->{macosx_sdk_version} =~ /^(10|11).[0-9]+$/;
		print $mp_conf_fh <<EOF
macosx_sdk_version @{[ $macports_dist_data->{macosx_sdk_version} ]}
EOF
	}

	if( exists $macports_pkg_data->{variants} ) {
		print $mp_vari_fh join "\n", @{ $macports_pkg_data->{variants} };
	}

	# Per the MacPorts documentation, this should shadow the default
	# MacPorts archive source.
	#
	# It also should not be working in this case as the prefix is not the
	# default prefix of /opt/local.
	print $mp_site_fh <<EOF;

name                	macports_archives

EOF
	# use cached path
	print $mp_site_fh <<EOF;

name                    My Cached Builds
urls                    file://${MACPORTS_CACHED_BUILD_DIR}
prefix                  @{[ MACPORTS_PREFIX ]}
applications_dir        @{[ MACPORTS_PREFIX ]}/Applications

EOF

	# Sign the binary archives <https://trac.macports.org/wiki/howto/ShareArchives2>
	my $privkey_path = File::Spec->catfile( $macports_etc_path, 'local-privkey.pem');
	my $pubkey_path  = File::Spec->catfile( $macports_etc_path, 'local-pubkey.pem');

	system(
		qw(openssl genrsa),
		qw(-out), $privkey_path,
		qw(2048)
	) == 0 or die;

	system(
		qw(openssl rsa),
		qw(-in), $privkey_path,
		qw(-pubout -out), $pubkey_path,
	) == 0 or die;

	print $mp_pk_fh "$pubkey_path\n";

	system( qw(tail -20), $macports_conf_path, $variants_conf_path, $archives_conf_path, $pubkeys_conf_path );
}

sub _gh_check_for_release {
	my ($tag) = @_;
	return !! IPC::Cmd::run( command => [
		qw(gh release view), $tag
	]);
}

sub _move_file_runner {
	my $source_path = shift @ARGV;
	my $target_path = shift @ARGV;

	my $parent_dir = File::Basename::dirname($target_path);
	File::Path::make_path( $parent_dir ) if ! -d $parent_dir;

	File::Copy::move($source_path, $target_path )
		or die "Could not copy: $source_path -> $target_path";
	_log "Moved $source_path -> $target_path\n";
}

sub cmd_install_macports {
	my $data = read_devops_file();
	my $macports_pkg_data = $data->{native}{ PLATFORM_MACOS_MACPORTS() };
	my $mp_softare_path = File::Spec->catfile( MACPORTS_PREFIX, qw(var macports software) );
	my $mp_incoming_path = File::Spec->catfile( MACPORTS_PREFIX, qw(var macports incoming verified) );
	my $macports_etc_path  = File::Spec->catfile( MACPORTS_PREFIX, qw(etc macports) );
	my $privkey_path = File::Spec->catfile( $macports_etc_path, 'local-privkey.pem');

	my $release_tag = 'continuous-macports';
	my $release_title = 'Continuous MacPorts builds';

	# Check for auth before anything else:
	#   $ gh auth status

	my $release_exists = _gh_check_for_release( $release_tag );
	my %ports_assets;
	my %assets_archives;
	if( $release_exists ) {
		# get list of assets
		my @asset_urls = do {
			my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
				command => [
					qw(gh release view), $release_tag,
						qw(--json assets),
						qw(-q), '.assets.[].url'
				],
				verbose => 0,
			) or die;

			split /\n/, join "", @$stdout_buff;
		};

		# download the assets and move them into ports software directory
		for my $asset_url (@asset_urls) {
			_log "Downloading asset $asset_url\n";
			my $asset_name = (split '/', $asset_url)[-1];
			$asset_name =~ s/%2B/+/g; # percent encoding unescape
			system( qw(curl -L),
				$asset_url,
				qw(--output), $asset_name,
			);

			my $asset_sign_name = "${asset_name}.rmd160";

			system( qw(sudo), qw(openssl dgst -ripemd160),
				qw(-sign), $privkey_path,
				qw(-out), $asset_sign_name,
				$asset_name,
			) == 0 or die;

			my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
				command => [
					qw(tar xjf),
						$asset_name,
						qw(-O ./+CONTENTS)
				],
				verbose => 0,
			) or die;
			my $port_name_line = first { /^\@portname\s+/ }
				split /\n/, join "", @$stdout_buff;
			my ($port_name) = $port_name_line =~ /^\@portname\s+(.*)$/;

			my $port_dir = File::Spec->catfile($MACPORTS_CACHED_BUILD_DIR, $port_name);
			do {
				my $source_path = $asset_name;
				my $target_path = File::Spec->catfile( $port_dir, $asset_name );

				system( qw(sudo), $^X, qw(-e), 'do shift @ARGV; _move_file_runner()', '--',
					File::Spec->rel2abs($0),
					$source_path, $target_path
				) == 0 or die;
			};
			do {
				my $source_path = $asset_sign_name;
				my $target_path = File::Spec->catfile( $port_dir, $asset_sign_name );

				system( qw(sudo), $^X, qw(-e), 'do shift @ARGV; _move_file_runner()', '--',
					File::Spec->rel2abs($0),
					$source_path, $target_path
				) == 0 or die;
			};

			$assets_archives{$asset_name} = 1;
			$ports_assets{$port_name} = $asset_name;
		}
	}

	my $should_install_all_cached_ports = 0;
	if( $should_install_all_cached_ports ) {
		# Install all pre-built port binary archives.
		my @ports_with_assets = keys %ports_assets;
		if( @ports_with_assets ) {
			IPC::Cmd::run( command => [
				qw(sudo port -N install --unrequested -b),
					@ports_with_assets
			]) or die;
		}
	}

	# This will install from the cached directory for any already built
	# ports.
	#
	# Ports that have not been built will be built from source.
	IPC::Cmd::run( command => [
		qw( sudo port -N install ),
			@{ $macports_pkg_data->{packages} },

			# Needed for build-time
			qw(pkgconfig),
	]) or die;

	## ignore exit value because it may possibly not exist yet
	#IPC::Cmd::run( command => [
		#qw(gh release delete), $release_tag
	#]);

	if( ! $release_exists ) {
		IPC::Cmd::run( command => [
			qw(gh release),
			qw(create),
			qw(--prerelease),
			qw(-t), $release_title,
			'--notes', 'Continous build of MacPorts archives',
			$release_tag
		]) or die;
	}

	my @files_found;
	File::Find::find(
		sub { push @files_found, $File::Find::name if -f },
		$mp_softare_path );

	my @files_to_upload;

	my @new_files = grep { ! exists $assets_archives{ File::Basename::basename($_) } } @files_found;

	@files_to_upload = @new_files;

	if( @files_to_upload ) {
		IPC::Cmd::run( command => [
			qw(gh release),
			qw(upload),
			$release_tag,
			@files_to_upload
		]) or die;
	}
}

sub _otool_libs {
	my ($file) = @_;

	my @libs = do {
		my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
			command => [ qw(otool -L), $file  ],
			verbose => 0,
		) or die;

		my @lines = split /\n/, join "", @$stdout_buff;

		# first line is $file
		shift @lines;
		grep { defined } map {
			$_ =~ m%[[:blank:]]+(.*/([^/]*\.dylib))[[:blank:]]+\(compatibility version%;
			my $path = $1;
			$path;
		} @lines;
	};

	\@libs;
}

sub cmd_setup_for_dmg {
	my $prefix = get_prefix();
	my $data = read_devops_file();
	my $dmg_data = $data->{dist}{ PLATFORM_MACOS_MACPORTS() }{dmg};
	my $app_name = $dmg_data->{'app-name'};

	# Set up paths
	my $install_dir = "/Applications/${app_name}.app";
	my $app_build_dir_orig = File::Spec->catfile(
		$prefix, "${app_name}.app"
	);
	my $app_build_dir = $app_build_dir_orig;
	$app_build_dir =~ s/ /-/g; # no space for build

	# Template paths
	my @T_DIR_RESOURCES = qw(Contents Resources);
	my @T_DIR_MACPORTS  = ( @T_DIR_RESOURCES,
		File::Spec->splitdir(MACPORTS_PREFIX) );

	my $app_res = File::Spec->catfile(
		$app_build_dir, @T_DIR_RESOURCES
	);

	# Install everything under the build dir's Contents/Resources
	$INSTALL_PREFIX = $app_res;
	_setup_perl_install();

	my $app_mp = File::Spec->catfile(
		$app_build_dir, @T_DIR_MACPORTS
	);

	my $app_perl5 = get_perl_install_prefix();
	my $app_app = get_app_install_prefix();

	# Make directory structure
	for my $dir ($app_build_dir, $app_res) {
		File::Path::make_path( $dir );
	}

	# Copy *contents* of MACPORTS_PREFIX into $app_mp
	# and change ownership to user.
	if( ! -d $app_mp ) {
		File::Path::make_path($app_mp);
		IPC::Cmd::run( command => [
			qw(sudo cp -aR), MACPORTS_PREFIX . "/.", $app_mp
		]) or die;
		IPC::Cmd::run( command => [
			qw(sudo chown -R), "$ENV{USER}:", $app_mp
		]) or die;
	}

	# exec to perl after this refers to macports perl
	unshift @PATH, File::Spec->catfile(
		$app_mp, qw(bin)
	);

	# Make perl refer to perl5.30
	symlink 'perl5.30', File::Spec->catfile(
		$app_mp, qw(bin perl),
	);
	symlink 'prove-5.30', File::Spec->catfile(
		$app_mp, qw(bin prove),
	);

	cmd_setup_cpan_client();
	cmd_install_via_cpanfile();

	IPC::Cmd::run( command => [
		qw(cpanm .),
		qw(--verbose -n --no-man-pages),
		qw(-l), $app_app,
	]) or die;


	my @MP_PERL_INC = do {
		local $ENV{PERL5LIB} = '';
		local $ENV{PERL5OPT} = '';
		local $ENV{PERLLIB} = '';
		# If `env -i` is used to ignore environment, then it needs to
		# be as
		#
		#     env -i \$(which perl)
		#
		# to get the MacPorts Perl without the path.
		split /\n/, `perl -e 'print join "\\n", \@INC; print "\\n"'`
	};

	my $output_perl5lib = join ":", map {
		my $inc_path = $_;
		$inc_path =~ s,^/,,;
		"$app_res/$inc_path"
	} @MP_PERL_INC;

	my $perl_path = File::Spec->catfile( $app_mp, qw(bin perl) );
	my @paths_to_change;
	push @paths_to_change, $perl_path;

	File::Find::find(
		sub { push @paths_to_change, $File::Find::name if -f && $_ =~ /\.bundle$/ },
		$app_perl5 );

	# Recursive processing of _otool_libs is not enough. Do it for all libs
	# because of the way that GObject Introspection loads other libraries
	# using the typelibs.
	#
	# Here .so files are also included because the gdk-pixbuf loaders use
	# the .so suffix.
	File::Find::find(
		sub { push @paths_to_change, $File::Find::name if -f && $_ =~ /\.(dylib|so)$/ },
		File::Spec->catfile($app_mp, 'lib') );

	my %paths_changed;
	for my $change_path (@paths_to_change) {
		next if exists $paths_changed{$change_path};
		$paths_changed{$change_path} = 1;
		_log "Processing libs for $change_path\n";
		my $libs = _otool_libs( $change_path );
		for my $lib (@$libs) {
			next unless index($lib, MACPORTS_PREFIX) == 0;
			my $lib_under_app_mp = File::Spec->catfile(
				$app_mp,
				File::Spec->abs2rel($lib, MACPORTS_PREFIX)
			);
			push @paths_to_change, $lib_under_app_mp;
			my $rel_to_dir = File::Spec->abs2rel(
				$lib_under_app_mp,
				File::Basename::dirname($perl_path)
			);
			IPC::Cmd::run( command => [
				qw(install_name_tool -change),
					$lib,
					"\@executable_path/$rel_to_dir",
					$change_path
			]) or die;
		}
	}


	my @gir_files;
	my $gir_dir_path = File::Spec->catfile($app_mp, 'share/gir-1.0');
	my $typelib_dir_path = File::Spec->catfile($app_mp, 'lib/girepository-1.0');
	File::Find::find(
		sub { push @gir_files, $File::Find::name if -f && $_ =~ /\.gir$/ },
		File::Spec->catfile($app_mp, 'share/gir-1.0') );

	for my $gir_file (@gir_files) {
		local $ENV{HELPER_PREFIX} = MACPORTS_PREFIX;

		system(
			qw(perl -pi -e),
			'if( $_ =~ /shared-library/ ) {
				my $needle = $ENV{HELPER_PREFIX};

				# correct location of gdk_pixbuf dylib
				my $patch_gdk_pixbuf_find = q|shared-library="./gdk-pixbuf/libgdk_pixbuf-2.0.0.dylib"|;
				my $patch_gdk_pixbuf_repl = qq|shared-library="$needle/lib/libgdk_pixbuf-2.0.0.dylib"|;
				$_ =~ s|\Q$patch_gdk_pixbuf_find\E|$patch_gdk_pixbuf_repl|;

				# use @executable_path to find library
				$_ =~ s,\Q$needle/\E,\@executable_path/../,g;
			}',
			$gir_file,
		) == 0 or die;
		my $gir_basename = File::Basename::basename( $gir_file, qw(.gir) );
		my $typelib_name = File::Spec->catfile( $typelib_dir_path, "${gir_basename}.typelib" );

		system(
			qw(g-ir-compiler),
			"--output=$typelib_name",
			$gir_file,
		) == 0 or die;
	}

	print <<EOF;
######
export PERL5LIB="$output_perl5lib";
export PATH="$app_mp/bin:\$PATH";
export GI_TYPELIB_PATH="$app_mp/lib/girepository-1.0";
perl -I $app_perl5/lib/perl5 -Mlocal::lib=--no-create,$app_perl5,$app_app -S prove
######
EOF


	my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
	my $tmp_scrpt_path = File::Spec->catfile(
		$tmpdir, 'main.scpt'
	);
	my $tmp_scrpt_fh = IO::File->new;
	$tmp_scrpt_fh->open( $tmp_scrpt_path, 'w')
		or die "Could not open $tmp_scrpt_path";

	print $tmp_scrpt_fh <<EOSCRIPT;
--- Utils

on joinAList(theList, delim)
	set newString to ""
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delim
	set newString to theList as string
	set AppleScript's text item delimiters to oldDelims
	return newString
end joinAList



--- Get paths

on get_path_to_bundle()
	# use code to get path to bundle
	if (path to me as string) ends with ":" then
		# Running as bundle
		set bundlePath to POSIX path of (path to me as text)
		return bundlePath
	else
		 tell application "Finder"
			set scriptsPath to parent of (path to me)
			set resPath to parent of scriptsPath
			set contentsPath to parent of resPath
			set bundlePath to POSIX path of (parent of contentsPath as text)
		end tell
		return bundlePath
	end if
end get_path_to_bundle

on get_path_to_res()
	return get_path_to_bundle() & "/Contents/Resources"
end get_path_to_res

on get_path_to_macports()
	return get_path_to_res() & "@{[ MACPORTS_PREFIX ]}"
end get_path_to_macports

on get_path_to_perl5()
	return get_path_to_res() & "/perl5"
end get_path_to_perl5

on get_path_to_app()
	return get_path_to_res() & "/app"
end get_path_to_app

--- Shell fragments

on shell_export_path()
	return "export PATH=\\"" ¬
		& get_path_to_app() & "/bin" & ":" ¬
		& get_path_to_macports() & "/bin" & ":" ¬
		& "\$PATH\\";"
end shell_export_path

on shell_export_perl5lib()
	set perl5ListRel to  { ¬
		@{[ join ",  ¬\n", map { qq|"$_"|  }  @MP_PERL_INC ]} }

	set perl5ListAbs to {}

	repeat with i in perl5ListRel
		copy ( get_path_to_res() & i ) to end of perl5ListAbs
	end repeat

	set perl5ListDelim to joinAList(perl5ListAbs, ":")

	return "export PERL5LIB='" & perl5ListDelim & "';"
end shell_export_perl5lib

on shell_export_xdg_data_dirs()
	return "export XDG_DATA_DIRS='" & get_path_to_macports() & "/share';"
end shell_export_xdg_data_dirs

on shell_export_gi_typelib_path()
	return "export GI_TYPELIB_PATH='" & get_path_to_macports() & "/lib/girepository-1.0';"
end shell_export_gi_typelib_path

on shell_setup_gdk_pixbuf()
	set pixbufLoaderPath to "/lib/gdk-pixbuf-2.0/2.10.0"
	-- NOTE The GDK_PIXBUF_MODULE_FILE can be set to be anywhere and not
	-- necessarily stored in the bundle.
	return  ¬
		& "export GDK_PIXBUF_MODULEDIR='"   & get_path_to_macports() & pixbufLoaderPath & "/loaders';" ¬
		& "export GDK_PIXBUF_MODULE_FILE='" & get_path_to_macports() & pixbufLoaderPath & "/loaders.cache';"  ¬
		& "gdk-pixbuf-query-loaders --update-cache;"
end shell_setup_gdk_pixbuf

on shell_perl_command()
	return "perl "  ¬
		& " -I " & get_path_to_perl5() & "/lib/perl5"  ¬
		& " -Mlocal::lib=--no-create," & get_path_to_perl5() & "," & get_path_to_app()  ¬
		& " "
end shell_perl_command

on shell_perl_prove()
	return  shell_perl_command() & " -S prove -v" & " ;"
end shell_perl_prove

on shell_perl_run_app()
	return  shell_perl_command() & " -S app.pl" & " ;"
end shell_perl_run_app

--- Run

on run
	set cmd to ""
	set cmd to shell_export_path() ¬
		& shell_export_perl5lib() ¬
		& shell_export_xdg_data_dirs() ¬
		& shell_export_gi_typelib_path() ¬
		& shell_setup_gdk_pixbuf() ¬
		& shell_perl_run_app()
		-- & shell_perl_prove()

	-- Debug cmd variable
	#do shell script "cat \<\<'EOF'\\n" & cmd & "\\nEOF"
	#do shell script "cat > debug-cmd.sh \<\<'EOF'\\n" & cmd & "\\nEOF"

	-- Run contents of cmd
	do shell script cmd
end run

EOSCRIPT

	my $main_scpt_output_path = File::Spec->catfile( $app_res, qw(Scripts main.scpt) );
	File::Path::make_path( File::Basename::dirname($main_scpt_output_path) );
	IPC::Cmd::run( command => [
		qw(osacompile),
		qw(-o), File::Spec->catfile( $app_res, qw(Scripts main.scpt) ),
		$tmp_scrpt_path
	]) or die;

	my $git_version = _git_version_from_tags();
	my $version_short = $git_version;
	my $version_long = "$app_name $version_short";

	my $plistbuddy = '/usr/libexec/PlistBuddy';
	my $info_plist_path = File::Spec->catfile($app_build_dir, 'Contents/Info.plist');
	system( qw(chmod a+w), $info_plist_path );
	system( $plistbuddy, '-c',
		"Add :NSUIElement integer 1",
		$info_plist_path );
	system( $plistbuddy, '-c',
		"Add :CFBundleIdentifier string @{[ $dmg_data->{plist}{CFBundleIdentifier} ]}",
		$info_plist_path );

	system( $plistbuddy, '-c',
		"Add :CFBundleShortVersionString string $version_short",
		$info_plist_path );
	system( $plistbuddy, '-c',
		"Add :CFBundleVersion string \"$version_long\"",
		$info_plist_path );
	system( $plistbuddy, '-c',
		"Add :NSHumanReadableCopyright string \"@{[ $dmg_data->{plist}{NSHumanReadableCopyright}  ]}\"",
		$info_plist_path );

	system( $plistbuddy, '-c',
		"Set :LSMinimumSystemVersionByArchitecture:x86_64 \"@{[ $dmg_data->{plist}{'LSMinimumSystemVersionByArchitecture_x86_64'} ]}\"",
		$info_plist_path );

	system( qw(plutil -convert xml1), $info_plist_path );
	system( qw(chmod a=r), $info_plist_path );

	# Remove MacPorts data
	IPC::Cmd::run( command => [
		qw(rm -R), "$app_mp/var/macports"
	]) or die;
	# Remove docs
	IPC::Cmd::run( command => [
		qw(rm -Rf),
			"$app_mp/share/doc",
			"$app_mp/share/man",
			"$app_mp/share/info",
			"$app_mp/share/gtk-doc",
			"$app_mp/share/devhelp",
			"$app_mp/share/examples",
	]) or die;

	# Place in directory with (possible) spaces
	IPC::Cmd::run( command => [
		qw(mv), $app_build_dir, $app_build_dir_orig,
	]) or die;
}

sub _build_dmg_get_create_dmg {
	my $cdmg_tool_dir = File::Spec->catfile( get_tool_prefix(), 'create-dmg');
	my $version = 'master';
	my $cdmg_download_url = "https://github.com/create-dmg/create-dmg/archive/refs/heads/$version.zip";
	my $cdmg_zip_path = File::Spec->catfile( $cdmg_tool_dir, 'create-dmg.zip' );

	my $cdmg_top_dir = File::Spec->catfile( $cdmg_tool_dir, 'extract' );
	my $cdmg_exe = File::Spec->catfile($cdmg_top_dir, "create-dmg-$version", 'create-dmg');

	if( !-d $cdmg_tool_dir ) {
		File::Path::make_path( $cdmg_tool_dir );
		IPC::Cmd::run( command => [
			qw(wget),
			qw(-O), $cdmg_zip_path,
			$cdmg_download_url,
		]) or die;
		File::Path::make_path $cdmg_top_dir;
		IPC::Cmd::run( command => [
			qw(unzip),
			$cdmg_zip_path,
			qw(-d), $cdmg_top_dir
		]) or die;
	}

	return $cdmg_exe;
}

sub cmd_build_dmg {
	my $prefix = get_prefix();
	my $data = read_devops_file();
	my $dmg_data = $data->{dist}{ PLATFORM_MACOS_MACPORTS() }{dmg};
	my $app_name = $dmg_data->{'app-name'};

	my $app_build_dir = File::Spec->catfile(
		$prefix, "${app_name}.app"
	);

	my $git_version = _git_version_from_tags();
	my $version_string = $git_version || 'noversion';
	my $volume_name = "$app_name $version_string";

	my $dmg_path = File::Spec->catfile(
		$prefix,
		"${app_name} version $version_string.dmg"
	);

	# call create-dmg
	my $create_dmg = _build_dmg_get_create_dmg;
	IPC::Cmd::run( command => [
		$create_dmg,
		qw(--hdiutil-verbose),
		qw(--sandbox-safe),
		qw(--volname), $volume_name,
		qw(--window-size 550 500),
		qw(--icon-size 48),
		qw(--icon), "${app_name}.app", qw(125 180),
		qw(--hide-extension), "${app_name}.app",
		qw(--app-drop-link 415 180),
		#qw(--disk-image-size 4500),
		$dmg_path,
		$app_build_dir
	]) or die;

	if( _is_github_action() ) {
		print '::set-output name=asset::', $dmg_path,  "\n";
	}
}

main if not caller;
