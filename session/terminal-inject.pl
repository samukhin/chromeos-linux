#!/usr/bin/env perl
# Inject terminal/terminal-ui.js into the shell pages over CDP.
#
# The Chrome binary is patched so the shared js/terminal.js resource does
# eval(localStorage.t||"") on load (for the Terminal page it is reached via
# terminalPrivate.openVmshellProcess). Both chrome-untrusted://terminal/ and
# chrome-untrusted://crosh/ load that resource, but every chrome-untrusted
# host is its own origin with its own localStorage — so the UI must be stored
# per origin. This script waits for Chrome's remote debugging port and, for
# each origin below, stores the UI there and reloads the page.
#
# Target handling per origin:
#   keep => 1 (terminal) — the page is the session shell: create the target
#           if absent and leave it open.
#   keep => 0 (crosh)    — a rarely used page: never leave an extra window
#           behind, on success and on failure alike. If no crosh target
#           exists, one is created just long enough to store the UI
#           (localStorage is per-profile and survives the close), then closed
#           again. The window blinks once per session start; a crosh the user
#           opens later mounts the UI from storage.
#
# Why the polling dance below: a freshly Target.createTarget'd page reports
# about:blank until the navigation commits, and a Runtime.evaluate issued
# before the commit lands in the wrong document (the item never reaches the
# target origin) or fails while the browser is still coming up — that was
# the "inject silently missed, terminal window stays white" bug. So we
# (1) retry target lookup/create, (2) wait until the document really is the
# origin's page and finished loading, (3) read the item back after storing,
# (4) verify after the reload that the UI actually mounted, re-running the
# set/reload cycle when it did not. Every step is logged to stderr;
# chromeos-linux-session appends it to terminal-inject.log.
#
# Usage: terminal-inject.pl <path/to/terminal-ui.js>
use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64;
use JSON::PP;
use Encode ();
use Time::HiRes ();

