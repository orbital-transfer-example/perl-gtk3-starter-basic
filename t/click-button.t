#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
	$ENV{'NO_AT_BRIDGE'} = 1; # faster test loading
}

use Test::More tests => 1;

use App::Example;
use Glib 'TRUE';

sub click_button {
	my ($context, $app) = @_;
	note "Clicking button";
	$app->clicking_button->signal_emit( 'clicked' );
	$context->iteration(TRUE);
}

subtest "Click button" => sub {
	my $app = App::Example->new;
	my $context = Glib::MainContext->default;
	$app->application->register;
	$app->application->activate;

	my $label;

	is $app->clicking_button_count, 0, 'Button count starts at 0';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";

	click_button($context, $app );

	is $app->clicking_button_count, 1, 'Incremented count';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";

	click_button($context, $app );

	is $app->clicking_button_count, 2, 'Incremented count';
	$label = $app->clicking_button->get_label;
	note "Label is: $label";
};

done_testing;
