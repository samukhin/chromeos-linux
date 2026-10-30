// session-bridge implements the ChromeOS session_manager pieces Ash expects.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	dbus "github.com/godbus/dbus/v5"
)

const (
	sessionService = "org.chromium.SessionManager"
	sessionPath    = dbus.ObjectPath("/org/chromium/SessionManager")
	sessionIface   = "org.chromium.SessionManagerInterface"

	udaService = "org.chromium.UserDataAuth"
	udaPath    = dbus.ObjectPath("/org/chromium/UserDataAuth")
	udaIface   = "org.chromium.UserDataAuthInterface"

	// What the real session_manager forwards LockScreen() to
	// (session_manager_service.cc: SessionManagerService::LockScreen() calls
	// chromeos::kScreenLockServiceShowLockScreenMethod). Chrome/Ash exports
	// this service itself via ash::ScreenLockServiceProvider; the handler
	// calls ash::ScreenLocker::HandleShowLockScreenRequest() and draws the
	// lock screen.
	screenLockService = "org.chromium.ScreenLockService"
	screenLockPath    = dbus.ObjectPath("/org/chromium/ScreenLockService")
	screenLockIface   = "org.chromium.ScreenLockServiceInterface"
	screenLockMethod  = "ShowLockScreen"

	guestHome = "/home/chronos/user"
)

type sessionManager struct {
	conn    *dbus.Conn
	startCh chan struct{}

	// Ash keeps the authoritative lock state internally, but other components
	// (power, notifications) query session_manager's IsScreenLocked to decide
	// whether the screen is locked. Ash tells us about transitions via
	// HandleLockScreenShown / HandleLockScreenDismissed, so we mirror them here
	// instead of hard-coding false.
	mu     sync.Mutex
	locked bool
}

const (
	testAccountID = "linux@local"
	testUserHash  = "test-user"
)

func (s *sessionManager) EmitLoginPromptVisible() *dbus.Error {
	log.Println("EmitLoginPromptVisible — Ash login screen is up")
	select {
	case s.startCh <- struct{}{}:
	default:
	}
	return nil
}

func (s *sessionManager) EmitLoginPromptAnimationFinished() *dbus.Error {
	return nil
}

func (s *sessionManager) EmitAshInitialized() *dbus.Error {
	log.Println("EmitAshInitialized")
	return nil
}

func (s *sessionManager) EmitStartedUserSession(accountID string) *dbus.Error {
	log.Printf("EmitStartedUserSession: %s", accountID)
	return nil
}

func (s *sessionManager) StartSession(accountID, uniqueID string) *dbus.Error {
	log.Printf("StartSession: %s", accountID)
	return nil
}

func (s *sessionManager) StartSessionEx(accountID, uniqueID string, chromeOwnerKey bool) *dbus.Error {
	log.Printf("StartSessionEx: %s chrome_owner_key=%v", accountID, chromeOwnerKey)
	return nil
}

// Ash signals "sign out" by calling StopSession / StopSessionWithReason on
// org.chromium.SessionManager. On real ChromeOS that hands control back to the
// login manager; here there is no login screen, so the correct behaviour is to
// shut the whole session down. The session script publishes its pid to
// $XDG_RUNTIME_DIR/chromeos-linux-session.pid and installs a TERM trap that
// tears down Chrome, sommelier, Xwayland and (if it started it) Xorg — so we
// just signal it and let that cleanup run. Without this, logout left Chrome
// alive on a black screen and the user had to kill everything by hand.
func requestSessionShutdown(reason string) {
	pid, ok := sessionScriptPID()
	if !ok {
		log.Printf("%s: no live session pid file — nothing to shut down", reason)
		return
	}
	log.Printf("%s: signalling session script (pid %d) to shut down", reason, pid)
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		log.Printf("%s: kill %d: %v", reason, pid, err)
	}
}

