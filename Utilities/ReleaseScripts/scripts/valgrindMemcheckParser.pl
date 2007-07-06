#!/usr/bin/perl
# $Id: valgrindMemcheckParser.pl,v 1.2 2007/06/13 09:04:20 rahatlou Exp $
# Created: June 2007
# Author: Giovanni Petrucciani, INFN Pisa
#
use strict;
use warnings;
use Data::Dumper;
use CGI;
use Date::Format;
use Getopt::Long;

my $mstart = qr/^==\d+== (\S.*? bytes) in \S+ blocks are (.*?) in loss (record \S+ of \S+)/;
my $mstartuni = qr/^==\d+== ()(\S.*uninitialised.*)()/;
my $mtrace = qr/^==\d+== \s+(?:at|by)\s.*?:\s+(.*?)\s\((.*)\)/;
my $version = "CMSSW_1_5_0_pre3";
my @showstoppers = qq(libFWCoreFramework);

my %presets = (
    'trash' => [ '__static_initialization_and_destruction_0', 'G__exec_statement', 'dlopen\@\@GLIBC_2', '_dl_lookup_symbol_x' ],
    'fwk' => [ qw(EventSetup  ESProd  castor  ROOT  Pool  Reflex  PluginManager  RFIO  xerces  G_) ],
    'tom'  =>  [ qw(EventSetup ESProd castor ROOT Pool Reflex PluginManager RFIO xerces G_ libGraf createES),
                 qw(Streamer python static MessageLogger ServiceRegistry) ],
    'prod' => [ '::produce\(\s*edm::Event\s*&' ],
    'prod1' => [ '::produce\(\s*\w+(?:\s+const)?\s*&\w*\s*\)' ],
);
my $preset_names = join(', ', sort(keys(%presets)));

my @trace = (); my @libs = (); my @presets = (); my @dump_presets = ();
my $help = '';  my $all = ''; my $onecolumn = ''; my $uninitialised = undef;

GetOptions(
        'rel|release|r=s' => \$version,
        'libs|l=s' => \@libs,
        'trace|t=s' => \@trace,
        'stopper|showstopper'=> \@showstoppers,
        'onecolumn|1' => \$onecolumn,
        'all|a' => \$all,
        'preset=s'   => \@presets,
        'dump-preset=s'   => \@dump_presets,
        'uninitialised|u' => \$uninitialised,
        'help|h|?' => \$help);
if ($uninitialised) { $mstart = $mstartuni; print STDERR "Hunting for uninitialised stuff\n"; }
if ($help) {
        print <<_END;
   Usage: valgrindMemcheckParser.pl [ --rel RELEASE ] 
                 [ --libs lib1,lib2,-lib3 ]
                 [ --trace match1,match2,-match3 ]
                 [ --stopper lib1,lib2 ]
                 [ --preset name,name,-name,+name,... ]
                 [ --all ]
                 [ --onecolumn ]
                 logfile [ logfile2 logfile3 ... ]
        
  It will output a XHTML file to standard output.

  If no input file is specified, reads from standard input.

  FILTERS
    --libs: coma-separated list of libs to require in the library stack trace 
            (or to exclude, if prefixed by a "-"). 
            Can be used multiple times. 
            Abbreviation is "-l" 
    --trace: coma-separated list of regexps to match in the stack trace
             (or to exclude, if prefixed by a "-"). 
             Can be used multiple times.
             Abbreviation is "-t" 
    --stopper: coma-separated list of libs to cut the stack trace at;
               libFWCoreFramework.so is in by default.
               set it to "none" to never break stack trace.
               use full library name.
    --preset: use a specified preset filter for exclusion or inclusion.
        filter names are $preset_names
        --preset name : require at least one of the regexps in "name" to match
                        in the stack trace
        --preset +name: requires all the regexp to match the in each stack trace 
                        (not all on the same stack trace element, of course)
        --preset -name: exclude the event if at least one regexp in name matches
                        in the stack trace
        to get the contents of a preset use "--dump-preset name" 

    --all: show all leaks, skipping any filter
             Abbreviation is "-a" 

    Note: you can use PERL regexps in "libs", "trace" 

  HTML & LINKING OPTIONS
    --onecolunm: output things in one column, avoiding the column with the library name,
                 for easier cut-n-paste in savannah
                 an alias is "-1"
    --rel: CMSSW_*, or "nightly" (default: $version) to set LXR links
           aliases are "--release" and "-r"
    --link-files: if set to true (default is false), links to Uppercase identifiers are
                  made using filename search instead of identifier search)
      [NOT IMPLEMENTED]

  HELP
    --help : prints this stuff (also -h, -?)
    --dump-preset name: dumps the content of a preset and exit

_END
    exit;  
}
if (@dump_presets) {
    foreach my $ps (@dump_presets) {
        print "Preset $ps: \n";
        print map("\t * '$_'\n", @{$presets{$ps}});
        print "\n";
    }
    exit;
}

