// cras-bridge maps Ash audio calls onto PipeWire/PulseAudio.
package main

import (
	"log"
	"os"
	"os/exec"
	"os/signal"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	dbus "github.com/godbus/dbus/v5"
)

const (
	crasService = "org.chromium.cras"
	crasPath    = dbus.ObjectPath("/org/chromium/cras")
	crasIface   = "org.chromium.cras.Control"
)

// Node IDs are fixed by the fake node list below. Chrome picks the headphone
// node as the active output on startup and tells us about it with
// SetActiveOutputNode; we must remember that choice, because the signal we
// emit later has to name the same node — otherwise Chrome logs
// "Active output node changed unexpectedly".
const (
	speakerNodeID   uint64 = 0x0001_0000_0001
	headphoneNodeID uint64 = 0x0002_0000_0001
	micNodeID       uint64 = 0x0001_0000_0002
	audioNodeCount         = 3
)

type audioState struct {
	volume       int32
	outputMuted  bool
	inputGain    int32
	inputMuted   bool
	activeOutput uint64
	activeInput  uint64
	// Whether Chrome has actually told us its choice. The 5-second
	// "initial" signal must not announce a default we merely guessed:
	// after a bridge restart Chrome keeps its own active node, and
	// contradicting it produces the very warning this code avoids.
	outputSet bool
	inputSet  bool
}

type crasControl struct {
	conn *dbus.Conn
	mu   sync.RWMutex
	st   audioState
}

func (c *crasControl) GetVolumeState() (int32, bool, int32, bool, bool, *dbus.Error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.st.volume, false, c.st.inputGain, c.st.inputMuted, c.st.outputMuted, nil
}

func (c *crasControl) SetActiveOutputNode(nodeID uint64) *dbus.Error {
	log.Printf("SetActiveOutputNode: 0x%x", nodeID)
	c.mu.Lock()
	changed := c.st.activeOutput != nodeID
	c.st.activeOutput = nodeID
	c.st.outputSet = true
	c.mu.Unlock()
	if changed {
		c.conn.Emit(crasPath, crasIface+".ActiveOutputNodeChanged", nodeID)
	}
	return nil
}

func (c *crasControl) SetActiveInputNode(nodeID uint64) *dbus.Error {
	log.Printf("SetActiveInputNode: 0x%x", nodeID)
	c.mu.Lock()
	changed := c.st.activeInput != nodeID
	c.st.activeInput = nodeID
	c.st.inputSet = true
	c.mu.Unlock()
	if changed {
		c.conn.Emit(crasPath, crasIface+".ActiveInputNodeChanged", nodeID)
	}
	return nil
}

func (c *crasControl) SetOutputNodeVolume(nodeID uint64, volume int32) *dbus.Error {
	log.Printf("SetOutputNodeVolume: node=0x%x volume=%d", nodeID, volume)
	if volume < 0 {
		volume = 0
	}
	if volume > 100 {
		volume = 100
	}
	c.mu.Lock()
	c.st.volume = volume
	c.mu.Unlock()
	pactl("set-sink-volume", "@DEFAULT_SINK@", strconv.Itoa(int(volume))+"%")
	return nil
}

func (c *crasControl) SetOutputVolume(volume int32) *dbus.Error {
	if volume < 0 {
		volume = 0
	}
	if volume > 100 {
		volume = 100
	}
	log.Printf("SetOutputVolume: %d", volume)
	c.mu.Lock()
	c.st.volume = volume
	c.mu.Unlock()
	pactl("set-sink-volume", "@DEFAULT_SINK@", strconv.Itoa(int(volume))+"%")
	return nil
}

func (c *crasControl) SetOutputUserMute(muted bool) *dbus.Error {
	log.Printf("SetOutputUserMute: %v", muted)
	c.mu.Lock()
	c.st.outputMuted = muted
	c.mu.Unlock()
	v := "0"
	if muted {
		v = "1"
	}
	pactl("set-sink-mute", "@DEFAULT_SINK@", v)
	return nil
}

