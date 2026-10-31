#!/usr/bin/env perl
# Inject terminal/terminal-ui.js into the Terminal SWA over CDP.
#
# The Chrome binary is patched so terminalPrivate.openVmshellProcess(...)
# evaluates localStorage.t instead of spawning a VM shell; this script waits
# for Chrome's remote debugging port, opens chrome-untrusted://terminal/,
# stores the UI there and reloads the page.
#
# Why the polling dance below: a freshly Target.createTarget'd page reports
# about:blank until the navigation commits, and a Runtime.evaluate issued
# before the commit lands in the wrong document (the item never reaches the
# terminal origin) or fails while the browser is still coming up — that was
# the "inject silently missed, terminal window stays white" bug. So we
# (1) retry target lookup/create, (2) wait until the document really is
# chrome-untrusted://terminal/ and finished loading, (3) read the item back
# after storing, (4) verify after the reload that the UI actually mounted,
# re-running the set/reload cycle when it did not. Every step is logged to
# stderr; chromeos-linux-session appends it to terminal-inject.log.
#
# Usage: terminal-inject.pl <path/to/terminal-ui.js>
use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64;
use JSON::PP;
use Encode ();
use Time::HiRes ();

my $ui = shift @ARGV;
$ui = $ENV{ASH_TERMINAL_UI} unless defined $ui && length $ui;
die "usage: terminal-inject.pl <path/to/terminal-ui.js>\n" unless defined $ui && -r $ui;

my $t0 = time;
sub note {
  my $m = shift;
  printf STDERR "+%5.1fs %s\n", Time::HiRes::time() - $t0, $m;
}
sub give_up {
  note("FAILED: $_[0]");
  exit 1;
}

my $mid = 1;

