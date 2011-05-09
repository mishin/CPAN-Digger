use strict;
use warnings;

use autodie;
use Encode         ();
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(mkpath);
use File::Temp qw(tempdir);
use JSON qw(from_json);
use Storable qw(dclone);

use Test::More;
use Test::Deep;
use Test::NoWarnings;

# number of tests in the following groups:
# collect,  process,   dancer,    noWarnings 
plan tests => 14 + 2 + 11 + 1;

my $cleanup = !$ENV{KEEP};

my $cpan = tempdir( CLEANUP => $cleanup );
my $dbdir = tempdir( CLEANUP => $cleanup );
my $outdir = tempdir( CLEANUP => $cleanup );
diag "cpan: $cpan";
diag "dbdir: $dbdir";

my $dbfile = "$dbdir/a.db";

use CPAN::Digger::DB;
use DBI;

my $TS = re('\d+'); # don't care about exact timestamps
my $ID = re('\d+'); # don't care about IDs as they are just helpers and they get allocated based on file-order


############################ setup cpan
create_file( "$cpan/authors/id/F/FA/FAKE1/Package-Name-0.02.meta" );
create_file( "$cpan/authors/id/F/FA/FAKE1/Package-Name-0.02.tar.gz" );

copy 't/files/My-Package-1.02.tar.gz', "$cpan/authors/id/F/FA/FAKE1/"  or die $!;
copy 't/files/02whois.xml', "$cpan/authors/00whois.xml" or die $!;
collect();


### check database
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");
my $sth = $dbh->prepare('SELECT * FROM distro ORDER BY name');

my %expected_authors = (
  'AFOXSON' => {
   pauseid   => 'AFOXSON',
   name      => '',
   asciiname => undef,
   email     => undef,
   homepage  => undef
 },
 'KORSHAK' => {
   pauseid   => 'KORSHAK',
   name      => 'Ярослав Коршак',
   email     => 'CENSORED',
   asciiname => undef,
   homepage  => undef
 },
 'SPECTRUM' => {
   pauseid   => 'SPECTRUM',
   name      => 'Черненко Эдуард Павлович',
   email     => 'edwardspec@gmail.com',
   asciiname => 'Edward Chernenko',
   homepage  => 'http://absurdopedia.net/wiki/User:Edward_Chernenko'
 },
 'FAKE1' => {
   pauseid   => 'FAKE1',
   name      => 'גאבור סבו - Gábor Szabó',
   email     => 'gabor@pti.co.il',
   asciiname => 'Gabor Szabo',
   homepage  => 'http://szabgab.com/'
 },
 'YKO' => {
   pauseid   => 'YKO',
   name      => 'Ярослав Коршак',
   email     => 'ykorshak@gmail.com',
   asciiname => 'Yaroslav Korshak',
   homepage  => 'http://korshak.name/'
 },
 'NUFFIN' => {
   pauseid   => 'NUFFIN',
   name      => 'יובל קוג\'מן (Yuval Kogman)',
   email     => 'nothingmuch@woobling.org',
   asciiname => 'Yuval Kogman',
   homepage  => 'http://nothingmuch.woobling.org/'
  },
);


{
  $sth->execute;
  my @data;
  while (my @row = $sth->fetchrow_array) {
  #    diag "@row";
      push @data, \@row;
  }
  #diag explain @data;

  cmp_deeply(\@data, [
    [$ID, 'FAKE1', 'My-Package', '1.02', 'F/FA/FAKE1/My-Package-1.02.tar.gz', $TS, $TS, undef, undef],
    [$ID, 'FAKE1', 'Package-Name', '0.02', 'F/FA/FAKE1/Package-Name-0.02.tar.gz', $TS, $TS, undef, undef],
  ], 'data is ok') or diag explain \@data;

  my $authors = $dbh->selectall_hashref('SELECT * FROM author ORDER BY pauseid', 'pauseid');
  #diag explain $authors;
  cmp_deeply $authors, {
    map {$_ => $expected_authors{$_}} qw(AFOXSON KORSHAK SPECTRUM FAKE1 YKO)
    } , 'authors';
}

