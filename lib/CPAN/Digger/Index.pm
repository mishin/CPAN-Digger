package CPAN::Digger::Index;
use 5.010;
use Moose;

our $VERSION = '0.01';

extends 'CPAN::Digger';

use autodie;
use Cwd                   qw(cwd);
use Capture::Tiny         qw(capture);
use Data::Dumper          qw(Dumper);
use File::Basename        qw(basename dirname);
use File::Copy            qw(copy move);
use File::Path            qw(mkpath);
use File::Spec            ();
use File::Temp            qw(tempdir);
use File::Find::Rule      ();
use JSON                  qw(to_json);
use Parse::CPAN::Authors  ();
use Parse::CPAN::Packages ();
use YAML::Any             ();

use CPAN::Digger::PPI;


#has 'counter'    => (is => 'rw', isa => 'HASH');
has 'counter_distro'    => (is => 'rw', isa => 'Int', default => 0);
has 'dir'    => (is => 'ro', isa => 'ArrayRef');

has 'authors'    => (is => 'rw', isa => 'Parse::CPAN::Authors');


sub index_dirs {
	my $self = shift;

	$ENV{PATH} = '/bin:/usr/bin';
	die Dumper $self->dir;

	return;
}

sub run_index {
	my $self = shift;

	$self->authors( Parse::CPAN::Authors->new( File::Spec->catfile( $self->cpan, 'authors', '01mailrc.txt.gz' )) );
	my $p = Parse::CPAN::Packages->new( File::Spec->catfile( $self->cpan, 'modules', '02packages.details.txt.gz' ));

	$ENV{PATH} = '/bin:/usr/bin';

	my $tt = $self->get_tt;

	my @distributions = $p->distributions;
	foreach my $d (@distributions) {
		$self->process_distro($d);
	}

	my @authors = $self->authors->authors;
	foreach my $author (@authors) {
		my $pauseid = $author->pauseid;
		#LOG("Author: $pauseid");
		my $outdir = _untaint_path( File::Spec->catdir( $self->output, 'id', lc $pauseid) );
		mkpath $outdir;
		my $outfile = File::Spec->catfile($outdir, 'index.html');
		my @packages;
		my $distros = $self->db->distro->find({ author => lc($pauseid) });
		while (my $d = $distros->next) {
			if ($d->{name}) {
				push @packages, {
					name => $d->{name},
				};
			} else {
				WARN("distro name is missing");
			}
		}
		my %data = (
			pauseid   => $pauseid,
			lcpauseid => lc($pauseid),
			name      => $author->name,
			backpan   => join("/", substr($pauseid, 0, 1), substr($pauseid, 0, 2), $pauseid),
			packages  => \@packages,
		);
		$tt->process('author.tt', \%data, $outfile) or die $tt->error;
	}


	return;
}

sub author_info {
	my ($self, $author) = @_;
	return $self->authors->author(uc $author);
}

