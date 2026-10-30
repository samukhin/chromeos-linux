// stub-bridge owns the ChromeOS services that simply do not exist on this
// Linux host (resourced, tpm_managerd, permission_broker, update_engine,
// typecd, pciguard, floss media, rgbkbd, cros-disks, biod, ml-service,
// lorgnette, upstart, fwupd) and answers every method Ash calls with a
// minimal no-op stub of the exact signature Chromium expects. The goal is
// only to stop the flood of ServiceUnknown/UnknownMethod errors in ash.log.
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	dbus "github.com/godbus/dbus/v5"
)

// --- org.chromium.ResourceManager (resourced) ------------------------------

type resourceManager struct{}

// Serialized proto requests; nothing to do with them.
func (r *resourceManager) ReportBrowserProcesses(req []byte) *dbus.Error {
	log.Printf("ResourceManager.ReportBrowserProcesses: %d bytes (no-op)", len(req))
	return nil
}

func (r *resourceManager) SetMemoryMargins(req []byte) *dbus.Error {
	log.Printf("ResourceManager.SetMemoryMargins: %d bytes (no-op)", len(req))
	return nil
}

func (r *resourceManager) SetProcessState(pid uint32, state byte) *dbus.Error {
	return nil
}

func (r *resourceManager) SetThreadState(pid, tid uint32, state byte) *dbus.Error {
	return nil
}

// --- org.chromium.TpmManager (tpm_managerd) --------------------------------

type tpmManager struct{}

// tpmReply returns an empty serialized proto: every field stays at its
// default, i.e. status=STATUS_SUCCESS(0), is_enabled=false, is_owned=false.
// TPMTokenInfoGetter then finishes immediately (TPM disabled -> no token)
// and SystemTokenCertDBInitializer stops retrying.
func tpmReply() ([]byte, *dbus.Error) {
	return []byte{}, nil
}