my $expected_data = 
         [
            { 
              author => 'FAKE1',
              name => 'My-Package',
              version => '1.02'
            },
            {
              author => 'FAKE1',
              name => 'Package-Name',
              version => '0.02'
            },
          ];
my $expected_data2 = dclone($expected_data);
$expected_data2->[0]{id} = $ID;
$expected_data2->[1]{id} = $ID;

{
    my $db = CPAN::Digger::DB->new(dbfile => $dbfile);
    $db->setup;
    my $data = $db->get_distros_like('Pack');
    my $data2 = $db->get_distros_latest_version('Pack');
    cmp_deeply($data, $expected_data, 'get_distros');
    cmp_deeply($data2, $expected_data2, 'get_distros_latest_version');

    cmp_deeply $db->get_authors('K'), [ map {$expected_authors{$_}} qw(FAKE1 KORSHAK YKO) ], 'authors with K';
    cmp_deeply $db->get_authors('N'), [ map {$expected_authors{$_}} qw(AFOXSON) ], 'authors with N';
    
    my $exp = dclone $expected_data;
    foreach my $i (0..1) {
      $exp->[$i]{id} = $ID;
      $exp->[$i]{file_timestamp} = $TS;
      $exp->[$i]{path} = ignore();
    }
    cmp_deeply($db->get_distros_of('FAKE1'), $exp, 'get_distros_of FAKE1');
    
    cmp_deeply($db->get_distro_latest('Package-Name'), {
      'added_timestamp' => $TS,
      'author'          => 'FAKE1',
      'file_timestamp'  => $TS,
      'id'              => $ID,
      'name' => 'Package-Name',
      'path' => 'F/FA/FAKE1/Package-Name-0.02.tar.gz',
      'version' => '0.02',
    }, 'get_distro_latest');

}
#diag explain $data;


############################# run collect again without any update to CPAN
collect();
{
    my $db = CPAN::Digger::DB->new(dbfile => $dbfile);
    $db->setup;
    my $data = $db->get_distros_like('Pack');
    my $data2 = $db->get_distros_latest_version('Pack');
    cmp_deeply($data, $expected_data, 'get_distros');
    cmp_deeply($data2, $expected_data2, 'get_distros_latest_version');
}


##################################### change cpan
mkpath  "$cpan/authors/id/F/FA/FAKE2/";
copy 't/files/Some-Package-2.00.tar.gz', "$cpan/authors/id/F/FA/FAKE2/";
copy 't/files/Some-Package-2.01.tar.gz', "$cpan/authors/id/F/FA/FAKE2/";
copy 't/files/03whois.xml', "$cpan/authors/00whois.xml" or die $!;

collect();

### check database
my $exp_data =  
         [
            { 
              author => 'FAKE1',
              name => 'My-Package',
              version => '1.02'
            },
            {
              author => 'FAKE1',
              name => 'Package-Name',
              version => '0.02'
            },
            {
              author => 'FAKE2',
              name => 'Some-Package',
              version => '2.00'
            },
            {
              author => 'FAKE2',
              name => 'Some-Package',
              version => '2.01'
            },
            ];
my $exp_data2 = dclone $exp_data;
splice(@$exp_data2, 2,1);
$exp_data2->[0]{id} = $ID;
$exp_data2->[1]{id} = $ID;
$exp_data2->[2]{id} = $ID;

my %expected_authors2 = (
  'NUFFIN' => $expected_authors{'NUFFIN'},
);

{
    my $db = CPAN::Digger::DB->new(dbfile => $dbfile);
    $db->setup;
    my $data = $db->get_distros_like('Pack');
    cmp_deeply($data, $exp_data, 'get_distros');

    my $data2 = $db->get_distros_latest_version('Pack');
    cmp_deeply($data2, $exp_data2, 'get_distros_latest_version');


    my $authors = $dbh->selectall_hashref('SELECT * FROM author ORDER BY pauseid', 'pauseid');
    #diag explain $authors;
    cmp_deeply $authors, \%expected_authors, 'authors';

    cmp_deeply $db->get_authors('N'), [ map {$expected_authors{$_}} qw(AFOXSON NUFFIN) ], 'authors with N';
}


