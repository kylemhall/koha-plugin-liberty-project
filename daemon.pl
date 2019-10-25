#!/usr/bin/perl

use Daemon::Easy
  sleep    => 1,
  stopfile => 'stop',
  pidfile  => 'pid',
  callback => 'worker';

use YAML qw( LoadFile DumpFile );
use File::Find::Rule;

=head1 USAGE

./daemon.pl [start stop restart status]

=cut

sub worker {
    my @files = File::Find::Rule->file()->name('*.acsfile')->in('/tmp');

    foreach my $file (@files) {
warn "FOUND FILE: $file";
        my $data = LoadFile($file);
        next if $data->{DOCKER_OUTPUT};
use Data::Dumper;
warn "PROCESSNG: " . Data::Dumper::Dumper( $data );

        my $PDFS_DIR = $data->{PDFS_DIR};
        my $TMP_DIR  = $data->{TMP_DIR};

        my $output = qx{docker run -v $PDFS_DIR:/ORIGIN -v $TMP_DIR:/DESTINATION liberty-uploader};
warn "OUTPUT: $output";
        DumpFile(
            $file,
            {
                PDFS_DIR      => $PDFS_DIR,
                TMP_DIR       => $TMP_DIR,
                DOCKER_OUTPUT => $output
            }
        );
    }

    sleep 1;
}

run();
