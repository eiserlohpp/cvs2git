#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(cwd);
use Data::Dumper qw(Dumper);
use Date::Format;
use Date::Parse;
use Encode qw(encode decode);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(mkpath);
use File::Spec::Functions qw(rel2abs);
use File::stat qw(stat);
use File::Temp qw(tempfile);
use Getopt::Long;
use IO::File;
use IO::File qw();
use POSIX qw(dup2);

my %authors = (
	'wasi'      => [ 'Thomas Egerer',      'thomas.washeim@gmx.net' ],
);

sub help()
{
	die <<EOF;
Usage: $0 --cvsdir <cvs_dir> --gitdir <git_dir>
          [--maxcommits <max number of commits>]
          [--squashdate <date up to which commits will be squashed>]
          [--finisher <scriptlet>] [--remove-prefix <prefix>]
          [--debug] [--dry-run] [--allow-unknown] [--help]

Convert CVS component in directory cvs-directory and store all commits
in git_directory.

cvs_directory is a working directory holding the component to convert
and must be updated prior to running this script.

git_directory must exist and a 'git init' must have been run. New
commits will be appended to the current branch, so best create a new
empty branch in the general case.

optional parameter maxcommits can be set a positive value to indicate
maximum number of commits to process.

optional parameter squashdate can be set to a date to indicate that all
files committed before that date will be squashed into in big commit.
below is a list known to be understood by squashdate:
	1995:01:24T09:08:17.1823213           ISO-8601
	1995-01-24T09:08:17.1823213
	Wed, 16 Jun 94 07:29:35 CST           Comma and day name are optional
	Thu, 13 Oct 94 10:13:13 -0700
	Wed, 9 Nov 1994 09:50:32 -0500 (EST)  Text in () will be ignored.
	21 dec 17:05                          Will be parsed in the current time zone
	21-dec 17:05
	21/dec 17:05
	21/dec/93 17:05
	1999 10:02:18 "GMT"
	16 Nov 94 22:28:20 PST

the optional parameter finisher specifies a script run in gitdir, after
the conversion process is (almost) finished; it can be used to issue
filters etc; script is given cvsdir, gitdir and number of commits
as command line arguments;

the optional parameter allow-unknown allows for unknown authors (i.e.
those not included in authors hash to not cause this program to fail
but to keep running modifying the commit message a little.

Use --dry-run to see what the script would do (except for retrieval of the
CVS commit log)

the --debug option does print the commands executed on STDOUT

the optional parameter remove-prefix is the prefix to be removed from
path and defaults to '/export/sina/cvs/components/tgz/'

EOF
}

################################################################################
# generate_commit_hash - generate a commit hash from the infos of the file     #
#                        currently processed to identify all files within this #
#                        commit: <epoch>_|||_<commitid>_||_<author>,           #
#                        sounds easier than it is since CVS does not generate  #
#                        commit IDs all the time and if it does collisions are #
#                        quite probable (I've seen them often)                 #
# in:  quite obvious                                                           #
# out: even more                                                               #
################################################################################
sub generate_commit_hash($$$)
{
	my ($epoch, $commitid, $author) = @_;

	# for projects with commits prior to Sep 9 2001, 03:46:40 we must
	# make sure that sorting succeeds when using the epoch value by
	# prepending zeros so it is 10 digits long
	sprintf('%010d', $epoch) . '_|||_' .  $commitid . '_|||_' . $author;
}

################################################################################
# build_env_hash - build environemnt for git to accept author date and mail    #
#                  for a commit                                                #
# in:  date - date to use for author date value                                #
#      author - author to use with commit                                      #
#      mail - mail address of the author                                       #
#      cdate - commit date to use with commit (defaults to date if omited)     #
# out: environemnt string to use with git commit                               #
################################################################################
sub build_env_hash($$$;$)
{
	my ($date, $author, $mail, $cdate) = @_;

	{
		'GIT_AUTHOR_DATE'       => $date,
		'GIT_AUTHOR_NAME'       => $author,
		'GIT_AUTHOR_EMAIL'      => $mail,
		'GIT_COMMITTER_DATE'    => "${\(defined $cdate ? $cdate : $date)}"
	}
}

################################################################################
# populate_commit_hash - looks for a suitable entry in <commits> and inserts   #
#                        the pushes file info contained in <rinfos> into this  #
#                        commits files array; if no entry is found, a new one  #
#                        is generated and <count> is increased.                #
# in:  commits - ref to commits hash                                           #
#      rinfos  - ref to file info hash (will be wiped except for the filename) #
#      count   - ref to number of commits, gets increased for a new one        #
# out: filename                                                                #
################################################################################
sub populate_commit_hash(%$$)
{
	my ($commits, $rinfos, $count) = @_;
	my (@commit_tags, $commit_tag, $epoch, $filename);

	if ($$rinfos->{'curr'}->{'rev'} !~ /^[0-9]+\.[0-9]+$/)
	{
		delete $$rinfos->{'curr'};
		return;
	}

	my $infos = $$rinfos;
	$infos->{'curr'}->{'rev'} = 'dead' if ($infos->{'curr'}->{'state'} eq 'dead');
	$infos->{'curr'}->{'commitid'} = "<unknown>" if (!exists $infos->{'curr'}->{'commitid'});

	$epoch = $infos->{'curr'}->{'epoch'};
	$filename = $infos->{'filename'};

	# CVS commits aren't atomic in means of time (or any other)
	# so we use this heuristic and accept all commits with the
	# same name and commit ID (if any, thank you CVS!) and author
	# within 15 seconds before and after the commit we're 
	# currently processing; if we have a hit we check the commit
	# message to be 100% sure it's really the same commit;
	for my $i (-15 .. 15)
	{
		my $tag = generate_commit_hash($epoch + $i, $infos->{'curr'}->{'commitid'},
									   $infos->{'curr'}->{'author'});

		if (exists $commits->{$tag})
		{
			# compare commit messages
			if ($commits->{$tag}->{'comment'} eq (join("\n", @{$infos->{'curr'}->{'comment'}})))
			{
				$commit_tag = $tag;
				last;
			}
		}
	}

	if (!defined $commit_tag)
	{
		# we need a new kenn^w commit tag
		$commit_tag = generate_commit_hash($epoch, $infos->{'curr'}->{'commitid'},
										   $infos->{'curr'}->{'author'});
	}

	if (!exists $commits->{$commit_tag})
	{
		# TODO remove, it's redundant and for debugging only
		my $date = ctime($epoch);
		chomp $date;
		$commits->{$commit_tag} =
		{
			'comment'  => join("\n", @{$infos->{'curr'}->{'comment'}}),
			'date'     => $date,
		};

		print "\rProcessed commit " . ++$$count;
	}

	my $hash =
	{
		'revision' => $infos->{'curr'}->{'rev'},
		'filename' => $filename,
	};
	$hash->{'binary'} = 1 if $infos->{'binary'};
	unshift @{${$commits->{$commit_tag}}{'files'}}, $hash;

	if ($infos->{'curr'}->{'tags'})
	{
		foreach my $tag (@{$infos->{'curr'}->{'tags'}})
		{
			if (!defined $commits->{'tags'}->{$tag} or
				defined $commits->{'tags'}->{$tag} < $epoch)
			{
				$commits->{'tags'}->{$tag} = $epoch
			}
		}
	}

	# clear up info hash except for the filename
	delete $$rinfos->{'curr'};
	$$rinfos->{'filename'} = $filename;
}

################################################################################
# <helper functions for commit log parser>                                     #
################################################################################
sub START() { return 0; }
sub INITIAL() { return 1; }
sub RCS_FILE() { return 2; }
sub SKIP_TO_TAGS() { return 3; }
sub PROCESS_TAGS() { return 4; }
sub SKIP_TO_REVISION() { return 5; }
sub SKIP_TO_INFOS() { return 6; }
sub SKIP_TO_BRANCH_INFO() { return 7; }
sub BUILD_COMMIT_LOG() { return 8; }
################################################################################
# </helper functions for commit log parser>                                    #
################################################################################

################################################################################
# parse_commit_log - parse the commit log obtained by executing <cmd> (read in #
#                    chunks of 4096 bytes into an internal structure that will #
#                    later on be used to generate git commits from; <prefix>   #
#                    is removed from path strings and unless <allow> is set,   #
#                    unknown authors are complained about; results are stored  #
#                    in $commits ref;                                          #
# in:  cmd           command to execute for cvs log (e.g. a cat command)       #
#      prefix        prefix to remove from cvs path                            #
#      allow         allow unknown authors                                     #
#      debug         1 == debug, 2 == dry-run                                  #
#      commits       hash ref to store results in                              #
# out: number of commits                                                       #
################################################################################
sub parse_commit_log($$$$%)
{
	my ($cmd, $prefix, $allow, $debug, $commits) = @_;
	my ($state, $infos, $tags, $count, $buf, $rest, %unknown_authors);

	$state = START;
	$count = 0;
	select(STDOUT);
	$| = 1;

	$cmd .= " | ";
	open C, $cmd;

	# this let's commit log contents stay within a page of memory;
	# some commit logs I've seen were very large and blew up this
	# little parser
	while (read(C, $buf, 4096) or $rest)
	{
		$buf = "\n" if !defined $buf;
		$buf = ($rest . $buf) if defined $rest;

		while ($buf =~ s/(.*)\n//)
		{
			my $line = $1;

			if ($state == INITIAL or $state == START)
			{
				if ($line =~ /^$/)
				{
					$state = RCS_FILE;
					next;
				}
				elsif ($state == START and $line =~ /^\? /)
				{
					# untracked file, skip it
					next;
				}
				else
				{
					die "Invalid input in state INITIAL: $line\n";
				}
			}
			elsif ($state == RCS_FILE)
			{
				if ($line =~ /RCS file: (.*?),v.*/)
				{
					undef $infos;
					undef $tags;
					$infos->{'filename'} = $1;
					$infos->{'filename'} =~ s|/Attic/|/|;
					if (defined $prefix and 0 == $infos->{'filename'} =~ s/\Q$prefix\E//o)
					{
						die "prefix '$prefix' not found in '$infos->{'filename'}"
					}
					$state = SKIP_TO_TAGS;
					next;
				}
				else
				{
					die "Invalid input in state RCS_FILE: $line\n";
				}
			}
			elsif ($state == SKIP_TO_TAGS)
			{
				$state = PROCESS_TAGS if ($line =~ /^symbolic names:/);
				next;
			}
			elsif ($state == PROCESS_TAGS)
			{
				if ($line =~ /^\t(.+): ([0-9.]+)/)
				{
					my ($tag, $rev) = ($1, $2);
					# ignore branches!
					unshift @{$tags->{$rev}}, $tag if $rev =~ /[0-9]+\.[0-9]+/;
				}
				elsif ($line =~ /^keyword substitution: b/)
				{
					# for now this only handles binary keyword substitution
					$infos->{'binary'} = 1;
				}
				elsif ($line eq ('-' x 28))
				{
					$state = SKIP_TO_REVISION;
				}
				next;
			}
			elsif ($state == SKIP_TO_REVISION)
			{
				if ($line =~ /^revision (\S+)/)
				{
					$infos->{'curr'}->{'rev'} = $1;
					$infos->{'curr'}->{'tags'} = $tags->{$1} if defined $tags->{$1};
					$state = SKIP_TO_INFOS;
				}
				next;
			}
			elsif ($state == SKIP_TO_INFOS)
			{
				if ($line =~ /date: (\S+) (.*?);/)
				{
					$infos->{'curr'}->{'epoch'} = str2time("$1 $2");
				}

				if ($line =~ /author: (.*?);/)
				{
					$unknown_authors{$1} = 1 if (!defined $authors{$1} and !$allow);
					$infos->{'curr'}->{'author'} = $1;
				}

				$infos->{'curr'}->{'state'} = $1 if ($line =~ /state: (.*?);/);
				$infos->{'curr'}->{'commitid'} = $1 if ($line =~ /commitid: (.*?);/);

				$state = SKIP_TO_BRANCH_INFO;
				next;
			}
			elsif ($state == SKIP_TO_BRANCH_INFO)
			{
				if ($line =~ /^branches:  [0-9.]+;/)
				{
					$state = BUILD_COMMIT_LOG;
				}
				else
				{
					# message already belongs to commit message
					push @{$infos->{'curr'}->{'comment'}}, $line;
					$state = BUILD_COMMIT_LOG;
				}

				next;
			}
			elsif ($state == BUILD_COMMIT_LOG)
			{
				if ($line eq ('-' x 28))
				{
					populate_commit_hash($commits, \$infos, \$count);
					$state = SKIP_TO_REVISION;
				}
				elsif($line eq ('=' x 77))
				{
					# last revision for file
					populate_commit_hash($commits, \$infos, \$count);
					$state = INITIAL;

				}
				else
				{
					# part of the commit message
					push @{$infos->{'curr'}->{'comment'}}, $line;
				}
				next;
			}
		}
		$rest = $buf;
	}

	if (!$allow && scalar keys %unknown_authors)
	{
		my @unknown_authors = keys %unknown_authors;
		local $" = ",\n\t";

		die "Unknown authors found:\n\t@unknown_authors,\nPlease fix!";
	}

	close C;
	print "\n";

	select(STDOUT);
	$| = 0;
	$count;
}

################################################################################
# cd - change into directory - dies on failure                                 #
# in:  directory to cd in                                                      #
################################################################################
sub cd($)
{
	chdir $_[0] or die "Failed to change to directory '$_[0]': $!";
}

################################################################################
# do_command - execute command with optional redirection of output into file   #
# in:  command  - command to execute (must be an array ref)                    #
#      debug    - 1 == debug, 2 == dry-run                                     #
#      filename - optional filename to use for STDOUT redirection              #
#      environ  - environment to use with command                              #
# out: 0 on success, 1 otherwise                                               #
################################################################################
sub do_command($;$$$)
{
	my ($cmd, $debug, $filename, $environ) = @_;

	$cmd or die "Invalid commmand parameter";

	if (defined $environ)
	{
		foreach my $name (keys %{$environ})
		{
			$ENV{$name} = $environ->{$name};
		}
	}

	if ($debug)
	{
		print("@{$cmd}" . ($filename ? " -> $filename\n" : "\n"));
		return 0 if 2 == $debug;
	}

	if ($filename)
	{
		my ($file, $pid);

		$file = IO::File->new($filename, 'w') or die "Failed to write to file: $!";
		$pid = fork();

		if (0 == $pid)
		{
			dup2(fileno($file), 1);
			exec (@{$cmd});
			die "cmd failed";
		}
		elsif ($pid > 0)
		{
			waitpid($pid, 0);
			if ($? != 0)
			{
				# TODO catch errors about anon cvs user here!
				#die "Command returned error code $pid\n";
				return 1;
			}
			$file->close;
		}
		else
		{
			die "Fork failed with: $!";
		}
	}
	else
	{
		system(@{$cmd}) == 0 or warn "Failed to run command: $?";
	}

	return 0;
}

################################################################################
# write_file - write given <content> into file                                 #
# in:  file to write to                                                        #
#      contents to write to file                                               #
################################################################################
sub write_file($$)
{
	my ($file, $content) = @_;
	open FILE, ">$file";
	print FILE $content;
	close FILE;
}

################################################################################
# convert_charset - convert charset from latin1 to utf-8                       #
#                   NOTE: had to shorten this sub like this, feels good though #
# in:  string to convert                                                       #
# out: converted string                                                        #
################################################################################
sub convert_charset($)
{
	my $comment = $_[0];
	eval
	{
		# Check if contents is uft8
		decode('utf-8', $_[0], Encode::FB_CROAK);
	};

	$@ ? encode('utf-8', decode('latin1', $comment)) : $comment;
}

################################################################################
# trim_comment - make first commit line for git look good; since git is        #
#                superiour to CVS in many ways a commit line displayed with    #
#                --oneline option should not exceed the 80 chars limit;        #
#                this is essentially what this function does; somehow the      #
#                commits that I've had the honor to convert with it kinda did  #
#                every crap one can possible think of (me included, though I   #
#                have been at least consistent in the crap I did);             #
#                took me quite some time to finally figure out what I had      #
#                planned with every single line in the first place, seemed to  #
#                make sense by the time writing it; note to self: use comments #
#                next time!                                                    #
# in:  possible crappy comment                                                 #
# out: somehow not so crappy headline of the new git commit                    #
################################################################################
sub trim_comment($)
{
	my $comment = $_[0];
	my ($ret, $line);
	$line = 0;

	$comment = convert_charset($comment);
	foreach my $s (split /\n/, $comment)
	{
		my ($words, $len);

		# leading white spaces
		$s =~ s/^\s+//;
		# leading dot-like stuff once, or even twice
		$s =~ s/^[-+_o*]{1,2}\s?(\w|\"|\')/$1/g;

		$words = scalar(my @words = split /\s/, $s);
		$len = $words ? length($words[0]) : 0;

		# we accept it as valid comment iff
		# - it has at least two words, or
		# - the first word is > 9 characters and comment line does not end
		#   with a colon(oscopie)
		if ((2 <= $words or ($len > 9 and $s !~ /:$/)) and !defined $ret)
		{
			($ret = $s) =~ s/^\s//g;
		}
		elsif (defined $ret)
		{
			# indicate that comment continues
			$ret =~ s/\s*$/.../;
			last;
		}
		++$line;
	}

	# fall back to single comment line
	$ret = $comment if !defined $ret;

	# limit lenght of line to 50 chars tops
	if (length($ret) > 50)
	{
	    $ret = substr($ret, 0, 47);
	    # remove any start of a german utf-8 character
	    $ret =~ s/\xC3$//;
		$ret =~ s/\s*$/.../;
	}

	"$ret\n";
}

################################################################################
# cvs2git - perform actual cvs update of the file and redirect it into git     #
#           repository                                                         #
# in:  filename - filename of the CVS file to copy to git                      #
#      revision - revision of the CVS file to use with update                  #
#      gitdir   - git directory to use for file                                #
#      mode     - file mode                                                    #
#      binary   - is this a binary file?                                       #
#      debug    - 1 == debug, 2 == dry-run                                     #
################################################################################
sub cvs2git($$$$$$) {
	my ($filename, $revision, $gitdir, $mode, $binary, $debug) = @_;
	my ($file, $cmd, $ret);

	$file = "$gitdir/$filename";
	print "mkdir ${\(dirname($file))}\n" if $debug;
	mkpath(dirname($file)) if 2 != $debug;

	if (!$binary)
	{
		do
		{
			$ret = do_command(['cvs', 'update', '-p', '-r', $revision, $filename],
							  $debug, $file);
		} while ($ret == 1);
	}
	else
	{
		do
		{
			$ret = do_command(['cvs', 'update', '-r', $revision, $filename],
							  $debug);
		} while ($ret == 1);

		print "cp $filename $file\n" if $debug;
		copy($filename, $file) if 2 != $debug;
	}

	if (defined $mode)
	{
		print "chmod $mode $file\n" if ($debug);

		if (2 > $debug)
		{
			chmod $mode, $file or die "Failed to chmod file '$file': $!";
		}
	}
}

sub create_commits(%$$$$$)
{
	my ($commits, $cvs_dir, $git_dir, $end, $squash_date, $debug) = @_;
	my (%revisions, $total, $i, $count, $start_date, $end_date, $squashed);
	my (undef, $temp_file) = tempfile();

	$squashed = $count = $i = 0;
	$total = scalar keys %{$commits};

	if ($end)
	{
		warn "Processing $end of the $total total commits\n";
		$total = $end
	}
	else
	{
		warn "Processing $total commits\n";
	}

	foreach my $commit (sort keys %{$commits})
	{
		my ($author, $mail, $commit_str, $headline, $comment, $epoch, $date, $env, $login, $do_commit);

		next if $commit eq 'tags';
		die "no files: $commit" if 0 == (scalar @{${$commits->{$commit}}{"files"}});

		$login = (split /\Q_|||_\E/, $commit)[2];
		($author, $mail) = (defined $authors{$login}) ?
				@{$authors{$login}} : ($login, "unknown");
		$author .= " ($login)" unless $author eq $login;

		$epoch = (split /\Q_|||_\E/, $commit, 2)[0];
		$date = ctime($epoch);
		chomp $date;
		$do_commit = $epoch > $squash_date;

		if (!$do_commit)
		{
			warn "Skipping commit ${\(++$i)}/$total\n";
			$start_date = $date if (!defined $start_date);
			$end_date = $date;
			++$squashed;
		}
		else
		{
			warn "Processing commit ${\(++$i)}/$total\n";
			if ($squashed)
			{
				$commit_str = "CVS import: Initial squash-commit\n\n" .
					"This commit squashes $squashed commits starting from\n" .
					"$start_date and ending $end_date\n" .
					"into a single commit to simplify git history.\n\nfiles:\n";
				$squashed = 0;
				$env = build_env_hash($end_date,
									  "Cvs T. Git (cvs2git.pl)",
									  'hakke_007@gmx.de');

				foreach my $filename (sort (keys %revisions))
				{
					my $binary = $commits->{$commit}->{$filename}{'binary'} ? 1 : 0;

					$commit_str .= "\t$filename: revision $revisions{$filename}\n";
					cvs2git($filename, $revisions{$filename}, $git_dir,
							undef, $binary, $debug);
				}
				cd($git_dir);
				do_command(['git', 'add', '.'], $debug);
				print $commit_str;
				write_file($temp_file, $commit_str);
				do_command(['git', 'commit', '-F', "$temp_file"], $debug, $env);
				++$count;
				cd($cvs_dir);
			}
		}

		$comment = $commits->{$commit}->{'comment'};
		$headline = trim_comment($comment);
		$comment = (" " x 4). $comment;
		$comment =~ s/\n/$& . (" " x 4)/eg;

		$commit_str = "$headline\nCVS import: $author" .
					  ", $date\n\noriginal comment:\n$comment\n\nfiles:\n";
		my @git_remove;
		my %commit_str;
		foreach my $file (sort @{${$commits->{$commit}}{"files"}}) {
			my ($revision, $filename, $binary, $prev_revision, $tmp);
			my $file_mode;

			# TODO add tags!
			$revision = ${$file}{'revision'};
			$filename = ${$file}{'filename'};
			$prev_revision = $revisions{$filename};
			$binary = ${$file}{'binary'} ? 1 : 0;

			next if ($revision =~ /\d+\.\d+\.\d+\./);

			if (!defined $prev_revision) {
				if ($revision eq 'dead') {
					# skip file that was initially committed to other branch
					next;
				}

				# new file, push it to git_add and set (prev_)revision(s)
				$commit_str{$filename} = "\t$filename: initial version ($revision)\n";
				my $stat = stat($filename);
				if (defined $stat) {
					$file_mode = $stat->mode & 0777;
				} else {
					# File do not exist (anymore), use some default moode
					$file_mode = 0644;
				}

				$prev_revision = $revisions{$filename} = "1.0";
			} elsif ($revision eq 'dead') {
				if (!defined $commit_str{$filename}) {
					push @git_remove, $filename;
					$commit_str{$filename} = "\t$filename: $prev_revision deleted\n";
				} else {
					do_command(['rm', $filename], $debug);
				}

				# Skip the following cvs add and cvs update operations
				delete $revisions{$filename};
				next;
			} else {
				# update commit string for file update only
				$commit_str{$filename} = "\t$filename: $prev_revision -> $revision\n";
			}

			# update revision for current file
			$revisions{$filename} = $revision;

			if ($do_commit)
			{
				cvs2git($filename, $revision, $git_dir,
						$file_mode, $binary, $debug);
			}
		}

		foreach my $filename (sort (keys %commit_str)) {
			$commit_str .= $commit_str{$filename};
		}

		if ($do_commit) {
			$env = build_env_hash($date, $author, $mail);
			cd($git_dir);
			foreach my $a (@git_remove)
			{
				if ($do_commit)
				{
					do_command(['git', 'rm', '-f', $a], $debug);
				}
			}

			do_command(['git', 'add', '.'], $debug);
			# commit changes
			write_file($temp_file, $commit_str);
			do_command(['git', 'commit', '-F', "$temp_file"], $debug, undef, $env);
			# unlink temporary files
			#unlink "msg", "patch.diff";
			++$count;
		}
		return $count if $end && $i == $end;
		cd($cvs_dir);
	}

	unlink($temp_file);
	return $count;
}

################################################################################
# parse_opts - parse opts and perform various sanity checks, dies on failure   #
# out: option array containing programs options:                               #
#      - cvsdir - CVS directory, must exist and contain a CVS subdir           #
#      - gitdir - git destination directory, will be created if non-existent   #
#      - maxcommits - maximum number of commits (optional)                     #
#      - squashdate - date to which all commits will be squashed (optional)    #
#      - finisher - finisher script to run after completion of conversion is   #
#                   complete e.g. git-filter-branch (optional)                 #
#      - allowunknown - do not abort if unknown authors were found (optional)  #
#      - removeprefix - prefix to cut from files parsed in CVS log (optional)  #
################################################################################
sub parse_opts()
{
	my ($opts, $args);

	eval
	{
		local $SIG{__WARN__} = sub { die "@_"; };

		GetOptions(
				'cvsdir=s'        => \$opts->{'cvsdir'},
				'gitdir=s'        => \$opts->{'gitdir'},
				'maxcommits=i'    => \$opts->{'maxcommits'},
				'squashdate=s'    => \$opts->{'squashdate'},
				'finisher=s'      => \$opts->{'finisher'},
				'allow-unknown'   => \$opts->{'allowunknown'},
				'remove-prefix=s' => \$opts->{'removeprefix'},
				'dry-run'         => \$opts->{'dryrun'},
				'debug'           => \$opts->{'debug'},
				'help'            => \$opts->{'help'})
	};

	chomp ($args = $@) if $@;

	if ($args)
	{
		warn "There were warnings/errors parsing the command line:\n" .
			 "\t$args\n\n";
		help();
	}
	elsif (!defined $opts->{'cvsdir'} or !defined $opts->{'gitdir'})
	{
		warn "cvs- and git-dir are mandatory, please fix!\n\n";
		help();
	}
	elsif (defined $opts->{'finisher'} and not -x $opts->{'finisher'})
	{
		warn "finisher script '$opts->{'finisher'}' is not executable!\n\n";
		help();
	}

	help() if $opts->{'help'};

	$opts->{'cvsdir'} = rel2abs($opts->{'cvsdir'});
	if (! -d $opts->{'cvsdir'} or ! -d "$opts->{'cvsdir'}/CVS")
	{
		die "Source CVS dir $opts->{'cvsdir'} does not exist " .
			"or is not a CVS directory!";
	}

	$opts->{'gitdir'} = rel2abs($opts->{'gitdir'});
	if (! -d $opts->{'gitdir'})
	{
		die "Source CVS dir $opts->{'gitdir'} does not exist!";
	}

	if (0 != system('git', '--git-dir', "$opts->{'gitdir'}/.git", 'rev-parse'))
	{
		cd($opts->{'gitdir'});
		system('git', 'init') and die "unable to create empty git-repo: $!";
	}

	$opts->{'squashdate'} = defined $opts->{'squashdate'} ?
		str2time($opts->{'squashdate'}) : 0;

	if (defined $opts->{'removeprefix'})
	{
		$opts->{'removeprefix'} .= '/' if ($opts->{'removeprefix'} !~ m|/$|);
	}

	if (defined $opts->{'dryrun'})
	{
		$opts->{'debug'} = 2;
		delete $opts->{'dryrun'};
	}
	$opts->{'debug'} = 0 if !defined $opts->{'debug'};

	return %$opts;
}

sub main()
{
	my ($component, %commits, $commits);
	my %opts = parse_opts();

	if ($opts{'cvsdir'} =~ m|/?([^/]+)/*$|)
	{
		$component = $1;
		print "Converting component $component in directory $opts{'cvsdir'}\n";
	}
	$opts{'removeprefix'}.= "$component/" if (defined $component);

	cd($opts{'cvsdir'});
	parse_commit_log('cvs log -r1 2>/dev/null',
					 $opts{'removeprefix'},
					 $opts{'allowunknown'},
					 $opts{'debug'},
					 \%commits);
	#print Data::Dumper->Dump([\%commits], [qw/foo/]);
	#exit;
	$commits = create_commits(\%commits,
							  $opts{'cvsdir'},
							  $opts{'gitdir'},
							  $opts{'maxcommits'},
							  $opts{'squashdate'},
							  $opts{'debug'});

	if ($opts{'finisher'})
	{
		system($opts{'finisher'}, $opts{'cvsdir'},
			   $opts{'gitdir'}, $commits);
	}
}

main();