func sessionScriptPID() (int, bool) {
	var candidates []string
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		candidates = append(candidates, filepath.Join(dir, "chromeos-linux-session.pid"))
	}
	// Fallback when the bridge's env lacks XDG_RUNTIME_DIR but runs as the same
	// user: the runtime dir is always /run/user/<uid>.
	candidates = append(candidates, fmt.Sprintf("/run/user/%d/chromeos-linux-session.pid", os.Getuid()))
	for _, p := range candidates {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
			// Confirm it is actually alive so we never signal a recycled pid.
			if err := syscall.Kill(pid, 0); err == nil {
				return pid, true
			}
		}
	}
	return 0, false
}

func (s *sessionManager) StopSession(uniqueID string) (bool, *dbus.Error) {
	log.Println("StopSession")
	requestSessionShutdown("StopSession")
	return true, nil
}

func (s *sessionManager) StopSessionWithReason(reason uint32) *dbus.Error {
	log.Printf("StopSessionWithReason: %d", reason)
	requestSessionShutdown("StopSessionWithReason")
	return nil
}

// LockScreen mirrors the real session_manager: acknowledge the caller
// immediately and forward ShowLockScreen to Chrome's ScreenLockServiceProvider
// (the real daemon does the same with an async CallMethod + base::DoNothing()).
// Before this forwarding existed the request was logged but nothing was drawn —
// ash only shows the lock UI when ScreenLocker::HandleShowLockScreenRequest()
// runs inside Chrome.
func (s *sessionManager) LockScreen() *dbus.Error {
	log.Println("LockScreen — forward -> org.chromium.ScreenLockService.ShowLockScreen")
	go func() {
		// godbus derives the INTERFACE header from the "iface.Member" spelling
		// of the method name (createCall splits on the last dot). Passing the
		// bare member drops the header, and Chromium's ExportedObject then
		// answers UnknownMethod: 'Method "ShowLockScreen" ... on interface
		// "(null)" doesn't exist'.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		reply := s.conn.Object(screenLockService, screenLockPath).
			CallWithContext(ctx, screenLockIface+"."+screenLockMethod, 0)
		if reply.Err != nil {
			log.Printf("LockScreen: ShowLockScreen forward failed: %v", reply.Err)
			return
		}
		log.Println("LockScreen — ShowLockScreen delivered")
	}()
	return nil
}

func (s *sessionManager) setLocked(v bool) {
	s.mu.Lock()
	s.locked = v
	s.mu.Unlock()
}

func (s *sessionManager) isLocked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.locked
}

func (s *sessionManager) RetrieveActiveSessions() (map[string]string, *dbus.Error) {
	return map[string]string{testAccountID: testUserHash}, nil
}

func (s *sessionManager) RetrievePrimarySession() (string, string, *dbus.Error) {
	return testAccountID, testUserHash, nil
}

func (s *sessionManager) RetrieveSessionState() (string, *dbus.Error) {
	return "started", nil
}

func (s *sessionManager) IsGuestSessionActive() (bool, *dbus.Error) {
	return false, nil
}

func (s *sessionManager) IsScreenLocked() (bool, *dbus.Error) {
	return s.isLocked(), nil
}

// QueryAdbSideload — there is no adb sideloading on this setup; answering
// false (like session_manager with sideloading disabled) is a valid reply and
// silences the UnknownMethod logged by SessionManagerClient.
func (s *sessionManager) QueryAdbSideload() (bool, *dbus.Error) {
	return false, nil
}

func (s *sessionManager) HandleLockScreenShown() *dbus.Error {
	log.Println("HandleLockScreenShown — screen locked")
	s.setLocked(true)
	return nil
}

func (s *sessionManager) HandleLockScreenDismissed() *dbus.Error {
	log.Println("HandleLockScreenDismissed — screen unlocked")
	s.setLocked(false)
	return nil
}

func (s *sessionManager) RetrievePolicyEx(descriptor []byte) ([]byte, *dbus.Error) {
	log.Printf("RetrievePolicyEx called (returning empty policy)")
	return []byte{}, nil
}

