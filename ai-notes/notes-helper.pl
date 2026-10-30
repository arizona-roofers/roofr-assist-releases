#!/usr/bin/perl
# Roofr Assist notes helper for macOS (the Windows twin is notes-helper.ps1). Lets Call Coach (a Chrome extension,
# which can't start programs) run an AI CLI on this Mac under the user's OWN account. Chrome starts this directly
# (native messaging host com.arizonaroofers.notes), sends ONE request, reads ONE reply, and the script exits.
#
#   {"type":"ping"}                                             -> {ok, version, backend, cli}
#   {"type":"generate","backend":"agy|claude","model":"..","system":"<doc>","prompt":"<call>"} -> {ok, text, model} | {ok:false, error}
#
# Perl + JSON::PP ship with macOS, so nothing needs installing. Installed by setup.sh into
# ~/Library/Application Support/RoofrAssist/notes-helper, which also records where claude / agy live in config.json:
# Chrome starts helpers with a bare PATH (/usr/bin:/bin:...), so the user's shell PATH isn't available here.
use strict;
use warnings;
use JSON::PP;
use IPC::Open3;
use Symbol qw(gensym);
use File::Temp qw(tempfile);
use FindBin qw($Bin);

my $VERSION = '1.2.0';
my $JSON = JSON::PP->new->utf8->canonical;
binmode STDIN; binmode STDOUT;

sub log_line {
    my ($m) = @_;
    if (open(my $fh, '>>', "$Bin/helper.log")) { my @t = localtime; printf $fh "%04d-%02d-%02dT%02d:%02d:%02d %s\n", $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0], $m; close $fh }
}

# ---- Chrome native messaging framing: 4-byte little-endian length + UTF-8 JSON, both directions ----
sub read_msg {
    my $got = read(STDIN, my $len, 4);
    return undef unless defined $got && $got == 4;
    my $size = unpack('V', $len);
    my $buf = '';
    while (length($buf) < $size) { my $r = read(STDIN, $buf, $size - length($buf), length($buf)); last unless $r }
    return $JSON->decode($buf);
}
sub send_msg {
    my $bytes = $JSON->encode($_[0]);
    print STDOUT pack('V', length($bytes)), $bytes;
    STDOUT->flush;
}

sub config {
    my $p = "$Bin/config.json";
    if (open(my $fh, '<:raw', $p)) { local $/; my $c = eval { $JSON->decode(<$fh>) }; close $fh; return $c if $c }
    return { backend => 'agy' };
}

sub find_cli {
    my ($name, $cfg) = @_;
    return $cfg->{$name} if $cfg->{$name} && -x $cfg->{$name};
    for my $d ("$ENV{HOME}/.local/bin", '/opt/homebrew/bin', '/usr/local/bin', "$ENV{HOME}/.claude/local", split(/:/, $ENV{PATH} // '')) {
        return "$d/$name" if -x "$d/$name";
    }
    return undef;
}

# Run a CLI with the prompt on stdin (UTF-8), no shell, with a timeout.
sub run_cli {
    my ($exe, $args, $stdin, $timeout) = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $exe, @$args);
    binmode $in, ':encoding(UTF-8)'; binmode $out; binmode $err;
    my ($stdout, $stderr) = ('', '');
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        print $in $stdin; close $in;
        { local $/; $stdout = <$out> // ''; $stderr = <$err> // '' }
        waitpid($pid, 0);
        alarm 0;
    };
    if ($@) { kill 'TERM', $pid; die "timed out after ${timeout}s\n" if $@ eq "timeout\n"; die $@ }
    return ($stdout, $stderr, $? >> 8);
}