func (c *crasControl) SetInputMute(muted bool) *dbus.Error {
	log.Printf("SetInputMute: %v", muted)
	c.mu.Lock()
	c.st.inputMuted = muted
	c.mu.Unlock()
	v := "0"
	if muted {
		v = "1"
	}
	pactl("set-source-mute", "@DEFAULT_SOURCE@", v)
	return nil
}

func (c *crasControl) SetInputNodeGain(nodeID uint64, gain int32) *dbus.Error {
	log.Printf("SetInputNodeGain: node=0x%x gain=%d", nodeID, gain)
	c.mu.Lock()
	c.st.inputGain = gain
	c.mu.Unlock()
	return nil
}

func (c *crasControl) SwapLeftRight(nodeID uint64, swap bool) *dbus.Error {
	return nil
}

// SetDisplayRotation(node_id, rotation) — audio routing does not depend on the
// display orientation here; accept the call so CrasAudioHandler stops logging
// UnknownMethod.
func (c *crasControl) SetDisplayRotation(nodeID uint64, rotation uint32) *dbus.Error {
	log.Printf("SetDisplayRotation: node=%d rotation=%d (no-op)", nodeID, rotation)
	return nil
}

// Media-player state Ash forwards to CRAS for hardware offload (D-Bus
// signatures confirmed from the binary: SetPlayerPlaybackStatus(s),
// SetPlayerIdentity(s), SetPlayerMetadata(a{sv})). There is no player
// attached to CRAS on this setup, so the calls are accepted and logged;
// without them the UnknownMethod reply reaches CrasAudioClientImpl and gets
// logged as ERROR on every media-session change.
func (c *crasControl) SetPlayerPlaybackStatus(status string) *dbus.Error {
	log.Printf("SetPlayerPlaybackStatus: %q (no-op)", status)
	return nil
}

func (c *crasControl) SetPlayerIdentity(identity string) *dbus.Error {
	log.Printf("SetPlayerIdentity: %q (no-op)", identity)
	return nil
}

func (c *crasControl) SetPlayerMetadata(metadata map[string]dbus.Variant) *dbus.Error {
	log.Printf("SetPlayerMetadata: %v (no-op)", metadata)
	return nil
}

// GetDeprioritizeBtWbsMic — there is no Bluetooth here, so the WBS mic is
// never deprioritized; answering false (retrieved as PopBool) gives
// CrasAudioHandler::HandleGetDeprioritizeBtWbsMic a definite value instead of
// the "Failed to retrieve WBS mic deprioritized flag" ERROR it logs when the
// call fails. Refreshed about once a minute.
func (c *crasControl) GetDeprioritizeBtWbsMic() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetDefaultOutputBufferSize() (int32, *dbus.Error) {
	return 512, nil
}

func (c *crasControl) GetNumberOfActiveOutputStreams() (int32, *dbus.Error) {
	out, err := exec.Command("pactl", "list", "sink-inputs", "short").Output()
	if err != nil {
		return 0, nil
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return 0, nil
	}
	return int32(len(lines)), nil
}

func (c *crasControl) GetNumberOfArcStreams() (int32, *dbus.Error) {
	return 0, nil
}

func (c *crasControl) GetNumberOfInputStreamsWithPermission() ([]map[string]dbus.Variant, *dbus.Error) {
	return nil, nil
}

func (c *crasControl) GetNumberOfNonChromeOutputStreams() (int32, *dbus.Error) {
	return 0, nil
}

func (c *crasControl) GetNumStreamIgnoreUiGains() (int32, *dbus.Error) {
	return 0, nil
}

func (c *crasControl) GetSidetoneSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetSystemAecGroupId() (int32, *dbus.Error) {
	return -1, nil
}

func (c *crasControl) GetSystemAecSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetSystemAgcSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetSystemNsSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) IsSpatialAudioSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) IsHfpMicSrSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) IsNoiseCancellationSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetAudioEffectDlcs() (string, *dbus.Error) {
	return "", nil
}