###################################

mkpath  "$cpan/authors/id/S/SP/SPECTRUM/";
copy 't/files/Padre-Plugin-CommandLine-0.02.tar.gz', "$cpan/authors/id/S/SP/SPECTRUM/";
collect();

###################################   process files
process('F/FA/FAKE1/Package-Name-0.02.tar.gz');
my $pathx = 'S/SP/SPECTRUM/Padre-Plugin-CommandLine-0.02.tar.gz'; 
process($pathx);
{
    my $db = CPAN::Digger::DB->new(dbfile => $dbfile);
    $db->setup;
    my $ppc = $db->get_distro_by_path($pathx);
    #diag explain $ppc;
    cmp_deeply $ppc, {
      'added_timestamp'     => $TS,
      'author'              => 'SPECTRUM',
      'file_timestamp'      => $TS,
      'name'                => 'Padre-Plugin-CommandLine',
      'version'             => '0.02',
      'id'                  => $ID,
      'path'                => $pathx,
      'unzip_error'         => ignore(),
      'unzip_error_details' => ignore(),
    }, 'Padre-Plugin-CommandLine';

    my ($cnt) = $dbh->selectrow_array('SELECT COUNT(*) FROM distro_details');
    #diag "Number of distro_detail lines $cnt";
    #diag "ID: $ppc->{id}";
    my $ppc_details = $db->get_distro_details($ppc->{id});
    #diag explain $ppc_details;
    cmp_deeply $ppc_details, {
      has_meta_json   => undef,
      has_meta_yml    => 1,
      has_t           => 1,
      id              => $ID,
      meta_abstract   => undef,
      meta_homepage   => undef,
      meta_repository => undef,
    }, 'Padre-Plugin-CommandLine details';
}


#################################################### Testing Dancer

use CPAN::Digger::WWW;
use Dancer::Test;

response_content_like [GET => '/'], qr{CPAN Digger - digging CPAN packages and Perl code}, "GET /";
response_content_like [GET => '/news'], qr{Development started}, "GET /news";
response_content_like [GET => '/faq'], qr{Frequently asked questions}, "GET /faq";
# TODO: check if the form is there?

# TODO check how we respond to a bad request that we don't send details of the system?!
{
    my $r = dancer_response(GET => '/xyz');
    is $r->{status}, 404, '404 as expected';
}

$ENV{CPAN_DIGGER_DBFILE} = $dbfile;
{
    my $r = dancer_response(GET => '/dist/Package-Name');
    is $r->{status}, 200, 'OK';
    like $r->{content}, qr{Package-Name}, 'Package-Name in /dist/Package-Name';
    like $r->{content}, qr{FAKE1}, 'FAKE1 in /dist/Package-Name';
}
{
    my $r = dancer_response(GET => '/id/FAKE1');
    is $r->{status}, 200, 'OK';
    #diag $r->{content};
    like Encode::encode('utf8', $r->{content}),  qr{$expected_authors{FAKE1}{name}}, 'name is in the content';
}

{
    my $r = dancer_response(GET => '/q/FA/author');
    is $r->{status}, 200, 'OK';
    my $data = from_json($r->{content});
    my $exp = dclone($expected_authors{FAKE1});
    $exp->{type} = 'a';
    $data->{data}[0]{name} = Encode::encode('utf8', $data->{data}[0]{name});
    cmp_deeply($data, {data => [$exp], ellapsed_time => ignore()}, '/q/FA/author');
}

#################################################### end

sub create_file {
    my $file = shift;
    mkpath dirname $file;
    open my $fh, '>', $file;
    print $fh "some text";
    close $fh;
}

sub collect {
    system("$^X -Ilib script/cpan_digger_index.pl --cpan $cpan --dbfile $dbfile --output $outdir --collect --whois");
}

sub process {
    my ($path) = @_;
    system("$^X -Ilib script/cpan_digger_index.pl --cpan $cpan --dbfile $dbfile --output $outdir --distro $path");
}