sub run_claude {
    my ($req, $cfg) = @_;
    my $exe = find_cli('claude', $cfg) or die "Claude Code CLI not found (install it and sign in with your Claude subscription, then run the setup again)\n";
    my ($fh, $sys) = tempfile('ra-note-sys-XXXXXX', TMPDIR => 1, UNLINK => 1);
    binmode $fh, ':encoding(UTF-8)'; print $fh ($req->{system} // ''); close $fh;
    my @args = ('-p', '--model', ($req->{model} || 'claude-sonnet-5-5'), '--system-prompt-file', $sys, '--tools', '',
        '--strict-mcp-config', '--output-format', 'json', '--no-session-persistence');
    my ($out, $errtxt) = run_cli($exe, \@args, $req->{prompt} // '', 240);
    my $j = eval { $JSON->decode($out) } or die "claude gave no readable reply: " . substr($errtxt || $out, 0, 300) . "\n";
    die "claude: " . ($j->{result} // 'error') . "\n" if $j->{is_error};
    return $j->{result} // '';
}

# agy (Antigravity) reads the whole prompt from stdin as one stream-json message and answers in stream-json: no
# argument-length limit, and the reply comes back as data instead of scraped text. (Its old "-p <prompt>" form took
# "--output-format" as the prompt when the prompt went on stdin: every note came back empty, Bronte's Mac 9/30.)
# One model, any agy offers ("agy models"): Gemini, Claude, GPT-OSS. agy has two quota pools (Claude + GPT-OSS, and
# everything else), so when one is used up the note is retried once on a model from the other pool.
# agy's default agent has tools (run a command, read files, browse) and, asked to write a note, sometimes reaches for
# one; headless mode can't ask permission, so the turn ends with no text (Bronte's Mac 9/30: "a tool required the
# command permission"). Notes run as a custom agent with NO tools instead: it can only answer. Auto-approving tools
# (--dangerously-skip-permissions) would let a caller's words steer commands on the CSR's computer. The agent file
# lives next to this script and agy runs from here, so it's found as a project agent.
my $AGENT_MD = join("\n", "---\nname: notes-writer\ndescription: Writes Roofr call notes as plain text from the message it is given. Uses no tools.\nmainAgent: true\nsubagent: false\nexcludeDefaultComponents: true\ntools: []\n---\n# Notes writer\nReply with text only. Never call a tool, run a command, open a file or browse: everything you need is in the message.\n");
sub agy_agent_dir {
    my $dir = "$Bin/.agents/agents/notes-writer";
    my $file = "$dir/agent.md";
    my $have = "";
    if (open(my $in, "<:raw", $file)) { local $/; $have = <$in> // ""; close $in }
    if ($have ne $AGENT_MD) {
        require File::Path; File::Path::make_path($dir);
        open(my $fh, '>:raw', $file) or die "couldn't write the notes agent ($file): $!\n"; print $fh $AGENT_MD; close $fh;
    }
    return $Bin;
}
sub agy_pool { return ($_[0] // '') =~ /claude|gpt-oss/i ? 'other' : 'gemini' }
sub agy_once {
    my ($exe, $model, $prompt) = @_;
    my $msg = JSON::PP->new->canonical->encode({ event => 'user', message => { role => 'user', content => $prompt } }) . "\n";
    chdir(agy_agent_dir()) or die "couldn't open the helper folder: $!\n";
    my @args = ('--agent', 'notes-writer', '--input-format', 'stream-json', '--output-format', 'stream-json', '--print-timeout', '180s', '--disable-slash-commands',
        ($model ? ('--model', $model) : ()));
    my ($out, $errtxt) = run_cli($exe, \@args, $msg, 240);
    my ($res) = grep { $_ && ($_->{event} // '') eq 'result' } map { my $l = $_; eval { $JSON->decode($l) } } grep { /\S/ } split /\n/, $out;
    my $r = $res ? $res->{result} : undef;
    return { text => $r->{response} } if $r && ($r->{status} // '') eq 'SUCCESS' && ($r->{response} // '') =~ /\S/;
    my $why = ($r && $r->{error}) || (split /\n/, ($errtxt // ''))[0] || 'no reply';
    return { error => $why, quota => ($why =~ /QUOTA|RESOURCE_EXHAUSTED|429/i || ($errtxt // '') =~ /QUOTA|RESOURCE_EXHAUSTED|429/i) ? 1 : 0 };
}
sub run_agy {
    my ($req, $cfg) = @_;
    my $exe = find_cli('agy', $cfg) or die "agy (Google Antigravity CLI) not found: run the AI notes setup again\n";
    # agy has no system-prompt flag: the note instructions and the call go in one prompt.
    my $prompt = ($req->{system} // '') . "\n\n=====\n\n" . ($req->{prompt} // '');
    my $model = $req->{model} || $cfg->{model} || '';
    my $spare = $req->{fallbackModel} // (agy_pool($model) eq 'gemini' ? 'claude-sonnet-4-6' : 'gemini-3.8-flash-medium');
    my $r = agy_once($exe, $model, $prompt);
    return ($r->{text}, $model || 'agy default') if defined $r->{text};
    if ($r->{quota} && $spare && agy_pool($spare) ne agy_pool($model)) {
        log_line("agy quota on " . ($model || 'default') . ", trying $spare");
        my $r2 = agy_once($exe, $spare, $prompt);
        return ($r2->{text}, $spare) if defined $r2->{text};
        die "agy quota is used up on both model pools for now; Call Coach keeps its own note\n" if $r2->{quota};
        die "agy ($spare): $r2->{error}; Call Coach keeps its own note\n";
    }
    die "your agy quota is used up for now; Call Coach keeps its own note\n" if $r->{quota};
    die "agy: $r->{error}; Call Coach keeps its own note\n";
}

my $req = eval { read_msg() };
exit 0 unless $req;
my $cfg = config();
my $backend = $req->{backend} || $cfg->{backend} || 'agy';
eval {
    if (($req->{type} // '') eq 'ping') {
        send_msg({ ok => JSON::PP::true, version => $VERSION, backend => $backend, cli => find_cli($backend, $cfg) });
    } elsif (($req->{type} // '') eq 'generate') {
        my $t0 = time;
        my ($text, $used) = $backend eq 'claude' ? (run_claude($req, $cfg), $req->{model}) : $backend eq 'agy' ? run_agy($req, $cfg) : die "unknown backend '$backend'\n";
        log_line(sprintf('generate %s %s ok %ds %d chars', $backend, $used // '', time - $t0, length $text));
        send_msg({ ok => JSON::PP::true, text => $text, backend => $backend, model => $used });
    } else {
        send_msg({ ok => JSON::PP::false, error => "unknown request type '" . ($req->{type} // '') . "'" });
    }
    1;
} or do {
    my $e = $@ || 'unknown error'; chomp $e;
    log_line("error: $e");
    send_msg({ ok => JSON::PP::false, error => $e });
};