sub process_distro {
	my ($self, $d) = @_;

	$self->counter_distro($self->counter_distro +1);
	if (not $d->dist) {
		WARN("No dist provided. Skipping " . $d->prefix);
		next;
	}

	if (my $filter = $self->filter) {
		next if $d->dist !~ /$filter/;
	}

	LOG("Working on " . $d->prefix);
	my $path     = dirname $d->prefix;
	my $src      = File::Spec->catfile( $self->cpan, 'authors', 'id', $d->prefix );
	my $src_dir  = File::Spec->catdir( $self->output, 'src' , lc $d->cpanid);
	my $dist_dir = File::Spec->catdir( $self->output, 'dist', $d->dist);

	foreach my $p ($src, $src_dir, $dist_dir) {
		$p = eval {_untaint_path($p)};
		if ($@) {
			chomp $@;
			WARN($@);
			return;
		}
	}

	my %data = (
		name   => $d->dist,
		author => lc $d->cpanid,
	);

	mkpath $dist_dir;
	mkpath $src_dir;
	chdir $src_dir;
	if (not -e File::Spec->catdir($src_dir, $d->distvname)) {
		my $unzip = $self->unzip($d, $src);
		if (not $unzip) {
			#$counter{unzip_failed}++;
			next;
		}
		if ($unzip == 2) {
			#$counter{unzip_without_subdir}++;
			$data{unzip_without_subdir} = 1;
		}
	}
	if (not -e File::Spec->catdir($src_dir, $d->distvname)) {
		WARN("No directory for $src_dir " . $d->distvname);
		#$counter{no_directory}++;
		next;
	}
	

	if (not $d->distvname) {
		WARN("distvname is empty, skipping database update");
		#$counter{distvname_empty}++;
		next;
	}

	chdir $d->distvname;
	
	my $pods = $self->generate_html_from_pod($dist_dir);
	$data{modules} = $pods->{modules};
	if (@{ $pods->{pods} }) {
		$data{pods} = $pods->{pods};
	}

	_generate_outline($dist_dir, $data{modules});

	$data{has_meta} = -e 'META.yml';
	# TODO we need to make sure the data we read from META.yml is correct and
	# someone does not try to fill it with garbage or too much data.
	if ($data{has_meta}) {
		eval {
			my $meta = YAML::Any::LoadFile('META.yml');
			#print Dumper $meta;
			my @fields = qw(license abstract author name requires version);
			foreach my $field (@fields) {
				$data{meta}{$field} = $meta->{$field};
			}
			if ($meta->{resources}) {
				foreach my $field (qw(repository homepage bugtracker license)) {
					$data{meta}{resources}{$field} = $meta->{resources}{$field};
				}
			}
		};
		if ($@) {
			WARN("Exception while reading YAML file: $@");
			#$counter{exception_in_yaml}++;
			$data{exception_in_yaml} = $@;
		}
	}

	if (-d 'xt') {
		$data{xt} = 1;
	}
	if (-d 't') {
		$data{t} = 1;
	}
	if (-f 'test.pl') {
		$data{test_file} = 1;
	}
	my @example_dirs = qw(eg examples);
	foreach my $dir (@example_dirs) {
		if (-d $dir) {
			$data{examples} = $dir;
		}
	}
	my @changes_files = qw(Changes CHANGES ChangeLog);

	LOG("Update DB");
	eval {
		$self->db->distro->update({ name => $d->dist }, \%data , { upsert => 1 });
	};
	if ($@) {
		WARN("Exception in MongoDB: $@");
	}

	my @readme_files = qw('README');

	# additional fields needed for the main page of the distribution
	my $author = $self->author_info($data{author});
	if ($author) {
		$data{author_name} = $author->name;
	} else {
		WARN("Could not find details of '$data{author}'");
	}

	$data{author_name} ||= $data{author};

	my @special_files = sort grep { -e $_ } (qw(META.yml MANIFEST INSTALL Makefile.PL Build.PL), @changes_files, @readme_files);
	$data{prefix} = $d->prefix;
	
	if ($data{meta}{resources}{repository}) {
		my $repo = delete $data{meta}{resources}{repository};
		$data{meta}{resources}{repository}{display} = $repo;
		$repo =~ s{git://(github.com/.*)\.git}{http://$1};
		$data{meta}{resources}{repository}{link} = $repo;
	}

	$data{special_files} = \@special_files;
	$data{distvname} = $d->distvname;
	my $outfile = File::Spec->catfile($dist_dir, 'index.html');
	my $tt = $self->get_tt;
	$tt->process('dist.tt', \%data, $outfile) or die $tt->error;

	return;
}


# starting from current directory
sub generate_html_from_pod {
	my ($self, $dir) = @_;

	my %ret;
	$ret{modules} = $self->_generate_html($dir, '.pm', 'lib');
	$ret{pods}    = $self->_generate_html($dir, '.pod', 'lib');

	return \%ret;
}

sub _generate_outline {
	my ($self, $dir, $files) = @_;

	foreach my $file (@$files) {
		my $outfile = File::Spec->catfile($dir, "$file->{path}.json");
		mkpath dirname $outfile;

		my $ppi = CPAN::Digger::PPI->new(infile => $file->{path});
		my $outline = $ppi->process;
		open my $out, '>', $$outfile;
		print $out to_json($outline);
	}
	return;
}

sub _generate_html {
	my ($self, $dir, $ext, $path) = @_;

	my @files = eval { sort map {_untaint_path($_)} File::Find::Rule->file->name("*$ext")->extras({ untaint => 1})->relative->in($path) };
	# id/K/KA/KAWASAKI/WSST-0.1.1.tar.gz
	# directory (lib/WSST/Templates/perl/lib/WebService/) {company_name} is still tainted at /usr/share/perl/5.10/File/Find.pm line 869.
	if ($@) {
		WARN("Exception in File::Find::Rule: $@");
		return [];
	}
	my @data;
	foreach my $infile (@files) {
		my $module = substr($infile, 0, -1 * length($ext));
		$module =~ s{/}{::}g;
		$infile = File::Spec->catdir($path, $infile);
		my $outfile = File::Spec->catfile($dir, $infile);
		mkpath dirname $outfile;
		
		if ($self->pod) {
			require CPAN::Digger::Pod;
			LOG("POD: $infile -> $outfile");
			my $pod = CPAN::Digger::Pod->new();
			$pod->process($infile, $outfile);
		}
		push @data, {
			path => $infile,
			name => $module,
		};
	}
	return \@data;
}


sub generate_central_files {
	my $self = shift;

	my $tt = $self->get_tt;
	my %map = (
		'index.tt'    => 'index.html',
		'news.tt'     => 'news.html',
		'faq.tt'      => 'faq.html',
		'licenses.tt' => 'licenses.html',
	);

	my $result = $self->db->run_command([
		"distinct" => "distro",
		"key"      => "meta.license",
		"query"    => {}
	]);

	my @licenses;
	foreach my $license ( @{ $result->{values} } ) {
#		print "D: $license\n";
		next if not defined $license or $license =~ /^\s*$/;
		push @licenses, $license;
	}

	my $outdir = _untaint_path($self->output);
	foreach my $infile (keys %map) {
		my $outfile = File::Spec->catfile($outdir, $map{$infile});
		my %data;
		$data{licenses} = \@licenses;
		LOG("Processing $infile to $outfile");
		$tt->process($infile, \%data, $outfile) or die $tt->error;
	}
	
	# just an empty file for now so it won't try to create a list of all the distributions
	open my $fh, '>', File::Spec->catfile($outdir, 'dist', 'index.html');
	close $fh;
	
	return;
}

sub copy_static_files {
	my $self = shift;
	foreach my $file (glob File::Spec->catdir($self->root, 'static', '*')) {
		$file = _untaint_path($file);
		my $output = _untaint_path(File::Spec->catdir($self->output, basename($file)));
		LOG("Copy $file to $output");
		copy $file, $output;
	}
	return;
}



sub WARN {
	LOG("WARN: $_[0]");
}
sub LOG {
	my $msg = shift;
	print "$msg\n";
}

sub unzip {
	my ($self, $d, $src) = @_;

	my @cmd;
	given ($d->prefix) {
		when (qr/\.(tar\.gz|tgz)$/) {
			@cmd = ('tar', 'xzf', "'$src'");
		}
		when (qr/\.tar\.bz2$/) {
			@cmd = ('tar', 'xjf', "'$src'");
		}
		when (qr/\.zip$/) {
			@cmd = ('unzip', "'$src'");
		}
		default{
		}
	}
	if (@cmd) {
		my $cmd = join " ", @cmd;
		#LOG(join " ", @cmd);
		LOG($cmd);

		my $cwd = eval { _untaint_path(cwd()) };
		if ($@) {
			WARN("Could not untaint cwd: '" . cwd() . "'  $@");
			return;
		}
		my $temp = tempdir( CLEANUP => 1 );
		chdir $temp;
		my ($out, $err) = eval { capture { system($cmd) } };
		if ($@) {
			die "$cmd $@";
		}
		if ($err) {
			WARN("Command ($cmd) failed: $err");
			chdir $cwd;
			return;
		}

		# TODO check if this was really successful?
		# TODO check what were the permission bits
		_chmod($temp);

		opendir my($dh), '.';
		my @content = eval { map { _untaint_path($_) } grep {$_ ne '.' and $_ ne '..'} readdir $dh };
		if ($@) {
			WARN("Could not untaint content of directory: $@");
			chdir $cwd;
			return;
		}
		
		#print "CON: @content\n";
		if (@content == 1 and $content[0] eq $d->distvname) {
			# using external mv as File::Copy::move cannot move directory...
			my $cmd_move = "mv " . $d->distvname . " $cwd";
			#LOG("Moving " . $d->distvname . " to $cwd");
			LOG($cmd_move);
			#move $d->distvname, File::Spec->catdir( $cwd, $d->distvname );
			system($cmd_move);
			# TODO: some files open with only read permissions on the main directory.
			# this needs to be reported and I need to correct it on the local unzip setting
			# xw on the directories and w on the files
			chdir $cwd;
			return 1;
		} else {
			my $target_dir = eval { _untaint_path(File::Spec->catdir( $cwd, $d->distvname )) };
			if ($@) {
				WARN("Could not untaint target_directory: $@");
				chdir $cwd;
				return;
			}
			LOG("Need to create $target_dir");
			mkdir $target_dir;
			foreach my $thing (@content) {
				system "mv $thing $target_dir";
			}
			chdir $cwd;
			return 2;
		}
	} else {
		WARN("Does not know how to unzip $src");
	}
	return 0;
}

sub _chmod {
	my $dir = shift;
	opendir my ($dh), $dir;
	my @content = eval { map { _untaint_path($_) } grep {$_ ne '.' and $_ ne '..'} readdir $dh };
	if ($@) {
		WARN("Could not untaint: $@");
	}
	foreach my $thing (@content) {
		my $path = File::Spec->catfile($dir, $thing);
		given ($path) {
			when (-l $_) {
				WARN("Symlink found '$path'");
				unlink $path;
			}
			when (-d $_) {
				chmod 0755, $path;
				_chmod($path);
			}
			when (-f $_) {
				chmod 0644, $path;
			}
			default {
				WARN("Unknown thing '$path'");
			}
		}
	}
	return;
}

sub _untaint_path {
	my $p = shift;
	if ($p =~ m{^([\w/:\\.-]+)$}x) {
		$p = $1;
	} else {
		Carp::confess("Untaint failed for '$p'\n");
	}
	if (index($p, '..') > -1) {
		Carp::confess("Found .. in '$p'\n");
	}
	return $p;
}


1;
