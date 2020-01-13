package Koha::Plugin::Info::KyleHall::LibertyProject;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use C4::Output;
use C4::Biblio qw( AddBiblio );

use MARC::Batch;
use MARC::Record;

use YAML qw( LoadFile DumpFile );

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Liberty Project Plugin',
    author          => 'Kyle M Hall',
    date_authored   => '2009-01-27',
    date_updated    => "1900-01-01",
    minimum_version => '16.05.07.000',
    maximum_version => '16.99.99.999',
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

    my $step = $cgi->param('step') || '1';

    if ( $step eq '1' ) {
        $self->tool_step1();
    } elsif ( $step eq '2' ) {
        $self->tool_step2();
    } elsif ( $step eq '3' ) {
        $self->tool_step3();
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

    my $ebooks_tmpdir = File::Temp::tempdir( TEMPLATE => '/tmp/ebooks_orig_XXXXX', CLEANUP => 0 );
    my $marc_tmpdir   = File::Temp::tempdir( TEMPLATE => '/tmp/marc_orig_XXXXX', CLEANUP => 0 );

    # Write ebooks zip file to filesystem
    my ( $etfh, $ebooks_tempfile ) =
      File::Temp::tempfile( SUFFIX => '.zip', UNLINK => 0 );

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
    my $unzip_output = qx/unzip $ebooks_tempfile -d $ebooks_tmpdir/;
    my $exit_code = $?;
    unless ( $exit_code == 0 ) {
        $errors->{'COVERS_UNZIP_FAIL'} = $ebooks_filename;
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    # Validate PDFs
    my $pdfs = $self->validate_pdfs( { dir => $ebooks_tmpdir, errors => $errors } );

    # Write MARC file to filesystem
    my ( $mtfh, $marc_tempfile ) =
      File::Temp::tempfile( SUFFIX => '.mrc', UNLINK => 1 );

    $errors->{'MARC_NOT_MRC'} = 1 if ( $marc_filename !~ /\.mrc$/i );
    $errors->{'NO_WRITE_TEMP'}     = 1 unless ( -w $marc_tmpdir );
    $errors->{'EMPTY_UPLOAD_MARC'} = 1 unless ( length($marc_file) > 0 );

    if (%$errors) {
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    while (<$marc_file>) {
        print $mtfh $_;
    }
    close $mtfh;

    # Rename to prevent deletion
    my $dir = File::Temp::tempdir( TEMPLATE => '/tmp/marc_dest_XXXXX', CLEANUP => 0 );
    my $new_file = "$dir/$marc_file";
    rename( $marc_tempfile, $new_file );
    $marc_tempfile = $new_file;

    my $records = $self->validate_marc( { file => $marc_tempfile, pdfs => $pdfs } );

    $template->param(
        step      => 2,
        errors    => $errors,
        pdfs      => $pdfs,
        records   => $records,
        marc_file => $marc_tempfile,
        pdfs_dir  => $ebooks_tmpdir,
    );
    $self->output_html( $template->output() );
}

sub tool_step3 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
warn "STEP 3 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";

    my $errors = {};

    my $template = $self->get_template( { file => 'tool-step2.tt' } );

    my $marc_file = $cgi->param('marc_file');
warn "MARC FILE: $marc_file";
    my $pdfs_dir  = $cgi->param('pdfs_dir');
warn "PDF DIR: $pdfs_dir";

    my $new_marc_file = "$pdfs_dir/marc.txt";
    qx{mv $marc_file $new_marc_file};
    $marc_file = $new_marc_file;

    # Validate the PDFs before running the ACS uploader, it deletes the PDF files!
    my $pdfs = $self->validate_pdfs( { dir => $pdfs_dir, errors => $errors } );

    # Write MARC file to filesystem
    if (%$errors) {
        $template->param( errors => $errors );
        $self->output_html( $template->output() );
        exit;
    }

    # Run the ACS importer last, it deletes the PDF and MARC files
    my $unixtime = time();
    my $acsfile = "/tmp/$unixtime.acsfile";
    DumpFile( $acsfile, { PDFS_DIR => $pdfs_dir } );
sleep 2;
warn "ACS FILE CONTENT: " . `cat $acsfile`;
    my $output;
warn "WAITING FOR FILE TO PROCESS";
# print $cgi->header('text/html');
my $thr = threads->create('keepalive_httpd');
    while ( 1 ) {
warn "WAITING...";
#print " ";
        sleep 1;
        my $yaml = LoadFile( $acsfile );
        last if $yaml->{DOCKER_OUTPUT}; 
        $output = $yaml->{DOCKER_OUTPUT};
    }
warn "FINISHED WAITING FOR FILE TO PROCESS";
$thr->kill('KILL')->detach();

    my $records = $self->validate_marc( { file => "$pdfs/uploadedMarcs.001", pdfs => $pdfs } );

    foreach my $record ( @$records ) {
        if ( $record->{pdf}->{is_valid} ) {
            my ( $biblionumber, $biblioitemnumber ) =
              AddBiblio( $record->{marc}, q{} );
            $record->{biblionumber} = $biblionumber;
        }
        else {
            warn "RECORD HAS INVALID PDF, SKIPPING IMPORT OF RECORD";
        }
    }

#    unlink $acsfile;
#    File::Path::remove_tree( $pdfs_dir );

    $template->param(
        step      => 3,
        errors    => $errors,
        pdfs      => $pdfs,
        records   => $records,
    );
#print $template->output();
    $self->output_html( $template->output() );
}

sub validate_marc {
    my ( $self, $args ) = @_;
    my $file = $args->{file}; 
    my $pdfs = $args->{pdfs};

    my $batch = MARC::Batch->new( 'USMARC', $file );
    my @records;
    while ( my $marc = $batch->next ) {
        my $record = { marc => $marc };
        $record->{title} = $marc->subfield( '245', 'a' );
        $record->{isbn}  = $marc->subfield( '020', 'a' );

        my $filename = $record->{isbn} . ".pdf";
        $pdfs->{$filename}->{has_record} = 1;

        $record->{filename} = $filename;
        $record->{pdf}      = $pdfs->{$filename};

        push( @records, $record );
    }

    return \@records;
}

sub validate_pdfs {
    my ( $self, $args ) = @_;
    my $dir    = $args->{dir};
    my $errors = $args->{errors};

    # Validate PDFs
    my $pdfs;
    opendir( DIR, $dir ) or die "Could not open $dir\n";
    while ( my $filename = readdir(DIR) ) {
        next unless $filename;
        next unless $filename =~ /\.pdf$/;

        $pdfs->{$filename}->{filename}   = $filename;
        $pdfs->{$filename}->{has_record} = 0;

        my $output = qx|pdftotext $dir/$filename /dev/null|;
        if ($output) {
            $errors->{'PDF_INVALID'}->{$filename} = $output;
            $pdfs->{$filename}->{is_valid}        = 0;
            $pdfs->{$filename}->{is_valid_error}  = $output;
        }
        else {
            $pdfs->{$filename}->{is_valid} = 1;
        }
    }
    closedir(DIR);

    return $pdfs;
}

# From newer versions of Koha/Plugins/Base.pm
=head2 output_html

    $self->output_html( $data, $status, $extra_options );

Outputs $data setting the right headers for HTML content.

Note: this is a wrapper function for C4::Output::output_with_http_headers

=cut

sub output_html {
    my ( $self, $data, $status, $extra_options ) = @_;
    C4::Output::output_with_http_headers( $self->{cgi}, undef, $data, 'html', $status, $extra_options );
}

use threads;
sub keepalive_httpd{
    $SIG{'KILL'} = sub { threads->exit(); };
    $| = 1;
    do{
        print ".\n";
        sleep 1;
    } while(1);
}

1;