func (t *tpmManager) GetTpmNonsensitiveStatus(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) GetVersionInfo(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) GetSupportedFeatures(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) GetDictionaryAttackInfo(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) TakeOwnership(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) ClearStoredOwnerPassword(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

func (t *tpmManager) ClearTpm(req []byte) ([]byte, *dbus.Error) {
	return tpmReply()
}

// --- org.chromium.PermissionBroker -----------------------------------------

type permissionBroker struct{}

// Grant everything: there is no real sandbox to enforce here, and a "denied"
// answer would only produce follow-up warnings in the caller.
func (p *permissionBroker) CheckPathAccess(path string) (bool, *dbus.Error) {
	log.Printf("PermissionBroker.CheckPathAccess: %q -> granted", path)
	return true, nil
}

func (p *permissionBroker) RequestUdpPortAccess(port uint16, interfaceName string, sock dbus.UnixFD) (bool, *dbus.Error) {
	log.Printf("PermissionBroker.RequestUdpPortAccess: %s:%d -> granted", interfaceName, port)
	return true, nil
}

// Nothing was actually reserved, so releasing is trivially successful; the
// bool is read by OnResponse on the Ash side.
func (p *permissionBroker) ReleaseTcpPort(port uint16, interfaceName string) (bool, *dbus.Error) {
	return true, nil
}

func (p *permissionBroker) ReleaseUdpPort(port uint16, interfaceName string) (bool, *dbus.Error) {
	return true, nil
}

// --- org.chromium.UpdateEngine ---------------------------------------------

type updateEngine struct{}

// Empty UpdateEngineStatus proto (all fields at defaults).
func (u *updateEngine) GetStatusAdvanced() ([]byte, *dbus.Error) {
	return []byte{}, nil
}

func (u *updateEngine) GetChannel(currentChannel bool) (string, *dbus.Error) {
	return "stable", nil
}

func (u *updateEngine) IsFeatureEnabled(feature string) (bool, *dbus.Error) {
	log.Printf("UpdateEngine.IsFeatureEnabled: %q -> false", feature)
	return false, nil
}

func (u *updateEngine) ToggleFeature(feature string, enable bool) *dbus.Error {
	log.Printf("UpdateEngine.ToggleFeature: %q=%v (no-op)", feature, enable)
	return nil
}

// --- org.chromium.typecd ----------------------------------------------------

type typecd struct{}

func (t *typecd) SetPeripheralDataAccess(permitted bool) *dbus.Error {
	log.Printf("typecd.SetPeripheralDataAccess: %v (no-op)", permitted)
	return nil
}

// --- org.chromium.pciguard --------------------------------------------------

type pciguard struct{}

func (p *pciguard) SetExternalPciDevicesPermission(permitted bool) *dbus.Error {
	log.Printf("pciguard.SetExternalPciDevicesPermission: %v (no-op)", permitted)
	return nil
}

// --- org.chromium.bluetooth (floss BluetoothMedia) --------------------------

type bluetoothMedia struct{}

func (b *bluetoothMedia) SetPlayerPlaybackStatus(status string) *dbus.Error {
	return nil
}

func (b *bluetoothMedia) SetPlayerIdentity(identity string) *dbus.Error {
	return nil
}

func (b *bluetoothMedia) SetPlayerPosition(position int64) *dbus.Error {
	return nil
}

func (b *bluetoothMedia) SetPlayerMetadata(metadata map[string]dbus.Variant) *dbus.Error {
	return nil
}

// --- org.chromium.Rgbkbd ----------------------------------------------------

type rgbkbd struct{}

// 0 = "no RGB keyboard" (RgbKeyboardCapabilities is a bitmask).
func (r *rgbkbd) GetRgbKeyboardCapabilities() (uint32, *dbus.Error) {
	return 0, nil
}

func (r *rgbkbd) SetCapsLockState(enabled bool) *dbus.Error {
	return nil
}

// --- org.chromium.CrosDisks -------------------------------------------------

type crosDisks struct{}

func (c *crosDisks) Mount(source, filesystemType string, options []string) *dbus.Error {
	log.Printf("CrosDisks.Mount: %s (%s) %v (no-op)", source, filesystemType, options)
	return nil
}

// 0 = cros_disks::MOUNT_ERROR_NONE.
func (c *crosDisks) Unmount(path string, options []string) (uint32, *dbus.Error) {
	log.Printf("CrosDisks.Unmount: %s (no-op)", path)
	return 0, nil
}

func (c *crosDisks) EnumerateDevices() ([]string, *dbus.Error) {
	return []string{}, nil
}

// MountPoint as marshalled by cros-disks: a(ususb). Nothing is mounted here,
// so the list is always empty (the client treats an empty array as success).
type mountEntry struct {
	SourceType   uint32
	Path         string
	FilesystemID uint32
	Label        string
	ReadOnly     bool
}

func (c *crosDisks) EnumerateMountEntries() ([]mountEntry, *dbus.Error) {
	return []mountEntry{}, nil
}

// --- org.chromium.BiometricsDaemon (biod) ----------------------------------

type biometrics struct{}

func (b *biometrics) GetRecordsForUser(user string) ([]dbus.ObjectPath, *dbus.Error) {
	return []dbus.ObjectPath{}, nil
}

// --- org.chromium.MachineLearning (ml-service) -----------------------------

type machineLearning struct{}

// false == "no Mojo connection", the same outcome the callers see today when
// the call fails; no listener is set up for the passed fd.
func (m *machineLearning) BootstrapMojoConnection(fd dbus.UnixFD) (bool, *dbus.Error) {
	log.Printf("MachineLearning.BootstrapMojoConnection: fd=%d (no-op)", fd)
	return false, nil
}

// --- org.chromium.lorgnette (scanner) --------------------------------------

type lorgnette struct{}

// Empty StartScannerDiscoveryReply proto (status at its default).
func (l *lorgnette) StartScannerDiscovery(req []byte) ([]byte, *dbus.Error) {
	return []byte{}, nil
}

// --- com.ubuntu.Upstart (job: arc-prepare-host-generated-dir) --------------

type upstartJob struct{}

func (j *upstartJob) Start(env []string, block bool) *dbus.Error {
	log.Printf("upstart Start arc-prepare-host-generated-dir (no-op)")
	return nil
}

func (j *upstartJob) Stop(env []string, block bool) *dbus.Error {
	log.Printf("upstart Stop arc-prepare-host-generated-dir (no-op)")
	return nil
}

// --- org.freedesktop.fwupd --------------------------------------------------

type fwupd struct{}

func (f *fwupd) GetDevices() ([]map[string]dbus.Variant, *dbus.Error) {
	return []map[string]dbus.Variant{}, nil
}

func (f *fwupd) GetUpgrades(deviceID string) ([]map[string]dbus.Variant, *dbus.Error) {
	return []map[string]dbus.Variant{}, nil
}

func (f *fwupd) SetFeatureFlags(flags uint64) *dbus.Error {
	return nil
}

func (f *fwupd) Install(deviceID string, fileDescriptor dbus.UnixFD, options map[string]dbus.Variant) *dbus.Error {
	log.Printf("fwupd.Install: %q (no-op)", deviceID)
	return nil
}

func (f *fwupd) UpdateMetadata(remoteID string, dataFD, sigFD dbus.UnixFD) *dbus.Error {
	log.Printf("fwupd.UpdateMetadata: %q (no-op)", remoteID)
	return nil
}

// dbus::PropertySet::GetAll on path "/" — an empty a{sv} is a valid reply.
type properties struct{}

func (p *properties) GetAll(interfaceName string) (map[string]dbus.Variant, *dbus.Error) {
	return map[string]dbus.Variant{}, nil
}

// -----------------------------------------------------------------------------

type registration struct {
	name  string
	path  dbus.ObjectPath
	iface string
	obj   any
}

func main() {
	log.SetPrefix("[stub-bridge] ")

	regs := []registration{
		// resourced
		{"org.chromium.ResourceManager", "/org/chromium/ResourceManager",
			"org.chromium.ResourceManager", &resourceManager{}},
		// tpm_managerd
		{"org.chromium.TpmManager", "/org/chromium/TpmManager",
			"org.chromium.TpmManager", &tpmManager{}},
		// permission_broker
		{"org.chromium.PermissionBroker", "/org/chromium/PermissionBroker",
			"org.chromium.PermissionBroker", &permissionBroker{}},
		// update_engine
		{"org.chromium.UpdateEngine", "/org/chromium/UpdateEngine",
			"org.chromium.UpdateEngineInterface", &updateEngine{}},
		// typecd
		{"org.chromium.typecd", "/org/chromium/typecd",
			"org.chromium.typecd", &typecd{}},
		// pciguard
		{"org.chromium.pciguard", "/org/chromium/pciguard",
			"org.chromium.pciguard", &pciguard{}},
		// floss media
		{"org.chromium.bluetooth", "/org/chromium/bluetooth/hci0/media",
			"org.chromium.bluetooth.BluetoothMedia", &bluetoothMedia{}},
		// rgbkbd (Ash uses the service name as the interface)
		{"org.chromium.Rgbkbd", "/org/chromium/Rgbkbd",
			"org.chromium.Rgbkbd", &rgbkbd{}},
		// cros-disks
		{"org.chromium.CrosDisks", "/org/chromium/CrosDisks",
			"org.chromium.CrosDisks", &crosDisks{}},
		// biod
		{"org.chromium.BiometricsDaemon", "/org/chromium/BiometricsDaemon/CrosFpBiometricsManager",
			"org.chromium.BiometricsDaemon.BiometricsManager", &biometrics{}},
		// ml-service
		{"org.chromium.MachineLearning", "/org/chromium/MachineLearning",
			"org.chromium.MachineLearning", &machineLearning{}},
		// lorgnette
		{"org.chromium.lorgnette", "/org/chromium/lorgnette/Manager",
			"org.chromium.lorgnette.Manager", &lorgnette{}},
		// upstart job object
		{"com.ubuntu.Upstart", "/com/ubuntu/Upstart/jobs/arc_2dprepare_2dhost_2dgenerated_2ddir",
			"com.ubuntu.Upstart0_6.Job", &upstartJob{}},
		// fwupd
		{"org.freedesktop.fwupd", "/",
			"org.freedesktop.fwupd", &fwupd{}},
		{"org.freedesktop.fwupd", "/",
			"org.freedesktop.DBus.Properties", &properties{}},
	}

	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		log.Fatalf("connect to system bus: %v", err)
	}
	defer conn.Close()

	for _, r := range regs {
		if err := conn.Export(r.obj, r.path, r.iface); err != nil {
			log.Fatalf("export %s (%s at %s): %v", r.name, r.iface, r.path, err)
		}
	}

	owned := map[string]bool{}
	for _, r := range regs {
		if owned[r.name] {
			continue
		}
		owned[r.name] = true
		reply, err := conn.RequestName(r.name, dbus.NameFlagDoNotQueue)
		if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
			log.Fatalf("request name %s: err=%v reply=%v", r.name, err, reply)
		}
		log.Printf("owned %s", r.name)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigCh
	log.Printf("signal %v, exiting", sig)
}