func (s *sessionManager) StorePolicyEx(descriptor []byte, policy []byte) *dbus.Error {
	log.Printf("StorePolicyEx called (ignored)")
	return nil
}

func (s *sessionManager) ListStoredComponentPolicies(descriptor []byte) ([]string, *dbus.Error) {
	return []string{}, nil
}

func boolField(fieldNum int, val bool) []byte {
	tag := byte((fieldNum << 3) | 0)
	if val {
		return []byte{tag, 0x01}
	}
	return []byte{tag, 0x00}
}

func bytesField(fieldNum int, val []byte) []byte {
	tag := byte((fieldNum << 3) | 2)
	l := byte(len(val))
	return append([]byte{tag, l}, val...)
}

type cryptohomeMisc struct{}

func (m *cryptohomeMisc) GetSystemSalt(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("GetSystemSalt", req)
	salt := []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
		0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
		0x01, 0x23, 0x45, 0x67}
	// GetSystemSaltReply имеет ровно 1 поле: salt = field 1, тэг 0x0a,
	// wt 2 (bytes), offset 0x18 (TcParse-таблица 0x15076e08, запись +0x40).
	// Ash читает его в SystemSaltGetter::DidGetSystemSalt (offset 0x18);
	// неверный номер поля = пустая соль = CHECK key.cc:66 !salt.empty().
	reply := bytesField(1, salt)
	log.Printf("GetSystemSalt reply (%d bytes): %x", len(reply), reply)
	return reply, nil
}

type userDataAuth struct{}

func (u *userDataAuth) IsMounted(req []byte) ([]byte, *dbus.Error) {
	return append(boolField(1, true), boolField(2, true)...), nil
}

func (u *userDataAuth) MountGuest(req []byte) ([]byte, *dbus.Error) {
	log.Println("MountGuest — creating", guestHome)
	os.MkdirAll(guestHome, 0755)
	return []byte{}, nil
}

func (u *userDataAuth) Unmount(req []byte) ([]byte, *dbus.Error) {
	log.Println("Unmount")
	return []byte{}, nil
}

func (u *userDataAuth) GetSupportedKeyPolicies(req []byte) ([]byte, *dbus.Error) {
	return []byte{}, nil
}

// logAuthReq records the raw protobuf bytes Ash sent so we can see the exact
// request shape. This is how we determine the correct success-reply encoding
// empirically instead of guessing proto field numbers.
func logAuthReq(method string, req []byte) {
	log.Printf("%s request (%d bytes): %x", method, len(req), req)
}

