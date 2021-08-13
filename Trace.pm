# -*- perl -*-

package Devel::Trace;
use strict; use warnings;
our $VERSION = '0.13';
our ($TRACE,$FORMAT,@ORDER,$FH);
use Data::Dump;
BEGIN {
    # these might have been set elsewhere already
    $TRACE   = 1              unless defined $TRACE; # trace state (on/off)
    $FORMAT  = ">> %s:%d: %s" unless $FORMAT;        # trace output format
    @ORDER   = (1,2,-1)       unless @ORDER;         # caller() ordering
    $FH;                                                # output filehandle
}
#CHECK {
#    print "FORMAT: $FORMAT\n";
#}
unless ($FH) {
    # dup STDERR on startup, since it may change later (rt id 113090)
    # XXX should we localize *STDERR ?
    open $FH, '>&', *STDERR;
    my $oldfh = select($FH); $| = 1; select($oldfh);
}

our %PKG;          # hash holding traced packages
our $simple;       # use old, quick implementation

# This is the important part.  The rest is just fluff.
no warnings 'redefine';
sub DB::DB {
  no strict 'refs';
  return unless $TRACE;
  my ($p, $f, $l) = caller;
  my $code = \@{"::_<$f"};
  my $line = $code->[$l];
  if ($simple) {
    print STDERR ">> $f:$l: $line";
    return;
  }
# End of important part. Begin of fluff.

  my @caller = ($p, $f, $l, ('') x 7);
  my $from;
  if (my @c = caller(1)) {
    @caller[3..10] = @c[3..10];
    $from = [ @c[0..3] ]; # calling package,file,line,called sub
  }

  # if we have some tracing specs, figure out what to do.
  if (%PKG) {
    my $p = $caller[0];
    my $pkg = $PKG{$p}; # current package being traced
    if ($from) {        # unset if no caller (in package main) (XXX eval)?
        my $callpack = $from->[0];
        my $follow = $PKG{$callpack}->{follow}; # what the caller allows
        if ($follow) {         # if the caller allows codepath in general
            if (ref $follow) { # return if the caller doesn't allow tracing
                return if ! $follow->{$from->[2]}  # for this line or
                      and ! $follow->{$from->[3]}; # this subroutine
            }
            # we are generally allowed being traced, so...
            for(qw(trace follow)) {  # mark us as tracing, and allow trace
                $pkg->{$_} = 1 if ! $pkg->{$_}; # unless own ideas present
            }
        }
    }
    # if we're not allowd to be traced at all, return
    return if ! $pkg or (ref $pkg eq 'HASH'  and ! $pkg->{trace});
    # return if the current line or sub isn't allowed to be traced
    if (ref $pkg->{lines} and ref $pkg->{lines} eq 'HASH') {
        return if ! ${$pkg->{lines}}{$caller[2]}  # traceable line
              and ! ${$pkg->{lines}}{$caller[3]}; # traceable subroutine
    }
  }

  push @caller, $from, [@_], $line;
  if (ref $FORMAT eq 'CODE') {
    print $FH $FORMAT->(@caller[@ORDER]);
  } else {
    printf $FH $FORMAT, @caller[@ORDER];
  }
}

sub import {
  my $package = shift;
  if (grep /^trace$/,@_) {
    my $caller = caller;
    *{$caller . '::trace'} = \&{$package . '::trace'};
  }
  $simple++ if grep /^s$/,@_;
  my @list = grep !/^(?:trace|s)$/,@_;
  $simple = 0 if @list;
  _expand_spec($_) for @list;
}

my %tracearg = ('on' => 1, 'off' => 0);

sub trace {
# warn "trace args = (@_)\n";
  my $arg = $_[0] =~ /^(?:0|1)$/ ? shift : 1;
  $arg = $tracearg{$arg} while exists $tracearg{$arg}; # funny way to say 'if'
  if(@_) {
    _expand_spec($arg, $_) for @_;
    $TRACE = 1 if $arg;
  } else {
    $TRACE = $arg;
  }
}

