package App::Example;
# ABSTRACT: An example Gtk3 app

use Mu;
use Gtk3 -init;

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

	$w->signal_connect(
		destroy => \&on_application_quit_cb, $self );
	$w->set_default_size( 800, 600 );
	$w;
};

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