// StartAuthSessionReply, recovered from dist/chrome/chrome:
//
//	field 2  = auth_session_id (bytes)  — OnStartAuthSession passes it to
//	           UserContext::SetAuthSessionIds(); an empty id makes the very
//	           next InvalidateAuthSession CHECK-fail
//	           (!context->GetAuthSessionId().empty(), auth_performer.cc:156)
//	           and FATAL-crash the session.
//	field 3  = user_exists (bool)      — OnStartAuthSession feeds it into the
//	           StartAuthSessionForLoggedIn callback; DoUnlock then rejects the
//	           unlock attempt with "User directory does not exist for
//	           supposedly existing user"
//	           (auth_session_authenticator.cc:529) unless it is true, so
//	           password entry could never reach AuthenticateAuthFactor.
//	field 9  = repeated AuthFactorWithStatus  — NOT field 5.
//	           StartAuthSessionReply has TWO repeated AuthFactorWithStatus
//	           fields. _InternalSerialize shows field 5's count lives at msg
//	           offset 0x20 (mov 0x20(%r12),%r15d before mov $0x5,%edi) while
//	           field 9's count lives at offset 0x58 (mov 0x58(%r12),%r15d
//	           before mov $0x9,%edi). The OnStartAuthSession loop that
//	           populates SessionAuthFactors reads its element count from
//	           offset 0x58 (movslq 0x58(%r12),%r12) and its elements array
//	           from offset 0x50 — i.e. it iterates field 9, not field 5.
//	           Placing the factor in field 5 leaves SessionAuthFactors empty
//	           and FindAnyPasswordFactor() returns nullptr ("Could not find
//	           Password key", auth_performer.cc:225).
//	             AuthFactorWithStatus.field 1 = AuthFactor
//	               AuthFactor.field 1 = type (AuthFactorType enum; 1 = PASSWORD —
//	                          verified via SafeConvertFactorTypeFromProto:
//	                          proto 1 -> internal 2, and LockContentsView
//	                          probes exactly {2,3,5} = password/pin/smartcard)
//	               AuthFactor.field 2 = label (string)
//
// Label MUST be exactly "local-password" (kCryptohomeLocalPasswordKeyLabel):
// after the plain key is hashed, AuthenticateUsingKnowledgeKey looks the
// factor up by that exact label — FindAnyPasswordFactor() →
// FindOnlinePasswordFactor() (gaia "legacy-" prefix, misses) →
// FindLocalPasswordFactor() → FindPasswordFactor("local-password"), which
// requires type==kPassword AND label=="local-password" (FindPasswordFactor
// at auth_performer.cc does an exact string compare). Any other label logs
// "Could not find Password key" (auth_performer.cc:225) and unlock never
// reaches AuthenticateAuthFactor.
//
// Without a factor in the reply LockContentsView logs "Unable to update auth
// factors, neither password, PIN or smart card auth is configured" and shows
// no input box, so unlock becomes impossible.
func (u *userDataAuth) StartAuthSession(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("StartAuthSession", req)

	const id = "ash-linux-lock-session-1"
	const label = "local-password"

	factor := []byte{0x08, 0x01} // AuthFactor.type = PASSWORD
	factor = append(factor, 0x12, byte(len(label)))
	factor = append(factor, label...)

	factorWithStatus := append([]byte{0x0a, byte(len(factor))}, factor...) // .auth_factor

	reply := append([]byte{0x12, byte(len(id))}, id...)      // .auth_session_id
	reply = append(reply, 0x18, 0x01)                        // .user_exists = true
	reply = append(reply, 0x4a, byte(len(factorWithStatus))) // field 9 (tag (9<<3)|2)
	reply = append(reply, factorWithStatus...)

	log.Printf("StartAuthSession reply (%d bytes): %x", len(reply), reply)
	return reply, nil
}

func (u *userDataAuth) AuthenticateAuthSession(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("AuthenticateAuthSession", req)
	return []byte{}, nil
}

// AuthenticateAuthFactor is the modern cryptohome API Ash actually uses to
// unlock the lock screen (AuthPerformer -> UserDataAuthClientImpl). The bridge
// previously only exported the legacy AuthenticateAuthSession, so unlock hit
// "unknown method" and always failed.
//
// OnAuthenticateAuthFactor (auth_performer.cc) CHECKs reply.has_value() and
// reply->has_auth_properties() (field 6, recovered from
// AuthenticateAuthFactorReply::_InternalSerialize: has-bit 0x2 -> ptr at 0x20
// -> InternalWriteMessage(6)); an empty reply FATAL-crashes the session. It
// then calls FillAuthenticationData which DCHECKs
// authorized_for_size() > 0 and reads seconds_left, so the embedded
// AuthSessionProperties (fields recovered from
// AuthSessionProperties::_InternalSerialize) must carry:
//
//	field 4 = packed repeated AuthIntent authorized_for
//	          (1 = DECRYPT, 2 = VERIFY_ONLY, 3 = WEBAUTHN — from the
//	          switch in FillAuthenticationData); we authorize both
//	          DECRYPT and VERIFY_ONLY to cover any downstream intent check.
//	field 5 = int32 seconds_left (session lifetime; 0 would expire the
//	          auth session immediately).
//
// The error field is not set, which ReplyToCryptohomeError reads as success —
// that is what makes the unlock passwordless: any entered password "matches".
func (u *userDataAuth) AuthenticateAuthFactor(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("AuthenticateAuthFactor", req)

	// AuthSessionProperties{authorized_for: [DECRYPT, VERIFY_ONLY],
	//                       seconds_left: 1800}
	props := []byte{0x22, 0x02, 0x01, 0x02, // field 4, packed len 2: 1, 2
		0x28, 0x88, 0x0e} // field 5: 1800
	// AuthenticateAuthFactorReply{auth_properties: props} (field 6)
	reply := append([]byte{0x32, byte(len(props))}, props...)

	log.Printf("AuthenticateAuthFactor reply (%d bytes): %x", len(reply), reply)
	return reply, nil
}