# takes e.g Foo::Bar=15-364+:1024-5432:foosub:barsub
# and builds a lookup table for the package.
sub _expand_spec {
    my ($trace, $pkg) = @_;
    $pkg = "main=$pkg" if $pkg !~ /=/;
    if ((my @s = split/=/,$pkg) == 2) {
        $PKG{$s[0]}->{lines} = {
            map +($_ => 1),
            map {
              s/\+//g;
              /(\d+)(?:\.\.|-)(\d+)/
              ? ($1 .. $2)
              : $_ =~ /^\d+$/
                ? $_
                : "$s[0]\::$_"
            }
            split/:/,$s[1]
        };
        $PKG{$s[0]}->{follow} = {
            map +($_ => 1),
            map {
              /(\d+)(?:\.\.|-)(\d+)/
              ? ($1 .. $2)
              : $_ =~ /^\d+$/
                ? $_
                : "$s[0]\::$_"
            }
            grep { s/\+//g }
            split/:/,$s[1]
        };
        $PKG{$s[0]}->{trace} = $trace;
    } else {
        $PKG{$pkg}->{trace} = $trace;
    }
#   dd %PKG;
}

1;

=head1 NAME

Devel::Trace - Print out each line before it is executed (like C<sh -x>)

=head1 SYNOPSIS

  perl -d:Trace program # like v0.12
  perl -d:Trace=0.12 program # same, old, fast behavior as of v0.12

  perl -d:Trace=42-314 program # limit trace to lines 42 through 314
  perl -d:Trace=Foo::Bar,main=24-42:512-1024:foosub:barsub program

=head1 DESCRIPTION

If you run your program with C<perl -d:Trace program>, this module
will print a message to standard error just before each line is executed.  
For example, if your program looks like this:

        #!/usr/bin/perl
        # file test
        
        print "Statement 1 at line 4\n";
        print "Statement 2 at line 5\n";
        print "Call to sub x returns ", &x(), " at line 6.\n";
        
        exit 0;
        
        
        sub x {
          print "In sub x at line 12.\n";
          return 13;
        }

Then  the C<Trace> output will look like this:

        >> ./test:4: print "Statement 1 at line 4\n";
        >> ./test:5: print "Statement 2 at line 5\n";
        >> ./test:6: print "Call to sub x returns ", &x(), " at line 6.\n";
        >> ./test:12:   print "In sub x at line 12.\n";
        >> ./test:13:   return 13;
        >> ./test:8: exit 0;

This is something like the shell's C<-x> option.

=head1 DETAILS

Inside your program, you can enable and disable tracing by doing

    $Devel::Trace::TRACE = 1;   # Enable
    $Devel::Trace::TRACE = 0;   # Disable

or

    Devel::Trace::trace('on');  # Enable
    Devel::Trace::trace('off'); # Disable


C<Devel::Trace> exports the C<trace> function if you ask it to:

    import Devel::Trace 'trace';

Then if you want you just say

    trace 'on';                 # Enable
    trace 'off';                # Disable

=head1 ADVANCED USAGE

=head2 Limiting to Packages, line numbers and/or subroutines

You can limit the trace to namespaces by assigning to C<%Devel::Trace::PKG>:

    $Devel::Trace::PKG{$_} = 1 for @namespaces;

or by adding them to the call to trace:

   trace 'on',  qw( Foo::Bar Net::LDAP ); # Enable
   trace 'off', qw( Foo::Bar main ); # Disable

This works also with imports. Thus,

   perl -d:Trace=Foo::Bar,HTML::Entities foo.pl

will trace only code executed in Foo::Bar and HTML::Entities. To include the
main script, add C<main>. To exlude a package from tracing, set it to 0
(as in the call to C<trace()>):

   perl -d:Trace=Foo::Bar,HTML::Entities=0 foo.pl

If the hash %Devel::Trace::PKG holds keys, but none has a true value,
tracing is globally disabled, even if $Devel::Trace::TRACE is true. Setting
$Devel::Trace::TRACE to a false value also disables tracing globally.

You can limit tracing to line numbers by specifying a colon separated list of
line number, number ranges and subroutines along with the package being traced:

    perl -d:Trace=Getopts::Std=getopts,main=120-150:somesub script.pl

will limit tracing to the subroutine C<getopts> of C<Getopt::Std> and to lines
120 through 250 of the main script.

If you want to trace some line numbers and want to trace all calls from there
into other packages, add a C<+> to the package spec:

    perl -d:Trace=50..100:123-321+

This will trace the main script from lines 50 to 100, from line 123 to 321, and
trace all calls to other packages from within the range 123 to 321.

=head2 Trace Format and Filehandle

You can change the format by assigning a C<printf> compatible format string
to C<$Devel::Trace::FORMAT>. The elements available for each trace line are
the same as given by C<caller EXPR> in list context, with some values added.
The current line traced is the last element, so it has index C<-1>. The element
before the last is a reference to a copy of the current subroutines arguments,
with index C<-2>.

        0        1      2      3      4      ...      -2      -1
   ( $package, $file, $line, $sub, $hasargs, ... [@DB::args], $code )

B<Please stick to this convention, since more elements might be inserted in future releases between the values provided by caller() and those added elements.>

The order by which they are fed into C<printf> is in the array C<@Devel::Trace::ORDER>.

The default format settings are:

=over 4

=item $FORMAT = ">> %s:%d: %s";

=item @ORDER  = (1,2,-1); # file, line, codeline

=back

If you want more control about the output format depending on the arguments,
you can assign a subroutine reference to C<$Devel::Trace::FORMAT> which will
be passed the arguments to C<sprintf> as set up by C<$Devel::Trace::ORDER>.
It is expected to return a string to print, all formatting is up to you.
Caveats as expressed in the C<caller> documentation for C<@DB::args> apply.

The default filehandle for trace messages is STDERR. You can change that by
assigning an open filehandle to C<$Devel::Trace::FH>.

If you want to capture the trace into a string, open a file handle to a scalar reference.

=head2 Example

This example shows all the above tweaks.

   # file Foo.pm
   package Foo;
   sub slt(;$){
       my$t=localtime(shift||time);
       $t
   }
   END { print "bye...\n" }
   1;

   #!/usr/bin/perl
   # file foo.pl
   BEGIN{
     $Devel::Trace::FORMAT = "# line %d %s: %s %s";
     @Devel::Trace::ORDER  = (2,0,3,-1); # line, package, code
     open my $fh, '>', \$foo;
     $Devel::Trace::FH = $fh;
   }
   use Foo;
   print Foo::slt(123456789),"\n";
   print "Hello World!\n";

   END { print "TRACE:\n$foo"; }

Running C<perl -d:Trace=Foo foo.pl> produces the output:

   Thu Nov 29 22:33:09 1973
   Hello World!
   TRACE:
   # line 3 Foo: sub slt(;$){my$t=localtime(shift||time);$t}
   # line 3 Foo: sub slt(;$){my$t=localtime(shift||time);$t}
   bye...

Here line 3 is output twice because it contains two statements.
Note that when capturing the output into a string, the END block ouput
in the Foo package is not included in the $foo variable output, since this
block is executed last, after $foo content has alrready been output and the
filehandle closed.

=head2 Custom debug package

Instead of including the C<Devel::Trace> tweaks into your script as above,
you might want to have a configuring module which fits your taste and needs.

This is one way to do it:

    package yDebug;
    our $file;
    BEGIN {
        # disable tracing while setting things up
        $Devel::Trace::TRACE = 0;
    }
    sub import {
        shift;
        if (@_) {
            $file = shift;
            warn __PACKAGE__.": tracing to '$file'\n";
        }
    }
    UNITCHECK { # why not CHECK? consult the docs...
        $Devel::Trace::FORMAT = \&format;
        @Devel::Trace::ORDER  = (0..12);
        if ($file) {
            open MYFH, '>', $file or die "open '$file': $!";
            $Devel::Trace::FH = *MYFH;
        }
        # enable tracing for package Foo
        $Devel::Trace::PKG{Foo}++;
        # done, enable tracing
        $Devel::Trace::TRACE = 1;
    }
    sub format {
        my ($package, $filename, $line, $subroutine, $hasargs,
            $wantarray, $evaltext, $is_require, $hints, $bitmask,
            $hinthash, $db_args, $codeline) = @_;
        my $ret;
        if ($filename ne $file) {
            $ret = "# file $filename\n";
            $file = $filename;
        }
        if ($package and $package ne $pkg) {
            $ret .= "# package $package\n";
            $pkg = $package;
        }
        if ($subroutine and $sub ne $subroutine) {
            $ret .= "# -> $subroutine (". join(', ',@$db_args).")";
            $ret .= ' called in '.
                    ($wantarray ? 'LIST' :
                        defined $wantarray ? 'SCALAR' : 'VOID'
                    ) . " context\n";
            $sub = $subroutine;
        } else {
            $sub = '';
        }
        $ret .= sprintf "%6s", $line;
        $ret .= " >> $codeline";
        $ret;
    }
    1;

Placing that somewhere in your C<@INC> (via C<PERL5OPTS> or such) lets you say

    perl -d:Trace -MyDebug myscript.pl

and have C<Devel::Trace> do what you want.

=head1 LICENSE

Devel::Trace 0.13 and its source code are hereby placed in the public domain.

=head1 AUTHOR

=begin text

Mark-Jason Dominus (C<mjd-perl-trace@plover.com>), Plover Systems co.

See the C<Devel::Trace.pm> Page at http://www.plover.com/~mjd/perl/Trace
for news and upgrades.  

=end text

=begin man

Mark-Jason Dominus (C<mjd-perl-trace@plover.com>), Plover Systems co.

See the C<Devel::Trace.pm> Page at http://www.plover.com/~mjd/perl/Trace
or CPAN for news and upgrades.  

=end man

=begin html
<p>Mark-Jason Dominus (<a href="mailto:mjd-perl-trace@plover.com"><tt>mjd-perl-trace@plover.com</tt></a>), Plover Systems co.</p>
<p>See <a href="http://www.plover.com/~mjd/perl/Trace/">The <tt>Devel::Trace.pm</tt> Page</a> or <a href="https://metacpan.org/release/Devel-Trace">CPAN</a> for news and upgrades.</p>

=end html

shmem C<shmem@cpan.org>, much appreciated contributions by perigrin.

=head1 MAINTAINER

shmem C<shmem@cpan.org>

=cut
