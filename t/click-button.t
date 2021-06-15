#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 1;

use App::Example;

sub click_button {
	my ($app) = @_;
	note "Clicking button";
	$app->clicking_button->signal_emit( 'clicked' );
	Gtk3::main_iteration_do(0);
}

subtest "Click button" => sub {
	my $app = App::Example->new;
	my $label;

	is $app->clicking_button_count, 0, 'Button count starts at 0';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";

	click_button( $app );

	is $app->clicking_button_count, 1, 'Incremented count';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";

	click_button( $app );

	is $app->clicking_button_count, 2, 'Incremented count';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";
};

done_testing;