sub rx {
  my ($s, $n) = @_;
  my $b = "";
  # Watchdog: a half-dead socket must not hang the injector forever — the
  # session relaunches it on every restart, and a leaked hang would pile up.
  local $SIG{ALRM} = sub { die "terminal-inject: response timeout\n" };
  while (length($b) < $n) {
    alarm 30;
    my $got = sysread($s, my $c, $n - length($b));
    alarm 0;
    # 0 = EOF (Chrome died/restarted mid-exchange), undef = socket error
    # (ECONNRESET). Without this check $b never grows on a dead connection
    # and the loop spins forever at 100% CPU.
    die "terminal-inject: connection lost (sysread failed or EOF)\n" unless $got;
    $b .= $c;
  }
  alarm 0;
  $b;
}
sub rv {
  my $s = shift; rx($s, 1); my $b = ord(rx($s, 1)); my $l = $b & 127;
  $l = unpack("n", rx($s, 2)) if $l == 126; rx($s, $l);
}
sub ws {
  my ($s, $t) = @_; my $l = length($t);
  my @m = map { int(rand(256)) } 1 .. 4;
  my $h = $l < 126 ? pack("CC", 0x81, 0x80 | $l) : pack("CCn", 0x81, 0xfe, $l);
  syswrite($s, $h . pack("C4", @m) . join("", map { chr(ord(substr($t, $_, 1)) ^ $m[$_ % 4]) } 0 .. $l - 1));
}
sub cdp {
  my ($s, $m, $p, $sid) = @_;
  my $id = $mid++;
  my %c = (id => $id, method => $m, params => ($p // {}));
  $c{sessionId} = $sid if $sid;
  ws($s, encode_json(\%c));
  while (1) {
    my $r = decode_json(rv($s));
    return $r if defined $r->{id} && $r->{id} == $id;
  }
}

# JS run inside the attached page: always answers with a JSON document so the
# caller can distinguish "wrong/absent document", "still loading" and "real
# failure" instead of guessing.
my $STATE_JS = '(function(){try{return JSON.stringify({'
  . 'href:location.href,'
  . 'rs:document.readyState,'
  . 't:(localStorage.getItem("t")||"").length,'
  . 'out:!!document.getElementById("out")'
  . '})}catch(e){return JSON.stringify({err:String(e)})}})()';

sub eval_json {
  my ($s, $sid, $js) = @_;
  my $r = cdp($s, "Runtime.evaluate",
    { expression => $js, returnByValue => JSON::PP::true }, $sid);
  return { __error => encode_json($r->{error}) } if $r->{error};
  my $rr = $r->{result} // {};
  return { __error => ($rr->{exceptionDetails}{exception}{description}
                       // "evaluate exception") }
    if $rr->{exceptionDetails};
  my $v = $rr->{result}{value};
  return { __error => "no value (context not ready)" } unless defined $v;
  my $d = eval { decode_json($v) };
  return { __error => "non-JSON value: $v" } unless $d;
  return $d;
}

sub main {
  my $code = do {
    open my $fh, "<", $ui or give_up "cannot read $ui: $!";
    local $/;
    <$fh> // "";
  };
  give_up "empty UI file $ui" unless length $code;
  my $chars = length(Encode::decode("UTF-8", $code));
  note(sprintf "ui=%s (%d bytes, %d chars)", $ui, length($code), $chars);

  # 1. Wait for the remote debugging port. Fresh/slow profiles can take a
  #    while before the browser binds it, so the budget is generous.
  my $ver;
  for (1 .. 60) {
    $ver = `curl -s http://localhost:9222/json/version 2>/dev/null`;
    last if $ver =~ /webSocketDebuggerUrl/;
    note("waiting for CDP port 9222 (attempt $_)") if $_ % 10 == 0;
    sleep 2;
  }
  give_up "CDP port never came up" unless $ver =~ /"webSocketDebuggerUrl"\s*:\s*"([^"]+)"/;
  note("CDP port is up");

  my $ws_url = $1;
  my ($host, $port, $path) = $ws_url =~ m!ws://([^:/]+):(\d+)(/.+)!
    or give_up "cannot parse webSocketDebuggerUrl: $ws_url";
  my $s = IO::Socket::INET->new(PeerHost => $host, PeerPort => $port,
    Proto => "tcp", Timeout => 15) or give_up "connect to $host:$port: $!";
  $s->autoflush(1);

  my $k = encode_base64(join("", map { chr(int(rand(256))) } 1 .. 16), "");
  syswrite($s, "GET $path HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\n" .
               "Connection: Upgrade\r\nSec-WebSocket-Key: $k\r\nSec-WebSocket-Version: 13\r\n\r\n");
  my $hs = "";
  while ($hs !~ /\r\n\r\n$/) { $hs .= rx($s, 1); last if length($hs) > 4096 }
  give_up "websocket handshake rejected" unless $hs =~ /101/;
  note("websocket connected ($host:$port)");

  # 2. Find the terminal target, creating it when absent. Retried: right
  #    after startup createTarget can be rejected while the browser is still
  #    logging in.
  my $tid;
  for my $try (1 .. 30) {
    my $tgts = eval { cdp($s, "Target.getTargets", {}) };
    for my $t (@{$tgts->{result}{targetInfos} // []}) {
      $tid = $t->{targetId} if ($t->{url} // "") =~ m!^chrome-untrusted://terminal!;
    }
    last if $tid;
    my $cr = cdp($s, "Target.createTarget", { url => "chrome-untrusted://terminal/" });
    if ($cr->{error}) {
      note(sprintf "createTarget failed (try %d): %s", $try, encode_json($cr->{error}));
    } elsif ($cr->{result}{targetId}) {
      $tid = $cr->{result}{targetId};
      note("created terminal target $tid");
      last;
    }
    sleep 1;
  }
  give_up "no terminal target after 30 attempts" unless $tid;
  note("terminal target: $tid");

  my $ar = cdp($s, "Target.attachToTarget", { targetId => $tid, flatten => JSON::PP::true });
  my $sid = $ar->{result}{sessionId};
  give_up "attach failed: " . encode_json($ar) unless $sid;

  # 3. Wait until the attached document is really the terminal page and has
  #    finished loading — evaluating any earlier writes into the void.
  my $st;
  for (1 .. 40) {
    $st = eval_json($s, $sid, $STATE_JS);
    if (!$st->{__error} && ($st->{href} // "") =~ m!^chrome-untrusted://terminal!
        && ($st->{rs} // "") eq "complete") {
      last;
    }
    note("waiting for terminal document: " . encode_json($st));
    sleep 0.5;
  }
  give_up "terminal document never loaded: " . encode_json($st)
    unless ($st->{href} // "") =~ m!^chrome-untrusted://terminal! && ($st->{rs} // "") eq "complete";
  note("document loaded: " . encode_json($st));
  if (($st->{t} // 0) == $chars && $st->{out}) {
    note("already injected and mounted, nothing to do");
    exit 0;
  }

  # 4. Store the UI, read it back, reload, verify the mount; up to 3 rounds.
  my $set_js = '(function(){var c=' . encode_json($code) . ';'
    . 'try{localStorage.setItem("t",c);'
    . 'return JSON.stringify({set:localStorage.getItem("t").length})}'
    . 'catch(e){return JSON.stringify({err:String(e)})}})()';

  for my $attempt (1 .. 3) {
    my $set = eval_json($s, $sid, $set_js);
    note(sprintf "setItem attempt %d -> %s", $attempt, encode_json($set));
    give_up "localStorage rejected the UI: " . encode_json($set)
      if $set->{__error} || $set->{err};
    give_up sprintf("stored length %d != %d — truncated write",
        $set->{set} // -1, $chars) if ($set->{set} // -1) != $chars;

    cdp($s, "Page.reload", {}, $sid);
    note("page reloaded, waiting for the UI to mount");

    my $mounted = 0;
    for (1 .. 40) {
      sleep 0.5;
      my $s2 = eval_json($s, $sid, $STATE_JS);
      next if $s2->{__error};    # navigation destroyed the context; keep polling
      if (($s2->{rs} // "") eq "complete") {
        note("post-reload state: " . encode_json($s2));
        $mounted = 1 if $s2->{out} && ($s2->{t} // 0) == $chars;
        last;
      }
    }
    if ($mounted) {
      note("SUCCESS: terminal UI mounted");
      exit 0;
    }
    note("UI not mounted after reload (attempt $attempt), retrying");
  }
  give_up "UI still not mounted after 3 set/reload rounds";
}

my $ok = eval { main(); 1 };
if (!$ok) {
  my $e = $@ || "unknown error";
  $e =~ s/\s+$//;
  note("fatal: $e");
  exit 1;
}