if ($version eq 'nightly') { $version = time2str('%Y-%m-%d',time()); }
@libs = split(/,/, join(',',@libs));
@trace = split(/,/, join(',',@trace));
@presets = split(/,/, join(',',@presets));
@showstoppers= split(/,/, join(',',@showstoppers));
if (grep($_ eq 'none', @showstoppers)) { @showstoppers = (); }
my @trace_in  = map (qr($_), grep ( $_ !~ m/^-/, @trace ));
my @trace_out = map (qr($_), grep ( s/^-//g, @trace ));
my @libs_in   = map (qr($_), grep ( $_ !~ m/^-/, @libs ));
my @libs_out  = map (qr($_), grep ( s/^-//g, @libs ));
my %stopmap = (); foreach (@showstoppers) { $stopmap{$_} = 1; }
my %presets_c = ();
foreach my $ps (keys(%presets)) { $presets_c{$ps} = [ map(qr($_), @{$presets{$ps}}) ] ; }
my @leaks = ();

sub cfilter {   
    my @trace = @{$_->{'trace'}};
    my $rx; 
    foreach $rx (@trace_in ) { return 0 unless ( grep( $_->[0] =~ $rx, @trace) ); }
    foreach $rx (@trace_out) { return 0 if     ( grep( $_->[0] =~ $rx, @trace) ); }
    foreach $rx (@libs_in )  { return 0 unless ( grep( $_->[1] =~ $rx, @trace) ); }
    foreach $rx (@libs_out)  { return 0 if     ( grep( $_->[1] =~ $rx, @trace) ); }
    foreach my $ps (@presets) {
        my ($op, $name) = ($ps =~ m/^([+\-]?)(\S+)/);
        if ($op eq '') {
            my $ok = 0;
            foreach $rx (@{$presets_c{$name}}) {
                if ( grep( $_->[0] =~ $rx, @trace) ) { $ok = 1; last; }
            }
            return 0 unless $ok;
        } elsif ($op eq '-') {
            foreach $rx (@{$presets_c{$name}}) {
                return 0 if     ( grep( $_->[0] =~ $rx, @trace) );
            }
        } elsif ($op eq '+') {
            foreach $rx (@{$presets_c{$name}}) {
                return 0 unless ( grep( $_->[0] =~ $rx, @trace) );
            }
        }
    }
    return 1;
}

sub realsize {
        my ($num) = ($_[0] =~ m/^([0-9,]+)/) or return 0;
        $num =~ s/,//g;
        return eval($num);
}
sub fformat {
        my $func = CGI::escapeHTML($_[0]);
        $func =~ s!(\b[A-Z]\w\w\w\w+)!<a class='obj' href='http://cmslxr.fnal.gov/lxr/ident?v=$version;i=$1'>$1</a>!g;
        $func =~ s!::(\w+)\(!::<a class='func' href='http://cmslxr.fnal.gov/lxr/ident?v=$version;i=$1'>$1</a>(!g;
        return $func;
}

while (<>) {
  if (/$mstart/) {
        my ($size, $status, $record) = ($1, $2, $3);
        #print STDERR "\nLoss size=$size, status=$status\n" if $#leaks < 20;

        my %libs = (); my @trace = ();
        while (<>) {
                my ($func, $lib) = /$mtrace/ or last;
                #$lib =~ s/^in \S+\/((?:lib|plugin)\w+)\.so/$1/ or next;
                $lib =~ s/^in \S+\/((?:lib|plugin)\w+)\.so/$1/; # or $lib = "";
                last if $stopmap{$lib};
                $libs{$lib} = 1; push @trace, [$func, $lib];
                die "I'm not defined" unless (defined($func) and defined($lib));
                #print STDERR "   lib=$lib, func=$func\n"  if $#leaks < 20;
        }

        push @leaks, { 'size'=>$size, 'realsize' => realsize($size), 'status'=>$status, 'record'=>$record, 'libs'=>[keys(%libs)], 'trace'=>\@trace};
  }
}


#print STDERR Dumper(\@leaks);
my @gleaks = ($all ? @leaks : grep ( cfilter($_), @leaks));
my @sleaks = sort {$b->{'realsize'} <=> $a->{'realsize'}} @gleaks ;
my $count = scalar(@sleaks); 
print STDERR "Selected $count leaks of " , scalar(@leaks) , ".\n";
print <<EOF;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" 
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
<head>
        <title>Valgrind MemCheck output</title>
        <link rel='stylesheet' type='text/css' href='valgrindMemcheckParser.css' />
</head>
<body>
        <h1>Valgrind MemCheck output ($count leaks)</h1>

<table width="100\%">
EOF
my $idx = 0;
foreach my $l (@sleaks) {
        my %L = %{$l}; $idx++;
        my $colspan = ($onecolumn ? 1 : 2);
        print "<tr class='header'><th class='header' colspan='$colspan'>Leak $idx: $L{size} $L{status} ($L{record})</th></tr>\n";
        foreach my $sf (@{$L{'trace'}}) {
                print "<tr class='trace'><td class='func'>"  . fformat($sf->[0]) . "</td>";
                print "<td class='lib'>" . $sf->[1]. "</td>" unless $onecolumn;
                print "</tr>\n";
        }
}

my $footer = "Done at " . scalar(localtime());
print <<EOF;
</table>
<p class='footer'>$footer</p>
</body>
</html>
EOF