func (c *crasControl) IsStyleTransferSupported() (bool, *dbus.Error) {
	return false, nil
}

func (c *crasControl) GetVoiceIsolationUIAppearance() (uint32, uint32, bool, *dbus.Error) {
	return 0, 0, false, nil
}

func (c *crasControl) SetSpatialAudio(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetFlossEnabled(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetFixA2dpPacketSize(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetForceRespectUiGains(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetEwmaPowerReportEnabled(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetKrispNoiseCancellationEnabled(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetSidetoneEnabled(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetSpeakOnMuteDetection(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetVoiceIsolationUIEnabled(enabled bool) *dbus.Error {
	return nil
}

func (c *crasControl) SetVoiceIsolationUIPreferredEffect(effect uint32) *dbus.Error {
	return nil
}

func pactl(args ...string) {
	if err := exec.Command("pactl", args...).Run(); err != nil {
		log.Printf("pactl %v: %v", args, err)
	}
}

func pactlVolume() (vol int32, muted bool, ok bool) {
	out, err := exec.Command("pactl", "get-sink-volume", "@DEFAULT_SINK@").Output()
	if err != nil {
		return 0, false, false
	}
	// "Volume: front-left: 49152 /  75% / -8.00 dB, ..."
	s := string(out)
	parts := strings.SplitN(s, "%", 2)
	if len(parts) < 2 {
		return 0, false, false
	}
	fields := strings.Fields(parts[0])
	if len(fields) == 0 {
		return 0, false, false
	}
	n, err := strconv.ParseInt(fields[len(fields)-1], 10, 32)
	if err != nil {
		return 0, false, false
	}

	muteOut, err := exec.Command("pactl", "get-sink-mute", "@DEFAULT_SINK@").Output()
	if err == nil {
		muted = strings.Contains(string(muteOut), "yes")
	}
	return int32(n), muted, true
}

func makeNode(id uint64, isInput bool, nodeType, name, deviceName string, active bool, nodeVolume uint64) map[string]dbus.Variant {
	channels := uint32(2)
	if isInput {
		channels = 1
	}
	return map[string]dbus.Variant{
		"IsInput":              dbus.MakeVariant(isInput),
		"Id":                   dbus.MakeVariant(id),
		"StableDeviceId":       dbus.MakeVariant(id >> 32),
		"StableDeviceIdNew":    dbus.MakeVariant(id),
		"Type":                 dbus.MakeVariant(nodeType),
		"Name":                 dbus.MakeVariant(name),
		"DeviceName":           dbus.MakeVariant(deviceName),
		"Active":               dbus.MakeVariant(active),
		"PluggedTime":          dbus.MakeVariant(uint64(0)),
		"NodeVolume":           dbus.MakeVariant(nodeVolume),
		"InputNodeGain":        dbus.MakeVariant(uint64(50)),
		"MaxSupportedChannels": dbus.MakeVariant(channels),
		"AudioEffect":          dbus.MakeVariant(uint32(0)),
		"NumberOfVolumeSteps":  dbus.MakeVariant(int32(25)),
	}
}

// nodes returns the node list with the Active flag matching the node Chrome
// selected via SetActiveOutputNode/SetActiveInputNode.
func (c *crasControl) nodes() []map[string]dbus.Variant {
	c.mu.RLock()
	activeOut, activeIn := c.st.activeOutput, c.st.activeInput
	c.mu.RUnlock()
	return []map[string]dbus.Variant{
		makeNode(speakerNodeID, false, "INTERNAL_SPEAKER", "Speaker", "Internal Speaker", activeOut == speakerNodeID, 100),
		makeNode(headphoneNodeID, false, "HEADPHONE", "Headphone", "Headphone Jack", activeOut == headphoneNodeID, 100),
		makeNode(micNodeID, true, "INTERNAL_MIC", "Internal Mic", "Internal Microphone", activeIn == micNodeID, 50),
	}
}

func makeGetNodesHandler(ctrl *crasControl) any {
	const n = audioNodeCount

	outTypes := make([]reflect.Type, n+1)
	mapType := reflect.TypeOf(map[string]dbus.Variant(nil))
	for i := range n {
		outTypes[i] = mapType
	}
	outTypes[n] = reflect.TypeOf((*dbus.Error)(nil))

	funcType := reflect.FuncOf(nil, outTypes, false)

	return reflect.MakeFunc(funcType, func(args []reflect.Value) []reflect.Value {
		nodes := ctrl.nodes()
		log.Printf("GetNodes called (reflect), returning %d nodes", len(nodes))
		results := make([]reflect.Value, n+1)
		for i := range n {
			results[i] = reflect.ValueOf(nodes[i])
		}
		results[n] = reflect.Zero(reflect.TypeOf((*dbus.Error)(nil)))
		return results
	}).Interface()
}

func crasMethods(ctrl *crasControl) map[string]any {
	methods := make(map[string]any)
	val := reflect.ValueOf(ctrl)
	typ := val.Type()
	errType := reflect.TypeOf((*dbus.Error)(nil))
	for i := 0; i < typ.NumMethod(); i++ {
		name := typ.Method(i).Name
		if name == "GetNodes" {
			continue
		}
		method := val.Method(i)
		t := method.Type()
		if t.NumOut() == 0 || t.Out(t.NumOut()-1) != errType || typ.Method(i).PkgPath != "" {
			continue
		}
		methods[name] = method.Interface()
	}
	return methods
}

func main() {
	log.SetPrefix("[cras-bridge] ")

	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		log.Fatalf("connect to system bus: %v", err)
	}
	defer conn.Close()

	st := audioState{
		volume:       75,
		inputGain:    50,
		activeOutput: speakerNodeID,
		activeInput:  micNodeID,
	}
	if vol, muted, ok := pactlVolume(); ok {
		st.volume = vol
		st.outputMuted = muted
		log.Printf("initial volume: %d%% muted=%v", vol, muted)
	} else {
		log.Println("PulseAudio/PipeWire not available — using default volume 75%")
	}

	ctrl := &crasControl{conn: conn, st: st}
	methods := crasMethods(ctrl)
	methods["GetNodes"] = makeGetNodesHandler(ctrl)
	if err := conn.ExportMethodTable(methods, crasPath, crasIface); err != nil {
		log.Fatalf("export methods: %v", err)
	}

	reply, err := conn.RequestName(crasService, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("request name %s: err=%v reply=%v", crasService, err, reply)
	}

	log.Printf("registered %s", crasService)

	go func() {
		lastVol := int32(-1)
		lastMute := false
		for range time.Tick(3 * time.Second) {
			vol, muted, ok := pactlVolume()
			if !ok {
				continue
			}
			volChanged := vol != lastVol
			muteChanged := muted != lastMute
			if !volChanged && !muteChanged {
				continue
			}
			ctrl.mu.Lock()
			ctrl.st.volume = vol
			ctrl.st.outputMuted = muted
			ctrl.mu.Unlock()
			lastVol, lastMute = vol, muted
			if volChanged {
				conn.Emit(crasPath, crasIface+".OutputVolumeChanged", vol)
			}
			if muteChanged {
				conn.Emit(crasPath, crasIface+".OutputMuteChanged", muted)
			}
		}
	}()

	go func() {
		time.Sleep(5 * time.Second)
		ctrl.mu.RLock()
		activeOutput, activeInput := ctrl.st.activeOutput, ctrl.st.activeInput
		outputSet, inputSet := ctrl.st.outputSet, ctrl.st.inputSet
		ctrl.mu.RUnlock()
		log.Printf("Emitting NodesChanged signal (active output=0x%x set=%v input=0x%x set=%v)",
			activeOutput, outputSet, activeInput, inputSet)
		conn.Emit(crasPath, crasIface+".NodesChanged")
		if outputSet {
			conn.Emit(crasPath, crasIface+".ActiveOutputNodeChanged", activeOutput)
		}
		if inputSet {
			conn.Emit(crasPath, crasIface+".ActiveInputNodeChanged", activeInput)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
}
