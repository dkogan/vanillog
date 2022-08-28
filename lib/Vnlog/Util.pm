package Vnlog::Util;

use strict;
use warnings;
use feature ':5.10';
use Carp 'confess';

our $VERSION = 1.00;
use base 'Exporter';
our @EXPORT_OK = qw(get_unbuffered_line parse_options read_and_preparse_input ensure_all_legends_equivalent reconstruct_substituted_command close_nondev_inputs get_key_index longest_leading_trailing_substring fork_and_filter);


# The bulk of these is for the coreutils wrappers such as sort, join, paste and
# so on


use FindBin '$Bin';
use lib "$Bin/lib";
use Vnlog::Parser;
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use Getopt::Long 'GetOptionsFromArray';




# Reads a line from STDIN one byte at a time. This means that as far as the OS
# is concerned we never read() past our line.
sub get_unbuffered_line
{
    my $fd = shift;

    my $line = '';

    while(1)
    {
        my $c = '';
        return undef unless 1 == sysread($fd, $c, 1);

        $line .= $c;
        return $line if $c eq "\n";
    }
}



sub open_file_as_pipe
{
    my ($filename, $input_filter, $unbuffered) = @_;

    if( defined $input_filter && $unbuffered)
    {
        die "Currently I refuse a custom input filter while running without a buffer; because the way I implement unbuffered-ness assumes the default filter";
    }

    if ($filename eq '-')
    {
        # This is required because Debian currently ships an ancient version of
        # mawk that has a bug: if an input file is given on the commandline,
        # -Winteractive is silently ignored. So I explicitly omit the input to
        # make my mawk work properly
        if(!$unbuffered)
        {
            $filename = '/dev/stdin';
        }
    }
    else
    {
        if ( ! -r $filename )
        {
            confess "'$filename' is not readable";
        }
    }

    # This invocation of 'mawk' or cat below is important. I want to read the
    # legend in this perl program from a FILE, and then exec the underlying
    # application, with the inner application using the post-legend
    # file-descriptor. Conceptually this works, BUT the inner application
    # expects to get a filename that it calls open() on, NOT an already-open
    # file-descriptor. I can get an open-able filename from /dev/fd/N, but on
    # Linux this is a plain symlink to the actual file, so the file would be
    # re-opened, and the legend visible again. By using a filtering process
    # (grep here), /dev/fd/N is a pipe, not a file. And opening this pipe DOES
    # start reading the file from the post-legend location

    my $pipe_cmd = $input_filter;
    if(!defined $pipe_cmd)
    {
        # mawk script to strip away comments and trailing whitespace (GNU coreutils
        # join treats trailing whitespace as empty-field data:
        # https://debbugs.gnu.org/32308). This is the pre-filter to the data
        my $mawk_strip_comments = <<'EOF';
        {
            if (havelegend)
            {
                sub("[\t ]*#.*","");     # have legend. Strip all comments
                if (match($0,"[^\t ]"))  # If any non-whitespace remains, print
                {
                    sub("[\t ]+$","");
                    print;
                }
            }
            else
            {
                sub("[\t ]*#[!#].*",""); # strip all ##/#! comments
                if (match($0,"^[\t ]*#[\t ]*$"))  # data-less # is a comment too
                {
                    next
                }
                if (!match($0,"[^\t ]")) # skip if only whitespace remains
                {
                    next
                }

                if (!match($0, "^[\t ]*#")) # Only single # comments are possible
                                            # If we hit something else, barf
                {
                    print "ERROR: Data before legend";
                    exit
                }

                havelegend = 1;          # got a legend. spit it out
                print;
            }
        }
EOF

        my @mawk_cmd = ('mawk');
        push @mawk_cmd, '-Winteractive' if $unbuffered;
        push @mawk_cmd, $mawk_strip_comments;

        $pipe_cmd = \@mawk_cmd;
    }
    return fork_and_filter(@$pipe_cmd)
      if ($filename eq '-' && $unbuffered);
    return fork_and_filter(@$pipe_cmd, $filename);
}