// The lock-screen flow calls more UserDataAuth methods than the bridge
// originally exported; godbus answers UnknownMethod for missing ones. An
// empty proto reply means "no cryptohome error" (HasError checks the error
// field's presence), so plain success is the right default for all of them.
// Each one logs the raw request so any unexpected reply semantics stay
// visible in session-bridge.log.
func (u *userDataAuth) InvalidateAuthSession(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("InvalidateAuthSession", req)
	return []byte{}, nil
}

func (u *userDataAuth) PrepareAuthFactor(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("PrepareAuthFactor", req)
	return []byte{}, nil
}

func (u *userDataAuth) TerminateAuthFactor(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("TerminateAuthFactor", req)
	return []byte{}, nil
}

func (u *userDataAuth) ListAuthFactors(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("ListAuthFactors", req)
	return []byte{}, nil
}

// ExtendAuthSessionReply field 3 = int32 seconds_left (tag 0x18, offset 0x24,
// recovered from ExtendAuthSessionReply::_InternalSerialize and the load in
// OnExtendAuthSession). OnExtendAuthSession multiplies it by 1e6 and calls
// SetSessionLifetime(); an empty reply leaves lifetime at 0 and the auth
// session expires immediately.
func (u *userDataAuth) ExtendAuthSession(req []byte) ([]byte, *dbus.Error) {
	logAuthReq("ExtendAuthSession", req)
	reply := []byte{0x18, 0x88, 0x0e} // seconds_left: 1800
	log.Printf("ExtendAuthSession reply (%d bytes): %x", len(reply), reply)
	return reply, nil
}

func (u *userDataAuth) GetAccountDiskUsage(req []byte) ([]byte, *dbus.Error) {
	return []byte{}, nil
}

func (u *userDataAuth) CheckHealth(req []byte) ([]byte, *dbus.Error) {
	return []byte{}, nil
}

func main() {
	log.SetPrefix("[session-bridge] ")

	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		log.Fatalf("connect to system bus: %v", err)
	}
	defer conn.Close()

	reply, err := conn.RequestName(sessionService, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("request name %s: err=%v reply=%v", sessionService, err, reply)
	}

	startCh := make(chan struct{}, 1)
	mgr := &sessionManager{conn: conn, startCh: startCh}
	conn.Export(mgr, sessionPath, sessionIface)

	reply, err = conn.RequestName(udaService, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("request name %s: err=%v reply=%v", udaService, err, reply)
	}

	conn.Export(&userDataAuth{}, udaPath, udaIface)
	conn.Export(&cryptohomeMisc{}, udaPath, "org.chromium.CryptohomeMiscInterface")

	log.Printf("registered %s and %s", sessionService, udaService)

	go func() {
		for range startCh {
			time.Sleep(300 * time.Millisecond)
			if err := conn.Emit(sessionPath, sessionIface+".SessionStateChanged", "started"); err != nil {
				log.Printf("emit SessionStateChanged: %v", err)
			} else {
				log.Println("emitted SessionStateChanged(started)")
			}
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
}
