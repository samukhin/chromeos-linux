// stub-bridge stubs the one-shot D-Bus methods Chrome calls at startup on
// ChromeOS daemons this setup does not run: tpm_managerd, resourced, pci
// guard, plugin VMs, update engine, SMB provider, RGB keyboard, machine
// learning, crosdisks and biod.
//
// Every signature below was read off the binary's client side (the Pop* call
// each On* handler makes on dbus::Response), so the replies decode cleanly and
// Chrome stops logging ServiceUnknown/UnknownMethod for these names. One
// process owns all ten names to keep the extra surface to a single binary.
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	dbus "github.com/godbus/dbus/v5"
)

type stub struct{}

// pciguard.SetExternalPciDevicesPermission(in b allowed) — reply is void; there
// are no hot-pluggable PCIe devices to gate on this setup.
func (s *stub) SetExternalPciDevicesPermission(allowed bool) *dbus.Error {
	log.Printf("pciguard.SetExternalPciDevicesPermission allowed=%v (no-op)", allowed)
	return nil
}

// VmPluginDispatcher.ListVms(in ay request) → ay response — both sides are
// plugin_dispatcher protos; an empty reply parses as an empty VM list.
func (s *stub) ListVms(req []byte) ([]byte, *dbus.Error) {
	log.Printf("VmPluginDispatcher.ListVms (%d-byte request -> empty)", len(req))
	return []byte{}, nil
}

// UpdateEngineInterface.GetStatusAdvanced() → ay (GetStatusAdvancedResponse
// proto). An empty buffer is a valid empty proto and carries no EOL info,
// which is right for this non-managed device.
func (s *stub) GetStatusAdvanced() ([]byte, *dbus.Error) {
	return []byte{}, nil
}

// UpdateEngineInterface.IsFeatureEnabled(in s feature) → b — no update-engine
// features are supported here (OnIsFeatureEnabled reads a PopBool).
func (s *stub) IsFeatureEnabled(feature string) (bool, *dbus.Error) {
	log.Printf("UpdateEngine.IsFeatureEnabled %q -> false", feature)
	return false, nil
}

// SmbProvider.SetupKerberos(in s realm) → b — no Kerberos setup for SMB shares;
// false makes ash::smb_client fall back instead of waiting for a realm.
func (s *stub) SetupKerberos(realm string) (bool, *dbus.Error) {
	log.Printf("SmbProvider.SetupKerberos realm=%q -> false", realm)
	return false, nil
}

// Rgbkbd.GetRgbKeyboardCapabilities() → u capability bitmask
// (RgbKeyboardClientImpl reads PopUint32); 0 = plain keyboard, no RGB.
func (s *stub) GetRgbKeyboardCapabilities() (uint32, *dbus.Error) {
	return 0, nil
}

// MachineLearning.BootstrapMojoConnection(in h platform_channel) → void (the
// response handler is folded with shill's OnVoidMethod). No ML service exists
// to attach the channel to: drop the descriptor we were handed and
// acknowledge, which is what the caller (ServiceConnectionAsh, WARNING-level
// on failure) treats as success.
func (s *stub) BootstrapMojoConnection(fd dbus.UnixFD) *dbus.Error {
	syscall.Close(int(fd))
	log.Printf("MachineLearning.BootstrapMojoConnection fd=%d closed (no ML service)", fd)
	return nil
}

// CrosDisks.EnumerateDevices() → as — no disks to enumerate here; the client
// (OnEnumerateDevices) reads PopArrayOfStrings.
func (s *stub) EnumerateDevices() ([]string, *dbus.Error) {
	log.Printf("CrosDisks.EnumerateDevices -> empty")
	return []string{}, nil
}

// CrosDisks.Mount(in s source, in s mount_path, in as options) — reply is void
// (OnMount only checks that a response arrived); real mount feedback arrives
// via the MountCompleted signal, which never fires for a no-op mount.
func (s *stub) Mount(source, mountPath string, options []string) *dbus.Error {
	log.Printf("CrosDisks.Mount source=%q path=%q options=%v (no-op)", source, mountPath, options)
	return nil
}