sub fork_and_filter
{
    my @cmd = @_;

    my $fh;
    my $pipe_pid = open($fh, "-|") // confess "Can't fork: $!";

    if (!$pipe_pid)
    {
        # child
        exec @cmd or confess "can't exec program: $!";
    }

    # parent

    # I'm going to be explicitly passing these to an exec, so FD_CLOEXEC
    # must be off
    my $flags = fcntl $fh, F_GETFD, 0;
    fcntl $fh, F_SETFD, ($flags & ~FD_CLOEXEC);
    return $fh;
}
sub pull_key
{
    my ($input) = @_;
    my $filename = $input->{filename};
    my $fh       = $input->{fh};

    my $keys;

    my $parser = Vnlog::Parser->new();
    while (defined ($_ = get_unbuffered_line($fh)))
    {
        if ( !$parser->parse($_) )
        {
            confess "Reading '$filename': Error parsing vnlog line '$_': " . $parser->error();
        }

        $keys = $parser->getKeys();
        if (defined $keys)
        {
            return $keys;
        }
    }

    confess "Error reading '$filename': no legend found!";
}
sub parse_options
{
    my ($_ARGV, $_specs, $num_nondash_options, $usage) = @_;

    my @specs     = @$_specs;
    my @ARGV_copy = @$_ARGV;

    # In my usage, options that take optional arguments (specified as
    # "option:type") must be given as --option=arg and NOT '--option arg'.
    # Getopt::Long doesn't allow this, so I have to do it myself.
    #
    # I find all occurrences in ARGV, I pull them out before parsing, and I put
    # them back afterwards. Since '--option arg' is invalid, I only need to pull
    # out single tokens: multiple-token options aren't valid
    my @optional_arg_opts = grep /:/, @specs;
    my %optional_arg_opts_tokens_removed;
    for my $optional_arg_opt (@optional_arg_opts)
    {
        my ($opt_spec) = split(/:/, $optional_arg_opt);
        # options are specified as a|b|cc|dd. The one-letter options appear as
        # -a, and the longer ones as --cc. I process each indepenently
        my @opts = split(/\|/, $opt_spec);
        for my $opt (@opts)
        {
            if(length($opt) == 1) { $opt = "-$opt";  }
            else                  { $opt = "--$opt"; }
            my $re = '^' . $opt . '(=|$)';
            $re = qr/$re/;
            my @tokens = grep /$re/, @ARGV_copy;
            if (@tokens)
            {
                $optional_arg_opts_tokens_removed{$optional_arg_opt} //= [];
                push @{$optional_arg_opts_tokens_removed{$optional_arg_opt}}, @tokens;
                @ARGV_copy = grep {$_ !~ /$re/} @ARGV_copy;
            }
        }
    }


    my %options;
    my $result;

    my $oldconfig = Getopt::Long::Configure('gnu_getopt');
    eval
    {
        $result =
          GetOptionsFromArray( \@ARGV_copy,
                               \%options,
                               @specs );
    };

    my $err = $@ || !$result;
    if(!$err && !$options{help})
    {
        # Parsing succeeded! I parse all the options I pulled out earlier, and
        # THEN I'm done
        for my $optional_arg_opt ( keys %optional_arg_opts_tokens_removed )
        {
            my $opt = $optional_arg_opts_tokens_removed{$optional_arg_opt};
            eval
            {
                $result =
                  GetOptionsFromArray( $opt,
                                       \%options,
                                       ($optional_arg_opt) );
            };

            $err = $@ || !$result;
            last if $err;

            push @ARGV_copy, @$opt;
        }
    }

    if( $err || $options{help})
    {
        if( $err )
        {
            say "Error parsing options!\n";
        }

        my ($what) = $0 =~ /-(.+?)$/;

        say <<EOF;
vnl-$what is a wrapper around the '$what' tool, so the usage
and options are almost identical. Main difference is that fields are referenced
by name instead of number. Please see the manpages for 'vnl-$what' and
'$what' for more detail
EOF

        if($usage)
        {
            print <<EOF;
Basic usage is:
$usage
EOF
        }

        exit ($err ? 1 : 0);
    }

    if('ARRAY' eq ref $oldconfig)
    {
        # I restore the old config. This feature (returning old configuration)
        # is undocumented in Getopt::Long::Configure, so I try to use it if it
        # returns a correct-looking thing
        Getopt::Long::Configure($oldconfig);
    }

    if(@ARGV_copy < $num_nondash_options)
    {
        confess "Error parsing options: expected at least $num_nondash_options non-dash arguments";
    }

    my @nondash_options = @ARGV_copy[0..($num_nondash_options-1)];
    splice @ARGV_copy, 0, $num_nondash_options;

    push @ARGV_copy, '-' unless @ARGV_copy;
    return (\@ARGV_copy, \%options, \@nondash_options);
}
sub legends_match
{
    my ($l1, $l2) = @_;

    return 0 if scalar(@$l1) != scalar(@$l2);
    for my $i (0..$#$l1)
    {
        return 0 if $l1->[$i] ne $l2->[$i];
    }
    return 1;
}
sub ensure_all_legends_equivalent
{
    my ($inputs) = @_;

    for my $i (1..$#$inputs)
    {
        if (!legends_match($inputs->[0 ]{keys},
                           $inputs->[$i]{keys})) {
            confess("All input legends must match! Instead files '$inputs->[0 ]{filename}' and '$inputs->[$i]{filename}' have keys " .
                "'@{$inputs->[0 ]{keys}}' and '@{$inputs->[$i]{keys}}' respectively");
        }
    }
    return 1;

}
sub read_and_preparse_input
{
    my ($filenames, $input_filter, $unbuffered) = @_;

    my @inputs = map { {filename => $_} } @$filenames;
    for my $input (@inputs)
    {
        $input->{fh}   = open_file_as_pipe($input->{filename}, $input_filter, $unbuffered);
        $input->{keys} = pull_key($input);
    }

    return \@inputs;
}

sub close_nondev_inputs
{
    my ($inputs) = @_;
    for my $input (@$inputs)
    {
        if( $input->{filename} !~ m{^-$             # stdin
                                    |               # or
                                    ^/(?:dev|proc)/ # device
                               }x )
        {
            close $input->{fh};
        }
    }
}


sub get_key_index
{
    my ($input, $key) = @_;

    my $index;

    my $keys = $input->{keys};
    for my $i (0..$#$keys)
    {
        next unless $keys->[$i] eq $key;

        if (defined $index)
        {
            my $key_list = '(' . join(' ', @$keys) . ')';
            confess "File '$input->{filename}' contains requested key '$key' more than once. Available keys: $key_list";
        }
        $index = $i + 1;        # keys are indexed from 1
    }

    if (!defined $index)
    {
        my $key_list = '(' . join(' ', @$keys) . ')';
        confess "File '$input->{filename}' does not contain key '$key'. Available keys: $key_list";
    }

    return $index;
};

sub reconstruct_substituted_command
{
    # reconstruct the command, invoking the internal GNU tool, but replacing the
    # filenames with the opened-and-read-past-the-legend pipe. The field
    # specifiers have already been replaced with their column indices
    my ($inputs, $options, $nondash_options, $specs, $keep_normal_files) = @_;

    my @argv;

    # First I pull in the arguments
    for my $option(keys %$options)
    {
        # vnlog-specific options are not passed on to the inner command
        next if $option =~ /^vnl/;


        my $re_specs_noarg    = qr/^ $option (?: \| [^=:] + )*   $/x;
        my $re_specs_yesarg   = qr/^ $option (?: \| [^=:] + )* =  /x;
        my $re_specs_maybearg = qr/^ $option (?: \| [^=:] + )* :  /x;

        my @specs_noarg    = grep { /$re_specs_noarg/    } @$specs;
        my @specs_yesarg   = grep { /$re_specs_yesarg/   } @$specs;
        my @specs_maybearg = grep { /$re_specs_maybearg/ } @$specs;

        if( scalar(@specs_noarg) + scalar(@specs_yesarg) + scalar(@specs_maybearg) != 1)
        {
            confess "Couldn't uniquely figure out where '$option' came from. This is a bug. Specs: '@$specs'";
        }

        my $dashoption = length($option) == 1 ? "-$option" : "--$option";
        my $push_value = sub
        {
            # This is overly complex, but mostly exists for "vnl-tail
            # --follow=name". This does NOT work as 'vnl-tail --follow name'
            if($_[0] eq '')
            {
                # -x or --xyz
                push @argv, $dashoption;
            }
            elsif($dashoption =~ '^--')
            {
                # --xyz=123
                push @argv, "$dashoption=$_[0]";
            }
            else
            {
                # -x 123
                push @argv, $dashoption;
                push @argv, $_[0];
            }
        };


        if( @specs_noarg )
        {
            push @argv, "$dashoption";
        }
        else
        {
            # required or optional arg. push_value() will omit the arg if the
            # value is ''
            my $value = $options->{$option};
            if( ref $options->{$option} )
            {
                for my $value(@{$options->{$option}})
                {
                    &$push_value($value);
                }
            }
            else
            {
                &$push_value($value);
            }
        }
    }

    push @argv, @$nondash_options;

    # And then I pull in the files
    push @argv,
      map {
          ($keep_normal_files && $_->{filename} !~ m{^-$             # stdin
                                                     |               # or
                                                     ^/(?:dev|proc)/ # device
                                                }x) ?
            $_->{filename} :
            ("/dev/fd/" . fileno $_->{fh})
      } @$inputs;
    return \@argv;
}

sub longest_leading_trailing_substring
{
    # I start out with the full first input string. At best this whole string is
    # the answer. I look through each string in the input, and wittle down the
    # leading/trailing matches
    my $match_leading           = shift;
    my $match_trailing_reversed = scalar reverse $match_leading;

    my @all = @_;
    for my $s (@all)
    {
        # xor difference string. '\0' bytes means "exact match"
        my $diff;

        $diff = $match_leading ^ $s;
        $diff =~ /^\0*/;
        my $NleadingMatches = $+[0];

        $diff = $match_trailing_reversed ^ (scalar reverse $s);
        $diff =~ /^\0*/;
        my $NtrailingMatches = $+[0];

        # I cut down the matching string to keep ONLY the matched bytes
        substr($match_leading,           $NleadingMatches ) = '';
        substr($match_trailing_reversed, $NtrailingMatches) = '';
    }

    # A common special case is that the input files are of the form aaaNNNbbb
    # where NNN are numbers. If the numbers are 0-padded, the set of NNN could
    # be "01", "02", "03". In this case the "0" is a common prefix, so it would
    # not be included in the file labels, which is NOT what you want here: the
    # labels should be "01", "02", ... not "1", "2". Here I handle this case by
    # removing all trailing digits from the common prefix
    $match_leading =~ s/[0-9]$//;
    return ($match_leading, scalar reverse $match_trailing_reversed);
}

1;

=head1 NAME

Vnlog::Util - Various utility functions useful in vnlog parsing

=head1 SYNOPSIS

 use Vnlog::Util 'get_unbuffered_line';

 while(defined ($_ = get_unbuffered_line(*STDIN)))
 {
   print "got line '$_'.";
 }


=head1 DESCRIPTION

This module provides some useful utilities

=over

=item get_unbuffered_line

Reads a line of input from the given pipe, and returns it. Common usage is like

 while(defined ($_ = get_unbuffered_line(*STDIN)))
 { ... }

which is identical to the basic form

 while(<STDIN>)
 { ... }

except C<get_unbuffered_line> reads I<only> the bytes in the line from the OS.
The rest is guaranteed to be available for future reading. This is useful for
tools that bootstrap vnlog processing by reading up-to the legend, and then
C<exec> some other tool to process the rest.

=back

=head1 REPOSITORY

L<https://github.com/dkogan/vnlog>

=head1 AUTHOR

Dima Kogan, C<< <dima@secretsauce.net> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2017 Dima Kogan <dima@secretsauce.net>

This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation; either version 2.1 of the License, or (at your option) any
later version.

=cut
