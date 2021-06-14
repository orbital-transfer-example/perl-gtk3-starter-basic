package App::Example;
# ABSTRACT: An example Gtk3 app

use Mu;
use Gtk3 -init;
use Glib;

=attr app_name

Name of the application.

=cut
lazy app_name => sub { "My Example App" };

=attr main_window

Main application window.

=cut
lazy main_window => sub {
	my ($self) = @_;
	my $w = Gtk3::Window->new;
	$w->set_title( $self->app_name );

	$w->add( $self->clicking_button );
	$self->clicking_button->set_halign('center');
	$self->clicking_button->set_valign('center');

	$w->signal_connect(
		destroy => \&on_application_quit_cb, $self );
	$w->set_default_size( 800, 600 );
	$w;
};

=attr clicking_button

A button for clicking

=cut
lazy clicking_button => sub {
	my ($self) = @_;

	# NOTE Getting icon size out of enum. Look for Gtk3::IconSize overrides
	# in Gtk3.pm
	my $button = Gtk3::Button->new_from_icon_name('input-mouse',
		Glib::Object::Introspection->convert_sv_to_enum( 'Gtk3::IconSize', 'button' )
	);
	$button->set_label("Click here");
	$button->set('always-show-image', Glib::TRUE);
	my $label = "Click here";

	$button->signal_connect(
		clicked => sub {
			$self->_increment_clicking_button_count;
			my $count = $self->clicking_button_count;
			$button->set_label(
				sprintf(
					( $count == 1
						? "You have clicked %d time!"
						: "You have clicked %d times!" ),
					$count )
				);
		}
	);

	$button;
};

=attr clicking_button_count

Count of times the button has been clicked.

=cut
rw clicking_button_count => default => sub { 0 };

# =method _increment_clicking_button_count
#
# [private]
#
# Increments C<clicking_button_count>.
#
# =cut
sub _increment_clicking_button_count {
	my ($self) = @_;
	$self->clicking_button_count( $self->clicking_button_count + 1 );
}

=method main

Starts the application.

=cut
sub main {
	my ($self) = @_;
	$self = __PACKAGE__->new unless ref $self;
	$self->main_window->show_all;
	$self->run;
}

=method run

Starts the L<Gtk3> event loop.

=cut
sub run {
	my ($self) = @_;
	Gtk3::main;
}

=func on_application_quit_cb

Callback that exits the L<Gtk3> event loop.

=cut
sub on_application_quit_cb {
	my ($event, $self) = @_;
	Gtk3::main_quit;
}

1;
