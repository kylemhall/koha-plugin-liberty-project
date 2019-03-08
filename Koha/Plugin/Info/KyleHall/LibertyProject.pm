package Koha::Plugin::Info::KyleHall::LibertyProject;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use Koha::Account::Lines;
use Koha::Account;
use Koha::DateUtils;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Patron;

use Cwd qw(abs_path);
use LWP::UserAgent;
use MARC::Batch;
use MARC::Record;
use Mojo::JSON qw(decode_json);
use URI::Escape qw(uri_unescape);

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Libery Project Plugin',
    author          => 'Kyle M Hall',
    date_authored   => '2009-01-27',
    date_updated    => "1900-01-01",
    minimum_version => '18.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements every available feature '
      . 'of the plugin system and is meant '
      . 'to be documentation and a starting point for writing your own plugins!',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'tool' subroutine means the plugin is capable
## of running a tool. The difference between a tool and a report is
## primarily semantic, but in general any plugin that modifies the
## Koha database should be considered a tool
sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('submitted') ) {
        $self->tool_step1();
    }
    else {
        $self->tool_step2();
    }

}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            foo           => $self->retrieve_data('foo'),
            bar           => $self->retrieve_data('bar'),
            last_upgraded => $self->retrieve_data('last_upgraded'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                foo                  => $cgi->param('foo'),
                bar                  => $cgi->param('bar'),
                last_configured_by   => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;
    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data(
        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;
    return 1;
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool-step1.tt' } );

    $self->output_html( $template->output() );
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $errors = {};

    my $template = $self->get_template( { file => 'tool-step2.tt' } );

    my $marc_file       = $cgi->param('uploadMarcFile');
    my $marc_filename   = $cgi->param('uploadMarcFile');
    my $ebooks_file     = $cgi->param('uploadEbooksFile');
    my $ebooks_filename = $cgi->param('uploadEbooksFile');

    warn "MARC: $marc_file";
    warn "COVES: $ebooks_file";

    my $ebooks_tmpdir = File::Temp::tempdir( CLEANUP => 1 );
    my $marc_tmpdir   = File::Temp::tempdir( CLEANUP => 1 );

    warn "ebooks_tmpdir = $ebooks_tmpdir";

    # Write ebooks zip file to filesystem
    my ( $etfh, $ebooks_tempfile ) =
      File::Temp::tempfile( SUFFIX => '.zip', UNLINK => 1 );
    warn "ebooks_tempfile = $ebooks_tempfile";

    $errors->{'COVERS_NOT_ZIP'} = 1 if ( $ebooks_filename !~ /\.zip$/i );
    $errors->{'NO_WRITE_TEMP'}       = 1 unless ( -w $ebooks_tmpdir );
    $errors->{'EMPTY_UPLOAD_COVERS'} = 1 unless ( length($ebooks_file) > 0 );

    if (%$errors) {
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    while (<$ebooks_file>) {
        print $etfh $_;
    }
    close $etfh;

    # Unzip ebooks zip file
    qx/unzip $ebooks_tempfile -d $ebooks_tmpdir/;
    my $exit_code = $?;
    unless ( $exit_code == 0 ) {
        $errors->{'COVERS_UNZIP_FAIL'} = $ebooks_filename;
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    # Validate PDFs
    opendir( DIR, $ebooks_tmpdir ) or die "Could not open $ebooks_tmpdir\n";
    while ( my $filename = readdir(DIR) ) {
        next unless $filename =~ /\.pdf$/;
        warn "$filename\n";
        my $output = qx|pdftotext $ebooks_tmpdir/$filename /dev/null|;
        if ( $output ) {
            warn "PDF file $filename appears to be corrupted";
            $errors->{'PDF_INVALID'}->{$filename} = $output;
        } else {
            warn "PDF file $filename appears to be cromulent!";
        }
    }
    closedir(DIR);

    # Write MARC file to filesystem
    my ( $mtfh, $marc_tempfile ) =
      File::Temp::tempfile( SUFFIX => '.mrc', UNLINK => 1 );
    warn "marc_tempfile = $marc_tempfile";

    $errors->{'MARC_NOT_MRC'} = 1 if ( $marc_filename !~ /\.mrc$/i );
    $errors->{'NO_WRITE_TEMP'}       = 1 unless ( -w $marc_tmpdir );
    $errors->{'EMPTY_UPLOAD_MARC'}   = 1 unless ( length($marc_file) > 0 );

    if (%$errors) {
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    while (<$marc_file>) {
        print $mtfh $_;
    }
    close $mtfh;
    
    warn "CHECKING MARC: $marc_tempfile";
    my $batch = MARC::Batch->new( 'USMARC', $marc_tempfile );
    while ( my $marc = $batch->next ) {
        warn "TITLE: " .  $marc->subfield(245,"a");
    }

    # No errors!
    $template->param( errors => $errors );
    $self->output_html( $template->output() );
}

1;
