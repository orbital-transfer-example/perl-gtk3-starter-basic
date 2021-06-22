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
	$PERL_CPANM_OPT
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

sub get_prefix {
	if( _is_github_action() ) {
		return get_gha_prefix();
	}

	File::Spec->catfile( Cwd::getcwd(), 'build' );
}

sub get_perl_install_prefix {
	File::Spec->catfile(get_prefix(), 'perl5');
}

sub get_tool_prefix {
	File::Spec->catfile( Cwd::getcwd(), '_tool' );
}

sub get_app_install_prefix {
	File::Spec->catfile(get_prefix(), 'app');
}

sub get_msys2_install_prefix {
	# /mingw64 gets installed under $PREFIX/mingw64
	get_prefix();
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

use constant {
	# NOTE using shell
	RUN_INST_CPANM_V_CURL => 'curl https://cpanmin.us | perl - App::cpanminus App::cpm local::lib -n --no-man-pages',
	RUN_INST_CPANM_V_CPAN => 'yes | cpan -T App::cpanminus App::cpm local::lib || true',
};
sub cmd_setup_cpan_client {
	$PERL_CPANM_OPT = "-L @{[ get_perl_install_prefix() ]}";
	if( IPC::Cmd::can_run('curl' ) ) {
		IPC::Cmd::run( command => RUN_INST_CPANM_V_CURL ) or die;
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
	my ($basename, $dirname) = File::Basename::fileparse( get_prefix() );
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
		File::Spec->abs2rel( get_app_install_prefix(), get_prefix() )
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
		qw(-o), File::Spec->catfile( get_prefix(), $exec_info->{par_output_name} ),
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

sub _build_msi_build_wix {
	my $old_cwd = Cwd::getcwd();
	my $prefix = get_prefix();

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

	# Get version from tags + commit
	_install_native_packages([ qw(git) ]); # should have git
	chomp( my $git_version = `git describe --exact-match --tags` );
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
	my $macports_conf_path = File::Spec->catfile( MACPORTS_PREFIX, qw(etc macports macports.conf) );
	my $variants_conf_path = File::Spec->catfile( MACPORTS_PREFIX, qw(etc macports variants.conf) );

	my $data = read_devops_file();
	my $macports_pkg_data = $data->{native}{ PLATFORM_MACOS_MACPORTS() };
	my $macports_dist_data = $data->{dist}{ PLATFORM_MACOS_MACPORTS() };

	my $mp_conf_fh = IO::File->new;
	$mp_conf_fh->open( $macports_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $macports_conf_path";
	my $mp_vari_fh = IO::File->new;
	$mp_vari_fh->open( $variants_conf_path, O_WRONLY|O_APPEND)
		or die "Could not open $variants_conf_path";
	if( exists $macports_dist_data->{macosx_deployment_target} ) {
		die "macosx_deployment_target invalid"
			unless $macports_dist_data->{macosx_deployment_target} =~ /^(10|11).[0-9]+$/;
		print $mp_conf_fh <<EOF
buildfromsource always
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

	system( qw(tail -20), $macports_conf_path, $variants_conf_path );
}

sub _gh_check_for_release {
	my ($tag) = @_;
	return !! IPC::Cmd::run( command => [
		qw(gh release view), $tag
	]);
}

sub cmd_install_macports {
	my $data = read_devops_file();
	my $macports_pkg_data = $data->{native}{ PLATFORM_MACOS_MACPORTS() };
	my $mp_softare_path = File::Spec->catfile( MACPORTS_PREFIX, qw(var macports software) );

	my $release_tag = 'continuous-macports';
	my $release_title = 'Continuous MacPorts builds';

	# Check for auth before anything else:
	#   $ gh auth status

	my $release_exists = _gh_check_for_release( $release_tag );
	my %software_from_assets;
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
			system( qw(curl -LO), $asset_url );
			my $asset_name = (split '/', $asset_url)[-1];

			my ($ok, $err, $full_buf, $stdout_buff, $stderr_buff) = IPC::Cmd::run(
				command => [
					qw(tar  xjf),
						$asset_name,
						qw(-O ./+CONTENTS)
				],
				verbose => 0,
			) or die;
			my $port_name_line = first { /^\@portname\s+/ }
				split /\n/, join "", @$stdout_buff;
			my ($port_name) = $port_name_line =~ /^\@portname\s+(.*)$/;

			my $port_dir = File::Spec->catfile($mp_softare_path, $port_name);
			File::Path::make_path( $port_dir ) if ! -d $port_dir;

			my $source_path = $asset_name;
			my $target_path = File::Spec->catfile( $port_dir, $asset_name );
			File::Copy::move($source_path, $target_path )
				or die "Could not copy: $source_path -> $target_path";
			_log "Moved $source_path -> $target_path\n";
			$software_from_assets{$target_path} = 1;
		}
	}

	# build any assets that need to be built
	IPC::Cmd::run( command => [
		qw( sudo port -N install ),
			@{ $macports_pkg_data->{packages} }
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

	my @new_files = grep { ! exists $software_from_assets{$_} } @files_found;
	use Data::Dumper; print Dumper(\@new_files);

	if( @files_to_upload ) {
		IPC::Cmd::run( command => [
			qw(gh release),
			qw(upload),
			$release_tag,
			@files_to_upload
		]) or die;
	}
}

main if not caller;
