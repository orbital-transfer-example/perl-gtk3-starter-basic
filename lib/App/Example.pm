package App::Example;
# ABSTRACT: An example Gtk3 app

use Mu;
use Gtk3;
use Glib;
use Glib::IO;

our $VERSION = v0.0.1;

use constant APP_ID => q/io.github.orbital-transfer-example.Perl-Gtk3-Starter-Basic/;
use constant DIST_NAME => q/App-Example/;

use Locale::Messages qw(bindtextdomain);
use File::ShareDir;
use File::Spec;
use FindBin;

BEGIN {
	my $share_dir;
	my $locale_data_dir = undef;
	if( $share_dir = eval { File::ShareDir::dist_dir(DIST_NAME) || '' } ) {
		$locale_data_dir = File::Spec->catfile(
			File::Spec->canonpath( $share_dir ),
			"LocaleData"
		);
	} elsif( $share_dir = eval {
			my $dir = File::Spec->catfile($FindBin::Bin, '..', 'share');
			die unless -d $dir;
			$dir;
		} ) {
		$locale_data_dir = File::Spec->catfile(
			$share_dir,
			"LocaleData"
		);
	}
	$locale_data_dir = undef unless -d $locale_data_dir;
	require Locale::TextDomain::UTF8;
	warn "Locale data directory not found.\n" unless $locale_data_dir;
	Locale::TextDomain::UTF8->import(APP_ID, $locale_data_dir);
}

=attr app_name

Name of the application.

=cut
lazy app_name => sub { __"My Example Application" };

=attr app_id

Identifier for application.

=cut
lazy app_id => sub { APP_ID };

=attr application

The GtkApplication instance.

=cut
lazy application => sub {
	my ($self) = @_;
	Gtk3::Application->new(
		$self->app_id,
		q/G_APPLICATION_FLAGS_NONE/
	);
};

=attr main_window

Main application window.

=cut
lazy main_window => sub {
	my ($self) = @_;
	my $w = Gtk3::ApplicationWindow->new( $self->application );
	$w->set_title( $self->app_name );

	$w->add( $self->clicking_button );
	$self->clicking_button->set_halign(q/center/);
	$self->clicking_button->set_valign(q/center/);

	$w->signal_connect(
		delete_event => sub { $self->application->quit },
	);
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
	my $button = Gtk3::Button->new_from_icon_name(q/input-mouse/,
		Glib::Object::Introspection->convert_sv_to_enum( q{Gtk3::IconSize}, q/button/ )
	);
	$button->set_label(__"Click here");
	$button->set(q/always-show-image/, Glib::TRUE);

	$button->signal_connect(
		clicked => sub {
			$self->_increment_clicking_button_count;
			my $count = $self->clicking_button_count;
			$button->set_label(
				__nx(
					"You have clicked {count} time!",
					"You have clicked {count} times!",
					$count,
					count => $count,
				)
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

sub BUILD {
	my ($self, $args) = @_;
	Glib::set_application_name( $self->app_name );
	$self->application->signal_connect(
		activate => sub {
			$self->main_window->show_all;
		},
	);
	$self->application->signal_connect(
		shutdown => \&on_application_shutdown_cb,
	);
}

=method main

Starts the application.

=cut
sub main {
	my ($self) = @_;
	$self = __PACKAGE__->new unless ref $self;
	$self->run;
}

=method run

Starts the L<Gtk3> event loop.

=cut
sub run {
	my ($self) = @_;
	$self->application->run(\@ARGV);
}

=func on_application_shutdown_cb

Callback that exits the L<Gtk3> event loop.

=cut
sub on_application_shutdown_cb {
	my ($event, $self) = @_;
	# clean up code here
}

1;
