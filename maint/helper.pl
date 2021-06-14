#!/usr/bin/env perl
# PODNAME: helper
# ABSTRACT: helper for build

use strict;
use warnings;

use CPAN::Meta::YAML; # only using for devops.yml
use IPC::Cmd ();
use JSON::PP ();
use File::Spec;
use File::Path ();
use File::Copy ();
use File::Basename ();
use File::Temp ();
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
	'create-dist-tarball' => \&cmd_create_dist_tarball,
	'build-msi' => \&cmd_build_msi,
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
	my $perl5_lib_dir  = File::Spec->catfile( $perl5_dir, qw(lib perl5));
	my $perl5_arch_dir = File::Spec->catfile( $perl5_dir, qw(lib perl5), $Config::Config{archname} );
	my $perl5_bin_dir = File::Spec->catfile( $perl5_dir, 'bin');
	unshift @PATH, $perl5_bin_dir;
	unshift @PERL5LIB, $perl5_lib_dir, $perl5_arch_dir;
	$PERL_LOCAL_LIB_ROOT = $perl5_dir;
	$PERL_MB_OPT = "--install_base $perl5_dir";
	$PERL_MM_OPT = "INSTALL_BASE=$perl5_dir";

	if( _is_msys2_mingw() ) {
		$PERL5OPT="-I@{[ Cwd::getcwd() ]}/maint -MEUMMnosearch";
	}
}

#### Commands

sub cmd_exec {
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
sub cmd_install_native_packages {
	my $packages = get_package_list();
	return unless @$packages;

	IPC::Cmd::run(
		command => [
			@{ $RUN_INSTALL_CMD->{ _get_platform_type() } },
			@$packages,
		]
	) or die;
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

sub _pacman_package_files {
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
			my $file_filter_re = qr/@{[ join "|", @{ $filter->{files} } ]}/;
			FILE: for my $file (keys %package_files_copy) {
				$package_files_copy{$file} = 0 if $file =~ $file_filter_re;
			}
		}
	}
	my @package_files_filtered = grep $package_files_copy{$_}, keys %package_files_copy;

	_log "$package: @{[ scalar @package_files_filtered ]} files to copy / @{[ scalar @$package_files ]} total files\n";

	\@package_files_filtered;
}

sub cmd_build_msi {
	die "Can only build .msi on @{[ PLATFORM_MSYS2_MINGW64 ]}"
		unless _is_msys2_mingw();

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
}

main;