// BiometricsDaemon.BiometricsManager.GetRecordsForUser(in s user_id) → ao —
// OnGetRecordsForUser reads PopArrayOfObjectPaths; an empty list means "no
// fingerprints enrolled", which is true here.
func (s *stub) GetRecordsForUser(userID string) ([]dbus.ObjectPath, *dbus.Error) {
	log.Printf("Biometrics.GetRecordsForUser user=%q -> none", userID)
	return []dbus.ObjectPath{}, nil
}

// TpmManager.GetTpmNonsensitiveStatus(in ay request) → ay — both sides are
// tpm_manager protos. An empty buffer parses as a reply with every field at
// its default, so status stays STATUS_SUCCESS(0) instead of the 3 this client
// writes when parsing fails. ash's consumers branch on that field: with 0 they
// stop retrying and the "Failed to get tpm status; status: 3" warnings go away
// with the ServiceUnknown error. There is no TPM here, so there is nothing to
// report — no fabricated fields, just an empty reply.
func (s *stub) GetTpmNonsensitiveStatus(req []byte) ([]byte, *dbus.Error) {
	log.Printf("TpmManager.GetTpmNonsensitiveStatus (%d-byte request -> empty reply)", len(req))
	return []byte{}, nil
}

// ResourceManager.SetMemoryMarginsBps(in u swap_margins_bps, in u
// vmmem_margins_bps) → (out t, out t) — the two uint64s are the margins
// resourced actually applied, in KB; OnMemoryMarginsSet only logs them. Nothing
// is applied here, so both read back as 0 and the call stops failing with
// ServiceUnknown every 30 seconds.
func (s *stub) SetMemoryMarginsBps(swapMarginsBps, vmmemMarginsBps uint32) (uint64, uint64, *dbus.Error) {
	log.Printf("ResourceManager.SetMemoryMarginsBps swap=%d vmmem=%d bps -> 0 KB / 0 KB",
		swapMarginsBps, vmmemMarginsBps)
	return 0, 0, nil
}

type service struct {
	name  string
	path  dbus.ObjectPath
	iface string
}

// Name/path/interface triples taken from the binary's proxy constants and the
// object_path= field of the failing calls in ash.log.
var services = []service{
	{"org.chromium.TpmManager", "/org/chromium/TpmManager", "org.chromium.TpmManager"},
	{"org.chromium.ResourceManager", "/org/chromium/ResourceManager", "org.chromium.ResourceManager"},
	{"org.chromium.pciguard", "/org/chromium/pciguard", "org.chromium.pciguard"},
	{"org.chromium.VmPluginDispatcher", "/org/chromium/VmPluginDispatcher", "org.chromium.VmPluginDispatcher"},
	{"org.chromium.UpdateEngine", "/org/chromium/UpdateEngine", "org.chromium.UpdateEngineInterface"},
	{"org.chromium.SmbProvider", "/org/chromium/SmbProvider", "org.chromium.SmbProvider"},
	{"org.chromium.Rgbkbd", "/org/chromium/Rgbkbd", "org.chromium.Rgbkbd"},
	{"org.chromium.MachineLearning", "/org/chromium/MachineLearning", "org.chromium.MachineLearning"},
	{"org.chromium.CrosDisks", "/org/chromium/CrosDisks", "org.chromium.CrosDisks"},
	{"org.chromium.BiometricsDaemon", "/org/chromium/BiometricsDaemon/CrosFpBiometricsManager", "org.chromium.BiometricsDaemon.BiometricsManager"},
}

func main() {
	log.SetPrefix("[stub-bridge] ")

	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		log.Fatalf("connect to system bus: %v", err)
	}
	defer conn.Close()

	obj := &stub{}
	for _, svc := range services {
		reply, err := conn.RequestName(svc.name, dbus.NameFlagDoNotQueue)
		if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
			log.Fatalf("request name %s: err=%v reply=%v", svc.name, err, reply)
		}
		if err := conn.Export(obj, svc.path, svc.iface); err != nil {
			log.Fatalf("export %s at %s: %v", svc.iface, svc.path, err)
		}
	}
	log.Printf("registered %d services", len(services))

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
}