my @ORIGINS = (
  { url => "chrome-untrusted://terminal/", keep => 1 },
  { url => "chrome-untrusted://crosh/",     keep => 0 },
);

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
  $l = unpack("n", rx($s, 2)) if $l == 126;
  $l = unpack("Q>", rx($s, 8)) if $l == 127;
  rx($s, $l);
}
sub ws {
  my ($s, $t) = @_; my $l = length($t);
  my @m = map { int(rand(256)) } 1 .. 4;
  # 7-bit, 16-bit and (for payloads >= 64 KiB) 64-bit lengths. Without the
  # 64-bit branch a too-long terminal-ui.js silently truncates the frame and
  # the terminal never injects.
  my $h = $l < 126    ? pack("CC", 0x81, 0x80 | $l)
         : $l < 65536 ? pack("CCn", 0x81, 0xfe, $l)
         :              pack("CCQ>", 0x81, 0xff, $l);
  my $f = $h . pack("C4", @m)
        . join("", map { chr(ord(substr($t, $_, 1)) ^ $m[$_ % 4]) } 0 .. $l - 1);
  # syswrite may emit fewer bytes than asked on a large frame; loop until the
  # whole frame is out, else Chrome sees a torn frame.
  my $off = 0;
  while ($off < length($f)) {
    my $n = syswrite($s, $f, length($f) - $off, $off);
    die "terminal-inject: write failed\n" unless defined $n && $n > 0;
    $off += $n;
  }
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
# failure" instead of guessing. #term/#ta are what terminal-ui.js appends when
# it boots, so their presence is the "UI actually mounted" signal.
my $STATE_JS = '(function(){try{return JSON.stringify({'
  . 'href:location.href,'
  . 'rs:document.readyState,'
  . 't:(localStorage.getItem("t")||"").length,'
  . 'mounted:!!document.getElementById("term") && !!document.getElementById("ta")'
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

# Close a target we created for a throwaway origin. No-op for kept pages and
# for targets that were already open. Under eval: the CDP connection may be
# the very thing that just failed, and cleanup must not mask the real error.
sub close_target {
  my $ctx = shift;
  return unless $ctx->{tid} && $ctx->{created} && !$ctx->{keep};
  my $r = eval {
    cdp($ctx->{s}, "Target.closeTarget", { targetId => $ctx->{tid} });
  };
  return unless $@ || ($r && $r->{error});
  my $why = $@ ? do { my $e = $@; $e =~ s/\s+$//; $e }
                : encode_json($r->{error});
  note("closeTarget($ctx->{tid}) failed: $why");
}

# Report a per-origin failure, close our throwaway target if there is one, and
# return false so the caller can move on to the next origin.
sub fail_origin {
  my ($ctx, $msg) = @_;
  note($msg);
  close_target($ctx);
  note("leaving target $ctx->{tid} open for inspection")
    if $ctx->{tid} && !($ctx->{created} && !$ctx->{keep});
  0;
}

# Inject one origin. Returns 1 on success; note()s the reason on failure.
# The body runs under eval so an unexpected die (CDP timeout, dead socket)
# still cleans up instead of leaking the target we created.
sub inject_origin {
  my ($s, $spec, $code, $chars, $json_code) = @_;
  my $ctx = {
    s       => $s,
    keep    => $spec->{keep},
    tid     => undef,
    created => 0,
  };
  my $status = eval { inject_origin_body($ctx, $spec, $code, $chars, $json_code) + 0 };
  return $status if defined $status;

  my $e = $@ || "unknown error";
  $e =~ s/\s+$//;
  note("$spec->{url}: fatal: $e");
  close_target($ctx);
  note("leaving target $ctx->{tid} open for inspection")
    if $ctx->{tid} && !($ctx->{created} && !$ctx->{keep});
  0;
}

sub inject_origin_body {
  my ($ctx, $spec, $code, $chars, $json_code) = @_;
  my $s = $ctx->{s};
  my $url = $spec->{url};
  my $name = $url;
  $name =~ s!^chrome-untrusted://!!; $name =~ s!/$!!;

  # 1. Find the target, creating it when absent. Retried: right after
  #    startup createTarget can be rejected while the browser is still
  #    logging in.
  my $tid;
  my $tries = 0;
  my $comm_fail = 0;
  for my $try (1 .. 30) {
    $tries = $try;
    my $tgts = eval { cdp($s, "Target.getTargets", {}) };
    if (!$tgts) {
      my $e = $@ || "no response";
      $e =~ s/\s+$//;
      note("getTargets($name) failed (try $try): $e");
      last if ++$comm_fail >= 3;   # desynced/dead socket: retrying cannot help
      Time::HiRes::sleep(1);
      next;
    }
    $comm_fail = 0;
    for my $t (@{$tgts->{result}{targetInfos} // []}) {
      $tid = $t->{targetId} if !defined $tid && ($t->{url} // "") =~ m!^\Q$url\E!;
    }
    last if $tid;
    my $cr = cdp($s, "Target.createTarget", { url => $url });
    if ($cr->{error}) {
      note(sprintf "createTarget(%s) failed (try %d): %s",
        $name, $try, encode_json($cr->{error}));
    } elsif ($cr->{result}{targetId}) {
      $tid = $ctx->{tid} = $cr->{result}{targetId};
      $ctx->{created} = 1;
      note("created $name target $tid");
      last;
    }
    Time::HiRes::sleep(1);
  }
  return do { note("no $name target after $tries attempt(s)"); 0 } unless $tid;
  $ctx->{tid} = $tid;
  note("$name target: $tid" . ($ctx->{created} ? " (created by us)" : ""));

  my $ar = cdp($s, "Target.attachToTarget", { targetId => $tid, flatten => JSON::PP::true });
  my $sid = $ar->{result}{sessionId};
  return fail_origin($ctx, "attach to $name failed: " . encode_json($ar))
    unless $sid;

  # 2. Wait until the attached document is really this origin's page and has
  #    finished loading — evaluating any earlier writes into the void.
  my $st;
  for (1 .. 40) {
    $st = eval_json($s, $sid, $STATE_JS);
    if (!$st->{__error} && ($st->{href} // "") =~ m!^\Q$url\E!
        && ($st->{rs} // "") eq "complete") {
      last;
    }
    note("waiting for $name document: " . encode_json($st));
    Time::HiRes::sleep(0.5);
  }
  return fail_origin($ctx, "$name document never loaded: " . encode_json($st))
    unless ($st->{href} // "") =~ m!^\Q$url\E! && ($st->{rs} // "") eq "complete";
  note("document loaded: " . encode_json($st));
  if (($st->{t} // 0) == $chars && $st->{mounted}) {
    note("$name: already injected and mounted, nothing to do");
    close_target($ctx);
    return 1;
  }

  # 3. Store the UI, read it back, reload, verify the mount; up to 3 rounds.
  # ascii => non-ASCII becomes \uXXXX escapes: the expression stays pure
  # ASCII, so the outer JSON encoder in cdp() cannot double-encode the UTF-8
  # bytes (which would store mojibake and make the length check fail).
  my $set_js = '(function(){var c=' . $json_code . ';'
    . 'try{localStorage.setItem("t",c);'
    . 'return JSON.stringify({set:localStorage.getItem("t").length})}'
    . 'catch(e){return JSON.stringify({err:String(e)})}})()';

  for my $attempt (1 .. 3) {
    my $set = eval_json($s, $sid, $set_js);
    note(sprintf "setItem(%s) attempt %d -> %s", $name, $attempt, encode_json($set));
    return fail_origin($ctx, "localStorage rejected the UI: " . encode_json($set))
      if $set->{__error} || $set->{err};
    return fail_origin($ctx, sprintf("stored length %d != %d — truncated write",
        $set->{set} // -1, $chars))
      if ($set->{set} // -1) != $chars;

    cdp($s, "Page.reload", {}, $sid);
    note("$name page reloaded, waiting for the UI to mount");

    my $mounted = 0;
    for (1 .. 40) {
      Time::HiRes::sleep(0.5);
      my $s2 = eval_json($s, $sid, $STATE_JS);
      next if $s2->{__error};    # navigation destroyed the context; keep polling
      if (($s2->{rs} // "") eq "complete") {
        note("post-reload state: " . encode_json($s2));
        $mounted = 1 if $s2->{mounted} && ($s2->{t} // 0) == $chars;
        last;
      }
    }
    if ($mounted) {
      note("SUCCESS: $name UI mounted");
      close_target($ctx);
      return 1;
    }
    note("UI not mounted after reload (attempt $attempt), retrying");
  }
  return fail_origin($ctx, "UI still not mounted after 3 set/reload rounds");
}

sub main {
  my $raw = do {
    open my $fh, "<", $ui or give_up "cannot read $ui: $!";
    local $/;
    <$fh> // "";
  };
  give_up "empty UI file $ui" unless length $raw;
  # The UI contains box-drawing/DEC-special characters, so decode before
  # handing it to encode_json(): feeding raw UTF-8 bytes makes JSON::PP treat
  # every byte as a separate codepoint (mojibake) and the stored length no
  # longer matches what the browser will see.
  my $code = Encode::decode("UTF-8", $raw);
  my $chars = length($code);
  note(sprintf "ui=%s (%d bytes, %d chars)", $ui, length($raw), $chars);

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

  # Pure-ASCII JSON encoding of the UI, reused for every origin.
  my $json_code = JSON::PP->new->ascii->allow_nonref->encode($code);

  # 2. Inject every origin; a failure of one must not skip the others.
  my @failed;
  for my $spec (@ORIGINS) {
    push @failed, $spec->{url}
      unless inject_origin($s, $spec, $code, $chars, $json_code);
  }
  if (@failed) {
    note("FAILED origins: " . join(", ", @failed));
    exit 1;
  }
  note("all origins injected");
}

my $ok = eval { main(); 1 };
if (!$ok) {
  my $e = $@ || "unknown error";
  $e =~ s/\s+$//;
  note("fatal: $e");
  exit 1;
}
