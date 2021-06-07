#!/usr/bin/env perl
# PODNAME: app
# ABSTRACT: Perl Gtk3 application

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use App::Example;

sub main {
	App::Example->main;
}

main;
