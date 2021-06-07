#!/usr/bin/env perl
# PODNAME: helper
# ABSTRACT: helper for build

use strict;
use warnings;

use CPAN::Meta::YAML; # only using for devops.yml

my $command_dispatch = {
	'get-packages' => \&cmd_get_packages,
};

sub main {
	my $command = shift @ARGV;

	die "Need command: @{[ keys %$command_dispatch ]}"
		unless $command;

	$command_dispatch->{$command}->();
}

sub _read_file {
	my ($file) = @_;
	open my $fh, "<:encoding(UTF-8)", $file;
	my $contents = do { local $/; <$fh> };
}

sub _is_debian { $^O eq 'linux' && -f '/etc/debian_version' }
sub _is_macos  { $^O eq 'darwin' }
sub _is_msys2_mingw { $^O eq 'MSWin32' && exists $ENV{MSYSTEM} }

sub get_package_list {
	my $yaml = CPAN::Meta::YAML->read_string(_read_file('maint/devops.yml'))
		or die CPAN::Meta::YAML->errstr;
	my $data = $yaml->[0];
	my $packages;
	if ( _is_debian() ) {
		$packages = $data->{native}{debian}{packages} || []
	} elsif( _is_macos() ) {
		$packages = $data->{native}{'macos-homebrew'}{packages} || []
	} elsif( _is_msys2_mingw() ) {
		$packages = $data->{native}{'msys2-mingw64'}{packages} || []
	} else {
		die "Unknown platform";
	}

	$packages;
}

sub cmd_get_packages {
	my $packages = get_package_list();
	print join(' ', @$packages), "\n";
}

main;
